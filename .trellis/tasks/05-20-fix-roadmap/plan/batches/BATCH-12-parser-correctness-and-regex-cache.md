# BATCH-12: parser 正确性 + regex/cache（章节解析路径）

**Stage**: P1
**Slug**: `parser-correctness-and-regex-cache`
**Effort**: M (≤500 行)
**Depends on**: none

## 1. 范围

集中修 core-source/parser 6 条正确性 + 性能问题：apply_format_js 双跑、resolve_image_src_headers regex 兼容/未缓存、Empty 错误分支信息丢失、多页 toc 子页失败 chapter_offset 错位、next_urls 队列无去重无上限、循环内 unwrap regex。

## 2. 包含的 findings

- [F-W1B-017] apply_format_js 每章 eval 两次（gInt 副作用错位） — `core/core-source/src/parser.rs:1162-1178, 1866`
- [F-W1B-018] resolve_image_src_headers regex 不支持单引号 + 未缓存 — `core/core-source/src/parser.rs:1979-2009`
- [F-W1B-019] 章节为空时 final_next_chapter_url 链路异常 — `core/core-source/src/parser.rs:1538-1542`
- [F-W1B-020] 多页目录拉取失败时 chapter_offset 已累加 — `core/core-source/src/parser.rs:1043-1153`
- [F-W1B-021] 多页 toc next_urls 队列无去重无上限 — `core/core-source/src/parser.rs:1145-1152`
- [F-W1B-022] resolve_image_src_headers regex 在循环内 unwrap — `core/core-source/src/parser.rs:1980`

## 3. 影响文件

- `core/core-source/src/parser.rs:1162-1178` — `apply_format_js` 改用闭包 `(function(){var gInt=...; var title=(${format_js})(); return [title, gInt];})()` 一次返回两值
- `core/core-source/src/parser.rs:1979-2009` — `resolve_image_src_headers` 改用 scraper 解析 + 重写 src，或 regex 支持单引号；regex 用 `LazyLock` 缓存
- `core/core-source/src/parser.rs:1538-1542` — content empty 但 next_chapter_url 非空时返回 Ok 占位章节让 UI 决定
- `core/core-source/src/parser.rs:1043-1153` — 在 ChapterInfo 加 placeholder，或 Result 带 partial flag；`tracing::warn!` 升级
- `core/core-source/src/parser.rs:1145-1152` — `url_queue` 用 HashSet 去重 + push 前比对长度
- `core/core-source/src/parser.rs:1980` — `static IMG_RE: LazyLock<Regex> = LazyLock::new(...)`

## 4. 修复方向

直接复用 master findings-rust-logic.md 中各条"建议"段落。

## 5. 测试策略

- Rust unit test：含 gInt 副作用的 format_js 在双跑场景下 +1 而非 +2
- Rust unit test：含单引号属性 / data-src 优先的 HTML 被 resolve_image_src_headers 正确处理
- Rust unit test：empty 章节 + next_url 不空时返回 Ok 占位
- Rust unit test：100 章书第 50 章拉超时，剩余章节有 placeholder + warn
- Rust unit test：next_urls 含 100 条同 URL，url_queue 不爆炸

## 6. 验收

- [ ] master finding F-W1B-017/018/019/020/021/022 全部消解
- [ ] 现有 sy/*.json 书源测试集回归通过

## 7. implement.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-logic.md", "reason": "本批次涉及的 wave 1B findings"}
{"file": "core/core-source/src/parser.rs", "reason": "parser 主体"}
{"file": "core/core-source/src/types.rs", "reason": "ChapterInfo 新增 placeholder / partial 字段"}
```

## 8. check.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md", "reason": "master report"}
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-logic.md", "reason": "Wave 1B"}
{"file": ".trellis/tasks/05-20-fix-roadmap/plan/batches/BATCH-12-parser-correctness-and-regex-cache.md", "reason": "本批次自身验收清单"}
```
