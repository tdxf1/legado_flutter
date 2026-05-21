# BATCH-04: JS 沙箱基础硬化（5 P0 + 1 P1，方案 A 完整 6 finding）

> Roadmap：`.trellis/tasks/archive/2026-05/05-20-fix-roadmap/plan/batches/BATCH-04-harden-js-sandbox-core.md`
> Master report：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md` 主题 1: JS 沙箱跑 Untrusted 远程书源代码

## Goal

把 Rust 端 JS 桥接 5 个 P0 安全短板 + 1 个 P1 一次性堵上：SSRF 防护 / 嵌套 Runtime 内存上限 / 文件桥默认禁用 / queryTtf SSRF + catch_unwind / HTTP 响应大小流式累计 / Android WebView bridge capability gate。

清理 6 条 finding：

1. **F-W1B-001 [P0]** java.ajax 系列 JS 桥接无 SSRF 防护 — `js_runtime.rs:1127-1228`
2. **F-W1B-002 [P0]** java.downloadFile / getFile / deleteFile / unzipFile 通过 `LEGADO_FILE_ROOT` env var 豁免沙箱 — `js_runtime.rs:2026-2179`
3. **F-W1B-003 [P0]** QuickJS 嵌套路径无内存/栈上限 — `js_runtime.rs:155-166`（主路径 line 174-175 已有 limit，BATCH-13 遗漏嵌套路径）
4. **F-W1B-004 [P0]** java.queryTtf 把任意 URL 当 ttf 下载（SSRF）+ 无 catch_unwind — `js_runtime.rs:2260-2305`
5. **F-W1B-010 [P1]** java HTTP 响应大小检查靠 `take(max+1)` 边界，chunked 可绕过 — `js_runtime.rs:1209-1221`
6. **F-W3-015 [P1]** LegadoJsBridge 50+ JavascriptInterface 方法对加载页 JS 全程暴露 — `MainActivity.kt:300`

## Decision (ADR-lite)

**Context**：
- Kotlin 端 `MainActivity.kt` 已有完整 SSRF 防护（`isPrivateHost` + `isAllowedWebViewUrl` + `isUrlSafeForFetch`），line 75-188。Rust 端 `js_runtime.rs` 完全没有。
- BATCH-13 已做 thread_local Runtime 池化 + memory/stack limit（line 174-175），但嵌套路径（line 155）漏了。
- `java_download_file` (line 2034) 和 `resolve_ttf_input` (line 2261-2267) 各自创建 `reqwest::blocking::Client` 发 HTTP 请求，都没有 host 校验。
- 响应大小用 `take(max_bytes + 1)` 后 `read_to_end` 是正确的（不依赖 Content-Length），但 `java_download_file` 的 `content_length().is_some_and(|len| len > MAX)` 仅检查 Content-Length header（chunked 无 header 时绕过）。实测 `java_download_file` 后面有流式累计 loop（line 2048-2072），所以 F-W1B-010 的"chunked 绕过"在 download 路径实际已有防护；真正的问题在 `java_http_request_blocking` 的 `take` 模式——但这也是正确的（`read_to_end` 最多读 max+1 字节后判 len > max）。**重新评估**：F-W1B-010 的 `take(max+1)` 模式本身是安全的（不依赖 Content-Length），finding 描述"chunked 可绕过"不准确。但 `java_download_file` 的 `content_length().is_some_and` 前置检查确实可被 chunked 绕过——不过后面的流式 loop 兜底了。**结论**：F-W1B-010 实际风险低于 P0 描述，但仍值得统一模式（删除 content_length 前置检查的误导性代码，仅保留流式累计）。

**Decision**：方案 A — 完整 6 finding 一次性做。

### 具体方案

1. **新建 `core/core-source/src/legado/ssrf_guard.rs`**（~100 行）：
   - `pub fn is_url_safe_for_fetch(url: &str) -> Result<(), SsrfError>`：scheme 限 http/https + host 不是 private/loopback/link-local/CGNAT/multicast
   - `pub fn is_private_host(host: &str) -> bool`：参考 Kotlin `isPrivateHost` 实现（IPv4 RFC1918 + loopback + link-local + CGNAT 100.64/10 + IPv6 ::1 + fe80::/10 + fc00::/7）
   - `pub enum SsrfError { ForbiddenScheme, PrivateHost, InvalidUrl }`
   - 不做 DNS rebinding 防护（Kotlin 端有 `isResolvedHostPublic` 但需要 async DNS resolve，Rust blocking 环境下做 `ToSocketAddrs` 会阻塞线程池；留 BATCH-10 评估）

2. **`js_runtime.rs` 改动**：
   - `java_http_request_blocking` (line 1127)：入口加 `ssrf_guard::is_url_safe_for_fetch(&url)?`（返回空串 on error，与原 `Err(_) => return String::new()` 语义对齐）
   - `java_download_file` (line 2034)：入口加 `is_url_safe_for_fetch(&url)`
   - `resolve_ttf_input` (line 2261)：HTTP 分支入口加 `is_url_safe_for_fetch(input)`
   - 嵌套路径 (line 155)：`Runtime::new()` 后加 `runtime.set_memory_limit(QUICKJS_MEMORY_LIMIT); runtime.set_max_stack_size(QUICKJS_STACK_LIMIT);`
   - `java_download_file` (line 2038-2043)：删除 `content_length().is_some_and(|len| len > MAX_ZIP_DOWNLOAD)` 前置检查（误导性；流式 loop 已兜底）
   - `resolve_ttf_input` HTTP 分支：加 `std::panic::catch_unwind` 包裹 `font_mappings_json(&bytes)` 调用（在 `java_query_ttf` line 2303 处包裹）
   - 缩 `MAX_ZIP_DOWNLOAD` 从 50 MiB → 10 MiB；`MAX_ZIP_ENTRY` 保持 10 MiB

3. **`http.rs` 改动**（LegadoHttpClient，非 JS 桥路径）：
   - `request_with_legado_url` 入口加 `ssrf_guard::is_url_safe_for_fetch(&url)?`（这是规则引擎的 HTTP 路径，同样需要 SSRF 防护）
   - 不改 `https_only(false)`（某些书源合法走 HTTP；BATCH-10 再评估 HTTPS-only + opt-in）

4. **`MainActivity.kt` 改动**（F-W3-015）：
   - `addJavascriptInterface` 后立即 `loadUrl(url)` 前不变
   - `evaluateAndFinish` 函数末尾（line 350 附近 `finish(...)` 调用前）加 `webView.removeJavascriptInterface("legadoNative")`
   - 这样 JS bridge 仅在 webJs 执行期间暴露；页面加载完成 + JS 执行完毕后立即 detach
   - **注意**：`onPageFinished` 和 `shouldInterceptRequest` 都调 `evaluateAndFinish()`，所以 bridge 在 eval 完成后统一 detach

5. **文件桥默认禁用**（F-W1B-002）：
   - `LEGADO_FILE_ROOT` 当前逻辑：env var 未设 → `resolve_file_path` / `resolve_write_path` 返回 None → 文件桥函数返回空串（等价禁用）
   - 实测：`LEGADO_FILE_ROOT` 在 Flutter 端由 `MainActivity.kt` line 248 设置为 `context.filesDir.resolve("legado_js_files")`
   - **改动**：在 `resolve_file_path` / `resolve_write_path` 入口加 `tracing::warn!` 日志（首次调用时），让审计可见；不改默认行为（已是"env var 未设 = 禁用"）
   - 缩 `MAX_ZIP_DOWNLOAD` 从 50 MiB → 10 MiB（减少 downloadFile 可写入的最大文件大小）
   - `java_unzip_file` 加拒绝符号链接条目（`entry.unix_mode()` 检查 `S_IFLNK`）

## Requirements

### F-W1B-001 — SSRF 防护

新建 `core/core-source/src/legado/ssrf_guard.rs`：

```rust
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

