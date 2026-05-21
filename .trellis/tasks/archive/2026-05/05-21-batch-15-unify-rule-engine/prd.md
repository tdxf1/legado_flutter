# BATCH-15: 双规则系统统一 + 重复 dispatcher 删除（6 条 P1 finding）

> Roadmap：`.trellis/tasks/archive/2026-05/05-20-fix-roadmap/plan/batches/BATCH-15-unify-rule-engine.md`
> Master report：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-logic.md`

## Goal

把 core-source 的双规则系统（`crate::rule_engine` vs `crate::legado::rule`）收口到 `legado::rule` 单一执行路径；删除 `js_shim.rs` 死代码；修两条 `legado/rule.rs` 行为不明确的小 bug；把 `parser.rs` 散落的 helper 收进 `ContentRule` 方法。

清理 6 条 P1 finding：

1. **F-W1B-032** core-source 存在两套并行规则系统 — 删除 `parser.rs::run_rule` 里 `rule_engine.execute_rule` fallback 路径
2. **F-W1B-033** `js_shim.rs` 90 行重复 dispatcher — 删除未引用 helper（`build_js_vars` / `js_requires_http` / `js_uses_clist_api` / `js_uses_challenge` / `build_minimal_js_vars`）
3. **F-W1B-035** `content_rule_field` 散落 — 改成 `ContentRule` 方法
4. **F-W1B-037** `execute_chapter_list_js_rule` 内外两份同名函数 — 文档化"sync helper + spawn_blocking 异步包装"双 fn 关系（不重构）
5. **F-W1B-040** `execute_css_rule` `||` 分支 `Err(_)` 吞错 — 加 `tracing::warn!` 不改语义
6. **F-W1B-041** `execute_legado_rule` 空 rule_str 透传整个 html — 改返回 `Ok(Vec::new())`

## Findings 落点

### F-W1B-032 — 删除 rule_engine.execute_rule fallback 路径（核心决策）

**当前**：`parser.rs:464-478` `BookSourceParser::run_rule`：

```rust
match crate::legado::execute_legado_rule(rule, html, context) {
    Ok(results) if !results.is_empty() => return Ok(results),
    Ok(results) if !can_fallback_to_legacy_rule_engine(rule) => return Ok(results),
    _ => {}
}
self.rule_engine
    .execute_rule(rule, html)
    .map_err(|e| e.to_string())
```

`can_fallback_to_legacy_rule_engine`（`parser.rs:1752`）只过滤掉 `@js: / js: / @js\n / <js> / @put: / @get: / @get.` 这 6 类（这些是 legado 独有），剩下纯 CSS / XPath / JSONPath / Regex 规则 + `legado` 返回空 results 时仍走 rule_engine。

**风险评估**：
- legado/rule.rs 已实现 CSS / XPath / JSONPath / Regex / 组合符 / `||` / JSOUP Default / `##` purification / `@get/@put` / `<js>` inline / case-insensitive `@css:` / 复杂 selector chain（selector.rs 1062 行）。功能上完全覆盖 rule_engine 的 CSS / XPath / Regex / JSONPath。
- rule_engine 的差异点：`css_index/css_skip` 修饰符（`!1`、`@@-2`）+ `@@N` 替换规则后缀。这两个在 legado/rule 已通过 selector.rs 的 ArrayModifier + selector.rs::ExtractSuffix 实现等价语义。
- legado/rule 在 5 项空 results 时（即 `Ok(vec![])`）才会触发 fallback。在 css/xpath/regex 实际匹配为空的合法语义下也会触发 — 这是 master finding 自陈"行为不易预测"的直接证据。
- 删除 fallback 等于"不再 silently 降级到 rule_engine"，对真实书源意味着：
  - 同一规则在 legado/rule 返回 `[]` 的：现在 fallback 到 rule_engine 可能有结果（fallback 隐藏书源/规则错误）→ 删除后用户能在结果列表为空时立刻知道是规则匹配为空（更好的可调试性）。
  - 同一规则在 legado/rule 返回 `Err(...)` 的：现在 fallback 到 rule_engine 兜底；删除后变成 Err 上抛 → caller 已经有 `?` 链 + warn! 链路，行为变化 = 错误能被看见。

