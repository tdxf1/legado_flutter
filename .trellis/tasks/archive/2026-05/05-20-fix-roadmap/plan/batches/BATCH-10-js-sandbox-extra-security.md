# BATCH-10: JS 沙箱补充安全（zip-slip / shared vars / template eval / DoS / HTTPS）

**Stage**: P1
**Slug**: `js-sandbox-extra-security`
**Effort**: M (≤500 行)
**Depends on**: BATCH-04 (基础 SSRF / 内存上限已就位)

## 1. 范围

把 BATCH-04 没解决但同主题的 6 条 P1 一次性堵上：zip-slip、shared variables 跨脚本泄漏、HTTPS-only redirect 限制、模板表达式 dangerous-eval、import 大小上限、JS 字符串拼接注入。

## 2. 包含的 findings

- [F-W1B-005] ZIP 路径无 traversal 防护（getZipStringContent / getZipByteArrayContent / read_allowed_file） — `core/core-source/src/legado/js_runtime.rs:1640-1675, 2041-2052`
- [F-W1B-006] java._vars 全局绑定，跨脚本变量泄漏 — `core/core-source/src/legado/js_runtime.rs:2081-2265`
- [F-W1B-007] LegadoHttpClient https_only(false) + 无 cross-scheme redirect 限制 — `core/core-source/src/legado/http.rs:25-30, 46-52`
- [F-W1B-008] {{...}} 模板表达式 dangerous-eval — `core/core-source/src/legado/url.rs:185-213, 496-560`
- [F-W1B-009] import_legado_source 无大小/字段数上限 — `core/core-source/src/legado/import.rs:264-272`
- [F-W1B-013] js_script_to_expression 字符串拼接生成 JS（注入风险） — `core/core-source/src/legado/js_runtime.rs:411-419`

## 3. 影响文件

- `core/core-source/src/legado/js_runtime.rs:1640-1675, 2041-2052` — `getZipStringContent` 解压前校验 path 不含 `..` / 不绝对；`read_allowed_file` 拒绝绝对路径与 `..`
- `core/core-source/src/legado/js_runtime.rs:2081-2265` — `java._vars` 改只读视图；显式列白允许 JS 写入的变量名；shared_variables 改 per-rule scope
- `core/core-source/src/legado/http.rs:25-30, 46-52` — 限制最大重定向跳数（如 5）；对每跳 host 做 SSRF 校验；增加配置位允许信任书源走 plain HTTP
- `core/core-source/src/legado/url.rs:185-213, 496-560` — 模板表达式只允许预定义白名单（key/keyword/page/encodeKey）；扩展表达式走简单 expression evaluator；keyword 注入前 sanitize
- `core/core-source/src/legado/import.rs:264-272` — import 入口设 max_size（5MB）+ max_entries（5000）；jsLib 字段单独限长（256KB）
- `core/core-source/src/legado/js_runtime.rs:411-419` — `js_script_to_expression` 改用 IIFE 包装代替字符串拼接；或 escape 输入

## 4. 修复方向

- 严格按 master findings-rust-logic.md 中各条"建议"段落实施。
- F-W1B-006：与 F-W1B-001 主题相通；shared_variables per-rule scope 是基础重构，需评估对现有书源的兼容性。
- F-W1B-008：白名单 evaluator 优先；如必须保留 JS，keyword sanitize（拒绝包含 `;`/`'`/换行的关键词或 base64 → JS 端 decode）。

## 5. 测试策略

- Rust unit test：构造含 `..` / 绝对路径的 zip entry 路径被拒绝
- Rust unit test：跨规则评估时 shared_variables 不互相串
- Rust unit test：6 跳 redirect 链路被拒绝
- Rust unit test：搜索 keyword 含 `;eval(...)` 不会被当 JS 代码运行
- Rust unit test：import_legado_source 6MB JSON 被拒绝；jsLib 300KB 被拒绝
- 现有 sy/*.json 测试集回归

## 6. 验收

- [ ] master finding F-W1B-005/006/007/008/009/013 全部消解
- [ ] 现有书源测试集回归通过（兼容性影响在 F-W1B-006 / 008 显著时需 spec 明确兼容性损失）

## 7. implement.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-logic.md", "reason": "本批次涉及的 wave 1B findings"}
{"file": "core/core-source/src/legado/js_runtime.rs", "reason": "zip-slip + shared vars + js_script_to_expression"}
{"file": "core/core-source/src/legado/http.rs", "reason": "redirect / scheme 限制"}
{"file": "core/core-source/src/legado/url.rs", "reason": "模板表达式 evaluator"}
{"file": "core/core-source/src/legado/import.rs", "reason": "import 大小上限"}
{"file": ".trellis/spec/backend/quality-guidelines.md", "reason": "JS 沙箱补充安全约束"}
```

## 8. check.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md", "reason": "master report 主题：JS 沙箱"}
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-logic.md", "reason": "Wave 1B 详细 findings"}
{"file": ".trellis/tasks/05-20-fix-roadmap/plan/batches/BATCH-10-js-sandbox-extra-security.md", "reason": "本批次自身验收清单"}
{"file": ".trellis/spec/backend/quality-guidelines.md", "reason": "spec 是否落地"}
```
