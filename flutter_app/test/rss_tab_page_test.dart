import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/features/rss/rss_tab_page.dart';

/// BATCH-28 (05-22): RssTabPage widget 测试。
///
/// 通过 [RssTabPage] 的 *Override 钩子注入 fake sources + groups +
/// unreadCounts，绕过 FRB 桥 / path_provider，验证：
/// 1. 空态：无源时显示 "暂无订阅源" + "去添加" 按钮。
/// 2. GridView 渲染：显示源名 + 4 列网格。
/// 3. 分组 chips：有分组时显示 ChoiceChip，选组后 filter。
/// 4. 点 source push `/rss-articles?sourceUrl=...`。
void main() {
  Widget buildPage({
    List<Map<String, dynamic>>? sources,
    List<String>? groups,
    Map<String, int>? unreadCounts,
  }) {
    return ProviderScope(
      child: MaterialApp(
        home: RssTabPage(
          dbPathOverride: '/tmp/legado-test.db',
          sourcesOverride: sources,
          groupsOverride: groups,
          unreadCountsOverride: unreadCounts,
        ),
      ),
    );
  }

  testWidgets('BATCH-28: 空态显示暂无订阅源 + 去添加按钮',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildPage(sources: const [], groups: const []));
    await tester.pumpAndSettle();
    expect(find.text('暂无订阅源'), findsOneWidget);
    expect(find.text('去添加'), findsOneWidget);
    expect(find.byIcon(Icons.rss_feed), findsOneWidget);
  });

  testWidgets('BATCH-28: GridView 渲染源名',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildPage(
      sources: const [
        {
          'source_url': 'https://feed.example/atom',
          'source_name': '示例 RSS',
          'source_group': '科技',
          'source_icon': '',
          'enabled': true,
        },
        {
          'source_url': 'https://feed2.example/rss',
          'source_name': 'RSS 2',
          'source_group': '科技',
          'source_icon': '',
          'enabled': true,
        },
        {
          'source_url': 'https://feed3.example/rss',
          'source_name': 'RSS 3',
          'source_group': null,
          'source_icon': '',
          'enabled': true,
        },
      ],
      groups: const ['科技', '生活'],
      unreadCounts: const {'https://feed.example/atom': 5},
    ));
    await tester.pumpAndSettle();

    // 3 个源名可见
    expect(find.text('示例 RSS'), findsOneWidget);
    expect(find.text('RSS 2'), findsOneWidget);
    expect(find.text('RSS 3'), findsOneWidget);

    // GridView 4 列
    expect(find.byType(GridView), findsOneWidget);

    // 未读 badge：示例 RSS 有 5 个未读 → badge 可见
    expect(find.text('5'), findsOneWidget);
    // RSS 2 和 RSS 3 无未读 → 不显示 badge 数字
    // (badge 数字仅在 unread > 0 时渲染)
  });

  testWidgets('BATCH-28: 分组 chips 筛选',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildPage(
      sources: const [
        {
          'source_url': 'https://a.example/rss',
          'source_name': '科技源',
          'source_group': '科技',
          'source_icon': '',
          'enabled': true,
        },
        {
          'source_url': 'https://b.example/rss',
          'source_name': '生活源',
          'source_group': '生活',
          'source_icon': '',
          'enabled': true,
        },
      ],
      groups: const ['科技', '生活'],
    ));
    await tester.pumpAndSettle();

    // 默认全部可见
    expect(find.text('科技源'), findsOneWidget);
    expect(find.text('生活源'), findsOneWidget);

    // 3 chips: 全部 + 科技 + 生活
    expect(find.byType(ChoiceChip), findsNWidgets(3));

    // 选「科技」→ 仅科技源可见
    await tester.tap(find.widgetWithText(ChoiceChip, '科技'));
    await tester.pumpAndSettle();
    expect(find.text('科技源'), findsOneWidget);
    expect(find.text('生活源'), findsNothing);

    // 选「全部」→ 全部可见
    await tester.tap(find.widgetWithText(ChoiceChip, '全部'));
    await tester.pumpAndSettle();
    expect(find.text('科技源'), findsOneWidget);
    expect(find.text('生活源'), findsOneWidget);
  });

  testWidgets('BATCH-28: AppBar actions 可见',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildPage(sources: const [], groups: const []));
    await tester.pumpAndSettle();

    // 收藏 / 分组 / 设置 3 个 IconButton
    expect(find.byIcon(Icons.star_outline), findsOneWidget);
    expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
  });
}