**修改方案**：
- `parser.rs::run_rule` body 直接：`crate::legado::execute_legado_rule(rule, html, context).map_err(|e| ...)`，删除 fallback 分支 + `can_fallback_to_legacy_rule_engine` helper（连同 `parser.rs:1752-1760`）。
- `parser.rs::BookSourceParser` struct 删 `rule_engine: RuleEngine` 字段 + `RuleEngine::new()` 构造调用 + `parser.rs:6` `use crate::rule_engine::RuleEngine;` import。
- **保留** `rule_engine` 模块本身：`lib.rs::check_rule_expression`（line 363-470）依赖 `rule_engine::strip_legado_replace_rules` / `strip_css_modifiers` / `split_css_alternatives` / `RuleExpression::parse` / `RuleType` 枚举做规则_校验_（不是执行）。这些 helper / 类型是纯静态分析工具，跟 fallback 执行路径解耦。
- `lib.rs:20` 的 `pub use rule_engine::{RuleEngine, RuleError, RuleExpression, RuleType}` 改为只 re-export `RuleExpression` / `RuleType`（其它 crate 没用 `RuleEngine` / `RuleError`）。
- **不动** `rule_engine.rs::execute_rule` 实现本体（`RuleEngine::execute_rule` / `RuleExpression::evaluate`）：标 `#[deprecated(note = "use legado::execute_legado_rule")]` + 新增 doc comment 说明保留原因（仅用作 RuleExpression::parse 的 evaluation entry，给单测覆盖；新代码不应调用）。

### F-W1B-033 — js_shim.rs 死代码删除

**当前**：`js_shim.rs` 128 行，5 个未引用 pub fn（grep 全工作区无 caller）：
- `build_js_vars` (line 62-91)
- `build_minimal_js_vars` (line 94-105)
- `js_requires_http` (line 41-46)
- `js_uses_clist_api` (line 49-51)
- `js_uses_challenge` (line 54-56)

`legado/mod.rs:18` 的 `pub use js_shim::{build_js_vars, is_blocking_rule, is_js_rule}` re-export `build_js_vars` 是死的（没人 import）；`is_js_rule` 只被 `is_blocking_rule` 内部用 + `parser.rs::can_fallback_to_legacy_rule_engine` 用（本批连同删除）。

**修改方案**：
- 删除 5 个死 pub fn + 它们的 doc comment。
- `legado/mod.rs:18` 改 `pub use js_shim::{is_blocking_rule, is_js_rule};`（保留 `is_js_rule` 给 `is_blocking_rule` 调用 — 同模块共生但仍 pub 因 BATCH-16 spec 段已固化"`legado::is_blocking_rule` + `legado::is_js_rule`"；移除 `is_js_rule` pub 会破坏 spec doc）。
- 顶部 module doc 注释删除 "实际 HTTP 调用由 parser.rs 中的 Rust fallback 处理" 行（指 rule_engine fallback，已删）+ "支持的 Legado JS API" 列表（误导性 — 此模块不是 JS bridge，js_runtime.rs 才是）。改成简短 "Legado 规则的 JS 标记检测 helper（`is_js_rule` / `is_blocking_rule`）。Bridge 在 `js_runtime.rs`。"

### F-W1B-035 — content_rule_field 收进 ContentRule 方法

**当前**：`parser.rs:1924` `fn content_rule_field(source: &BookSource, f: impl FnOnce(...) -> Option<String>) -> Option<String>` + 6 处 caller（line 1503/1504/1505 + 1679/1680/1681 各 3 个 image_style/image_decode/pay_action 字段）。

**修改方案**：在 `types.rs::ContentRule` impl block 加：

```rust
impl ContentRule {
    /// Read an Option<String> field, treating empty / whitespace-only strings as None.
    /// Used to centralize the "empty rule = field absent" convention.
    pub fn non_empty_field<F>(source: Option<&Self>, f: F) -> Option<String>
    where
        F: FnOnce(&Self) -> Option<String>,
    {
        source.and_then(f).filter(|s| !s.trim().is_empty())
    }
}
```

或更直接：保留 free function 形式但搬到 `types.rs` 里靠近 `ContentRule`（不引入泛型方法的额外语法噪声）。**选后者**：caller 行数完全不变（还是 `content_rule_field(source, ...)`，只是改 import 路径）。

**实施**：把 `parser.rs:1924-1926` 的 fn 整段移到 `types.rs::ContentRule` 之后，改 pub fn 位置，6 个 caller 改 `crate::types::content_rule_field(source, ...)`。

### F-W1B-037 — execute_chapter_list_js_rule 双 fn 关系文档化

