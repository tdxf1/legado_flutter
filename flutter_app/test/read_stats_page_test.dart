import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/features/settings/read_stats_page.dart';

/// 批次 14 (05-19): 阅读统计页 widget 测试。
///
/// 通过 [ReadStatsPage] 的 *Override 钩子注入 fake records + total，
/// 绕过 FRB 桥 / path_provider，验证：
/// 1. 顶部 Card 显示总时长格式（formatReadDuration 公共 helper）。
/// 2. ListView 至少含 fake 书名 + 单本时长格式正确。
/// 3. formatReadDuration 边界：3725 秒 → "1 小时 2 分"。
void main() {
  testWidgets('ReadStatsPage renders total + per-book entries',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: ReadStatsPage(
            dbPathOverride: '/tmp/legado-test.db',
            recordsOverride: const [
              {
                'id': 'r1',
                'book_id': 'b1',
                'book_name': '三体',
                'read_time': 3725, // 1h 2m
                'last_read_at': 1, // 古老 → 走"yyyy-MM-dd"分支但 not crash
              },
              {
                'id': 'r2',
                'book_id': 'b2',
                'book_name': '球状闪电',
                'read_time': 60, // 0h 1m
                'last_read_at': 2,
              },
            ],
            totalOverride: 3725 + 60, // 3785s = 1h 3m
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // AppBar 标题。
    expect(find.text('阅读统计'), findsOneWidget);
    // 顶部 Card：总时长。
    expect(find.text('累计阅读时长'), findsOneWidget);
    expect(find.text('1 小时 3 分'), findsOneWidget);
    // ListView：两本书都在。
    expect(find.text('三体'), findsOneWidget);
    expect(find.text('球状闪电'), findsOneWidget);
    // 单本时长（与"上次读" 拼在 subtitle 一起）。
    expect(find.textContaining('1 小时 2 分'), findsOneWidget);
    expect(find.textContaining('1 分'), findsWidgets); // matches subtitle of b2
  });

  testWidgets(
      'ReadStatsPage shows empty state when records list is empty',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: ReadStatsPage(
            dbPathOverride: '/tmp/legado-test.db',
            recordsOverride: const [],
            totalOverride: 0,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂无阅读记录'), findsOneWidget);
    // 0 秒 -> "0 分"
    expect(find.text('0 分'), findsOneWidget);
  });

  test('formatReadDuration edge cases', () {
    expect(formatReadDuration(0), '0 分');
    expect(formatReadDuration(-5), '0 分');
    expect(formatReadDuration(59), '0 分');
    expect(formatReadDuration(60), '1 分');
    expect(formatReadDuration(3725), '1 小时 2 分');
    expect(formatReadDuration(3600), '1 小时 0 分');
  });
}
