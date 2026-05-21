# BATCH-12: parser correctness + LazyLock regex + toc dedup

## Goal

5 条 P1 finding 保守补丁 + 1 条 warn 升级，全部命中 `core/core-source/src/parser.rs`、`core/core-source/src/utils.rs`、`core/core-parser/src/cleaner.rs` 三个文件：

- **F-W1B-017**：`apply_format_js` 双 eval bug（gInt 副作用被 double-applied + 2× QuickJS Runtime 创建）
- **F-W1B-018**：`resolve_image_src_headers` regex 不支持单引号 + 属性顺序
- **F-W1B-020**：toc 多页 `url_queue` 没去重 + 没上限保护
- **F-W1B-022**：`resolve_image_src_headers` regex 每次重编译（LazyLock）
- **F-W1B-065 / F-W1B-071**：utils.rs / cleaner.rs 内联 regex 改 LazyLock
- **F-W1B-019**：仅在 `ParserError::Empty` 触发处加 warn 记录 next_chapter_url（不动 ParserError 结构）

## What I already know

### 三个文件现状（grep + read 已确认）

#### F-W1B-017 — `parser.rs:1850-1898`

```rust
// 当前 buggy 流程：
let wrapped_script = format!("var gInt = {};\n{}\n", g_int, format_js);
runtime.eval(&wrapped_script, &vars);   // 第 1 次 eval：跑 format_js 修改 chapter.title
// ...
let g_int_script = format!("var gInt = {};\n{};\ngInt", g_int, format_js);
runtime.eval(&g_int_script, &vars);     // 第 2 次 eval：又跑一遍 format_js 提取 gInt
```

副作用 bug：第 2 次 eval 把 `format_js` 整段重新跑了，如 formatJs 里有 `gInt++` 副作用，gInt 会被 +2 而非 +1。

修：用 IIFE 一次返回两个值：

```rust
let combined_script = format!(
    "(function() {{\n  var gInt = {};\n  var __r = (function() {{ {} }})();\n  return [__r, gInt];\n}})()",
    g_int, format_js
);
match runtime.eval(&combined_script, &vars) {
    Ok(LegadoValue::Array(arr)) if arr.len() >= 2 => {
        let new_title = arr[0].as_string_lossy();
        if !new_title.is_empty() { chapter.title = new_title; }
        if let LegadoValue::Int(v) = &arr[1] {
            g_int = *v;
        } else if let Ok(v) = arr[1].as_string_lossy().parse::<i64>() {
            g_int = v;
        }
    }
    Ok(other) => warn!("formatJs 返回值不是 [title, gInt] 数组: {:?}", other),
    Err(e) => warn!("formatJs 执行失败 (chapter {}): {}", idx + 1, e),
}
```

但是！要先确认 `format_js` 本身往往不是表达式而是一段语句（多个 `;`）。原代码 `var gInt = ...; format_js`——format_js 末尾的"返回值"其实是隐式："最后一条语句的求值结果"。把它包进 `(function(){{ {format_js} }})()` 时，需要在 format_js 末尾自动 `return ...;`——这是难点。

**更安全的修法**：**只把"提取 gInt"那次 eval 改成只读 gInt**（不再 eval format_js），把 format_js 与 gInt 提取拆成两步——第 1 步 eval format_js，第 2 步 eval `gInt`（仅引用变量，不重跑）。问题是 vars 没传 gInt 写回，第 2 步 eval 看不到第 1 步修改的 gInt。

**最稳路径**：改成把 format_js 包装成 IIFE 但用 `eval(format_js)` 形式：

```rust
let combined_script = format!(
    r#"(function(){{ var gInt={}; var result=eval({}); return [result, gInt]; }})()"#,
    g_int,
    serde_json::to_string(format_js).unwrap_or_else(|_| "\"\"".to_string()),
);
```

