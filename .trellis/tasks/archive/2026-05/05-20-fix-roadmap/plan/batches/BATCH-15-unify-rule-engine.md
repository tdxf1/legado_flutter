# BATCH-15: 双规则系统统一 + 重复 dispatcher 删除

**Stage**: P1
**Slug**: `unify-rule-engine`
**Edit-effort**: M
**Effort**: M (≤500 行)
**Depends on**: BATCH-14 (rule.rs 已 perf 化)

## 1. 范围

清理 core-source 中两套并行规则系统（rule_engine vs legado/rule）+ js_shim 死代码 dispatcher + execute_chapter_list_js_rule 内外两份同名函数 + execute_css_rule || break 语义错位 + execute_legado_rule 空 rule_str 透传 + content_rule_field helper 散落。这是产品决策"选哪套保留"的直接落地，但 master report 已经给方向（保留 legado/rule，删 rule_engine）。

## 2. 包含的 findings

- [F-W1B-032] core-source 存在两套并行规则系统 — `core/core-source/`
- [F-W1B-033] js_shim.rs 90 行重复 dispatcher — `core/core-source/src/legado/js_shim.rs`
- [F-W1B-035] content_rule_field 处理空字符串过滤逻辑分散 — `core/core-source/src/parser.rs:1820-1822`
- [F-W1B-037] execute_chapter_list_js_rule 内外两份同名函数 — `core/core-source/src/parser.rs:1899-1923`
- [F-W1B-040] execute_css_rule || break 语义错位 — `core/core-source/src/legado/rule.rs:283-295`
- [F-W1B-041] execute_legado_rule 空 rule_str 返回 html 等价无差别 — `core/core-source/src/legado/rule.rs:80-83`

## 3. 影响文件

- `core/core-source/src/rule_engine.rs` — 标 `#[deprecated]`；逐步移植 CSS / XPath / Regex / JSONPath 实现到 legado/rule（保留 css_index/css_skip/replace_rules 能力）；新增 case 一律进 legado/rule
- `core/core-source/src/parser.rs:455-469` — `run_rule` "先试新再 fallback 旧" 改为只调 legado/rule
- `core/core-source/src/legado/rule.rs:80-83, 283-295` — 空 rule_str 改返回 Vec::new() 或 Err 而非透传整个 html；`||` 路径 `Err(_)` 加 `tracing::warn!`
- `core/core-source/src/legado/js_shim.rs` — 删除未引用 `is_js_rule` 之外的所有 helper；保留的部分挪进 legado/rule.rs 私有 helper
- `core/core-source/src/parser.rs:1820-1822` — 把 ContentRule field 提取的 helper 搬到 types.rs 作为 ContentRule 方法
- `core/core-source/src/parser.rs:1899-1923` — 统一入口 `RuleEngineExt::execute(rule, ctx, opts)` 用 builder 选择 mode（async/blocking, with-cookie-jar/without）

## 4. 修复方向

直接复用 master findings-rust-logic.md 中各条"建议"段落 + 主题汇总"共同建议"。

## 5. 测试策略

- 现有 sy/*.json 书源测试集回归（关键风险：选定保留 legado/rule 后部分依赖 rule_engine 特定行为的书源可能失败，需在测试集逐条验证）
- Rust unit test：execute_legado_rule(html, "") 返回 Vec::new() 或 Err（不再透传）

## 6. 验收

- [ ] master finding F-W1B-032/033/035/037/040/041 全部消解
- [ ] grep `crate::rule_engine` 仅在 deprecation 注释中出现
- [ ] 现有书源测试集回归通过

## 7. implement.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-logic.md", "reason": "本批次涉及的 wave 1B findings"}
{"file": "core/core-source/src/rule_engine.rs", "reason": "deprecation 主体"}
{"file": "core/core-source/src/legado/rule.rs", "reason": "保留并扩展的规则系统"}
{"file": "core/core-source/src/legado/js_shim.rs", "reason": "重复 dispatcher 删除"}
{"file": "core/core-source/src/parser.rs", "reason": "调用方收口"}
{"file": "core/core-source/src/types.rs", "reason": "ContentRule helper"}
```

## 8. check.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md", "reason": "master report 主题：重复 SQL / 重复实现 / 死代码"}
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-logic.md", "reason": "Wave 1B"}
{"file": ".trellis/tasks/05-20-fix-roadmap/plan/batches/BATCH-15-unify-rule-engine.md", "reason": "本批次自身验收清单"}
```
