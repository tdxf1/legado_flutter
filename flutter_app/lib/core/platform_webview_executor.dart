import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'dto.dart';
import 'security/webview_safety.dart';

class WebViewExecutionResult {
  final String content;
  final String? resourceUrl;
  final bool sourceRegexRequired;
  final bool sourceRegexMatched;

  const WebViewExecutionResult({
    required this.content,
    this.resourceUrl,
    this.sourceRegexRequired = false,
    this.sourceRegexMatched = false,
  });
}

/// Reader 主路径 WebView 执行器。
///
/// **业务约束**：必须 [JavaScriptMode.unrestricted] —— 远端书源 JS 规则
/// （`webJs` / source regex extraction）在此跑，关闭 JS 直接破坏业务路径。
///
/// **安全边界**（BATCH-05 引入）：
/// - 所有 `Uri.parse(url)` 之前必经 [enforceWebViewScheme]（仅放 http/https）
/// - 缺省 UA 走 [defaultUserAgent]，避免 webview-flutter 默认 UA 暴露指纹
/// - JS 返回值走 [safeJsResultDecode] 取代旧 `_normalizeJsResult` 的
///   粗暴 `substring(1, len-1)` 去引号路径
///
/// **新增 webview caller 必须走 `core/security/webview_safety.dart` 这套**；
/// JS mode 由 caller 决定（reader=unrestricted, RSS=disabled，见
/// `.trellis/spec/flutter-app/quality-and-anti-patterns.md`「WebView /
/// Untrusted-Network 边界 (BATCH-05)」段）。
class PlatformWebViewExecutor {
  static const MethodChannel _channel =
      MethodChannel('legado/webview_executor');

  Future<WebViewExecutionResult> execute(
    BuildContext context,
    PlatformRequest request,
  ) async {
    if (request.type != 'web_view_content') {
      throw UnsupportedError('Unsupported platform request: ${request.type}');
    }
    final url = request.url;
    if (url == null || url.isEmpty) {
      throw ArgumentError('WebView request missing url');
    }
    // BATCH-05 (F-W2A-009): scheme 白名单防线。caller 之前是 reader 链路，
    // url 来自书源 JSON，恶意源可能塞 file:// / javascript: / data: 等。
    enforceWebViewScheme(url);
    final nativeResult = await _executeNative(request);
    if (nativeResult != null) {
      return nativeResult;
    }
    final result = await Navigator.of(context).push<WebViewExecutionResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _WebViewExecutionPage(request: request),
      ),
    );
    if (result == null) {
      throw StateError('WebView execution was cancelled');
    }
    return result;
  }

  Future<WebViewExecutionResult?> _executeNative(
      PlatformRequest request) async {
    try {
      final result =
          await _channel.invokeMapMethod<String, dynamic>('execute', {
        'url': request.url,
        'webJs': request.webJs,
        'sourceRegex': request.sourceRegex,
        'headers': request.headers,
        'userAgent': request.userAgent,
        'timeoutMs': 30000,
      });
      if (result == null) return null;
      return WebViewExecutionResult(
        content: result['content'] as String? ?? '',
        resourceUrl: result['resourceUrl'] as String?,
        sourceRegexRequired: request.sourceRegex?.trim().isNotEmpty == true,
        sourceRegexMatched: result['sourceRegexMatched'] as bool? ?? false,
      );
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      if (Platform.isAndroid) {
        throw StateError(e.message ?? 'Android WebView executor failed');
      }
      return null;
    }
  }
}

class _WebViewExecutionPage extends StatefulWidget {
  final PlatformRequest request;

  const _WebViewExecutionPage({required this.request});

  @override
  State<_WebViewExecutionPage> createState() => _WebViewExecutionPageState();
}

class _WebViewExecutionPageState extends State<_WebViewExecutionPage> {
  late final WebViewController _controller;
  var _isExecuting = false;
  var _progress = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (mounted) setState(() => _progress = progress);
          },
          onPageFinished: (_) => _executeRules(),
          onWebResourceError: (error) {
            if (mounted) {
              setState(() => _error = error.description);
            }
          },
        ),
      );
    final ua = widget.request.userAgent;
    if (ua != null && ua.isNotEmpty) {
      _controller.setUserAgent(ua);
    } else {
      // BATCH-05 (F-W2A-009): caller 没指定 UA 时走项目统一 UA，避免
      // webview-flutter 默认 UA 暴露 Android API 版本等指纹。
      _controller.setUserAgent(defaultUserAgent());
    }
    final url = widget.request.url!;
    try {
      // BATCH-05 (F-W2A-009): 二次防线 —— PlatformWebViewExecutor.execute()
      // 已校验过，但 page 可能被外部直接构造，再校一次代价低。
      enforceWebViewScheme(url);
    } on WebViewSafetyException catch (e) {
      // 校验失败：不发起 loadRequest，直接展示错误占位。
      _error = e.toString();
      return;
    }
    final headers = widget.request.headers;
    if (headers.isNotEmpty) {
      _controller.loadRequest(
        Uri.parse(url),
        headers: headers,
      );
    } else {
      _controller.loadRequest(Uri.parse(url));
    }
  }

  Future<void> _executeRules() async {
    if (_isExecuting) return;
    _isExecuting = true;
    try {
      final webJs = widget.request.webJs?.trim();
      final Object? rawResult;
      if (webJs != null && webJs.isNotEmpty) {
        rawResult = await _controller.runJavaScriptReturningResult(
          _wrapJavaScript(webJs),
        );
      } else {
        rawResult = await _controller.runJavaScriptReturningResult(
          'document.documentElement.outerHTML',
        );
      }
      final content = safeJsResultDecode(rawResult);
      if (!mounted) return;
      Navigator.of(context).pop(
        WebViewExecutionResult(
          content: content,
          sourceRegexRequired:
              widget.request.sourceRegex?.trim().isNotEmpty == true,
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    }
  }

  String _wrapJavaScript(String script) {
    return '''
(function() {
  var result = '';
  var src = document.documentElement.outerHTML;
  var baseUrl = location.href;
  var out = (function(){
$script
  })();
  if (out === undefined || out === null) return '';
  if (typeof out === 'string') return out;
  return String(out);
})()
''';
  }

  @override
  void dispose() {
    // BATCH-05b：reader webview 跑远端 webJs 规则（unrestricted JS 由
    // 业务必需保留），但 page session 完成后清 cache + localStorage 防
    // 跨 rule eval 状态污染。控制器已 late final 初始化 → 无需 null 检查。
    _controller.clearCache().catchError((_) {});
    _controller.clearLocalStorage().catchError((_) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('WebView 解析'),
        actions: [
          TextButton(
            onPressed: _executeRules,
            child: const Text('执行'),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_progress < 100) LinearProgressIndicator(value: _progress / 100),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'WebView 执行失败: $_error',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    );
  }
}
