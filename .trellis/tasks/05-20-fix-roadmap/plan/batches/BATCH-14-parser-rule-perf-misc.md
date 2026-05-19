# BATCH-14: search/css/rate-limit/font 性能（parser & rule 余下条目）

**Stage**: P1
**Slug**: `parser-rule-perf-misc`
**Effort**: M (≤500 行)
**Depends on**: BATCH-13 (Runtime 池化)

## 1. 范围

清理 parser & rule 主路径上 4 条性能问题：search per-rule × per-item 慢、css HTML 重复 parse、rate limiter 全局 Mutex 竞争、font_mappings_json 全量序列化。

## 2. 包含的 findings

- [F-W1B-028] search 每个 item 单独 extract_from_contexts — `core/core-source/src/parser.rs:558-612`
- [F-W1B-029] execute_single_css 重复 parse_document — `core/core-source/src/legado/rule.rs:312-340`
- [F-W1B-030] RATE_LIMITER std::sync::Mutex 高并发时阻塞 — `core/core-source/src/parser.rs:29-30, 162`
- [F-W1B-031] font_mappings_json 反复序列化 — `core/core-source/src/legado/js_runtime.rs:1924-1953`

## 3. 影响文件

- `core/core-source/src/parser.rs:558-612` — search 重构为 per-item 一次性提取所有字段（嵌套循环外层 items 内层 fields）
- `core/core-source/src/legado/rule.rs:312-340` — 同一 html 只 parse_document 一次，按 RuleEngine 调用周期 cache（per-context cache_key）
- `core/core-source/src/parser.rs:29-30, 162` — 改 `dashmap` 或 sharded mutex；单个 source 严格同步，跨 source 完全可并行
- `core/core-source/src/legado/js_runtime.rs:1924-1953` — 增加 `__legado_replace_font_with_urls` 接口，全过程在 Rust 内完成；保留旧接口兼容

## 4. 修复方向

直接复用 master findings-rust-logic.md 的"建议"段落。

## 5. 测试策略

- Rust benchmark：search 1000 items 时间下降；20 书源并行搜索 RATE_LIMITER 不再热点
- Rust benchmark：CJK font 解码场景 chapter 处理时间下降
- 现有书源测试集回归

## 6. 验收

- [ ] master finding F-W1B-028/029/030/031 全部消解
- [ ] benchmark 数据贴 PR 描述

## 7. implement.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-logic.md", "reason": "本批次涉及的 wave 1B findings"}
{"file": "core/core-source/src/parser.rs", "reason": "search + RATE_LIMITER"}
{"file": "core/core-source/src/legado/rule.rs", "reason": "execute_single_css"}
{"file": "core/core-source/src/legado/js_runtime.rs", "reason": "font_mappings_json"}
```

## 8. check.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md", "reason": "master report"}
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-logic.md", "reason": "Wave 1B"}
{"file": ".trellis/tasks/05-20-fix-roadmap/plan/batches/BATCH-14-parser-rule-perf-misc.md", "reason": "本批次自身验收清单"}
```
