# BATCH-13: QuickJS Runtime 池化 + Context 复用

**Stage**: P1
**Slug**: `quickjs-runtime-pool`
**Effort**: M (≤500 行)
**Depends on**: BATCH-11 (java.put 语义已 thread_local 落地)

## 1. 范围

把"每次 eval new Runtime + register 30+ Function"的重型初始化改为 per-thread / per-source 复用——是 chapter list / search / template 多个调用路径的共同瓶颈，单批做能让所有相关 finding 一次性验证。

## 2. 包含的 findings

- [F-W1B-023] QuickJS Runtime 每次新建注册 30+ Function — `core/core-source/src/legado/js_runtime.rs:303-322`
- [F-W1B-024] chapter list js_lib 每章新建 runtime — `core/core-source/src/parser.rs:1551-1567`
- [F-W1B-026] resolve_template_expressions 每个 {{}} 块新建 runtime — `core/core-source/src/legado/url.rs:185-213, 546, 555`
- [F-W1B-027] execute_js_rule / execute_inline_js_rule 各自 new Runtime — `core/core-source/src/legado/rule.rs:514-523, 593-655`
- [F-W1B-025] parse_chapters_from_page 每章 extract_from_contexts — `core/core-source/src/parser.rs:1198-1366`

## 3. 影响文件

- `core/core-source/src/legado/js_runtime.rs:303-322` — 在 BookSourceParser / RuleEngine 实例上挂 `thread_local!` lazy Runtime；新增 `with_runtime(|rt| ...)` API 让 caller 复用
- `core/core-source/src/parser.rs:1551-1567` — jsLib 后处理改用复用的 runtime；jsLib 脚本编译结果按"书源 ID"cache
- `core/core-source/src/legado/url.rs` — `resolve_template_expressions` 把 runtime 作为参数沿调用链传，函数链路上只建一次
- `core/core-source/src/legado/rule.rs` — `execute_js_rule` / `execute_inline_js_rule` 接受外部 runtime
- `core/core-source/src/parser.rs:1198-1366` — `parse_chapters_from_page` 改用 batch 调用：JS-only 规则一次 eval 处理所有 items；Rust 端规则避免 ctx.clone（用 `&mut ctx`）

## 4. 修复方向

按 master findings-rust-logic.md 推荐：rquickjs Runtime per-thread 复用；`Mutex<Runtime>` + `Vec<Context>` pool 也是 fallback。jsLib script 编译结果可用 LRU cache。

## 5. 测试策略

- Rust benchmark：1000 章书 chapter_list 处理时间从 N 秒降至 < N/3 秒
- Rust unit test：复用 runtime 后 java.put / java.get 跨调用语义正确（无串扰）
- 现有书源测试集回归

## 6. 验收

- [ ] master finding F-W1B-023/024/025/026/027 全部消解
- [ ] benchmark 数据贴 PR 描述

## 7. implement.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-logic.md", "reason": "本批次涉及的 wave 1B findings"}
{"file": "core/core-source/src/legado/js_runtime.rs", "reason": "Runtime 池"}
{"file": "core/core-source/src/parser.rs", "reason": "chapter_list / search 调用路径"}
{"file": "core/core-source/src/legado/url.rs", "reason": "template expression"}
{"file": "core/core-source/src/legado/rule.rs", "reason": "execute_js_rule"}
```

## 8. check.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md", "reason": "master report"}
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-logic.md", "reason": "Wave 1B"}
{"file": ".trellis/tasks/05-20-fix-roadmap/plan/batches/BATCH-13-quickjs-runtime-pool.md", "reason": "本批次自身验收清单"}
```