#[derive(Debug, Clone)]
pub enum SsrfError {
    ForbiddenScheme(String),
    PrivateHost(String),
    InvalidUrl(String),
}

impl std::fmt::Display for SsrfError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::ForbiddenScheme(s) => write!(f, "forbidden scheme: {s}"),
            Self::PrivateHost(h) => write!(f, "private/reserved host: {h}"),
            Self::InvalidUrl(u) => write!(f, "invalid URL: {u}"),
        }
    }
}

/// Returns Ok(()) if the URL is safe for outbound fetch (http/https + public host).
pub fn is_url_safe_for_fetch(url: &str) -> Result<(), SsrfError> {
    let parsed = url::Url::parse(url).map_err(|_| SsrfError::InvalidUrl(url.to_string()))?;
    let scheme = parsed.scheme();
    if scheme != "http" && scheme != "https" {
        return Err(SsrfError::ForbiddenScheme(scheme.to_string()));
    }
    let host = parsed.host_str().ok_or_else(|| SsrfError::InvalidUrl(url.to_string()))?;
    if is_private_host(host) {
        return Err(SsrfError::PrivateHost(host.to_string()));
    }
    Ok(())
}

pub fn is_private_host(host: &str) -> bool {
    let h = host.to_ascii_lowercase();
    if h == "localhost" || h == "ip6-localhost" || h == "ip6-loopback" {
        return true;
    }
    // Cloud metadata
    if h == "metadata.google.internal" || h == "169.254.169.254" {
        return true;
    }
    // Try parse as IP literal
    if let Ok(ip) = h.parse::<IpAddr>() {
        return is_private_ip(ip);
    }
    // Bracketed IPv6 (unlikely after url::Url parse, but defensive)
    let stripped = h.strip_prefix('[').and_then(|s| s.strip_suffix(']')).unwrap_or(&h);
    if let Ok(ip) = stripped.parse::<IpAddr>() {
        return is_private_ip(ip);
    }
    false
}

