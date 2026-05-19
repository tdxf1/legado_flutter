# BATCH-05: WebView 边界 + QR 导入 + RSS WebView 三处加固

**Stage**: P0
**Slug**: `tighten-webview-and-qr-boundaries`
**Effort**: M (≤500 行)
**Depends on**: none

## 1. 范围

把 Flutter 端 3 个"远端 untrusted 内容直接进 WebView / dio.get"的入口一次性收紧：reader 主路径 WebView 执行器、QR 扫码导入、RSS 文章 WebView。WebView 安全策略集中到 `WebViewSafety` 单点，避免散开维护。

## 2. 包含的 findings

- [F-W2A-009] WebView 始终 unrestricted JS + 无 userAgent / headers 校验 — `flutter_app/lib/core/platform_webview_executor.dart:104-105`
- [F-W2A-010] _normalizeJsResult fallback 路径不 sanitize — `flutter_app/lib/core/platform_webview_executor.dart:189` (强耦合：同文件)
- [F-W2B-002] QR 扫到的 URL 直接 dio.get，无 host 校验 — `flutter_app/lib/features/qr/legado_qr_protocol.dart:55-56`
- [F-W2B-058] mobile_scanner 权限拒绝路径无 UI fallback — `flutter_app/lib/features/qr/qr_scan_page.dart:88-104` (强耦合：同 QR 主题)
- [F-W2B-010] RSS WebView unrestricted JS 加载远端 HTML，无 NavigationDelegate — `flutter_app/lib/features/rss/rss_article_detail_page.dart:225-227`
- [F-W2B-011] WebViewController init 失败 catch silent — `flutter_app/lib/features/rss/rss_article_detail_page.dart:228-231` (强耦合：同文件)

## 3. 影响文件

- `flutter_app/lib/core/security/webview_safety.dart` — 新增；统一 `WebViewSafety.policy(uri)` 入口（host whitelist + scheme 校验 + JS interface capability + navigation lock）
- `flutter_app/lib/core/platform_webview_executor.dart:104-189` — 调用 WebViewSafety；scheme 限制 `http/https`；`_normalizeJsResult` fallback 路径改 jsonDecode 失败时记录原始 hash 后返回原文（不再粗暴去引号）
- `flutter_app/lib/features/qr/legado_qr_protocol.dart:55-56` — 解析后调 WebViewSafety.policy；默认拒绝 `http://` 与 RFC1918；二次确认 dialog 提示 host 是否首次出现
- `flutter_app/lib/features/qr/qr_import_handler.dart` — `_fetchText` 限制 max body size（10MB）+ Content-Type 校验
- `flutter_app/lib/features/qr/qr_scan_page.dart:88-104` — permission_handler 检查 camera 权限；拒绝时显示 fallback UI + 跳转设置按钮
- `flutter_app/lib/features/rss/rss_article_detail_page.dart:225-231` — 默认 `JavaScriptMode.disabled` + 用户开关；setNavigationDelegate 拦截非 article baseUrl 跳转；catch (e) 改 `debugPrint` + `_webError` State

## 4. 修复方向

- F-W2A-009：在 `_executeNative` / `Uri.parse(widget.request.url!)` 前强校验 scheme；其它直接抛异常；考虑 `clearLocalStorage` / `clearCache` 在 dispose 时调用避免跨书源 cookie 持久化。
- F-W2A-010：jsonDecode 失败时记录原始长度 + hash，直接返回原文（带首尾引号）由调用方决定，不再粗暴去引号。
- F-W2B-002：默认拒绝 `http://` 与 RFC1918 / 链路本地 / loopback；确认 dialog prominently 显示 host 是否首次；维护可选白名单（如 raw.githubusercontent.com / gitee.com）；`_fetchText` 限制 max body size。
- F-W2B-010：默认 `JavaScriptMode.disabled`，加用户开关"加载 JS"；setNavigationDelegate 拦截非 article baseUrl 的跳转；考虑用 `core-parser` HTML sanitize 函数剥离 `<script>` / `<iframe>`。
- F-W2B-011：catch (e) 加 `debugPrint`；`_webError` State 区分"测试模式"vs"WebView 加载失败"。
- F-W2B-058：进页前 permission_handler 检查；拒绝时显示"请授予相机权限"页 + 跳转设置按钮。

## 5. 测试策略

- Widget test：构造 mocked WebView 与 SSRF URL，断言 platform_webview_executor 拒绝 scheme=`file:` / `javascript:`
- Widget test：QR 扫到 RFC1918 URL 弹警告 dialog；首次 host 弹特殊提示
- Widget test：RSS detail JS 默认 disabled；切换开关后 enabled
- Widget test：camera 权限拒绝时显示 fallback UI
- 手动：构造测试 RSS 页面验证 unrestricted JS 已禁

## 6. 验收

- [ ] 全代码库仅 `WebViewSafety` 一处定义 webview policy（grep `JavaScriptMode.unrestricted` 无散落使用）
- [ ] master finding F-W2A-009/010 / F-W2B-002/058/010/011 全部消解
- [ ] QR 扫码、RSS 详情、reader webJs 三条路径在 SSRF / unrestricted JS 上一致

## 7. implement.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-flutter-core.md", "reason": "本批次涉及的 wave 2A findings（F-W2A-009/010）"}
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-flutter-features.md", "reason": "本批次涉及的 wave 2B findings（F-W2B-002/058/010/011）"}
{"file": "flutter_app/lib/core/platform_webview_executor.dart", "reason": "reader 主路径 WebView 执行器"}
{"file": "flutter_app/lib/features/qr/legado_qr_protocol.dart", "reason": "QR URL 解析"}
{"file": "flutter_app/lib/features/qr/qr_import_handler.dart", "reason": "QR fetch 实现"}
{"file": "flutter_app/lib/features/qr/qr_scan_page.dart", "reason": "QR scan 权限处理"}
{"file": "flutter_app/lib/features/rss/rss_article_detail_page.dart", "reason": "RSS WebView"}
{"file": ".trellis/spec/backend/quality-guidelines.md", "reason": "WebView 安全约束 + scheme 白名单约束 spec"}
```

## 8. check.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md", "reason": "master report 主题：WebView / JS 边界缺安全 gating"}
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-flutter-core.md", "reason": "Wave 2A 详细 findings"}
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-flutter-features.md", "reason": "Wave 2B 详细 findings"}
{"file": ".trellis/tasks/05-20-fix-roadmap/plan/batches/BATCH-05-tighten-webview-and-qr-boundaries.md", "reason": "本批次自身验收清单"}
```
