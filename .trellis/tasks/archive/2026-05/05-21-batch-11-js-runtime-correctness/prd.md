# BATCH-11: JS runtime correctness（5 条 P1 finding）

> Roadmap：`.trellis/tasks/archive/2026-05/05-20-fix-roadmap/plan/batches/BATCH-11-js-runtime-correctness-fixes.md`
> Master report：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-logic.md`

## Goal

修 5 条 P1 QuickJS runtime correctness finding，全部在 `core/core-source/src/legado/js_runtime.rs` 一个文件内（少量 `utils.rs` 调用）。**不**做 Runtime pool 化（属 BATCH-13），**不**改 LegadoValue 类型定义。

## Findings 落点

### F-W1B-011 — `java.put` 跨阶段失效

**位置**：`js_runtime.rs:2185`（PREAMBLE 中的 `put: function(key, value) { this._vars[String(key)] = value; ... }`）
**当前**：`java.put` 只写 JS 端 `this._vars`，每次 `eval()` 都 new Runtime + Context，`_vars` 是 `__legado_variables__` 的副本——下次 eval 拿不到这次 put 的值。Legado 真实书源大量依赖 `java.put('cookie', ...)` 在 search→content 阶段传递状态，本实现这一路完全失效。
**Infrastructure**：thread_local `LEGADO_JS_VARIABLES` (line 19) + helper `set_current_js_variable(key, value)` (line 1089) 已经存在；`build_runtime_vars` (line 69) 在每次 eval 进入时读 thread_local 当作 vars。
**方案**：新增 `__legado_js_put(key, value) -> String` bridge：直接调 `set_current_js_variable(key, LegadoValue::String(value))`；PREAMBLE `java.put` 改成 `function(key, value) { var v = String(value); this._vars[String(key)] = v; __legado_js_put(String(key), v); return v; }` —— write-through 到 thread_local。
**收益**：search→content 阶段 java.put('token', ...) 在第二次 eval 仍能 java.get 拿到。

### F-W1B-012 — `JSON.stringify(undefined)` / 非 JSON-safe 序列化丢失

**位置**：`js_runtime.rs:323-325, 387`
**当前**：`format!("JSON.stringify(({}))", expression)` — 对 `function(){}` 类对象返回 `undefined` string；对有 toString 但非 JSON-safe wrapper（如 `java._wrapElement` 返回的对象）序列化为空对象 `{}`。
**方案（保守 A）**：**只给 `java._wrapElement` 加 `toJSON: function() { return this.text(); }`**——让 wrapper 在 stringify 时自然返回字符串。**不**改全局 stringify wrapper，避免改变所有 eval 输出路径行为。
**理由**：finding 描述的核心症状是 `wrapElement` 序列化空对象。其它"返回 function / 奇怪对象"场景属于书源作者错误，不应在框架层兜底。
**收益**：覆盖 finding 提到的"wrapper 误用"主场景；不引入全局行为变化。

### F-W1B-014 — HashMap Map 序列化键序不稳

**位置**：`js_runtime.rs:470-475`
**当前**：`for (key, value) in map` 直接遍历 `&HashMap<String, LegadoValue>`，每次 eval 顺序不同 — `Object.keys(book)[0]` 不稳定。
**方案**：在 `legado_value_to_js_expr` 内 `let mut keys: Vec<&String> = map.keys().collect(); keys.sort();` 然后按排序后顺序生成对象字面量。**不**改 `LegadoValue::Map(HashMap)` 类型定义——只是输出端排序。
**收益**：`for (var k in obj)` / `Object.keys(obj)` 顺序稳定 + 单测可重复。

### F-W1B-015 — `_resolveUrl` JS vs Rust 不一致

**位置**：`js_runtime.rs:2255-2268`（PREAMBLE 中的 `_resolveUrl: function(value, base) { ... }`）
**当前**：JS 手写实现，对 IPv6 / `//host/path` 兜底 https / `?query`、`#fragment` 在 base 中的剥离顺序与 Rust 端 `url::Url::join` 行为不一致。同一相对路径在 `element.absUrl(...)`（走 JS 路）vs `crate::utils::build_full_url`（Rust 路）解出不同 URL，下游 cache key 不一致。
**方案**：
1. 新增 `__legado_resolve_url(value, base) -> String` bridge：`crate::utils::build_full_url(&base, &value)` 直接套用，与 Rust 端 100% 同算法。
2. PREAMBLE `_resolveUrl: function(value, base) { return __legado_resolve_url(String(value || ''), String(base || '')); }` —— 删除 JS 手写实现。
**收益**：JS / Rust URL 解析同源，cache key、redirect chain 一致。

### F-W1B-016 — `java_time_format` 边界 bug

**位置**：`js_runtime.rs:1581-1592`
**当前**：
```rust
if timestamp.abs() >= 1_000_000_000_000 || timestamp.abs() < 1_000_000_000 {
    timestamp /= 1000;
}
```
合法秒级 timestamp `999_999_999`（2001-09-09 之前）被错误地当作毫秒 → `/1000` 得到 1000 万秒。负数（pre-1970）也被 abs() 错误压缩。
**方案**（保守）：改启发式为"只有看起来像毫秒（>= 10^11，约对应 1973 年）才 /1000"：
```rust
if timestamp >= 100_000_000_000 {  // 10^11 ms ≈ 1973-03-03 ms
    timestamp /= 1000;
}
```
- 不再误处理小秒级 timestamp（999_999_999 = 2001-09-09 秒级保留）
- 负数（pre-1970）保留秒级，不再 abs() 压缩
- `>= 10^11`（约 1973 年的毫秒戳）作为"毫秒边界"判定 —— 任何"小于 1973 的毫秒戳"会被误当作秒，但这种值极少在 Legado 真实书源里出现。
**记录** Legado 原项目 chrono 默认毫秒语义到 doc comment。

