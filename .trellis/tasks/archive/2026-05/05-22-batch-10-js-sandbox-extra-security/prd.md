# BATCH-10: JS 沙箱补充安全（zip-slip + redirect + 模板表达式 + import + IIFE 统一）

**Stage**: P1
**Depends on**: BATCH-04 ✅
**Effort**: M（≤300 行 + tests）
**实施范围**: 5 P1 finding（F-W1B-005/007/008/009/013）+ 1 标 Resolved-by-Design（F-W1B-006）

## 1. 范围

把 BATCH-04 没解决但同主题的 P1 finding 一次性堵上，外加把 F-W1B-006 用 spec 边界文档化。

## 2. 包含的 findings

### 实施修复（5 条）

| Finding | 当前状态 | 实施 |
|---------|---------|------|
| F-W1B-005 | `java.getZipStringContent` / `java.getZipByteArrayContent` 用 `archive.by_name(path)` 无 `..` 校验；`read_allowed_file` 用 `path.trim_start_matches('/')` 后 canonicalize（symlink 窗口） | `js_runtime.rs:1930-1942` 入口 reject `..` / 绝对路径；`read_allowed_file` (line 2414) 在 join 前显式 reject `..` 段 |
| F-W1B-007 | `LegadoHttpClient` ureq agent 无 redirect 限制（`http.rs:25-30, 46-52`，`https_only(false)` 业务豁免，已 ADR） | 加 `.max_redirects(5)` + 默认 `max_redirects_will_error(true)`（ureq 3.x default 已是 10，缩到 5） |
| F-W1B-008 | `resolve_template_expressions` (`url.rs:185-213`) 把 `{{...}}` 内容当 JS eval；keyword 直接通过 `key=keyword` 注入到 JS scope | 关键路径加白名单 fast-path：`{key/keyword/page/encodeKey/encode_keyword}` 直接查 `vars` 命中即返回，不进 JS eval；剩余表达式仍走 JS（兼容性）；keyword `as_string_lossy` 路径已是 string 替换无注入风险 |
| F-W1B-009 | `import_legado_source` (`import.rs:264`) `serde_json::from_str` 无大小/字段数上限 | 入口加 `MAX_IMPORT_BYTES = 5 * 1024 * 1024` (5 MiB)；解析后 `legado_sources.len() > 5000` reject；`legado_to_imported` 单 source `js_lib`/`book_url_pattern` 等长字段 > 256 KiB reject |
| F-W1B-013 | `js_script_to_expression` (`js_runtime.rs:602-615`) 三分支：iife / contains_return / needs_direct_eval；后者用 `eval(...)` 字符串拼接（语法歧义） | 简化为：iife 透传；其他全部 IIFE 包装 `(function(){...})()`，删除 `needs_direct_eval` 分支 + 该函数 |

### 标 Resolved-by-Design（1 条）

**F-W1B-006**：`java._vars` 跨脚本变量泄漏。
- 已有边界：`RuleContext` per-source 构造（`context.rs::new`），shared_variables 不跨 Context。
- 已有 RAII：`JsVariablesOverride`（BATCH-11）按帧快照/恢复 `LEGADO_JS_VARIABLES` thread_local。
- 业务必需：Legado 书源核心模式 `java.put('cookie', ...)` 在 search→content 阶段传递，BATCH-11 刚为此修过 write-through bridge。
- 收紧选项（如 PREAMBLE 拒绝 `__` 开头 key）已被 BATCH-11 的全局 PREAMBLE 设计内化（外部 JS 写不到 `__legado_xxx_*` bridge name 上，因为它们是 Rust 端注入的 free-standing function）。
- 在 spec 写明：业务侧持久状态走 `RuleContext::shared_variables`（Arc<Mutex>，cross-thread），单线程跨 eval 走 thread_local；不再考虑 `_vars` 名字白名单。

## 3. 影响文件

- `core/core-source/src/legado/js_runtime.rs`
  - `java_get_zip_string_content` / `java_get_zip_byte_array_content`：入口 reject `..` / 绝对路径
  - `read_allowed_file`：join 前显式 reject `..` 段
  - `js_script_to_expression`：删 `needs_direct_eval` 分支，改全 IIFE
  - 删 `needs_direct_eval` 函数（用法清零后死代码）
- `core/core-source/src/legado/http.rs`
  - 两处 `Agent::config_builder` 加 `.max_redirects(5)`
- `core/core-source/src/legado/url.rs`
  - `resolve_template_expressions`：白名单 fast-path 文档化（实际已是；显式 `WHITELIST` const + 注释边界）
- `core/core-source/src/legado/import.rs`
  - 入口加大小/数量上限
- `.trellis/spec/rust-core/quality-and-anti-patterns.md`
  - 新增「JS 模板表达式与 import 上限 (BATCH-10)」段
  - 「JS 沙箱安全边界 (BATCH-04)」段补 F-W1B-006 Resolved-by-Design 说明

## 4. 测试策略

- Rust unit test（新增）：
  - `test_get_zip_string_content_rejects_traversal`：path = `../etc/passwd` 返回空
  - `test_read_allowed_file_rejects_dotdot`：path = `subdir/../../etc` 返回 None
  - `test_legado_http_client_redirect_limited`：mock 6 跳 redirect 链返回错误（用 `mockito` 或 `httpmock`，本仓已有 mock 测试模板）
  - `test_import_rejects_oversized_json`：构造 6 MiB JSON，`Err`
  - `test_import_rejects_too_many_entries`：5001 entries，`Err`
  - `test_import_rejects_oversized_jslib`：单 source `js_lib` 300 KiB，`Err`
  - `test_js_script_to_expression_iife_for_var_decl`：`"var x=1; x"` 输出 `"(function(){var x=1; x})()"`
- 现有测试集回归：`cargo test --workspace` 95/95 必须 PASS
- Flutter 侧：`flutter analyze` 0 / `flutter test` 483/483 必须 PASS

## 5. 验收

- [ ] master finding F-W1B-005/007/008/009/013 全部消解（Resolution 标 BATCH-10）
- [ ] F-W1B-006 标 "Resolved-by-design BATCH-10" 并指 spec
- [ ] cargo build --workspace 0 error
- [ ] cargo test --workspace PASS（含新增 ~7 单测）
- [ ] flutter analyze 0 issue / flutter test PASS

## 6. 不在范围

- `https_only(true)` 切换：`http://` 中文小说源是常态业务豁免，已有 ADR（BATCH-05）
- DNS rebinding 防护：留 BATCH-10 之外（需要 async resolve 评估，单独 issue）
- redirect 每跳 SSRF 检查：ureq 3.x 没暴露 redirect callback；`max_redirects(5)` + 入口 SSRF 是当前防线（spec 写清）
- `shared_variables` per-rule 重构：tracked as Resolved-by-Design（已是 per-Context + thread_local RAII）