**当前**：`parser.rs:2007` `fn execute_chapter_list_js_rule(...)` 同步 + `parser.rs:2133` `async fn execute_chapter_list_js_rule_blocking(...)` 用 `tokio::task::spawn_blocking` 包装前者。这是 BATCH-16 之前的常见 pattern，并不是真"两份重复实现"，只是"sync core + async wrapper"。

**修改方案**：保留 fn 结构（unify 成 `RuleEngineExt::execute(...)` builder 是 BATCH-15 effort 之外 + 收益不大）。在 `execute_chapter_list_js_rule` 上加 doc comment 解释"为什么有这对 sync/async 双胞胎 fn"（与 BATCH-16 `run_rule_first` `block_in_place` 选性策略对应）。

### F-W1B-040 — execute_css_rule || 分支 Err(_) 吞错

**当前**：`legado/rule.rs:340-347`：

```rust
for part in selector_str.split("||") {
    ...
    match execute_single_css(part, html) {
        Ok(mut r) => results.append(&mut r),
        Err(_) => {}
    }
    if !results.is_empty() {
        break;
    }
}
```

**修改方案**：`Err(_) => {}` 改 `Err(e) => tracing::warn!("execute_css_rule: || branch '{}' failed: {}", part, e)`。语义不变（仍然继续下一 branch），加可见性。

### F-W1B-041 — 空 rule_str 透传 html 改 Vec::new()

**当前**：`legado/rule.rs:127-130`：

```rust
let rule_str = rule_str.trim();
if rule_str.is_empty() {
    return Ok(vec![html.to_string()]);
}
```

意图是 "空规则 = 透传"（Legado 原版语义复刻），但 caller 用结果做"是否成功匹配"判断时被误导（finding 原话）。

**修改方案**：改 `Ok(Vec::new())`。配套：
- 加单测 `test_execute_legado_rule_empty_rule_returns_empty` 断言空 rule 返回空 Vec。
- `parser.rs::run_rule` 改造之后（fallback 删除），空规则现在直接命中 legado 路径返回 `Ok(vec![])`，不再走 rule_engine fallback；但既有 caller 是否依赖"空规则透传 html"？grep 既有 caller：`run_rule` / `run_rule_first` / `extract_from_contexts` / 5 处 closure（is_vip / is_volume / is_pay / update_time / parse_chapters_from_page` 内的 `extract_field` BATCH-14）。所有 caller 都对 `Some(rule)` 做了显式 None 检查（如 `content_rule_field` 空过滤 + Option<&str> 类型），不会传空 string。**新增风险**：若有书源 rule 字段是 `""`（非 None）字面量（合法 JSON），原行为透传 html，现在返回空 Vec → 用户拿不到 fallback。**评估**：sy/*.json grep `"": ""` 字段 0 命中（仅 `"": null` 之类）；行为变化在合法书源场景不存在。
- 必要时在 `parser.rs::run_rule` 入口加防御：`if rule.trim().is_empty() { return Ok(vec![html.to_string()]); }` —— **不做**，会与 finding 修正意图冲突；让 caller 看到空 Vec 是 finding 的目的。

## Requirements

- 删 `parser.rs::run_rule` 中 `rule_engine.execute_rule` fallback；删 `BookSourceParser::rule_engine` 字段；删 `can_fallback_to_legacy_rule_engine` helper
- `rule_engine.rs` 模块保留，但 `RuleEngine` struct 标 `#[deprecated]`
- 删 `js_shim.rs` 5 个未引用 pub fn；`legado/mod.rs:18` re-export 列表收尾
- `content_rule_field` helper 搬到 `types.rs`
- `execute_css_rule` `||` 分支 `Err` 加 `warn!`
- `execute_legado_rule` 空 rule_str 改 `Ok(Vec::new())`
- `execute_chapter_list_js_rule` doc 加"sync core + async wrapper" pattern 注释
- 新增 1 单测 `test_execute_legado_rule_empty_rule_returns_empty`

## Acceptance Criteria

- [ ] `cargo build --workspace` 0 warning（包括 deprecated 警告：`#[allow(deprecated)]` 仅在保留的内部 test caller 上）
- [ ] `cargo test --workspace --lib --no-fail-fast` 全过（关键风险：删除 fallback 后某些 既有书源回归 test 可能 fail；按 finding 修复期望调整）
- [ ] `cargo test -p bridge --tests` 全过
- [ ] `cargo clippy --workspace -- -D warnings` baseline 不变（deprecated 项例外 — `#[allow(deprecated)]` 在保留的本地 caller / 单测上）
- [ ] 1 新单测 `test_execute_legado_rule_empty_rule_returns_empty`
- [ ] 6 条 finding Resolution 落 master findings.md + findings-rust-logic.md
- [ ] grep `RuleEngine::new\|rule_engine\.execute_rule` 仅在测试 / deprecated note 中出现

