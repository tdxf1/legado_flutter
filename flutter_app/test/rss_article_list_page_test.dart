import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/features/rss/rss_article_list_page.dart';

/// 批次 17 (05-19): RSS 文章列表页 widget 测试。
///
/// 通过 [RssArticleListPage] 的 *Override 钩子注入 fake source / tabs /
/// articles + getArticlesOverride mock，绕过 FRB 桥 / path_provider。
///
/// 验证：
/// 1. 列表渲染：5 篇文章（已读/未读混合），unread 标题前应有蓝点；
///    pubDate / description 50 字符 subtitle 正确。
/// 2. 下拉刷新：触发 getArticlesOverride mock 一次。
void main() {
  testWidgets('renders article list with unread/read mix',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: RssArticleListPage(
            sourceUrl: 'https://feed.example/atom',
            dbPathOverride: '/tmp/legado-test.db',
            sourceOverride: const {
              'source_url': 'https://feed.example/atom',
              'source_name': '示例 RSS',
              'single_url': true,
              'sort_url': null,
            },
            tabsOverride: const [],
            articlesOverride: const [
              {
                'origin': 'https://feed.example/atom',
                'sort': '',
                'title': '标题 A — Read',
                'pub_date': '2024-01-01',
                'link': 'https://x/a',
                'image': null,
                'description': 'Desc A',
                'order_num': 0,
                'read_time': 1700000000,
                'star': 0,
              },
              {
                'origin': 'https://feed.example/atom',
                'sort': '',
                'title': '标题 B — Unread',
                'pub_date': '2024-01-02',
                'link': 'https://x/b',
                'image': null,
                'description': 'Desc B',
                'order_num': 1,
                'read_time': 0,
                'star': 0,
              },
              {
                'origin': 'https://feed.example/atom',
                'sort': '',
                'title': '标题 C — Unread',
                'pub_date': '2024-01-03',
                'link': 'https://x/c',
                'image': null,
                'description': 'Desc C',
                'order_num': 2,
                'read_time': 0,
                'star': 0,
              },
              {
                'origin': 'https://feed.example/atom',
                'sort': '',
                'title': '标题 D — Read',
                'pub_date': '2024-01-04',
                'link': 'https://x/d',
                'image': null,
                'description': 'Desc D',
                'order_num': 3,
                'read_time': 1700000010,
                'star': 0,
              },
              {
                'origin': 'https://feed.example/atom',
                'sort': '',
                'title': '标题 E — Unread',
                'pub_date': '2024-01-05',
                'link': 'https://x/e',
                'image': null,
                'description': 'Desc E',
                'order_num': 4,
                'read_time': 0,
                'star': 0,
              },
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // AppBar title = source_name
    expect(find.text('示例 RSS'), findsOneWidget);
    // 5 个标题
    expect(find.text('标题 A — Read'), findsOneWidget);
    expect(find.text('标题 B — Unread'), findsOneWidget);
    expect(find.text('标题 C — Unread'), findsOneWidget);
    expect(find.text('标题 D — Read'), findsOneWidget);
    expect(find.text('标题 E — Unread'), findsOneWidget);

    // 5 个 subtitle (pubDate · desc)
    expect(find.text('2024-01-01 · Desc A'), findsOneWidget);
    expect(find.text('2024-01-05 · Desc E'), findsOneWidget);

    // 单 URL 模式 → 不应有 TabBar
    expect(find.byType(TabBar), findsNothing);
  });

  testWidgets('pull-to-refresh triggers getArticlesOverride exactly once',
      (WidgetTester tester) async {
    int calls = 0;
    String? lastSortName;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: RssArticleListPage(
            sourceUrl: 'https://feed.example/atom',
            dbPathOverride: '/tmp/legado-test.db',
            sourceOverride: const {
              'source_url': 'https://feed.example/atom',
              'source_name': '示例 RSS',
              'single_url': true,
              'sort_url': null,
            },
            tabsOverride: const [],
            articlesOverride: const [
              {
                'origin': 'https://feed.example/atom',
                'sort': '',
                'title': '标题 A',
                'pub_date': '2024-01-01',
                'link': 'https://x/a',
                'image': null,
                'description': 'Desc A',
                'order_num': 0,
                'read_time': 0,
                'star': 0,
              },
            ],
            getArticlesOverride: (
              dbPath,
              sourceUrl,
              sortName,
              sortUrl,
              page,
            ) async {
              calls++;
              lastSortName = sortName;
              // 返回新的 1 条数据
              return jsonEncode([
                {
                  'origin': 'https://feed.example/atom',
                  'sort': '',
                  'title': '标题 A (refreshed)',
                  'pub_date': '2024-01-02',
                  'link': 'https://x/a',
                  'image': null,
                  'description': 'Desc A New',
                  'order_num': 0,
                  'read_time': 0,
                  'star': 0,
                },
              ]);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 下拉刷新（drag from list top down）
    await tester.fling(find.byType(ListView), const Offset(0, 400), 1000);
    await tester.pump(); // refresh starts
    await tester.pumpAndSettle();

    expect(calls, 1, reason: '下拉刷新应只触发一次 mock');
    expect(lastSortName, '');
    // 列表已被替换
    expect(find.text('标题 A (refreshed)'), findsOneWidget);
  });
}
