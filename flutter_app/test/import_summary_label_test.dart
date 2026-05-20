/// `formatImportSummaryLabel` helper 边界测试（BATCH-24, F-W2B-024）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/util/import_summary_label.dart';

void main() {
  group('formatImportSummaryLabel', () {
    test('完整 JSON 拼接（无错误）', () {
      final json = jsonEncode({
        'books': 12,
        'groups': 3,
        'bookmarks': 45,
        'replace_rules': 7,
        'sources': 5,
        'errors': <String>[],
      });
      final label = formatImportSummaryLabel(
        json,
        prefix: '导入完成',
        fallback: '导入完成',
      );
      expect(
        label,
        '导入完成: 12 本书 / 3 个分组 / 45 条书签 / 7 条替换规则 / 5 个书源',
      );
    });

    test('errors > 0 含错误数（WebDAV 前缀）', () {
      final json = jsonEncode({
        'books': 1,
        'groups': 0,
        'bookmarks': 0,
        'replace_rules': 0,
        'sources': 0,
        'errors': ['解析失败: bad.json', '空 zip'],
      });
      final label = formatImportSummaryLabel(
        json,
        prefix: '从 WebDAV 恢复',
        fallback: '从 WebDAV 恢复完成',
      );
      expect(
        label,
        '从 WebDAV 恢复: 1 本书 / 0 个分组 / 0 条书签 / 0 条替换规则 / 0 个书源（2 项错误）',
      );
    });

    test('字段缺失走 ?? 0 兜底', () {
      // 仅有 books 一个字段，其它走默认 0
      final json = jsonEncode({'books': 5});
      final label = formatImportSummaryLabel(
        json,
        prefix: '导入完成',
        fallback: '导入完成',
      );
      expect(
        label,
        '导入完成: 5 本书 / 0 个分组 / 0 条书签 / 0 条替换规则 / 0 个书源',
      );
    });

    test('解析失败走 fallback', () {
      const badJson = 'not-a-json{';
      final label = formatImportSummaryLabel(
        badJson,
        prefix: '导入完成',
        fallback: '导入完成',
      );
      expect(label, '导入完成');
    });
  });
}