`eval(<string>)` 让 format_js 走 ECMAScript eval 语义，最后一条 expression 自动是返回值。

不过这还是要 caller 端 LegadoValue 支持 Array 解构。看 LegadoValue 是否支持：

#### F-W1B-018 / F-W1B-022 — `parser.rs:1979-2009`

```rust
fn resolve_image_src_headers(content: &str, base_url: &str) -> String {
    let img_re = regex::Regex::new(r#"<img\s+[^>]*src="([^"]*)"[^>]*>"#).unwrap();
    img_re.replace_all(content, |caps| { ... })
}
```

- **F-W1B-022 修**：regex 提到 `static IMG_RE: LazyLock<Regex> = ...`
- **F-W1B-018 修**：扩 regex 支持单引号 + 属性顺序

```rust
static IMG_RE: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
    // 支持双引号 / 单引号；src 可能在任意属性位置。
    regex::Regex::new(r#"<img\b[^>]*?\bsrc=(?:"([^"]*)"|'([^']*)')[^>]*>"#).unwrap()
});
```

caps.get(1) 或 caps.get(2)，二者其一为 Some——逻辑改造小。

#### F-W1B-020 — `parser.rs:1145-1152`

```rust
for next in next_urls {
    if !next.trim().is_empty() {
        let full_url = crate::utils::build_full_url(&url, &next);
        if !full_url.is_empty() && !seen_urls.contains(&full_url) {
            url_queue.push_back(full_url);
        }
    }
}
```

`url_queue: VecDeque<String>` 在 push 时只检查 seen_urls 不检查自身已含——同一 next_rule 解析返回多次相同 url 会重复 push。

修：dedup with HashSet local check + 加 push 上限：

```rust
const MAX_QUEUE_SIZE: usize = MAX_TOC_PAGES * 4; // 容许有 4× 缓冲，远超正常书源
for next in next_urls {
    if next.trim().is_empty() { continue; }
    let full_url = crate::utils::build_full_url(&url, &next);
    if full_url.is_empty() || seen_urls.contains(&full_url) { continue; }
    if url_queue.contains(&full_url) { continue; }  // ← F-W1B-020 dedup
    if url_queue.len() >= MAX_QUEUE_SIZE {
        warn!("toc url_queue 达到上限 {} 拒绝新 push: {}", MAX_QUEUE_SIZE, full_url);
        break;
    }
    url_queue.push_back(full_url);
}
```

这条 finding 在 parser.rs 里实际**有两处**类似 push 循环（L1145-1152 与 L1528-1533）。我们要改两处。

#### F-W1B-065 — `utils.rs:96-100`

```rust
pub fn clean_html_fragment(html: &str) -> String {
    let re = regex::Regex::new(r"\s+").unwrap();
    re.replace_all(html, " ").trim().to_string()
}
```

简单改 LazyLock。

#### F-W1B-071 — `cleaner.rs:107-117`

```rust
if self.config.remove_empty_lines {
    let re = Regex::new(r"\n\s*\n\s*\n").unwrap();
    text = re.replace_all(&text, "\n\n").to_string();
}
if self.config.collapse_whitespace {
    let re = Regex::new(r"[ \t]+").unwrap();
    text = re.replace_all(&text, " ").to_string();
}
```

两处改 LazyLock。

#### F-W1B-019 — `parser.rs:1538-1542`

仅在 `Err(ParserError::Empty)` 之前 warn 一行带 final_next_chapter_url 的上下文。不改 ParserError 结构，不改 caller 行为。完整跨层重构（让 UI 跳读）留 follow-up。

## Open Questions

（已收敛 — 用户选保守五补丁 + warn）

## Requirements (final)

### MVP scope（6 项）