fn is_private_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            v4.is_loopback()                    // 127.0.0.0/8
            || v4.is_private()                  // 10/8, 172.16/12, 192.168/16
            || v4.is_link_local()               // 169.254.0.0/16
            || v4.is_unspecified()              // 0.0.0.0
            || v4.is_broadcast()               // 255.255.255.255
            || v4.is_multicast()               // 224.0.0.0/4
            || is_cgnat(v4)                    // 100.64.0.0/10
        }
        IpAddr::V6(v6) => {
            v6.is_loopback()                    // ::1
            || v6.is_unspecified()              // ::
            || v6.is_multicast()               // ff00::/8
            || is_ipv6_link_local(v6)          // fe80::/10
            || is_ipv6_unique_local(v6)        // fc00::/7
            || is_ipv4_mapped_private(v6)      // ::ffff:10.x.x.x etc.
        }
    }
}

fn is_cgnat(v4: Ipv4Addr) -> bool {
    let [a, b, ..] = v4.octets();
    a == 100 && (b & 0xC0) == 64  // 100.64.0.0/10
}

fn is_ipv6_link_local(v6: Ipv6Addr) -> bool {
    let segs = v6.segments();
    (segs[0] & 0xFFC0) == 0xFE80
}

fn is_ipv6_unique_local(v6: Ipv6Addr) -> bool {
    let segs = v6.segments();
    (segs[0] & 0xFE00) == 0xFC00
}

