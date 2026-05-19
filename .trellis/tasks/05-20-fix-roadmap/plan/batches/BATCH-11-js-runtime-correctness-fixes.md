# BATCH-11: JS runtime 序列化 / 解析 / time_format 一致性修正

**Stage**: P1
**Slug**: `js-runtime-correctness-fixes`
**Effort**: M (≤500 行)
**Depends on**: BATCH-04 (基础硬化已就位)

## 1. 范围

修复 5 条 QuickJS 调用流程的正确性问题：runtime 复用对 java.put 的影响、JSON.stringify(undefined) 序列化不一致、HashMap 键序不稳、_resolveUrl 与 Rust 端实现不一致、java_time_format 启发式 bug。

## 2. 包含的 findings

- [F-W1B-011] 每次 eval 都 new Runtime + Context，性能 + 状态泄漏（影响 java.put 跨阶段失效） — `core/core-source/src/legado/js_runtime.rs:303-329`
- [F-W1B-012] JSON.stringify(undefined) 序列化丢失 — `core/core-source/src/legado/js_runtime.rs:323-326`
- [F-W1B-014] legado_value_to_js_expr 用 HashMap 序列化键序不稳 — `core/core-source/src/legado/js_runtime.rs:451-478`
- [F-W1B-015] _resolveUrl JS 实现与 Rust 端 build_full_url 行为不一致 — `core/core-source/src/legado/js_runtime.rs:2191-2204`
- [F-W1B-016] java_time_format 整数 / 毫秒判断启发式有 bug — `core/core-source/src/legado/js_runtime.rs:1574-1585`

## 3. 影响文件

- `core/core-source/src/legado/js_runtime.rs:303-329` — Runtime 复用基础设施（也是 BATCH-13 的前置，但这里只解决 java.put 跨阶段语义；具体 pool 化在 BATCH-13）
  - 至少：让 `java.put` 写到 `LEGADO_JS_VARIABLES` thread_local（write-through），下次 eval 还能拿到
- `core/core-source/src/legado/js_runtime.rs:323-326` — 在 PREAMBLE 增加 `result.toString` 兜底；或 wrapper 提供 `toJSON`；文档化此限制
- `core/core-source/src/legado/js_runtime.rs:451-478` — 用 BTreeMap 排序后再生成 JS 对象字面量；长期用 rquickjs 直接 set object property
- `core/core-source/src/legado/js_runtime.rs:2191-2204` — JS bridge 增加 `__legado_resolve_url` 调 url crate 实现，PREAMBLE 调它；删除 JS 端手写 _resolveUrl
- `core/core-source/src/legado/js_runtime.rs:1574-1585` — 改成显式毫秒 / 秒标志参数；或用 `>= 10^11` 判定毫秒；记录 Legado 原项目语义（chrono 默认毫秒）

## 4. 修复方向

直接复用 master findings-rust-logic.md 的"建议"段落。

## 5. 测试策略

- Rust unit test：search→content 阶段间 java.put 设置的 cookie 在第二次 eval 仍可见
- Rust unit test：`return undefined` 与 `return ''` 在 JS 端被区分
- Rust unit test：legado_value_to_js_expr Map 输出键序稳定（可重复）
- Rust unit test：相对 URL 在 JS 端与 Rust 端解析结果一致
- Rust unit test：java_time_format 边界值（999_999_999 / 1_000_000_000）行为正确

## 6. 验收

- [ ] master finding F-W1B-011/012/014/015/016 全部消解
- [ ] 现有书源测试集回归通过

## 7. implement.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-logic.md", "reason": "本批次涉及的 wave 1B findings"}
{"file": "core/core-source/src/legado/js_runtime.rs", "reason": "JS runtime 主体"}
{"file": "core/core-source/src/utils.rs", "reason": "build_full_url 实现参考"}
```

## 8. check.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md", "reason": "master report"}
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-logic.md", "reason": "Wave 1B"}
{"file": ".trellis/tasks/05-20-fix-roadmap/plan/batches/BATCH-11-js-runtime-correctness-fixes.md", "reason": "本批次自身验收清单"}
```
