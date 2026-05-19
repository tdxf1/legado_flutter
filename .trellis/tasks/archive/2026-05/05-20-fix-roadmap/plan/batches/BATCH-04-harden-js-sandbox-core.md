# BATCH-04: JS 沙箱基础硬化（SSRF / 内存上限 / 文件桥）

**Stage**: P0
**Slug**: `harden-js-sandbox-core`
**Effort**: L (≤800 行)
**Depends on**: none

## 1. 范围

把 JS 桥接 4 个 P0 安全短板一次性堵上：SSRF / 内存上限 / 文件桥豁免 / queryTtf 远程下载。集中改 `core-source/legado/js_runtime.rs` + `legado/http.rs`，不混批是因为这部分需要专项 threat model 评审。

## 2. 包含的 findings

- [F-W1B-001] java.ajax 系列 JS 桥接无 SSRF 防护 — `core/core-source/src/legado/js_runtime.rs:886-998`
- [F-W1B-002] java.downloadFile / getFile / deleteFile / unzipFile 通过 `LEGADO_FILE_ROOT` env var 豁免沙箱 — `core/core-source/src/legado/js_runtime.rs:1733-1796`
- [F-W1B-003] QuickJS 无内存 / 栈上限，仅 wall-clock 超时 — `core/core-source/src/legado/js_runtime.rs:301-329`
- [F-W1B-004] java.queryTtf 把任意 base64 输入当 ttf 解析（含远程下载路径） — `core/core-source/src/legado/js_runtime.rs:1966-1999`
- [F-W1B-010] java HTTP 响应大小检查靠 `take(max+1)`，chunked 可绕过 — `core/core-source/src/legado/js_runtime.rs:980-992` (强耦合：同主题 + 同模块网络层)
- [F-W3-015] LegadoJsBridge 50+ JavascriptInterface 方法对加载页 JS 全开 — `flutter_app/android/.../MainActivity.kt:300` (强耦合：同 JS 沙箱主题，且 Rust 端做完后 Android 端必须同步收紧 capability)

## 3. 影响文件

- `core/core-source/src/legado/js_runtime.rs:886-998` — `java_http_request_blocking` 加 SSRF 黑白名单 helper（参考 `MainActivity.kt::isPrivateHost` 等价 Rust 实现）；scheme 限制 http/https；URL parse 后阻止 RFC1918 / loopback / link-local
- `core/core-source/src/legado/js_runtime.rs:301-329` — `Runtime::new()` 后调 `set_memory_limit(64 * 1024 * 1024)` + `set_max_stack_size(1 * 1024 * 1024)`
- `core/core-source/src/legado/js_runtime.rs:1733-1820` — 默认禁用文件类 bridge（`LEGADO_FILE_ROOT` 改成"显式 opt-in 才生效"）；缩 MAX_ZIP_DOWNLOAD/ENTRY；解压拒绝符号链接
- `core/core-source/src/legado/js_runtime.rs:1966-1999` — `java.queryTtf` 走与 java.ajax 相同 SSRF 白名单；输入大小封 5MB；`Face::parse` 包 `catch_unwind`
- `core/core-source/src/legado/js_runtime.rs:980-992` — 响应大小用 `Content-Length` + 流式累计，不依赖 take 边界
- `flutter_app/android/app/src/main/kotlin/io/legado/app/flutter/MainActivity.kt:300` — JS bridge capability gate：`removeJavascriptInterface` → `loadUrl` → `evaluateJavascript(webJs)` → 立即 `removeJavascriptInterface`

## 4. 修复方向

- F-W1B-001：默认阻止 RFC1918 / loopback / link-local / 多播；做一个可配置 allowlist；URL scheme 限制到 http/https；所有 `java.proxy` 走系统代理或拒绝。
- F-W1B-002：默认禁用文件类 bridge；用户级 opt-in（书源可信开关）；下载 URL 校验同 F-W1B-001；缩小 MAX_ZIP_DOWNLOAD/ENTRY 到 10MB/2MB；解压前严格 enclosed_name 校验已有，再加拒绝符号链接条目。
- F-W1B-003：调 `Runtime::set_memory_limit(64MB)` + `set_max_stack_size(1MB)`，并把 GC threshold 调小让长期运行的服务也及时释放。
- F-W1B-004：与 F-W1B-001 共用 SSRF 白名单；并把 Face::parse 包 `catch_unwind`；输入大小封 5MB。
- F-W1B-010：给 JS bridge 设全局 in-flight Semaphore（如 8 并发）；超过总限直接 timeout error 而非排队 hang。
- F-W3-015：高危方法（`readFile` / `downloadFile` / `unzipFile` / `aesCrypt`）用 capability flag 控制，默认 off，只在书源 explicit opt-in 时打开；撰写 `WebViewBridgeThreatModel.md`。

## 5. 测试策略

- Rust unit test：构造 SSRF payload（URL 指向 127.0.0.1 / 169.254.169.254 / 内网 RFC1918）确认被拒；构造大响应（chunked transfer）确认 size cap 生效。
- Rust unit test：QuickJS 跑 `new Array(1<<28)` 确认 memory limit 触发；递归调用确认 stack limit。
- Rust unit test：java.queryTtf 输入畸形 ttf 不 panic（catch_unwind 工作）。
- 手动：Android 端 webview 加载已知书源页面，确认 capability gate 不破坏正常解析；尝试加载恶意 HTML 确认 JS bridge 已 detach。

## 6. 验收

- [ ] master finding F-W1B-001/002/003/004/010 / F-W3-015 全部消解
- [ ] `WebViewBridgeThreatModel.md` 落地，列出每个 JavascriptInterface 方法的威胁分析
- [ ] 现有书源测试集（sy/*.json）回归通过

## 7. implement.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-logic.md", "reason": "本批次涉及的 wave 1B findings（F-W1B-001~010）"}
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-cross-config.md", "reason": "F-W3-015 LegadoJsBridge 详细分析"}
{"file": "core/core-source/src/legado/js_runtime.rs", "reason": "JS 桥接主体，SSRF / 内存 / 文件桥 / queryTtf 全部在此"}
{"file": "core/core-source/src/legado/http.rs", "reason": "LegadoHttpClient + redirect / scheme 防护"}
{"file": "flutter_app/android/app/src/main/kotlin/io/legado/app/flutter/MainActivity.kt", "reason": "LegadoJsBridge 注入逻辑"}
{"file": ".trellis/spec/backend/quality-guidelines.md", "reason": "JS 沙箱安全约束写入 spec"}
```

## 8. check.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md", "reason": "master report 主题汇总：JS 沙箱主题"}
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-logic.md", "reason": "Wave 1B 详细 findings"}
{"file": ".trellis/tasks/05-20-fix-roadmap/plan/batches/BATCH-04-harden-js-sandbox-core.md", "reason": "本批次自身验收清单"}
{"file": ".trellis/spec/backend/quality-guidelines.md", "reason": "JS 沙箱安全约束是否落地 spec"}
```
