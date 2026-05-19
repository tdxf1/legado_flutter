import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
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
  /// 拉取 URL → 返回响应 body（纯文本）。MVP 用 dio + 30s 超时。
  /// 测试钩子绕过这一步。
  static Future<String> _fetchText(String url) async {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
    ));
    final resp = await dio.get<String>(
      url,
      options: Options(responseType: ResponseType.plain),
    );
    final data = resp.data;
    if (data == null || data.isEmpty) {
      throw Exception('远端返回空内容');
    }
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
