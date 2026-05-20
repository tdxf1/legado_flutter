import 'dart:convert';

/// `ImportSummary` JSON → 中文展示标签 helper（BATCH-24, 2026-05-21）。
///
/// Rust `import_backup_zip` 与 `webdav_download_backup` 都返回同一个
/// `ImportSummary` JSON：
/// ```json
/// {"books": 12, "groups": 3, "bookmarks": 45, "replace_rules": 7,
///  "sources": 5, "errors": []}
/// ```
///
/// 历史上 backup_page.dart 在两处 caller (本地导入 + WebDAV 恢复) 各自抄了
/// 一遍 `jsonDecode + 6 字段读取 + label 拼接 + try/catch fallback` 模板，仅
/// 前缀文案与兜底文案不同。
///
/// 本 helper 抽取共同逻辑，caller 只传入两段文案：
///
/// ```dart
/// // 本地导入路径：
/// label = formatImportSummaryLabel(
///   summaryJson,
///   prefix: '导入完成',
///   fallback: '导入完成',
/// );
/// // WebDAV 恢复路径：
/// label = formatImportSummaryLabel(
///   summaryJson,
///   prefix: '从 WebDAV 恢复',
///   fallback: '从 WebDAV 恢复完成',
/// );
/// ```
///
/// 成功路径输出形如：
/// `导入完成: 12 本书 / 3 个分组 / 45 条书签 / 7 条替换规则 / 5 个书源（2 项错误）`
///
/// 见 finding F-W2B-024 in `findings-flutter-features.md`。
String formatImportSummaryLabel(
  String summaryJson, {
  required String prefix,
  required String fallback,
}) {
  try {
    final Map<String, dynamic> summary =
        jsonDecode(summaryJson) as Map<String, dynamic>;
    final books = summary['books'] ?? 0;
    final groups = summary['groups'] ?? 0;
    final bookmarks = summary['bookmarks'] ?? 0;
    final rules = summary['replace_rules'] ?? 0;
    final sources = summary['sources'] ?? 0;
    final errors = summary['errors'];
    final errorCount = (errors is List) ? errors.length : 0;
    return '$prefix: $books 本书 / $groups 个分组 / '
        '$bookmarks 条书签 / $rules 条替换规则 / $sources 个书源'
        '${errorCount > 0 ? '（$errorCount 项错误）' : ''}';
  } catch (_) {
    return fallback;
  }
}
