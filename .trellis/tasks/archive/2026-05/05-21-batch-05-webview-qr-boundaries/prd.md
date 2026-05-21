# BATCH-05: WebView/QR 边界加固（6 finding：2 P0 + 4 P1，方案 A 集中安全库）

> Roadmap：`.trellis/tasks/archive/2026-05/05-20-fix-roadmap/plan/batches/BATCH-05-tighten-webview-and-qr-boundaries.md`
> Master report：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md` 主题 5: WebView / JS 边界缺安全 gating

## Goal

把 Flutter 端 3 个「远端 untrusted 内容直接进 WebView / dio.get」的入口一次性收紧（reader 主路径 webview / QR 扫码导入 / RSS 文章 webview），WebView 安全策略集中到 `core/security/webview_safety.dart` 单点；同步顺手清理 `_normalizeJsResult` 容错路径、WebView init silent catch、camera 权限拒绝路径无 UI fallback。

清理 6 条 finding：

1. **F-W2A-009 [P0]** WebView 始终 unrestricted JS + 无 URL scheme 校验 + 无 UA/headers 校验
2. **F-W2B-002 [P0]** QR 扫到的 URL 直接 dio.get，无 host 校验、无 body size 限制
3. **F-W2A-010 [P1]** `_normalizeJsResult` jsonDecode 失败粗暴去引号
4. **F-W2B-010 [P1]** RSS WebView unrestricted JS 加载远端 HTML，无 NavigationDelegate
5. **F-W2B-011 [P1]** WebViewController init 失败 catch silent（同 RSS 文件）
6. **F-W2B-058 [P1]** mobile_scanner 权限拒绝路径无 UI fallback

## Decision (ADR-lite)

**Context**：master report 主题 5 列了 7 条 WebView/JS 边界 finding，本批取其中 Flutter 侧 6 条。Roadmap batch 文档建议「集中到 `WebViewSafety` 单点」避免散开维护。3 个 webview caller 业务语义不同：

- **reader webview** (`_WebViewExecutionPage` in `core/platform_webview_executor.dart`): 业务上**必须** unrestricted JS（要在远端页面跑 `webJs` 提取规则——selectors / DOM 改写 / cookie 读取等）
- **RSS 文章 webview** (`rss_article_detail_page.dart`): 业务上**不需要** JS（仅展示订阅文章 HTML）
- **QR 扫码 fetch** (`qr_import_handler._fetchText`): 不走 webview，走 dio.get，但 URL 与 webview 同源威胁，host/scheme 校验复用同套规则

**Decision**：方案 A — 集中安全库 + 双 caller。新建 `flutter_app/lib/core/security/webview_safety.dart` 提供 4 个公共 API：

1. `enforceWebViewScheme(String url)` — 限定 `http(s)://`，拒 `file://`/`javascript:`/`data:`/`intent:`/`content:` 等，越界 throw `WebViewSafetyException`
2. `classifyHost(String url) → HostClass`（enum：`loopback` / `linkLocal` / `privateNetwork` / `public` / `invalid`）— 让 caller 决定是否拒绝（QR 扫码默认拒非 public；reader webview 不强制拒，仅记录 warning，因为某些书源合法走子域名/IP）
3. `defaultUserAgent()` — 返回项目统一的 UA 字符串（避免裸暴露 webview-flutter 默认 UA 暴露 Android API 版本等指纹）
4. `safeJsResultDecode(Object? raw) → String` — 取代 `_normalizeJsResult`，jsonDecode 失败时记录 `len=N hash=...`（debugPrint）并返回原始 toString()，不再粗暴 substring(1, len-1)

JS mode 由 caller 决定（reader=unrestricted, RSS=disabled），不放进 `WebViewSafety` 强制策略——避免反而限制 reader 业务路径。

**理由**（vs 方案 B 拆 BATCH-05b）：
- 方案 B 把 F-W2A-010/F-W2B-011/F-W2B-058 留二批：3 条 P1 都是「同文件顺手清」（W2A-010 与 W2A-009 同文件 `platform_webview_executor.dart`；W2B-011 与 W2B-010 同文件 `rss_article_detail_page.dart`；W2B-058 与 W2B-002 同 QR 主题）。拆批会让两批都打开同一文件，回归测试重跑，效率低。
- 方案 B 节省的 effort 仅是 ~80 行（3 条 P1 中两条是已有 catch 块改 `debugPrint`，第三条 mobile_scanner 用 errors 流监听，最小代码量），不值得分批。

