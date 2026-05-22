/// WebView / Untrusted-Network 安全边界（BATCH-05 / F-W2A-009 / F-W2A-010 /
/// F-W2B-002 / F-W2B-010 / F-W2B-011 / F-W2B-058）。
///
/// 集中存放 3 个 caller 共用的安全策略：
///
/// - reader 主路径 webview ([`PlatformWebViewExecutor`])
/// - QR 扫码导入 ([`legado_qr_protocol`] + [`QrImportHandler`] + [`QrScanPage`])
/// - RSS 文章 webview ([`RssArticleDetailPage`])
///
/// ## 公开 API
///
/// - [enforceWebViewScheme] — scheme 白名单（http / https），越界 throw
///   [WebViewSafetyException]。任意 `Uri.parse(remoteUrl)` 之前必经此处。
/// - [classifyHost] — 把 URL host 归类成 `loopback` / `linkLocal` /
///   `privateNetwork` / `public` / `invalid`。caller 决定是否拒绝（QR
///   confirm dialog 用此结果显示警告；reader webview 不强制拒绝因为合法
///   书源可能走子域名/IP）。
/// - [defaultUserAgent] — 项目统一 UA 字符串，避免 webview-flutter 默认
///   UA 暴露 Android API level 等指纹。
/// - [safeJsResultDecode] — 取代旧 `_normalizeJsResult` 的粗暴去引号路径。
///   jsonDecode 失败时记录 length + md5 hash 后返回原值 `toString()`，
///   不再 substring(1, len-1) 丢内容。
///
/// ## JS mode 不在本库管控
///
/// `JavaScriptMode` 由 caller 决定（reader=unrestricted, RSS=disabled），
/// 不放进 [WebViewSafety] 强制策略 —— 避免反过来限制 reader 业务路径
/// （reader 必须 unrestricted JS 跑远端 webJs 规则）。
///
/// ## 与 `core/security/secure_storage.dart` 同源
///
/// 都属 `core/security/` 跨 feature 安全工具；都用 top-level 函数 + 不绑
/// Riverpod provider；纯函数无需 override 钩子（caller 之前已有自己的
/// fetch/scan override 钩子覆盖测试路径）。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// scheme 白名单越界异常。
class WebViewSafetyException implements Exception {
  final String message;
  final String url;
  const WebViewSafetyException(this.message, this.url);

  @override
  String toString() => 'WebViewSafetyException: $message (url=$url)';
}

/// 校验 [url] 的 scheme 是否在 `http` / `https` 白名单中。
///
/// 越界（如 `file://`, `javascript:`, `data:`, `intent:`, `content:`,
/// `ftp:`, …）抛 [WebViewSafetyException]。无法解析 / 无 scheme 也抛。
///
/// 返回值 void —— 由 caller 自己决定后续是不是再 `Uri.parse`，避免双重解析。
void enforceWebViewScheme(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) {
    throw WebViewSafetyException('empty url', url);
  }
  final Uri parsed;
  try {
    parsed = Uri.parse(trimmed);
  } on FormatException {
    throw WebViewSafetyException('invalid url', url);
  }
  final scheme = parsed.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') {
    throw WebViewSafetyException(
      'scheme not allowed (only http/https): $scheme',
      url,
    );
  }
}

/// host 风险分类。SSRF 防护决策由 caller 做（loopback / linkLocal /
/// privateNetwork 通常需要警告或拒绝；public 放行；invalid 解析失败）。
enum HostClass {
  loopback,
  linkLocal,
  privateNetwork,
  public,
  invalid,
}