## Requirements

- F-W1B-011 新增 `__legado_js_put` bridge + PREAMBLE `java.put` write-through 到 `LEGADO_JS_VARIABLES`
- F-W1B-012 `java._wrapElement` 加 `toJSON: function() { return this.text(); }`（**不**动全局 stringify wrapper）
- F-W1B-014 `legado_value_to_js_expr` Map 输出按键名排序
- F-W1B-015 新增 `__legado_resolve_url` bridge 复用 `crate::utils::build_full_url`；PREAMBLE 删 JS 手写 `_resolveUrl`
- F-W1B-016 `java_time_format` 改 `>= 10^11` 判定毫秒；保留负数

## Acceptance Criteria

- [ ] `cargo build --workspace` 通过 0 warning
- [ ] `cargo test --workspace --lib` 通过（含已有 `test_java_time_format_bridge` line 2860）
- [ ] `cargo test -p bridge --tests` 通过
- [ ] `cargo clippy --workspace` baseline 不变
- [ ] 5 条新单测：
  - `test_java_put_persists_across_eval`：两次 eval 之间 `java.put('k', 'v')` + 第二次 eval `java.get('k')` 拿到值
  - `test_wrap_element_to_json_returns_text`：`JSON.stringify(java._wrapElement({tagName:"a", text:"link"}))` 返回 `"link"`（字符串），不再是 `{}`
  - `test_legado_value_to_js_expr_map_key_order_stable`：同 Map 跑 10 次输出字符串完全相同
  - `test_resolve_url_consistent_with_rust`：构造若干相对 URL，断言 JS bridge 走 `__legado_resolve_url` 与 Rust `build_full_url` 输出一致（特别覆盖 `//host`、`?query`、`#fragment`）
  - `test_java_time_format_seconds_boundary`：`999_999_999` 秒级 → 2001-09-09；`100_000_000_000` 毫秒级 → 1973；负数保留秒级
- [ ] master report 5 条 finding 全部更新 Resolution

## Definition of Done

- 测试：5 条新单测覆盖全部 5 条 finding
- Lint：clippy / cargo build green
- 文档：master report finding 状态更新（按 BATCH-23 习惯）
- Commit：单一 commit `fix(rust): 第 11 批 JS runtime correctness（5 条 finding）`

## Out of Scope

- Runtime pool 化（属 BATCH-13 / F-W1B-023）
- `LegadoValue::Map` 类型从 HashMap 改 IndexMap（BATCH-14 接受 sort 输出方案，不动类型）
- `js_script_to_expression` corner case wrapper 决策表（属 F-W1B-013，非本批 5 条之一）
- BATCH-04 SSRF / 内存上限 / 文件桥 capability（P0 主题，单独批次）

## Technical Notes

- `LEGADO_JS_VARIABLES` thread_local + `JsVariablesOverride` RAII guard 已经在 `eval_default_with_http_state` (line 121) 安装；本批新加 `__legado_js_put` bridge 需要确保 `eval` 路径也安装了 guard（不安装的话 thread_local 是 stale 的）。**实现时核查**：是否所有 caller 都通过 `eval_default_with_http_state` 进入；如果有非 install guard 的 caller，java.put 在那种调用下不会污染但也不会持久化。
- `__legado_resolve_url` bridge 需要在 `register_quickjs_bridge` (line 492) 内挂 Function；boa 路径如果还在用，也要同步 register。
- PREAMBLE wrapper for stringify 改动会影响所有 eval 输出路径——单测覆盖必须包括"原本能用 JSON.stringify 直接处理的常规 case 不退化"。
- `java_time_format` 的"秒级 / 毫秒级判定"是启发式，不可能 100% 正确；改保守阈值是 trade-off。

## Decision (ADR-lite)

**Context**：5 条 P1 都是 JS runtime 行为偏离 Legado 原版 / Rust 端的预期。Master report 里给的修复方向都属于"局部精确修"，没有大重构需求。

**Decision**：
- 011：write-through pattern（不依赖 Runtime pool）
- 012：只加 `_wrapElement.toJSON`，**不**动全局 stringify wrapper
- 014：输出排序，**不**改 LegadoValue 类型
- 015：bridge 复用 Rust `build_full_url`，删 JS 手写
- 016：保守 `>= 10^11` 阈值（13 个月误判带，远小于 `>= 10^12` 的 30+ 年带）

**Consequences**：
- ✅ 5 条 P1 一批清完，全在 js_runtime.rs 内
- ✅ 风险局限：5 处都是局部改动 + 5 条新单测；不改全局 stringify wrapper 行为
- ⚠️ 016 启发式仍可能在"1970-01-01 ~ 1973-03-03 之间的毫秒戳"误判（≈13 个月窗口，对中文小说书源不现实）
- ⚠️ 011 依赖 caller 安装 JsVariablesOverride guard——如果发现有不走 install 的 caller，会在测试里暴露
- ⚠️ 012 不覆盖"书源返回 function / 奇怪对象"——按 finding 描述这属于书源作者错误，不在框架层兜底