1. **F-W1B-017**：`apply_format_js` 改用 IIFE + `eval(format_js)` 一次返回 `[title, gInt]` 数组，避免 double-eval 副作用。需先验证 LegadoValue 支持 Array。
2. **F-W1B-018 + F-W1B-022 合并**：`resolve_image_src_headers` 抽 `IMG_RE: LazyLock<Regex>`，扩 pattern 支持单/双引号 src。
3. **F-W1B-020**：parser.rs 两处 toc url push 都加 in-queue dedup + queue size cap (`MAX_TOC_PAGES * 4`)。
4. **F-W1B-065**：`utils.rs::clean_html_fragment` regex 改 LazyLock。
5. **F-W1B-071**：`cleaner.rs::clean()` 两处 inline regex 改 LazyLock。
6. **F-W1B-019**：`parser.rs::content_path` 在 `return Err(ParserError::Empty)` 前加 `warn!` 带 final_next_chapter_url。
7. 至少 4 个新单测：
   - `test_resolve_image_src_handles_single_quote` — 单引号 src 也能被 resolve
   - `test_resolve_image_src_uses_lazylock_regex` — 调多次不重复编译（粗略：调 2 次都 Ok 即过）
   - `test_toc_url_queue_dedupes_within_push` — 同 next_rule 返回重复 url 不重复进队
   - `test_toc_url_queue_caps_when_overflow` — 模拟 next_rule 返回大批 unique urls 触发 cap warn
   - 可选：`test_apply_format_js_g_int_increment_once` — gInt++ 应只 +1 不 +2

### 不在范围

- F-W1B-019 完整跨层改造（ParserError::Empty 扩结构 + caller 处理 + UI 跳读）
- 完整 HTML parser 替代 regex-based image src 处理（候选项之一）
- core-parser cleaner.rs 测试新增（已有 5 测覆盖关键路径）
- 其它 W1B P2/P3 finding（cleaner debug bytes / java_log / xpath helper 重复）

## Acceptance Criteria

- [ ] `parser.rs` 含 `static IMG_RE: LazyLock<Regex>` 一处，函数体不再 `Regex::new`
- [ ] IMG_RE 模式支持单引号 / 双引号
- [ ] `apply_format_js` 不再有第二次 `let g_int_script = format!("var gInt = {};\n{};\ngInt", ...)` 重 eval format_js
- [ ] `parser.rs` 两处 next URL push 循环都含 `url_queue.contains(&full_url)` 检查 + size cap
- [ ] `parser.rs` `Err(ParserError::Empty)` 之前 warn 含 next_chapter_url
- [ ] `utils.rs::clean_html_fragment` 用 LazyLock
- [ ] `cleaner.rs::clean()` 用 LazyLock
- [ ] grep `Regex::new` 在 `core/core-parser/src/cleaner.rs` `core/core-source/src/utils.rs` 函数体内 0 命中（仅 LazyLock 闭包内 OK）
- [ ] `cargo build --workspace` 0 warning 0 error
- [ ] `cargo test --workspace --lib` 全绿（基线 361 + 新 4-5 ≈ 365-366）
- [ ] master report `findings-rust-logic.md` F-W1B-017/018/019/020/022/065/071 标 Resolution
- [ ] master report 主索引同步

## Definition of Done

- 5 项 P1 全做完 + 1 条 warn 升级 + 4-5 单测 + cargo build/test 全绿
- F-W1B-017/018/019/020/022/065/071 七条 finding 闭环（其中 019 缩范围仅 warn）

## Decision (ADR-lite)

**Context**: BATCH-17 后选 BATCH-12 quick win。6+1 条 P1/P3 finding 命中 3 个文件，性质相近（regex / dedup / 性能）；唯一非平凡的 F-W1B-017 用 IIFE+eval() 收敛。F-W1B-019 完整改造涉及跨层 UI 工作，留 follow-up。

**Decision**: 保守五补丁 + warn — 全做 LazyLock + dedup + image regex + apply_format_js 修 bug，F-W1B-019 仅 warn 升级。