**Consequences**：
- ✅ 6 条 finding 全部消解，主题 5 (WebView/JS 边界) Flutter 侧清完
- ✅ `WebViewSafety` 单点便于后续审计（grep `JavaScriptMode.unrestricted` 仅留 reader 一处合法 + 文档注释 ADR）
- ✅ QR 扫码引入 host classification + body size 限制，SSRF 防护到位
- ✅ 不引入新依赖（mobile_scanner 自身 errors 流监听权限拒绝；不需 permission_handler）
- ⚠️ reader webview 仍 unrestricted JS（业务约束，spec 要求加 ADR 文档化）
- ⚠️ host classification 对 IPv6 链路本地的支持不完整（Dart `Uri.parseIPv6Address` 简单实现），留 BATCH-05b 占位

## Requirements

### F-W2A-009 + F-W2A-010：reader webview 收紧

文件：`flutter_app/lib/core/platform_webview_executor.dart`

- `_executeNative` 与 `_WebViewExecutionPageState.initState` 在 `Uri.parse(url)` 前调 `enforceWebViewScheme(url)`，越界 throw（caller 已在 try-catch 中，UI 显示错误）。
- `_WebViewExecutionPage` 顶部 `_controller.setUserAgent(...)` 改：caller 提供 UA 时用 caller 的，否则用 `defaultUserAgent()`（不再让 webview-flutter 默认 UA 暴露指纹）。
- `_normalizeJsResult` 替换为 `safeJsResultDecode`：jsonDecode 失败时 `debugPrint` 记录 length + hash 后返回原值（带引号）不再 substring 去引号。
- reader webview 保留 `JavaScriptMode.unrestricted`（业务约束），在文件顶部 doc 注释 ADR：「reader webview 必须 unrestricted JS 跑远端 webJs 规则；scheme 白名单 + UA 默认值 + JS 字符串 sanitize 是 BATCH-05 引入的边界控制；新增 webview caller 必须走 `WebViewSafety`」。

### F-W2B-002 + F-W2B-058：QR 扫码 host 校验 + body size + 权限 fallback

文件：`flutter_app/lib/features/qr/legado_qr_protocol.dart` + `qr_import_handler.dart` + `qr_scan_page.dart`

- `legado_qr_protocol.dart::parseLegadoQrPayload` 解析后调 `enforceWebViewScheme(fetchUrl)`：拒非 http(s)，越界 → 返回 null（`null` 已被 `qr_scan_page` 处理为「未识别」dialog）。**不在 protocol 层校验 host class**（host class 决策属 UX policy 不属 parser）。
- `qr_scan_page._showConfirmDialog` 在显示导入确认 dialog 时，多展示一行 host class（`classifyHost` 结果）：private/loopback/linkLocal 用红字警告 + 「这是内网地址，可能是 SSRF 攻击。仍要导入吗？」。public 不显示警告。
- `qr_import_handler._fetchText` 加 max body size = 10 MB；超出 throw；同时加 Content-Type 校验：仅接受 `application/json` / `text/plain` / `text/json`（防被骗下载二进制）。
- `qr_scan_page._QrScanPageState`：监听 `_controller!.errors` stream（mobile_scanner 5.x 暴露 `Stream<MobileScannerException>`），异常 errorCode == `unauthorized`（或文本含 `permission`）时 → setState `_permissionDenied = true`，UI 切换显示「相机权限被拒绝」+ 提示文案「请到系统设置 → 应用 → 当前应用 → 权限 中开启相机权限」+ 返回按钮（不引入 app_settings/permission_handler 包）。

### F-W2B-010 + F-W2B-011：RSS webview 默认 JS 关闭 + NavigationDelegate + 错误日志

文件：`flutter_app/lib/features/rss/rss_article_detail_page.dart`

- `WebViewController()..setJavaScriptMode(JavaScriptMode.unrestricted)` → 改 `JavaScriptMode.disabled`（默认）。
- 加 `setNavigationDelegate(NavigationDelegate(onNavigationRequest: (req) { ... }))`：
  - 拦截非 article baseUrl host 的导航 → 返回 `NavigationDecision.prevent`（用户在 webview 内点链接不会跳转；后续批次 19+ 实装「阅读原文」用 `url_launcher` 跳系统浏览器更安全）
  - 同 host 允许（让锚点 / 同站资源加载）
