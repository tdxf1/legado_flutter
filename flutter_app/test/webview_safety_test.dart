import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/core/security/webview_safety.dart';

/// BATCH-05 (05-21): WebView/Untrusted-Network 安全边界单测。
///
/// 覆盖：
/// - [enforceWebViewScheme] 白名单（http/https 通过，file/javascript/data 拒绝）
/// - [classifyHost] 4 个分类 + invalid 路径
/// - [safeJsResultDecode] 不再做粗暴 substring 去引号；jsonDecode 失败保留原值
void main() {
  group('enforceWebViewScheme', () {
    test('http allowed', () {
      expect(
        () => enforceWebViewScheme('http://example.com'),
        returnsNormally,
      );
    });

    test('https allowed', () {
      expect(
        () => enforceWebViewScheme('https://example.com/path?q=1'),
        returnsNormally,
      );
    });

    test('HTTPS uppercase scheme allowed (case-insensitive)', () {
      expect(
        () => enforceWebViewScheme('HTTPS://example.com'),
        returnsNormally,
      );
    });

    test('file:// rejected', () {
      expect(
        () => enforceWebViewScheme('file:///etc/passwd'),
        throwsA(isA<WebViewSafetyException>()),
      );
    });

    test('javascript: rejected', () {
      expect(
        () => enforceWebViewScheme('javascript:alert(1)'),
        throwsA(isA<WebViewSafetyException>()),
      );
    });

    test('data: rejected', () {
      expect(
        () => enforceWebViewScheme(
            'data:text/html,<script>alert(1)</script>'),
        throwsA(isA<WebViewSafetyException>()),
      );
    });

    test('intent: rejected', () {
      expect(
        () => enforceWebViewScheme('intent://x#Intent;scheme=http;end'),
        throwsA(isA<WebViewSafetyException>()),
      );
    });

    test('content: rejected', () {
      expect(
        () => enforceWebViewScheme('content://media/external/file/123'),
        throwsA(isA<WebViewSafetyException>()),
      );
    });

    test('ftp: rejected', () {
      expect(
        () => enforceWebViewScheme('ftp://example.com/x'),
        throwsA(isA<WebViewSafetyException>()),
      );
    });

    test('empty string rejected', () {
      expect(
        () => enforceWebViewScheme(''),
        throwsA(isA<WebViewSafetyException>()),
      );
    });

    test('whitespace-only string rejected', () {
      expect(
        () => enforceWebViewScheme('   '),
        throwsA(isA<WebViewSafetyException>()),
      );
    });
  });

  group('classifyHost', () {
    test('public IPv4', () {
      expect(classifyHost('https://8.8.8.8'), HostClass.public);
    });

    test('public domain', () {
      expect(classifyHost('https://example.com'), HostClass.public);
    });

    test('public domain with port', () {
      expect(classifyHost('https://example.com:8443/x'), HostClass.public);
    });

    test('loopback 127.0.0.1', () {
      expect(classifyHost('http://127.0.0.1'), HostClass.loopback);
    });

    test('loopback 127.255.0.1', () {
      // 127.0.0.0/8 整段 loopback
      expect(classifyHost('http://127.255.0.1'), HostClass.loopback);
    });

    test('loopback localhost', () {
      expect(classifyHost('http://localhost'), HostClass.loopback);
    });

    test('loopback localhost.localdomain', () {
      expect(
        classifyHost('http://localhost.localdomain'),
        HostClass.loopback,
      );
    });

    test('rfc1918 192.168.x.x', () {
      expect(
        classifyHost('http://192.168.1.1'),
        HostClass.privateNetwork,
      );
    });

    test('rfc1918 10.x.x.x', () {
      expect(classifyHost('http://10.0.0.1'), HostClass.privateNetwork);
    });

    test('rfc1918 172.16.x.x', () {
      expect(classifyHost('http://172.16.0.1'), HostClass.privateNetwork);
    });

    test('rfc1918 172.31.x.x (boundary)', () {
      expect(
        classifyHost('http://172.31.255.255'),
        HostClass.privateNetwork,
      );
    });

    test('172.32.x.x is public (just outside rfc1918)', () {
      expect(classifyHost('http://172.32.0.1'), HostClass.public);
    });

    test('172.15.x.x is public (just outside rfc1918)', () {
      expect(classifyHost('http://172.15.0.1'), HostClass.public);
    });

    test('linkLocal 169.254.169.254 (AWS metadata)', () {
      expect(classifyHost('http://169.254.169.254'), HostClass.linkLocal);
    });

    test('IPv6 loopback ::1', () {
      expect(classifyHost('http://[::1]'), HostClass.loopback);
    });

    test('IPv6 link-local fe80::', () {
      expect(classifyHost('http://[fe80::1]'), HostClass.linkLocal);
    });

    test('IPv6 public 2001:db8::', () {
      expect(classifyHost('http://[2001:db8::1]'), HostClass.public);
    });

    // BATCH-05b: 对齐 Rust ssrf_guard.rs:86-110 的 host 分类范围。
    test('IPv4 CGNAT 100.64.0.0/10', () {
      expect(classifyHost('http://100.64.0.1'), HostClass.privateNetwork);
      expect(
        classifyHost('http://100.127.255.255'),
        HostClass.privateNetwork,
      );
    });

    test('IPv4 CGNAT 边界 100.63 和 100.128 是 public', () {
      expect(classifyHost('http://100.63.255.255'), HostClass.public);
      expect(classifyHost('http://100.128.0.1'), HostClass.public);
    });

    test('IPv4 multicast 224.0.0.0/4', () {
      expect(classifyHost('http://224.0.0.1'), HostClass.privateNetwork);
      expect(
        classifyHost('http://239.255.255.255'),
        HostClass.privateNetwork,
      );
    });

    test('IPv4 0.0.0.0/8 → loopback', () {
      expect(classifyHost('http://0.0.0.0'), HostClass.loopback);
      expect(classifyHost('http://0.255.255.255'), HostClass.loopback);
    });

    test('IPv6 ULA fc00::/7', () {
      expect(classifyHost('http://[fc00::1]'), HostClass.privateNetwork);
      expect(
        classifyHost('http://[fd12:3456::1]'),
        HostClass.privateNetwork,
      );
    });

    test('IPv6 multicast ff00::/8', () {
      expect(classifyHost('http://[ff02::1]'), HostClass.privateNetwork);
    });

    test('IPv4-mapped IPv6 ::ffff:127.0.0.1 → loopback', () {
      expect(
        classifyHost('http://[::ffff:127.0.0.1]'),
        HostClass.loopback,
      );
    });

    test('IPv4-mapped IPv6 ::ffff:10.0.0.1 → privateNetwork', () {
      expect(
        classifyHost('http://[::ffff:10.0.0.1]'),
        HostClass.privateNetwork,
      );
    });

    test('IPv4-mapped IPv6 ::ffff:8.8.8.8 → public', () {
      expect(classifyHost('http://[::ffff:8.8.8.8]'), HostClass.public);
    });

    test('invalid empty', () {
      expect(classifyHost(''), HostClass.invalid);
    });

    test('invalid no host', () {
      expect(classifyHost('http:///path'), HostClass.invalid);
    });
  });

  group('defaultUserAgent', () {
    test('returns stable hardcoded UA', () {
      expect(defaultUserAgent(), 'LegadoFlutter/0.1.0 webview_flutter');
    });
  });

  group('safeJsResultDecode', () {
    test('null → empty', () {
      expect(safeJsResultDecode(null), '');
    });

    test('plain string passthrough', () {
      expect(safeJsResultDecode('hello'), 'hello');
    });

    test('JSON-string raw decoded', () {
      expect(safeJsResultDecode('"hello"'), 'hello');
    });

    test('JSON-string with escapes properly decoded', () {
      expect(safeJsResultDecode('"a\\nb"'), 'a\nb');
      expect(safeJsResultDecode(r'"\u4e2d"'), '中');
    });

    test('malformed JSON-string keeps original (no quote-stripping)', () {
      // 旧 _normalizeJsResult 在此走 substring(1, -1) 把内容截成 'unterminated；
      // 新 safeJsResultDecode 保留原值（带引号），让 caller 自己决定。
      expect(safeJsResultDecode('"unterminated'), '"unterminated');
    });

    test('non-string already decoded by webview returns toString()', () {
      // webview 桥可能直接返 num / bool —— toString 即可
      expect(safeJsResultDecode(42), '42');
      expect(safeJsResultDecode(true), 'true');
    });
  });
}
