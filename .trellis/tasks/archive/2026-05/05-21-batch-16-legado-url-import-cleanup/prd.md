# BATCH-16: legado/url + import 收尾（5 条 P1 finding）

> Roadmap：`.trellis/tasks/archive/2026-05/05-20-fix-roadmap/plan/batches/BATCH-16-legado-url-and-import-cleanup.md`
> Master report：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-logic.md`

## Goal

清理 5 条 P1 架构 / 正确性 finding：

1. F-W1B-034 `clean_legado_url` 与 `url::parse_legado_url` 双实现
2. F-W1B-036 `<,{{page}}>` 模板"仅支持第一处"契约不明
3. F-W1B-038 `@js:` 规则跨路径 spawn_blocking 不一致（reactor starve 风险）
4. F-W1B-039 RSS BOM 剥离逻辑双份
5. F-W1B-042 JSONPath `{{ {$.x} }}` 嵌套边界 contract

不做：rule 系统统一（BATCH-15 范围）；`LegadoValue` / RuleEngine trait 重构；BATCH-04 SSRF / 内存上限。

## Findings 落点

### F-W1B-034 — `clean_legado_url` rsplit_once(',') 与 `url::parse_legado_url` 不一致

**位置**：`core/core-source/src/legado/import.rs:594`（私有 `clean_legado_url`）；调用点 line 314 / 339 / 361。
**当前**：`clean_legado_url` 用 `rsplit_once(',')` 取最后一段当 path，**不**走 legado URL 语法。`url::parse_legado_url` (在 `legado/url.rs`) 才是正确解析（处理 `,{...options}` JSON 后缀、`<...>` 条件段等）。
**症状**：导入书源时 `bookSourceUrl` 含 `,{"charset":"gbk"}` 这种合法 legado 后缀的 URL 被截掉首段，写入 DB 的 source url 缺前缀。
**方案**：删 `clean_legado_url`；3 处 caller 改调 `url::parse_legado_url(url).path` 取 path 字段。
**注意**：BATCH-23 在 `source_dao.rs:723` 已内联清理过同名旧函数；此处是 `import.rs` 内的另一份副本，需独立处理。
**测试**：`test_clean_legado_url_does_not_strip_conditional_page_template`（已存在 line 695）迁移到新接口；不重命名测试名。

### F-W1B-036 — `resolve_conditional_page` 多 `<...>` 段契约不明

**位置**：`core/core-source/src/legado/url.rs:236-260` `resolve_conditional_page` + `:263-268` `resolve_conditional_placeholder`。
**当前**：用 `find('<')` + `find('>')` 只匹配第一段；URL 模板含两段（如 `prefix1<,{{page}}>?sort=<,asc>`）的话只处理第一段，第二段 `<...>` 留在 URL 里。
**Finding 自陈**："虽未在 sy/*.json 见到[多段用法]"——真实书源未触发。
**方案**：保守——加 doc 注释明确 contract"仅识别 URL 中第一处 `<...>` 段"；加 1 条单测断言"含两段 `<...>` 时仅展开第一段"，让 contract 在测试里固化。
**不做**：扩展支持多段（无真实 demand + 多段语义在 Legado 原版未见明确文档）。

### F-W1B-038 — `@js:` 规则 spawn_blocking 不一致（reactor starve）

**位置**：`core/core-source/src/parser.rs:1663` `run_rule_first_blocking`（spawn_blocking 包装，仅 content 路径调用 line 1544）；其它 9 处 sync `run_rule_first` 调用点（search/explore/book_info/toc，含 line 928/938/943/981/1356/1371/1387/1403/2150/2179）。
**当前**：content 路径走 `spawn_blocking + 30s 超时`；其它路径直接同步，在 FRB tokio reactor 上 block。
**问题**：`@js:` 规则可能调 `java.ajax(url)` 同步 HTTP（5s 默认），相当于在 reactor 上同步等 HTTP—— starve 同 reactor 上其它 task。CSS / XPath / JsonPath 是 µs 级，不构成问题。
**方案 B（选性 spawn_blocking）**：
1. 复用现有 `legado::is_js_rule(rule)` (`legado/js_shim.rs:20`，已 pub)：检测 `@js:` / `js:` / `@js\n` 前缀。**扩展**为新加 helper `legado::is_blocking_rule(rule) -> bool`：`is_js_rule(rule) || rule.contains("<js>")`（同 `parser.rs:1734` `contains_inline_js` 既有判定）。放 `js_shim.rs` 与 `is_js_rule` 同处。
2. `run_rule_first` 内：若 `is_blocking_rule(rule)` 命中 → 走 `tokio::task::block_in_place(|| run_rule(rule, html, ctx))` 包装；否则保持同步。
3. **不**改 `run_rule_first` 函数签名（仍 sync），不改 9 处调用点。
4. **block_in_place 前提确认**：FRB 用 `flutter_rust_bridge::frb_generated_default_handler!()` 默认 handler（`frb_generated.rs:45`），FRB 2.12 默认 handler 内部用 multi-thread tokio runtime。`core/Cargo.toml:33` `tokio features = ["full"]` 包含 `rt-multi-thread`。结论：multi-thread 是默认。
5. **panic 防御**：`block_in_place` 在非 multi-thread runtime 会 panic。生产路径 OK，但单测可能在 `#[tokio::test]` 用 `current_thread`。**方案**：检测 runtime flavor 不可行（API 不稳）；改方案——`tokio::task::block_in_place` 在 `current_thread` runtime 下会 panic，所以 sync test 直接调 `run_rule_first` 不在 tokio context 下，`block_in_place` 直接 panic（`called outside of Tokio runtime`）。**安全模式**：用 `tokio::runtime::Handle::try_current().is_ok()` gate—— 在 tokio context 下走 `block_in_place`，否则直接同步执行（已经在阻塞线程里）。
**收益**：
- search 含 `@js:` 规则的书源不再 starve reactor
- 纯 CSS / XPath / JsonPath 规则零调度成本（spawn_blocking 自身有 ~µs 调度开销，热点路径不能无脑包）
**不做**：把 `run_rule_first` 改 async + 8 处 caller .await（finding 047 估 +500 行；当前批 effort 限 M）。

