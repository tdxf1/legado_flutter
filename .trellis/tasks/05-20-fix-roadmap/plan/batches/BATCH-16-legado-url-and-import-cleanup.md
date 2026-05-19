# BATCH-16: legado/url & import 边界统一 + RSS BOM 复用 + spawn_blocking 统一

**Stage**: P1
**Slug**: `legado-url-and-import-cleanup`
**Effort**: M (≤500 行)
**Depends on**: BATCH-15 (rule 系统已统一)

## 1. 范围

清理 legado/import & url & rss 中 5 条架构 / 正确性问题：clean_legado_url 与 url::extract 双实现、模板"<,{{page}}>"逻辑分散、JSONPath lookbehind 漏配、RSS BOM 双份剥离、spawn_blocking 路径不一致。

## 2. 包含的 findings

- [F-W1B-034] clean_legado_url 用 rsplit_once(',') 与 url::extract 不一致 — `core/core-source/src/legado/import.rs:594-606`
- [F-W1B-036] resolve_conditional_page 处理 <,{{page}}> 模板逻辑分散 — `core/core-source/src/legado/url.rs:236-268`
- [F-W1B-038] spawn_blocking 调阻塞 reqwest 可能 starvation — `core/core-source/src/parser.rs:1582-1607`
- [F-W1B-039] RSS BOM 剥离逻辑双份 — `core/core-source/src/rss/parse_xml.rs:55-76, mod.rs:87-89`
- [F-W1B-042] JSONPath 模板 lookbehind 漏配 — `core/core-source/src/legado/url.rs:471-495`

## 3. 影响文件

- `core/core-source/src/legado/import.rs:594-606` — 调用 `url::parse_legado_url` 取 path 字段；移除手写的 clean_legado_url
- `core/core-source/src/legado/url.rs:236-268` — `resolve_conditional_page` 加测试明确"仅支持第一处" 契约；或扩展支持多处
- `core/core-source/src/parser.rs:1582-1607` — 所有 `@js:` 规则统一走 spawn_blocking；rule_engine JS 路径改 async wrapper
- `core/core-source/src/rss/parse_xml.rs:55-76, mod.rs:87-89` — 公开 `skip_xml_prologue` 给 mod.rs 复用
- `core/core-source/src/legado/url.rs:471-495` — 加 unit test 覆盖嵌套 `{{ {$.x} }}` 场景；或在文档注明边界

## 4. 修复方向

复用 master findings-rust-logic.md 各条建议。

## 5. 测试策略

- Rust unit test：clean_legado_url 删除后所有 caller 走统一 url::parse_legado_url 路径
- Rust unit test：resolve_conditional_page 多处 `<...>` 行为一致或文档化
- Rust unit test：search/toc/book_info 走 JS 规则时不再 starve reactor
- Rust unit test：RSS feed 含 `<?xml ?>` 在 mod.rs detect_format 路径正常
- Rust unit test：JSONPath `{{ {$.x} }}` 嵌套行为明确

## 6. 验收

- [ ] master finding F-W1B-034/036/038/039/042 全部消解
- [ ] 现有 sy/*.json + RSS feed 测试集回归通过

## 7. implement.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-logic.md", "reason": "本批次涉及的 wave 1B findings"}
{"file": "core/core-source/src/legado/import.rs", "reason": "clean_legado_url"}
{"file": "core/core-source/src/legado/url.rs", "reason": "resolve_conditional_page + JSONPath"}
{"file": "core/core-source/src/parser.rs", "reason": "spawn_blocking 统一"}
{"file": "core/core-source/src/rss/parse_xml.rs", "reason": "skip_xml_prologue"}
{"file": "core/core-source/src/rss/mod.rs", "reason": "BOM 剥离"}
```

## 8. check.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md", "reason": "master report"}
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-logic.md", "reason": "Wave 1B"}
{"file": ".trellis/tasks/05-20-fix-roadmap/plan/batches/BATCH-16-legado-url-and-import-cleanup.md", "reason": "本批次自身验收清单"}
```
