# BATCH-05b: WebView dispose 清理 + IPv6 / IPv4 SSRF 分类完整化

**Stage**: P2 (follow-up of BATCH-05)
**Slug**: `webview-cleanup-and-ipv6`
**Effort**: S (~150 行)
**Depends on**: BATCH-05 ✅（webview_safety.dart 基础设施已建好）

## 1. 范围

收尾 BATCH-05 / BATCH-04 留下的两块 follow-up：
1. **WebView dispose 清缓存**：两处 WebView caller (`rss_article_detail_page.dart` + `platform_webview_executor.dart`) 都**没有 dispose override**，关闭时 cookie/cache/localStorage 不清——跨书源导致 cookie 持久化、跨文章导致 RSS HTML cache 累积。
2. **`classifyHost` IPv6 / IPv4 完整化**：Dart 端 `classifyHost` 主流前缀已识别，但相比 Rust `ssrf_guard::is_url_safe_for_fetch` 缺：CGNAT (100.64.0.0/10) / IPv4 multicast (224.0.0.0/4) / "this network" (0.0.0.0/8) / IPv6 ULA (fc00::/7) / IPv6 multicast (ff00::/8) / IPv4-mapped IPv6 (::ffff:* 重分类)。Rust 端已覆盖（BATCH-04 ssrf_guard.rs:94-103）；Dart `classifyHost` 应对齐。

**关键发现**：BATCH-05 PRD 当时说"webview_flutter 4.x 跨平台 API 不一致"，但当前 webview_flutter 4.13.1（pubspec ^4.8.0）已经统一了 `controller.clearCache()` + `controller.clearLocalStorage()`，跨 Android/iOS 都能用，effort 大幅下降。

## 2. 包含的 finding 

| Finding | 状态 | 实施 |
|---------|------|------|
| BATCH-05 follow-up: WebView clearCache/clearLocalStorage on dispose | 路线图原标 BATCH-05b | 两处 WebView caller 加 dispose override 调 `controller.clearCache()` + `controller.clearLocalStorage()` |
| BATCH-05 follow-up: `classifyHost` IPv6 链路本地完整支持 | 路线图原标 BATCH-05b | 对齐 Rust ssrf_guard 的 host 分类范围（CGNAT / multicast / ULA / IPv4-mapped）|

## 3. 影响文件

### 3.1 WebView dispose 清理（核心）

**`flutter_app/lib/features/rss/rss_article_detail_page.dart`**

`_RssArticleDetailPageState` 当前**无 dispose override**。在 `initState` (line 128-132) 后或 `build` (line 352) 前加：
```dart
@override
void dispose() {
  // BATCH-05b：跨文章避免 cookie / cache / localStorage 累积。
  // RSS detail webview 加载远端 untrusted HTML（disabled JS 已是
  // BATCH-05 防线），但 cache 仍持久化跨域 cookie；dispose 时清。
  // controller.clearCache() / clearLocalStorage() 在 webview_flutter
  // 4.13 跨 Android/iOS 统一 API（4.x early 不支持，参考 pubspec ^4.8.0）。
  final ctl = _webController;
  if (ctl != null) {
    ctl.clearCache().catchError((_) {});
    ctl.clearLocalStorage().catchError((_) {});
  }
  super.dispose();
}
```

**`flutter_app/lib/core/platform_webview_executor.dart`**

`_WebViewExecutionPageState` 同样无 dispose override。在 `build` (line 213) 前加同样的 dispose（reader webview 路径，executes webJs rules + 可能含 cookie 鉴权 → 跨规则 page session 不该共享）：
```dart
@override
void dispose() {
  // BATCH-05b：reader webview 跑远端 webJs 规则（unrestricted JS 由
  // 业务必需保留），但 page session 完成后清 cache + localStorage 防
  // 跨 rule eval 状态污染。控制器已 late final 初始化 → 无需 null 检查。
  _controller.clearCache().catchError((_) {});
  _controller.clearLocalStorage().catchError((_) {});
  super.dispose();
}
```

### 3.2 classifyHost 对齐 Rust ssrf_guard

**`flutter_app/lib/core/security/webview_safety.dart`**