### F-W1B-039 — RSS BOM 剥离逻辑双份

**位置**：`core/core-source/src/rss/parse_xml.rs:55` `fn skip_xml_prologue`（私有，处理 BOM + `<?xml...?>` + `<!--...-->` 头）；`core/core-source/src/rss/mod.rs:93` `body.trim_start_matches('\u{FEFF}').trim_start()`（简化版，不处理 XML 声明）。
**症状**：feed 头部含 `<?xml version="1.0"?>` 时，`mod.rs::detect_format` 简化版剥不掉，导致 detect_format 误判走规则路径而非 XML parser 路径。
**方案**：
1. `skip_xml_prologue` 改 `pub(crate)`。
2. `mod.rs:93` 改调 `crate::rss::parse_xml::skip_xml_prologue(body)`。
**测试**：现有 `parse_xml.rs` 测试覆盖 prologue 行为；新加 1 条 `mod.rs::detect_format` 测试，feed 含 `<?xml ?>` 时正确走 XML 路径。

### F-W1B-042 — JSONPath `{{ {$.x} }}` 嵌套边界 contract

**位置**：`core/core-source/src/legado/url.rs:454` `resolve_single_brace_jsonpath`（finding 报 471-495 实际偏移）。
**当前**：用正则匹配 `{$.path}` 解 JSONPath；当模板里有 `{{ {$.x} }}`（双花括号包单 JSONPath）时，外层 `{{...}}` 是 mustache、内层 `{$...}` 是 JSONPath—— 两者交叉的边界情况测试覆盖薄。
**Finding 自陈**："lookbehind 漏配，问题不在'错'而在'未明确'"。
**方案**（轻量）：
1. 加 doc 注释明确 contract："`resolve_single_brace_jsonpath` 仅替换单花括号 `{$.path}`；双花括号 `{{ }}` 由上层 `resolve_rule_template` 先处理（mustache 优先）"。
2. 加 2 条单测：
   - `test_resolve_jsonpath_inside_double_braces`：输入 `{{ {$.url} }}`，断言**外层 mustache 替换后**才进入 JSONPath 解析（行为不变，固化 contract）
   - `test_resolve_single_brace_jsonpath_only`：输入 `prefix {$.url} suffix`（无 `{{}}`），单花括号正常展开
**不做**：改函数语义、引入 lookbehind regex（Rust regex crate 不支持 lookbehind）。

## Requirements

- F-W1B-034 删 `import.rs::clean_legado_url`，3 处 caller 改 `url::parse_legado_url(url).path`；现有单测迁移
- F-W1B-036 `resolve_conditional_page` 加 doc + 1 条多段 `<...>` 单测
- F-W1B-038 加 `legado::is_blocking_rule(rule) -> bool`（在 `js_shim.rs` 与 `is_js_rule` 同处，复用 `is_js_rule` + `contains("<js>")`）；`run_rule_first` 用 `Handle::try_current().ok().is_some()` gate 在 tokio context 内对 JS 规则走 `block_in_place`
- F-W1B-039 `skip_xml_prologue` 改 `pub(crate)`；`rss/mod.rs:93` 调用复用
- F-W1B-042 `resolve_single_brace_jsonpath` 加 doc + 2 条边界单测

## Acceptance Criteria

