import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/security/webview_safety.dart';
import '../../src/rust/api.dart' as rust_api;
import 'legado_qr_protocol.dart';

/// QR 扫码导入处理器（批次 20 / 05-19）。
///
/// [parseLegadoQrPayload] 拿到 [ParsedLegadoQr] 后，按 type 分发：
/// - bookSource → 远端拉 JSON → [`rust_api.importSourcesFromJson`]
/// - rssSource  → 远端拉 JSON → [`rust_api.rssSourceImportJson`]
/// - sourceSub  → [`rust_api.ruleSubCreate`] + [`rust_api.ruleSubRefresh`]
///   一气呵成
/// - replaceRule → 暂占位"批次 21+ 实装"
///
/// 返回一行 SnackBar 用的人类可读结果字符串。失败时仍返回字符串而不是
/// 抛异常（除非 [fetchUrlOverride] / FRB 调用本身抛错）。
///
/// 测试钩子：所有外部依赖（dbPath / 网络 / FRB 调用）都可注入：
/// - [dbPathOverride] 注入假 dbPath，绕过 [dbPathProvider]
/// - [fetchUrlOverride] 注入假 HTTP 响应内容（绕过 dio）
/// - [importBookSourcesOverride] / [importRssSourcesOverride] /
///   [createRuleSubOverride] / [refreshRuleSubOverride] 注入假 FRB
class QrImportHandler {
  /// QR fetch 响应体上限：10 MB。攻击者构造的恶意源可能推大流量耗手机存储 /
  /// 内存；超此上限直接拒绝。
  static const int _maxBodyBytes = 10 * 1024 * 1024;

  /// 校验 fetch 拿到的 body：[Content-Type allow-list + size 上限]。
  ///
  /// 单独抽出方便单测；[contentType] 传 `resp.headers.value('content-type')`
  /// 原值（含 mime + charset），由本函数 lower-case 后子串匹配。
  ///
  /// 拒绝条件：
  /// - body 字节数 > [_maxBodyBytes]（10 MB）
  /// - contentType 非空且既不含 `json` / `text/plain` / `text` —— 避免被
  ///   骗下载二进制（如 `.exe` / `.zip`）。空 Content-Type 放行（许多 GitHub
  ///   raw 服务给 `.json` 文件返 `application/octet-stream` 或缺省）。
  ///
  /// 抛 [Exception] 表示拒绝。
  @visibleForTesting
  static void validateFetchedBody(String body, String? contentType) {
    if (body.length > _maxBodyBytes) {
      throw Exception('响应过大（> 10 MB），已拒绝');
    }
    final ct = contentType?.toLowerCase().trim() ?? '';
    if (ct.isEmpty) return; // 缺 Content-Type 放行（兼容性）
    final ok = ct.contains('json') ||
        ct.contains('text/plain') ||
        ct.contains('application/octet-stream');
    if (!ok) {
      throw Exception('远端 Content-Type 不允许: $ct');
    }
  }

  /// 拉取 URL → 返回响应 body（纯文本）。MVP 用 dio + 30s 超时 +
  /// 10 MB body 上限 + Content-Type allow-list（BATCH-05 / F-W2B-002）。
  /// 测试钩子绕过这一步。
  static Future<String> _fetchText(String url) async {
    // BATCH-05 (F-W2B-002): defense-in-depth —— protocol parser 已校过
    // scheme，但万一别的 caller 直接调 _fetchText（含未来 path），仍守住。
    enforceWebViewScheme(url);
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
    ));
    final resp = await dio.get<String>(
      url,
      options: Options(
        responseType: ResponseType.plain,
        headers: {'User-Agent': defaultUserAgent()},
      ),
    );
    final data = resp.data;
    if (data == null || data.isEmpty) {
      throw Exception('远端返回空内容');
    }
    final ct = resp.headers.value('content-type');
    validateFetchedBody(data, ct);
    return data;
  }

  /// 把 URL 的 host (+ path 末段) 拼成订阅源默认名，避免空名。
  static String _defaultSubName(String url) {
    try {
      final uri = Uri.parse(url);
      final host = uri.host;
      final segs = uri.pathSegments
          .where((s) => s.isNotEmpty)
          .toList(growable: false);
      if (segs.isEmpty) return host.isEmpty ? '订阅源' : host;
      return host.isEmpty ? segs.last : '$host/${segs.last}';
    } catch (_) {
      return '订阅源';
    }
  }

  /// 主入口。返回适合直接显示在 SnackBar 的文本。
  static Future<String> handle(
    WidgetRef ref,
    ParsedLegadoQr parsed, {
    String? dbPathOverride,
    Future<String> Function(String url)? fetchUrlOverride,
    Future<int> Function(String dbPath, String json)?
        importBookSourcesOverride,
    Future<String> Function(String dbPath, String json)?
        importRssSourcesOverride,
    Future<String> Function(
      String dbPath,
      String name,
      String url,
      int subType,
    )? createRuleSubOverride,
    Future<String> Function(String dbPath, String id)?
        refreshRuleSubOverride,
  }) async {
    final String dbPath =
        dbPathOverride ?? await ref.read(dbPathProvider.future);
    final fetch = fetchUrlOverride ?? _fetchText;
    switch (parsed.type) {
      case LegadoQrType.bookSource:
        final body = await fetch(parsed.fetchUrl);
        final fn = importBookSourcesOverride ??
            (db, j) =>
                rust_api.importSourcesFromJson(dbPath: db, json: j);
        final n = await fn(dbPath, body);
        return '已导入 $n 个书源';
      case LegadoQrType.rssSource:
        final body = await fetch(parsed.fetchUrl);
        final fn = importRssSourcesOverride ??
            (db, j) =>
                rust_api.rssSourceImportJson(dbPath: db, json: j);
        final summaryJson = await fn(dbPath, body);
        try {
          final m = jsonDecode(summaryJson) as Map<String, dynamic>;
          final added = (m['added'] as num?)?.toInt() ?? 0;
          final updated = (m['updated'] as num?)?.toInt() ?? 0;
          final skipped = (m['skipped'] as num?)?.toInt() ?? 0;
          return '新增 $added，更新 $updated，跳过 $skipped';
        } catch (_) {
          return '已导入 RSS 源';
        }
      case LegadoQrType.sourceSub:
        final name = _defaultSubName(parsed.fetchUrl);
        final createFn = createRuleSubOverride ??
            (String db, String n, String u, int t) =>
                rust_api.ruleSubCreate(
                    dbPath: db, name: n, url: u, subType: t);
        final subJson =
            await createFn(dbPath, name, parsed.fetchUrl, 0);
        String? newId;
        try {
          final m = jsonDecode(subJson) as Map<String, dynamic>;
          newId = m['id'] as String?;
        } catch (_) {
          newId = null;
        }
        if (newId == null || newId.isEmpty) {
          return '已添加订阅源（解析 id 失败，未自动刷新）';
        }
        final refreshFn = refreshRuleSubOverride ??
            (String db, String id) =>
                rust_api.ruleSubRefresh(dbPath: db, id: id);
        try {
          await refreshFn(dbPath, newId);
        } catch (e) {
          return '已添加订阅源，但刷新失败: $e';
        }
        return '已添加订阅源《$name》并刷新完成';
      case LegadoQrType.replaceRule:
        return '替换规则订阅暂未实装（批次 21+）';
    }
  }
}