## Definition of Done

- 测试：1 新单测 + 既有全过
- Lint：clippy / cargo build green
- 文档：master report 6 条 Resolution + spec 加「Legado 规则单一执行路径：legado::rule 是 source-of-truth；rule_engine 仅用于规则_校验_helper」段
- Commit：3 个（fix + spec + archive，按 BATCH-13 模式）

## Out of Scope

- `rule_engine.rs` 整体删除 / 移动到独立 `rule_validation` 模块（重命名风险高，留后续批次；本批仅标 `#[deprecated]` + 文档化保留原因）
- `RuleEngineExt::execute(rule, ctx, opts)` builder 抽象（finding 建议但 effort 远超 BATCH-15；execute_chapter_list_js_rule_blocking 与现有签名兼容已 OK）
- BATCH-04 SSRF / capability（独立批次）
- F-W1B-038 全 async 化（BATCH-16 已选性 block_in_place 解决）

## Technical Notes

- **`#[deprecated]` 配 lint**：`#[allow(deprecated)]` 加在 `rule_engine.rs::tests` 模块顶部 + 任何剩余的 `RuleEngine::new()` / `execute_rule()` 单测 caller，避免触发 `-D warnings`。
- **回归 risk**：执行回归测试集时若有 case 依赖"空规则透传 html"或"legado 返回空时 rule_engine 兜底"，需检查是不是真实业务依赖还是 test 自身问题。如有真实依赖，回滚改动并改成更窄修复（见 BATCH-12 F-W1B-019 部分修复模式）。
- **lib.rs check_rule_expression**：保持不动，仍 import `rule_engine::strip_legado_replace_rules` 等 pub(crate) helper。这是 rule_engine 模块的合法 use case。
- **`tracing::warn!` 已是 workspace 标配**：`legado/rule.rs` 已 import tracing（本批新加 warn 语句沿用）。
- **mod.rs 改动**：仅 `legado/mod.rs:18` 一处 + 顶部 doc comment；rule_engine.rs 自身的 mod 路径 `lib.rs:10` 不动。

## Decision (ADR-lite)

**Context**：BookSourceParser 创建之初依赖老的 `rule_engine`（CSS/XPath/Regex/JSONPath 简单实现），后续 `legado/rule` 演进出 JSOUP Default + `||` 组合 + `<js>` inline + `@put/@get` 完整替换品。`run_rule` 当前是"先试新再 fallback 旧"的过渡形态，是历史债。

**Decision**：删除 fallback 路径（方案 A）；保留 `rule_engine` 模块作为规则_校验_helper（方案 B 的折中）。

**理由**（vs 其它候选）：
- vs 方案 C（整体删除 rule_engine 模块 + lib.rs 校验改用 legado/rule helper）：legado/rule 没有公开等价的 strip_legado_replace_rules / strip_css_modifiers / split_css_alternatives；这些是规则字符串的纯文本预处理，跟执行路径解耦，硬要迁移会造成 legado/rule 内部接口暴露到 lib.rs，破坏封装。
- vs 方案 D（保留 fallback，仅文档化）：finding 自陈"行为不易预测"，这是真实可见 bug；保留即留毒。
- vs 方案 E（推迟）：roadmap BATCH-15 是 P1，依赖此批的 BATCH-19/21（reader / search refactor）需要清晰的规则执行入口。

**Consequences**：
- ✅ `BookSourceParser::run_rule` 单一执行路径：`legado::execute_legado_rule`
- ✅ `js_shim.rs` 从 128 行降到 ~50 行（仅保 is_js_rule + is_blocking_rule + module doc）
- ✅ `parser.rs` -1 字段（`rule_engine`）-1 helper（`can_fallback_to_legacy_rule_engine`）-7 行 import / 构造代码
- ✅ `content_rule_field` 与 ContentRule 共生，types.rs 内聚
- ⚠️ 既有书源依赖 fallback 兜底的 case：在测试集回归时暴露；需要按 case 决定回滚还是修 legado/rule
- ⚠️ rule_engine.rs 仍 885 行：作为 deprecated 模块继续维护成本不变，但新代码不应用