fn is_ipv4_mapped_private(v6: Ipv6Addr) -> bool {
    if let Some(v4) = v6.to_ipv4_mapped() {
        is_private_ip(IpAddr::V4(v4))
    } else {
        false
    }
}
```

**Callers**（3 处 + 1 处 http.rs）：
- `java_http_request_blocking` line 1132 后：`if let Err(_e) = ssrf_guard::is_url_safe_for_fetch(&url) { return String::new(); }`
- `java_download_file` line 2026 后：同上
- `resolve_ttf_input` line 2261 HTTP 分支入口：`ssrf_guard::is_url_safe_for_fetch(input).ok()?;`
- `http.rs::LegadoHttpClient` 的 `request` 方法入口：`ssrf_guard::is_url_safe_for_fetch(&url)?`（需要 `impl From<SsrfError> for ...` 或 map_err）

### F-W1B-003 — 嵌套 Runtime 内存上限

`js_runtime.rs` line 155-156 改：

```rust
if QUICKJS_POOL_BUSY.with(|cell| cell.get()) {
    let runtime = Runtime::new().map_err(|e| format!("quickjs runtime: {e}"))?;
    runtime.set_memory_limit(QUICKJS_MEMORY_LIMIT);   // 新增
    runtime.set_max_stack_size(QUICKJS_STACK_LIMIT);   // 新增
    let context = Context::full(&runtime).map_err(|e| format!("quickjs context: {e}"))?;
    ...
}
```

### F-W1B-002 — 文件桥收紧

- `MAX_ZIP_DOWNLOAD` 从 `50 * 1024 * 1024` 缩到 `10 * 1024 * 1024`
- `java_unzip_file` 加符号链接拒绝：在 entry 循环内检查 `entry.unix_mode()` 含 `0o120000`（S_IFLNK）时 skip
- `resolve_file_path` / `resolve_write_path` 入口加 `tracing::debug!` 日志（审计可见）

### F-W1B-004 — queryTtf catch_unwind + SSRF

- `resolve_ttf_input` HTTP 分支入口加 `ssrf_guard::is_url_safe_for_fetch(input).ok()?;`（与 F-W1B-001 共用）
- `java_query_ttf` (line 2299-2305) 改：

```rust
fn java_query_ttf(input: String) -> String {
    let bytes = match resolve_ttf_input(&input) {
        Some(b) => b,
        None => return "null".to_string(),
    };
    // catch_unwind 防止畸形 ttf 触发 panic
    match std::panic::catch_unwind(|| font_mappings_json(&bytes)) {
        Ok(result) => result,
        Err(_) => "null".to_string(),
    }
}
```

同样包裹 `java_query_base64_ttf` (line 2289-2296)。

### F-W1B-010 — 响应大小统一

- `java_download_file` line 2038-2043：删除 `content_length().is_some_and(...)` 前置检查（流式 loop 已兜底，前置检查仅是 fast-path 优化但给人"这是唯一防线"的错觉）
- 不改 `java_http_request_blocking` 的 `take(max+1)` 模式（已正确）
- 加注释说明 `take(max+1) + read_to_end + len > max` 模式为何安全

### F-W3-015 — Android bridge capability gate

`MainActivity.kt::evaluateAndFinish` 函数内，在 `finish(...)` 调用前加：

```kotlin
try {
    webView.removeJavascriptInterface("legadoNative")
} catch (_: Exception) { /* already removed or webView destroyed */ }
```

这样 JS bridge 仅在 webJs 执行期间暴露；`onPageFinished` / `shouldInterceptRequest` 触发 `evaluateAndFinish` 后 bridge 立即 detach。

## Acceptance Criteria

- [ ] `cargo build --workspace` 0 error
- [ ] `cargo test --workspace` 全过（含本批新增 ~10-15 单测）
- [ ] `flutter analyze` 0 issues（Android Kotlin 改动不影响 Dart）
- [ ] `flutter test` 483/483 PASS（不动 Dart 层）
- [ ] grep `is_url_safe_for_fetch` 在 `js_runtime.rs` + `http.rs` 共 4 处调用
- [ ] grep `set_memory_limit` 在 `js_runtime.rs` 出现 2 处（主路径 + 嵌套路径）
- [ ] grep `removeJavascriptInterface` 在 `MainActivity.kt` 出现 1 处
- [ ] master finding F-W1B-001/002/003/004/010 + F-W3-015 全部消解

## Definition of Done

- 测试：~10-15 Rust 单测 + 既有全过
- Lint：cargo clippy 0 warning；flutter analyze 0 issues
- 文档：master report 6 条 Resolution + spec 加「JS 沙箱安全边界 (BATCH-04)」段
- Commit：3 个（fix(rust+android) + docs(trellis) + archive）

## Out of Scope

- DNS rebinding 防护（`ToSocketAddrs` resolve 后再判 IP）— BATCH-10
- `https_only` 强制 + opt-in HTTP — BATCH-10
- `java._vars` 跨脚本泄漏 — BATCH-10 (F-W1B-006)
- `{{...}}` 模板表达式 dangerous-eval — BATCH-10 (F-W1B-008)
- `import_legado_source` 大小上限 — BATCH-10 (F-W1B-009)
- `js_script_to_expression` 字符串拼接注入 — BATCH-10 (F-W1B-013)
- `WebViewBridgeThreatModel.md` 完整文档 — BATCH-10（本批仅做 capability gate 实施）
- 书源可信开关 UI — 需要 Flutter + FRB 联动，留独立批次

## Technical Notes

- **`url` crate 依赖**：`core-source/Cargo.toml` 已有 `url = "2"` 依赖（通过 `ureq` 间接引入）；如果没有直接依赖需要加。
- **`std::panic::catch_unwind`**：`font_mappings_json` 内部调 `ttf-parser::Face::parse`，该 crate 不保证 panic-free（虽然大部分路径返回 Result）；catch_unwind 是 defense-in-depth。需要确保 `font_mappings_json` 是 `UnwindSafe`（或用 `AssertUnwindSafe` 包裹）。
- **`reqwest` redirect policy**：默认 follow 10 次。SSRF guard 在入口 URL 检查，但 redirect 目标可能是 private host。**改动**：`js_http_client` 加 `.redirect(reqwest::redirect::Policy::custom(|attempt| { ... ssrf check ... }))` 或简单限制 `.redirect(reqwest::redirect::Policy::limited(5))` + 在 redirect 回调中检查目标 host。**简化方案**：本批仅做入口 URL 检查 + 限制 redirect 次数到 5（默认 10 太多）；redirect 目标 SSRF 检查留 BATCH-10（需要 async resolve 或 blocking resolve 的 trade-off 评估）。
- **`http.rs` error type**：`LegadoHttpClient` 方法返回 `Result<String, Box<dyn std::error::Error>>`；`SsrfError` 需要 `impl std::error::Error`。
- **Android `removeJavascriptInterface` timing**：在 `evaluateAndFinish` 内 `finish(result)` 前调用。`finish` 是 `MethodChannel.invokeMethod("webViewResult", result)` 回传 Flutter 端。detach 在 result 回传前执行，确保 JS bridge 不会在 result 回传后被恶意页面利用。
- **嵌套 Runtime 频率**：嵌套路径（line 154-167）仅在 JS 调 `java.getString(rule)` → Rust `execute_legado_rule` → 再次 eval JS 时触发。频率低但攻击者可构造递归书源触发。加 memory limit 后递归深度受限。
- **`MAX_ZIP_DOWNLOAD` 缩小影响**：从 50 MiB → 10 MiB。现有书源 downloadFile 用例（字体文件 / 图片包）通常 < 5 MiB；10 MiB 足够。如有用户报告"下载失败"可后续调大。

## 范围内具体改动

### 新增

- `core/core-source/src/legado/ssrf_guard.rs`（~100 行）
- `core/core-source/src/legado/ssrf_guard_test.rs` 或 `#[cfg(test)] mod tests`（~80 行，15 case）