- catch (e) 改 `debugPrint('[RssDetail] WebView init failed: $e')` + 把 e.toString() 存到 `_webError` State 字段；`_buildBody` 内 disableWebView/null controller 分支额外检查 `_webError`：有值时显示「WebView 加载失败：$_webError」+ 显示 HTML 长度占位（区分「测试模式」和「真实加载失败」）。
- **暂不**为「用户开启 JS」提供 UI 开关（master report finding 建议但 PRD 范围控制；留 P3 future work，文档化即可）。

## Acceptance Criteria

- [ ] `flutter analyze` 0 issues
- [ ] `flutter test` 全过（含本批新增 ~6-10 单测：safeJsResultDecode / enforceWebViewScheme / classifyHost / qr body size enforcement / qr permission denied UI / rss disabled JS）
- [ ] grep `JavaScriptMode.unrestricted` 在 `flutter_app/lib/` 下仅 1 处命中：`platform_webview_executor.dart`（reader webview 业务约束 + ADR 注释）
- [ ] grep `Uri.parse(.*url` 在 `lib/core/platform_webview_executor.dart` 与 `lib/features/qr/` 中所有 caller 之前都有 `enforceWebViewScheme` 防线
- [ ] master finding F-W2A-009/010 + F-W2B-002/010/011/058 全部消解（写 master findings.md + findings-flutter-core.md / findings-flutter-features.md）

## Definition of Done

- 测试：6-10 单测 + 既有全过
- Lint：flutter analyze 0 issues；flutter test green
- 文档：master report 6 条 Resolution + spec 加「WebView/Untrusted-Network 边界（BATCH-05）」段（覆盖：scheme 白名单约定 / host class API / safeJsResultDecode 替代规则 / reader unrestricted JS 业务豁免 + ADR / RSS 默认 disabled JS）
- Commit：3 个（fix(flutter) + docs(trellis) + archive，按 BATCH-13/15/03 模式）

## Out of Scope

- **reader webview 切换 JS mode 开关**：业务上必须 unrestricted（webJs 规则要跑），不做开关。
- **RSS webview「加载 JS」用户开关**：留 P3 future work。
- **HTML sanitize（剥 `<script>`/`<iframe>`）**：roadmap 提议但需 Rust 端 `core-parser` 加 sanitize 函数，跨层 effort 大，留 BATCH-05b。本批仅 disabled JS + NavigationDelegate 已足够中和「远端 HTML 含 `<script>` 任意执行」核心风险。
- **WebView dispose 时 clearLocalStorage / clearCache**：roadmap 提议但 webview_flutter 4.x 跨平台 API 不一致（Android 走 `WebViewController.clearCache()`，iOS 走 `WKWebsiteDataStore`），留 BATCH-05b。本批 unrestricted JS 仅 reader 路径，不接入第三方 cookie 是默认行为，影响有限。
- **IPv6 链路本地完整支持**：`classifyHost` 仅做 IPv4 RFC1918 + loopback + linkLocal 主路径，IPv6 仅识别 `::1` 和 `fe80::/10` 主流前缀，留 BATCH-05b。
- **app_settings / permission_handler 引入**：F-W2B-058 用 mobile_scanner 自身 errors 流监听 + UI 文案引导用户去系统设置，不跳转。
- **token / API key 在 QR URL 中的检测**：跨主题，留 BATCH-22+。

## Technical Notes

- **`WebViewSafety` API surface**（薄包装 + 纯函数 + 文件级 const）：
  - `enforceWebViewScheme(String url) → void`（throw `WebViewSafetyException` 越界）；不返回 Uri 让 caller 自己 `Uri.parse`，避免双解析浪费
  - `classifyHost(String url) → HostClass enum { loopback, linkLocal, privateNetwork, public, invalid }`
  - `String defaultUserAgent()` — 返回 `'LegadoFlutter/<package_version> webview_flutter'`（package_info_plus 暂未引入；先用 hardcode `LegadoFlutter/0.1.0`）
  - `String safeJsResultDecode(Object? raw)` — 取代 `_normalizeJsResult`
- **测试钩子**：纯函数无需 override；qr_scan_page 测试用 `scanResultOverride` 已有钩子；mobile_scanner 5.x errors stream 在测试模式（`_isRealCameraMode == false`）不创建 controller，所以 `_permissionDenied` UI 单测用 `_QrScanPageState` 私有方法 trigger 比较脆弱——简化方案：把 `_permissionDenied` 提到 widget public override `permissionDeniedOverride: bool = false`，单测直接传 true 验证 UI。
- **`safeJsResultDecode` 与 `_normalizeJsResult` 行为差异**：
  - 旧：jsonDecode 失败 `substring(1, len-1)` 粗暴去引号（可能丢实际内容）
  - 新：jsonDecode 失败 `debugPrint('[WebViewExec] decode JS string failed: len=$len hash=${md5...}')` 后返回**原 raw.toString()**（保留引号）；caller 自己决定怎么用