`_classifyIpv4` (line 159-168) 加 4 个 RFC：
```dart
HostClass _classifyIpv4(List<int> octets) {
  final a = octets[0];
  final b = octets[1];
  if (a == 127) return HostClass.loopback;
  if (a == 0) return HostClass.loopback; // BATCH-05b: 0.0.0.0/8 "this network"
  if (a == 169 && b == 254) return HostClass.linkLocal;
  if (a == 10) return HostClass.privateNetwork;
  if (a == 172 && b >= 16 && b <= 31) return HostClass.privateNetwork;
  if (a == 192 && b == 168) return HostClass.privateNetwork;
  // BATCH-05b：CGNAT 100.64.0.0/10
  if (a == 100 && b >= 64 && b <= 127) return HostClass.privateNetwork;
  // BATCH-05b：IPv4 multicast 224.0.0.0/4
  if (a >= 224 && a <= 239) return HostClass.privateNetwork;
  return HostClass.public;
}
```

`classifyHost` IPv6 分支 (line 129-140) 重构为更稳的解析：
```dart
// IPv6：URI host 不带方括号
if (host.contains(':')) {
  // ::1 → loopback
  if (host == '::1') return HostClass.loopback;
  // IPv4-mapped IPv6 (::ffff:a.b.c.d) → 按 IPv4 重分类
  if (host.startsWith('::ffff:')) {
    final ipv4Part = host.substring(7);
    final ipv4 = _tryParseIpv4(ipv4Part);
    if (ipv4 != null) return _classifyIpv4(ipv4);
  }
  // fe80::/10 link-local
  if (_ipv6HasPrefix(host, ['fe8', 'fe9', 'fea', 'feb'])) {
    return HostClass.linkLocal;
  }
  // BATCH-05b: fc00::/7 ULA (unique local) — fc** / fd**
  if (_ipv6HasPrefix(host, ['fc', 'fd'])) {
    return HostClass.privateNetwork;
  }
  // BATCH-05b: ff00::/8 multicast
  if (host.startsWith('ff')) {
    return HostClass.privateNetwork;
  }
  return HostClass.public;
}
```

加 helper：
```dart
bool _ipv6HasPrefix(String host, List<String> prefixes) {
  return prefixes.any((p) => host.startsWith(p));
}
```

### 3.3 spec 更新

**`.trellis/spec/flutter-app/quality-and-anti-patterns.md`**

「WebView 边界 (BATCH-05)」段补充小节「WebView dispose 清理 + IPv6/IPv4 完整 (BATCH-05b)」：
- WebView caller 必须 override dispose 调 `clearCache + clearLocalStorage`
- `classifyHost` 与 Rust `ssrf_guard::is_url_safe_for_fetch` host 分类范围对齐（参考 `core/core-source/src/legado/ssrf_guard.rs:94-103`）
- IPv4-mapped IPv6 走重分类策略（不让攻击者用 `::ffff:127.0.0.1` 绕过 IPv4 检查）

## 4. 测试策略

### 4.1 webview_safety_test.dart 加 IPv6/IPv4 case

`flutter_app/test/webview_safety_test.dart` group `classifyHost` 加：
```dart
test('IPv4 CGNAT 100.64.0.0/10', () {
  expect(classifyHost('http://100.64.0.1'), HostClass.privateNetwork);
  expect(classifyHost('http://100.127.255.255'), HostClass.privateNetwork);
});
test('IPv4 CGNAT 边界 100.63 和 100.128 是 public', () {
  expect(classifyHost('http://100.63.255.255'), HostClass.public);
  expect(classifyHost('http://100.128.0.1'), HostClass.public);
});
test('IPv4 multicast 224.0.0.0/4', () {
  expect(classifyHost('http://224.0.0.1'), HostClass.privateNetwork);
  expect(classifyHost('http://239.255.255.255'), HostClass.privateNetwork);
});
test('IPv4 0.0.0.0/8 → loopback', () {
  expect(classifyHost('http://0.0.0.0'), HostClass.loopback);
  expect(classifyHost('http://0.255.255.255'), HostClass.loopback);
});
test('IPv6 ULA fc00::/7', () {
  expect(classifyHost('http://[fc00::1]'), HostClass.privateNetwork);
  expect(classifyHost('http://[fd12:3456::1]'), HostClass.privateNetwork);
});
test('IPv6 multicast ff00::/8', () {
  expect(classifyHost('http://[ff02::1]'), HostClass.privateNetwork);
});
test('IPv4-mapped IPv6 ::ffff:127.0.0.1 → loopback', () {
  expect(classifyHost('http://[::ffff:127.0.0.1]'), HostClass.loopback);
});
test('IPv4-mapped IPv6 ::ffff:10.0.0.1 → privateNetwork', () {
  expect(classifyHost('http://[::ffff:10.0.0.1]'), HostClass.privateNetwork);
});
test('IPv4-mapped IPv6 ::ffff:8.8.8.8 → public', () {
  expect(classifyHost('http://[::ffff:8.8.8.8]'), HostClass.public);
});
```

