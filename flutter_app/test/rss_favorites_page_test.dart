import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/features/rss/rss_favorites_page.dart';

/// 批次 18 (05-19): RSS 收藏页 widget 测试。
///
/// 通过 [RssFavoritesPage] 的 *Override 钩子注入 starsOverride，绕过
/// FRB 桥 / path_provider。
///
/// 验证：
/// 1. 空态：starsOverride=[] 时显示 "暂无收藏" + 提示文案
/// 2. 列表态：5 条收藏渲染 title / source_name · pub_date subtitle
void main() {
  testWidgets('renders empty state when no favorites',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: RssFavoritesPage(
            dbPathOverride: '/tmp/legado-test.db',
            starsOverride: [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('暂无收藏'), findsOneWidget);
    expect(find.textContaining('点 ★ 收藏'), findsOneWidget);
  });

  testWidgets('renders list of favorites with mocked data',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: RssFavoritesPage(
            dbPathOverride: '/tmp/legado-test.db',
            starsOverride: const [
              {
                'origin': 'https://feed.example/atom',
                'source_name': '示例 RSS',
                'sort': '',
                'title': '收藏文章 A',
                'pub_date': '2024-05-19',
                'image': null,
                'link': 'https://x/article/1',
                'description': null,
                'variable': null,
                'star_time': 1716000000,
              },
              {
                'origin': 'https://feed.example/atom',
                'source_name': '示例 RSS',
                'sort': '',
                'title': '收藏文章 B',
                'pub_date': '2024-05-18',
                'image': null,
                'link': 'https://x/article/2',
                'description': null,
                'variable': null,
                'star_time': 1715990000,
              },
              {
                'origin': 'https://feed.other/feed',
                'source_name': '另一源',
                'sort': '',
                'title': '收藏文章 C',
                'pub_date': '2024-05-17',
                'image': null,
                'link': 'https://y/3',
                'description': null,
                'variable': null,
                'star_time': 1715980000,
              },
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // AppBar
    expect(find.text('RSS 收藏'), findsOneWidget);
    // 3 个 title
    expect(find.text('收藏文章 A'), findsOneWidget);
    expect(find.text('收藏文章 B'), findsOneWidget);
    expect(find.text('收藏文章 C'), findsOneWidget);
    // subtitle 包含 source_name + pub_date
    expect(find.text('示例 RSS · 2024-05-19'), findsOneWidget);
    expect(find.text('另一源 · 2024-05-17'), findsOneWidget);
    // 不应显示空态
    expect(find.text('暂无收藏'), findsNothing);
  });
}