- **mobile_scanner errors 监听**：`_controller!.errors` 是 `Stream<MobileScannerException>`（v5.x），订阅后 listen e.errorCode；`unauthorized` 是 enum value（`MobileScannerErrorCode.permissionDenied` 或字符串包含 `permission`/`unauthorized`）。dispose 时取消订阅。
- **RSS NavigationDelegate `onNavigationRequest`**：req.url 是导航目标 URL；判 `Uri.parse(req.url).host == Uri.parse(_baseUrl).host` 同 host 放行；非同 host `prevent`。**不**给「真要外跳」按钮（留 P3）。
- **QR body size**：`dio` 的 `BaseOptions(maxResponseSize)` 不是稳定 API；改用 `Options(receiveDataWhenStatusError: false)` + `responseType: ResponseType.bytes` 拿 bytes 后判 length；保持同步语义不变。
  - **更简洁方案**：保持 `responseType: plain`，加 `validateStatus`，response body 拿到后判 `data.length > 10 * 1024 * 1024` throw；同时加 Content-Type 校验从 `resp.headers.value('content-type')` 拿。
- **reader webview ADR 注释**：放在 `platform_webview_executor.dart::PlatformWebViewExecutor` class doc 顶部，链接 spec `quality-and-anti-patterns.md::WebView/Untrusted-Network 边界 (BATCH-05)`。
- **测试基础设施**：本批不引入新 fake；qr_scan_page 用 `permissionDeniedOverride` 钩子；rss webview disabled JS 测试用 `disableWebView=true` 已有钩子。

## 范围内具体改动

### 新增

- `flutter_app/lib/core/security/webview_safety.dart`（~80 行）
- `flutter_app/test/webview_safety_test.dart`（~6 case：scheme reject 4 种 + classifyHost 4 enum + safeJsResultDecode 3 case）

### 修改

- `flutter_app/lib/core/platform_webview_executor.dart`：
  - import webview_safety.dart
  - `_executeNative` 入口 + `_WebViewExecutionPageState.initState` 在 `Uri.parse` 前调 `enforceWebViewScheme`
  - `_normalizeJsResult` 替换为调用 `safeJsResultDecode`
  - `setUserAgent`：caller UA 为空时用 `defaultUserAgent()`
  - 顶部 PlatformWebViewExecutor class doc 加 ADR 注释
- `flutter_app/lib/features/qr/legado_qr_protocol.dart`：
  - `parseLegadoQrPayload` 末尾、return ParsedLegadoQr 前 try `enforceWebViewScheme(src)`，越界返回 null
- `flutter_app/lib/features/qr/qr_import_handler.dart`：
  - `_fetchText` 加 body size 校验 + Content-Type 校验
- `flutter_app/lib/features/qr/qr_scan_page.dart`：
  - 加 `permissionDeniedOverride` 测试钩子
  - 监听 `_controller!.errors` stream，errorCode unauthorized → setState `_permissionDenied = true`
  - `_buildBody` 加 `_permissionDenied` 分支 UI
  - `_showConfirmDialog` 多显示 host class 警告行
- `flutter_app/lib/features/rss/rss_article_detail_page.dart`：
  - `JavaScriptMode.unrestricted` → `disabled`
  - 加 `setNavigationDelegate(NavigationDelegate(onNavigationRequest: ...))`
  - catch (e) 改 `debugPrint` + `_webError` State

### 测试新增

- `webview_safety_test.dart`（~6 case）
- `qr_scan_page_test.dart`：1 新 case 验证 permissionDeniedOverride=true 时 UI 显示
- `rss_article_detail_page_test.dart`：1 新 case 验证 setNavigationDelegate 已调用（实测可能复杂——如果难做就只验 JS mode 默认 disabled）
- `qr_import_handler_test.dart`：1-2 新 case 验证 body size > 10MB 抛错 / Content-Type 拒非 JSON
- 既有所有 test 不破坏

总改动估算：新建 ~80 行 + 修改 ~150 行 + 测试 ~120 行 = ~350 行（roadmap 估 ≤500，符合 effort M）。