### 4.2 dispose 行为不强求 widget test

WebView dispose 行为难测（`controller.clearCache()` 是 platform channel 调用，widget test 没 channel）。对策：
- 不加 widget test（与 BATCH-21b 同模式：跨平台桥接 in widget test 难度高 ROI 低）
- 用回归 baseline 验证（既有 webview test 不挂）

### 4.3 验收 baseline
- `flutter analyze` 0 issue
- `flutter test` baseline 527 + 9 新 IPv6/IPv4 case ≈ 536 PASS
- `cargo build/test --workspace` 不动 Rust，应该全 PASS

## 5. 验收

- [ ] `rss_article_detail_page.dart` 加 dispose override 调 clearCache+clearLocalStorage
- [ ] `platform_webview_executor.dart` 加 dispose override 调 clearCache+clearLocalStorage
- [ ] `classifyHost` 加 4 个 IPv4 RFC（CGNAT / multicast / 0.0.0.0/8 + 不动既有）
- [ ] `classifyHost` IPv6 加 ULA / multicast / IPv4-mapped 重分类
- [ ] webview_safety_test.dart 加 9 个新 case
- [ ] flutter analyze / flutter test / cargo 全 PASS
- [ ] master findings: BATCH-05 主题段补充 BATCH-05b 收尾说明（如已有 Resolution 行追加；如未有就新增）
- [ ] spec 「WebView 边界」段加 BATCH-05b 小节

## 6. 不在范围

- HTML sanitize（剥 `<script>`/`<iframe>`）：跨层 effort 大需要 Rust core-parser 加 sanitize fn；当前 disabled JS + NavigationDelegate 已中和远端 HTML 任意 JS 执行核心风险（BATCH-05 ADR）
- DNS 解析做 SSRF 主机查询：会增加同步 IO，需要重设计；属 BATCH-10 留给的 DNS rebinding 防护范围
- WebView caller `userAgent` 动态化（package_info_plus）：现 hardcode，单独评估
- Reader webview 取消 unrestricted JS：业务豁免，BATCH-05 ADR 已记录

## 7. 风险点

- **`controller.clearCache()` / `clearLocalStorage()` 在 dispose 中调** 是异步 Future，不 await（dispose 不能 async）。`.catchError((_) {})` 处理静默失败。极端情况下平台 channel 在 widget tree 销毁后才 resolve，但不影响功能（目的就是异步清理）。
- **`_controller` in `platform_webview_executor.dart` 是 late final**：如果 `_error != null` 提前 return（line 152-153）那 `_controller.clearCache()` 调用安全（late final 已初始化）。但若 `enforceWebViewScheme` throw 在 line 122-136 controller 构造**之前**呢？不会——构造在 throw 之前。安全。
- **IPv4-mapped IPv6 `::ffff:host` 解析**：Dart `Uri.parse` 对 IPv6 host 自动去方括号，所以 `parsed.host` 形如 `::ffff:127.0.0.1`（不带方括号）。`startsWith('::ffff:')` 判断正确。
- **既有 BATCH-05 测试不挂**：原 4 case (`::1` / `fe80::1` / `2001:db8::1` / IPv4 RFC1918) 全保留，新 case 仅追加。