**Consequences**:
- 净 ~100-180 行 + 4-5 单测，0 新依赖
- F-W1B-017 修复 gInt 副作用 bug（用户读章节标题不再被错误 +2）
- 7 条 finding 闭环（含 2 P3 顺手扫尾）
- regex 编译 hot path 一次性优化，章节切换不再每次毫秒级编译
- toc url_queue 攻击书源场景安全收敛

## Technical Notes

### 风险点

- **F-W1B-017 IIFE 内 eval(format_js)**：QuickJS 支持 `eval()` 是默认行为；rquickjs 没禁用。format_js 末尾的 expression 会成为 `eval()` 的返回值。但若 format_js 是多 statement，最后一条不是 expression（如 `var x = 1;`），eval 返回 undefined，结果 `[undefined, gInt]`。caller 端要检查 result.as_string_lossy() 是否为 `"undefined"` 或空串再决定是否更新 title。当前代码已有"if !new_title.is_empty()"保护——这层保护会兼容 undefined → "" → 不修改 title。
- **LegadoValue::Array 支持**：本批前先 grep 确认；若 LegadoValue 没 Array 变体，方案降级为"返回 JSON 字符串然后 parse"。
- **F-W1B-020 dedup 的 O(n) `contains`**：url_queue.contains 是 O(n)，但 MAX_TOC_PAGES = 50 → MAX_QUEUE_SIZE = 200，O(n) 可接受。改 HashSet 镜像会需要双结构，复杂度 / 维护性不划算。
- **F-W1B-018 单引号 regex**：用 `(?:"([^"]*)"|'([^']*)')` 双 capture group，caps.get(1).or(caps.get(2))。实现稍微调整 closure 逻辑。

### 实施顺序

1. 先改 LazyLock 三处（utils.rs / cleaner.rs 两处 / parser.rs IMG_RE）—— 最低风险，先建 baseline。
2. 改 image regex 支持单引号 + 修 closure 逻辑（依赖第 1 步）。
3. F-W1B-020 toc url_queue dedup + cap（独立改动）。
4. F-W1B-019 warn 升级（独立 1 行）。
5. F-W1B-017 apply_format_js IIFE 改造（最复杂，最后做避免影响前面测试）。
6. 加 4-5 新单测。
7. cargo test --workspace --lib 全过。
8. master report 更新。

### 测试 case 设计

```rust
#[test]
fn test_resolve_image_src_handles_single_quote() {
    let html = r#"<img alt='x' src='/p/img.jpg'>"#;
    let resolved = resolve_image_src_headers(html, "https://example.com/book");
    assert!(resolved.contains("https://example.com/p/img.jpg"));
}

#[test]
fn test_resolve_image_src_double_quote_still_works() {
    let html = r#"<img src="/p/img.jpg" alt="x">"#;
    let resolved = resolve_image_src_headers(html, "https://example.com/book");
    assert!(resolved.contains("https://example.com/p/img.jpg"));
}

#[test]
fn test_toc_url_queue_dedupes_within_push() {
    // 模拟 next_rule 返回 ["page2", "page2"] (重复)
    // 预期 url_queue.len() 推前 1 次 push 后只 +1，不是 +2
    // ...
}

#[test]
fn test_apply_format_js_g_int_increment_once() {
    // formatJs = "result; gInt++"，初始 gInt=0
    // 跑一次 apply_format_js for one chapter
    // 期待 g_int 最终为 1（不是 2）
}
```

## Research References

- 路线图 BATCH-12：`.trellis/tasks/archive/2026-05/05-20-fix-roadmap/plan/roadmap.md:24` — `parser correctness | 6 | M | none`
- F-W1B-017/018/019/020/022 master：`findings-rust-logic.md:241-308`
- F-W1B-065/071 master：`findings-rust-logic.md:825,897`
- BATCH-17 archive：`.trellis/tasks/archive/2026-05/05-21-batch-17-core-net-cookie-webdav/`