/// 解析 [url] 并把 host 归类。
///
/// IPv4 RFC 标准（与 Rust `core/core-source/src/legado/ssrf_guard.rs:86-110`
/// 对齐）：
/// - `127.0.0.0/8` → loopback
/// - `0.0.0.0/8` → loopback（"this network"，BATCH-05b）
/// - `169.254.0.0/16` → linkLocal
/// - `10.0.0.0/8` / `172.16.0.0/12` / `192.168.0.0/16` → privateNetwork
/// - `100.64.0.0/10` (CGNAT) → privateNetwork（BATCH-05b）
/// - `224.0.0.0/4` (multicast) → privateNetwork（BATCH-05b）
/// - 其余 → public
///
/// IPv6（best-effort，BATCH-05b 扩展）：
/// - `::1` → loopback
/// - `::ffff:a.b.c.d` (IPv4-mapped) → 按 IPv4 重分类，防 `::ffff:127.0.0.1`
///   绕过 IPv4 检查
/// - `fe80::/10` → linkLocal
/// - `fc00::/7` (ULA) → privateNetwork
/// - `ff00::/8` (multicast) → privateNetwork
/// - 其余 → public
///
/// 主机名：
/// - `localhost` / `localhost.localdomain` → loopback
/// - 其余域名 → public（不做 DNS 解析；DNS rebinding 防护范围属 BATCH-10）
///
/// 解析失败 → invalid。
HostClass classifyHost(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return HostClass.invalid;
  Uri parsed;
  try {
    parsed = Uri.parse(trimmed);
  } on FormatException {
    return HostClass.invalid;
  }
  final host = parsed.host.toLowerCase();
  if (host.isEmpty) return HostClass.invalid;

  // 主机名特例
  if (host == 'localhost' || host == 'localhost.localdomain') {
    return HostClass.loopback;
  }

  // IPv4：4 段 0-255 的纯数字
  final ipv4 = _tryParseIpv4(host);
  if (ipv4 != null) {
    return _classifyIpv4(ipv4);
  }

  // IPv6：URI host 不带方括号，但包含 `:`
  if (host.contains(':')) {
    if (host == '::1') return HostClass.loopback;
    // BATCH-05b: IPv4-mapped IPv6 (::ffff:a.b.c.d) → 按 IPv4 重分类，
    // 防攻击者用 `::ffff:127.0.0.1` / `::ffff:10.0.0.1` 绕过 IPv4 检查
    if (host.startsWith('::ffff:')) {
      final ipv4Part = host.substring(7);
      final ipv4Mapped = _tryParseIpv4(ipv4Part);
      if (ipv4Mapped != null) return _classifyIpv4(ipv4Mapped);
    }
    // fe80::/10 link-local — 前缀 fe8x / fe9x / feax / febx
    if (_ipv6HasPrefix(host, const ['fe8', 'fe9', 'fea', 'feb'])) {
      return HostClass.linkLocal;
    }
    // BATCH-05b: fc00::/7 ULA (unique local) — fc** / fd**
    if (_ipv6HasPrefix(host, const ['fc', 'fd'])) {
      return HostClass.privateNetwork;
    }
    // BATCH-05b: ff00::/8 multicast
    if (host.startsWith('ff')) {
      return HostClass.privateNetwork;
    }
    return HostClass.public;
  }

  // 普通域名 → public（不做 DNS 解析）
  return HostClass.public;
}

List<int>? _tryParseIpv4(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return null;
  final out = <int>[];
  for (final p in parts) {
    if (p.isEmpty || p.length > 3) return null;
    final v = int.tryParse(p);
    if (v == null || v < 0 || v > 255) return null;
    out.add(v);
  }
  return out;
}

HostClass _classifyIpv4(List<int> octets) {
  final a = octets[0];
  final b = octets[1];
  if (a == 127) return HostClass.loopback;
  // BATCH-05b: 0.0.0.0/8 "this network" 当 loopback 处理（与 Rust
  // ssrf_guard `is_unspecified` 对齐）
  if (a == 0) return HostClass.loopback;
  if (a == 169 && b == 254) return HostClass.linkLocal;
  if (a == 10) return HostClass.privateNetwork;
  if (a == 172 && b >= 16 && b <= 31) return HostClass.privateNetwork;
  if (a == 192 && b == 168) return HostClass.privateNetwork;
  // BATCH-05b: CGNAT 100.64.0.0/10
  if (a == 100 && b >= 64 && b <= 127) return HostClass.privateNetwork;
  // BATCH-05b: IPv4 multicast 224.0.0.0/4 (224..239)
  if (a >= 224 && a <= 239) return HostClass.privateNetwork;
  return HostClass.public;
}

bool _ipv6HasPrefix(String host, List<String> prefixes) {
  for (final p in prefixes) {
    if (host.startsWith(p)) return true;
  }
  return false;
}

/// 项目统一 UA。避免 webview-flutter 默认 UA 暴露 Android API level / 设备
/// 型号等指纹。后续接入 `package_info_plus` 可换成动态版本号；当前 hardcode。
String defaultUserAgent() {
  return 'LegadoFlutter/0.1.0 webview_flutter';
}

/// JS 调用返回值的安全解码。取代旧 `_normalizeJsResult` 的
/// `substring(1, len-1)` 粗暴去引号 fallback：那个路径在 JSON-string
/// 含转义（`\n` / `\u4e2d` / `\\`）时会把转义当字面量保留，造成内容失真。
///
/// 本函数：
/// - null → 返回空串
/// - 不是 `"…"` 形式 → 直接 `toString()`
/// - 形如 `"…"` → 尝试 `jsonDecode`；成功返回解码字符串；失败时
///   `debugPrint('[WebViewSafety] decode JS string failed: len=$len hash=$h')`
///   后返回**原 raw.toString()**（带引号），让 caller 自己决定怎么用，
///   不丢字符。
String safeJsResultDecode(Object? raw) {
  if (raw == null) return '';
  final text = raw.toString();
  if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
    try {
      return jsonDecode(text) as String;
    } catch (_) {
      final hash = md5.convert(utf8.encode(text)).toString();
      debugPrint(
        '[WebViewSafety] decode JS string failed: len=${text.length} hash=$hash',
      );
      return text;
    }
  }
  return text;
}