- [ ] `cargo build --workspace` 0 warning
- [ ] `cargo test --workspace --lib --no-fail-fast` 通过（含已有 import.rs / url.rs 单测）
- [ ] `cargo test -p bridge --tests` 通过
- [ ] `cargo clippy --workspace -- -D warnings` baseline 不变
- [ ] 5 条新单测 + 1 条迁移：
  - `test_clean_legado_url_does_not_strip_conditional_page_template`（迁移自 import.rs:695）
  - `test_resolve_conditional_page_only_first_segment`（multi `<...>` contract）
  - `test_is_blocking_rule_detects_js_markers`（`@js:`、`js:`、`@js\n`、`<js>...</js>` 四种）
  - `test_detect_format_handles_xml_prologue`（feed 含 `<?xml ?>`）
  - `test_resolve_jsonpath_inside_double_braces`
  - `test_resolve_single_brace_jsonpath_only`
- [ ] master findings.md + findings-rust-logic.md 5 条 Resolution 落

## Definition of Done

- 测试：5 新 + 1 迁移
- Lint：clippy / cargo build green
- 文档：master report 5 条 finding 状态 RESOLVED + Resolution 段（按 BATCH-23/14/11 模式）
- Commit：单 `fix(rust): 第 16 批 legado/url + import 收尾（5 条 finding）`

## Out of Scope

- BATCH-15 rule 系统统一（execute_legado_rule_values / execute_legado_rule_with_http_state / execute_chapter_list_js_rule 三入口合并）
- F-W1B-038 完整 async 化（`run_rule_first` 改 async + 8 处 caller .await，估 +500 行；本批选 block_in_place 路径）
- F-W1B-036 多段 `<...>` 扩展支持（无真实 demand）
- F-W1B-042 JSONPath 引入 lookbehind regex（Rust regex 不支持 + 重构面过大）
- BATCH-04 SSRF / 文件桥 capability / 内存上限

## Technical Notes

- **block_in_place 前提**：FRB 用 `flutter_rust_bridge::frb_generated_default_handler!()` 默认 handler，FRB 2.12 内部 multi-thread tokio runtime + `core/Cargo.toml:33` `tokio features = ["full"]`。`block_in_place` 在 single-thread runtime / 非 tokio context 会 panic—— 实施时用 `tokio::runtime::Handle::try_current()` gate。
- **`is_js_rule` 已存在**：`legado::is_js_rule` (`js_shim.rs:20`) 已 pub use 到 `legado::*`（`legado/mod.rs:18`）。新加 `is_blocking_rule = is_js_rule || contains("<js>")`，**不**重复实现。
- **`contains_inline_js` 私有 helper**：`legado/rule.rs:658` 已有 `fn contains_inline_js(rule: &str) -> bool { rule.contains("<js>") && rule.contains("</js>") }`。可选——把 `is_blocking_rule` 实现成 `is_js_rule(rule) || contains_inline_js(rule)` + 把 `contains_inline_js` 改 `pub(crate)`；或直接在 js_shim.rs 内独立实现 `<js>` 子串检查。**首选**：复用 + 改 pub(crate)，避免重复 contains 检查。
- **F-W1B-034 caller 行号**：BATCH-23 在 `source_dao.rs` 内联了同名旧函数，import.rs 内 `clean_legado_url` 调用点是独立的 3 处（line 314/339/361），实施前 sub-agent 重新 grep 行号。
- **`url::parse_legado_url` 返回类型**：检查它是否返回 `LegadoUrl { path, options }` 还是 `&str`，决定 caller 取 path 字段方式。
- **F-W1B-039 `skip_xml_prologue` 输入输出**：检查它是 `&str -> &str`（slice）还是返回 owned String；`mod.rs:93` 当前用 chained trim_start，签名匹配性影响改动范围。

## Decision (ADR-lite)

**Context**：5 条 finding 都是局部精确修，无大重构。F-W1B-038 范围曾考虑 3 个方案（A：全面 async + spawn_blocking；B：选性 block_in_place；C：推迟）。

**Decision**：
- 034：删 helper，统一走 `parse_legado_url`
- 036：契约文档化 + 单测固化"仅第一段"
- 038：方案 B 选性 `block_in_place`，仅 JS 规则走 blocking
- 039：`pub(crate) skip_xml_prologue` 复用
- 042：契约文档化 + 单测固化嵌套边界

**Consequences**：
- ✅ 5 条 P1 一批清完，effort 控制在 M（≤500 行）
- ✅ F-W1B-038 修核心痛点（reactor starve）+ 不改 8 处 caller 签名
- ⚠️ 038 依赖 multi-thread tokio runtime；若 single-thread 回退到"doc + 现状"
- ⚠️ 036 / 042 是 contract-docs-only fix，不增强行为；finding 自陈无真实 demand
- ⚠️ 034 删除涉及 3 caller + 1 单测迁移，需仔细回归
