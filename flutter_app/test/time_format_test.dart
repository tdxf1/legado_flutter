/// `formatRelativeTime` helper 边界测试（BATCH-24, F-W2B-030）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/util/time_format.dart';

void main() {
  group('formatRelativeTime', () {
    test('sec=0 返回 "从未"（修 bookshelf 端历史 bug）', () {
      expect(formatRelativeTime(0), '从未');
    });

    test('sec<0 返回 "从未"', () {
      expect(formatRelativeTime(-1), '从未');
    });

    test('30 秒前返回 "刚刚"', () {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect(formatRelativeTime(now - 30), '刚刚');
    });

    test('90 秒前返回 "1 分钟前"', () {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect(formatRelativeTime(now - 90), '1 分钟前');
    });

    test('2 小时前返回 "2 小时前"', () {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect(formatRelativeTime(now - 2 * 3600), '2 小时前');
    });

    test('5 天前返回 "5 天前"', () {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect(formatRelativeTime(now - 5 * 86400), '5 天前');
    });

    test('超过 30 天走 yyyy-MM-dd 格式', () {
      // 用一个固定的过去时间戳：2024-01-15 00:00 UTC
      const ts = 1705276800; // 2024-01-15 00:00 UTC
      final result = formatRelativeTime(ts);
      // 取 toLocal() 后日期，跨时区可能 ±1 天，但格式必定是 yyyy-MM-dd
      expect(result, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    });
  });
}