### 修改

- `core/core-source/src/legado/mod.rs`：加 `pub mod ssrf_guard;`
- `core/core-source/src/legado/js_runtime.rs`：
  - line 155 嵌套路径加 memory/stack limit（+2 行）
  - line 1132 `java_http_request_blocking` 入口加 SSRF check（+3 行）
  - line 1933 `MAX_ZIP_DOWNLOAD` 50→10 MiB
  - line 2034 `java_download_file` 入口加 SSRF check + 删 content_length 前置检查（+3/-5 行）
  - line 2261 `resolve_ttf_input` HTTP 分支加 SSRF check（+1 行）
  - line 2299 `java_query_ttf` 加 catch_unwind（+5 行）
  - line 2289 `java_query_base64_ttf` 加 catch_unwind（+5 行）
  - `java_unzip_file` 加符号链接拒绝（+5 行）
  - `js_http_client` 加 `.redirect(Policy::limited(5))`（+1 行）
- `core/core-source/src/legado/http.rs`：
  - `request` 方法入口加 SSRF check（+3 行）
  - `impl From<SsrfError> for Box<dyn Error>` 或 map_err
- `core/core-source/Cargo.toml`：确认 `url` 直接依赖存在（可能已有）
- `flutter_app/android/app/src/main/kotlin/.../MainActivity.kt`：
  - `evaluateAndFinish` 内加 `removeJavascriptInterface`（+3 行）

### 测试新增

- `ssrf_guard.rs` 内 `#[cfg(test)]` 模块：~15 case（loopback / RFC1918 / link-local / CGNAT / multicast / IPv6 ::1 / fe80:: / fc00:: / public OK / scheme reject / metadata.google.internal / IPv4-mapped IPv6）
- `js_runtime.rs` 内加 2 case：嵌套 Runtime memory limit 生效（`new Array(1<<28)` 触发 OOM）；SSRF URL 被拒
- `java_query_ttf` 加 1 case：畸形 bytes 不 panic

总改动估算：新建 ~180 行 + 修改 ~50 行 + 测试 ~100 行 = ~330 行（roadmap 估 ≤800，实际远小于预估）。
