# BATCH-14: parser/rule perf misc（4 条 P1 性能 finding）

> Roadmap：`.trellis/tasks/archive/2026-05/05-20-fix-roadmap/plan/batches/BATCH-14-parser-rule-perf-misc.md`
> Master report：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-logic.md`

## Goal

清理 parser & rule 主路径上 4 条 P1 性能 finding。功能本身没有 bug，目标是用最小改动消除已识别的热点，**不**借机做大重构。

## Findings 落点（已 brainstorm 收敛）

### F-W1B-028 — search per-rule × per-item

**位置**：`core/core-source/src/parser.rs:558-612`
**当前**：5 次 `extract_from_contexts(field_rule, contexts)`，每次都遍历所有 N items 调 `run_rule_first`，复杂度 O(5N)。
**方案**：重构为 **per-item 嵌套循环**——外层一次性遍历 contexts，内层对每个 item 调用 5 次 `run_rule_first`（其中 4 次复用同一个 context-clone）。
**收益**：
- `run_rule_first` 调用次数不变（5N），但每个 item 的 5 次共享同一 base_context.clone()，少 4 次 clone。
- 主收益是数据局部性 + 与 029 协同（per-item 时同一 html parse 结果可以更自然复用，但本批先解耦）。

### F-W1B-029 — execute_single_css 重复 parse_document

**位置**：`core/core-source/src/legado/rule.rs:312-340`
**当前**：每次调用 `execute_single_css` 都 `scraper::Html::parse_document(html)`。一次 search 5 字段 + `||` 组合可能 parse 5+ 次。
**方案**：**search 函数本地 parse 一次**——
1. 在 `parser.rs::search` 拿到 html 后，先 `let document = scraper::Html::parse_document(&html)`。
2. 提供一个新的内部 entry：`execute_single_css_pre_parsed(&document, selector_str, ...)`，把 `Html::parse_document(html)` 抽出去。
3. search 走 5 字段时调用新接口，复用同一个 `document`。
4. `execute_single_css` 保留旧签名（接受 `&str html`），内部委托给 pre-parsed 版本。其它非 search 路径不动。
**作用域**：仅限 search 函数（5 字段同 html 复用）；不引入全局 cache、不动 RuleEngine 调用周期。

### F-W1B-030 — RATE_LIMITER std::sync::Mutex

**位置**：`core/core-source/src/parser.rs:29-30, 162`
**判断**：代码注释（lines 22-28 + R5/R34）已声明 std::sync::Mutex 是 *intentional*；后续添加的 atomic-based sweep throttling（`should_run_sweep_now`, lines 125-150）已经把 hot-path 锁的 O(n) 扫描压到 30s 一次。
**方案**：**不动代码**——
1. 在 `RATE_LIMITER` 注释里追加一行说明，明确 "F-W1B-030 mitigated by sweep throttling, intentional design"。
2. master report 写 Resolution：`mitigated by sweep throttling + short critical section`，路径同 BATCH-23 的 F-W3-030 处理。
**理由**：现行设计的 contention profile 在仓库目前的并发量级（个位数同时 search）下已经不是瓶颈；切 dashmap 反而带来 batch eviction 锁顺序的新复杂度。

### F-W1B-031 — font_mappings_json JSON 桥接

**位置**：`core/core-source/src/legado/js_runtime.rs:1932-1953, 2002-2026, 2236`
**当前**：`java.queryTtf(input) → font_mappings_json → JS JSON.parse → java.replaceFont(text, json1, json2) → java_replace_font 再 JSON.parse 两份`。CJK 字体 mapping 数千条，每章每段都跑一遍。
**方案**：**新增 Rust 一次到位接口，保留旧 API**——
1. Rust 端新增 `__legado_replace_font_by_urls(text, url_or_input1, url_or_input2)`：
   - 复用 `java_query_ttf` 已有的 input 解析（http url / base64 / file path）拿 bytes
   - 复用 `ttf_parser::Face` 解析逻辑（提到一个内部 helper `parse_ttf_to_mapping(bytes) -> HashMap<u32, u16>`）
   - 直接在 Rust 内做 `replace_font` 文本替换（复用 `java_replace_font` 算法），不绕回 JS 端
   - 返回替换后的 text
2. JS PREAMBLE 暴露 `java.replaceFontByUrls(text, url1, url2)`。
3. **保留旧 API**：`__legado_query_ttf` / `__legado_query_base64_ttf` / `__legado_replace_font` 全部保留，行为不变（兼容现有书源）。
4. 内部把 `font_mappings_json` 保留只做"序列化为 JSON"那一层，把 ttf parse → mapping 抽到 `parse_ttf_to_mapping(bytes)` helper，让新旧两条路共享。
**收益**：
- 老书源（调 queryTtf + replaceFont）：行为零变化。
- 新书源（如改造）：1 次 ttf parse + 1 次替换，无 JSON 桥接；典型 CJK 章节预期减少 70%+ 字体处理时间。

## Requirements

- F-W1B-028 search 重构为 per-item 嵌套循环（外层 contexts，内层 5 字段共享 context clone）
- F-W1B-029 search 函数本地 parse_document 一次，5 字段共享；新增内部 `execute_single_css_pre_parsed`
- F-W1B-030 不动代码，仅补注释 + master report Resolution
- F-W1B-031 新增 `__legado_replace_font_by_urls` + `java.replaceFontByUrls` PREAMBLE；抽 `parse_ttf_to_mapping` helper；保留旧 API

## Acceptance Criteria

- [ ] `cargo build --workspace` 通过
- [ ] `cargo test --workspace` 通过（含 RATE_LIMITER 单元测试 `parser.rs:2258`）
- [ ] `cargo clippy --workspace` 0 新 warning
- [ ] search 5 字段输出与原实现等价（加一条单测：N=3 items × 5 字段，断言每条结果对齐）
- [ ] `||` 组合 CSS 选择器 + 单选择器场景行为不变（既有 rule.rs 测试 green）
- [ ] queryTtf + replaceFont 老路径行为零变化（既有测试 green）
- [ ] 新路径 replaceFontByUrls 加一条单测：构造小 ttf bytes，与"老路径走两步"输出等价
- [ ] master report 4 条 finding 全部更新 Resolution

## Definition of Done

- 测试：search per-item 1 条 + replaceFontByUrls 1 条，覆盖增量代码路径
- Lint：clippy / cargo build green
- 文档：master report finding 状态更新（按 BATCH-23 习惯）；RATE_LIMITER 注释追加 030 mitigation 说明
- Commit：单一 commit `fix(rust): 第 14 批 parser/rule perf misc（4 条 finding）`

## Out of Scope

- Rule engine 双系统统一（属 BATCH-15 / F-W1B-032）
- QuickJS Runtime 池（属 BATCH-13 / F-W1B-026）
- per-RuleContext html cache（更大范围的 029 方案 B）
- RATE_LIMITER 切 dashmap / sharded mutex
- 改造既有书源去用 replaceFontByUrls 新接口

## Technical Notes

- `extract_from_contexts` 当前位于 `parser.rs:2093-2119`；per-item 重构后该函数可考虑保留作为 single-field fallback，或私有化，需在实现时判断。
- `scraper::Html` 本身 `Send` 不保证；search 是同步路径（`run_rule_first` 同步），方案 A 在 stack frame 内传引用安全。
- `java_query_ttf` 的 input 解析（http / base64 / file path）抽到 helper `resolve_ttf_input(input) -> Option<Vec<u8>>` 复用给新旧路径。
- `font_mappings_json` 保留：`parse_ttf_to_mapping(bytes) -> Option<HashMap<u32, u16>>` 抽出，旧函数变成 `parse_ttf_to_mapping(bytes).and_then(|m| serde_json::to_string(&m).ok()).unwrap_or("null")`。
- RATE_LIMITER 注释追加位置：`parser.rs:14-28` 那段 doc comment 末尾。
- 新增 JS-bridge function 必须挂在 `register_java_*` 注册流程内（参考 `js_runtime.rs:782-789`）。

## Decision (ADR-lite)

**Context**：BATCH-14 包含 4 条 P1 性能 finding，路线图标 effort=M。逐一评估后发现 030 已经被 sweep throttling 修过、029 用本地复用就能拿到主要收益、031 新接口才是真正的杠杆。

**Decision**：
- 028/029：纯 Rust 直接重构（最小作用域）
- 030：不动代码 + 文档对齐
- 031：新接口 + 旧接口保留兼容

**Consequences**：
- ✅ 4 条 finding 一批清完
- ✅ 风险可控：028/029 局部、030 零代码、031 不影响老书源
- ⚠️ 031 收益要等书源自己迁过来才完整释放（路线图原本就接受这点）
