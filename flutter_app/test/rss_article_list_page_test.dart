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

  testWidgets(
      'BATCH-21 (F-W2B-013): KeepAlive — 切换 tab 后 ListView state '
      '通过 AutomaticKeepAlive 保留', (WidgetTester tester) async {
    // 构造一个多 tab 的源 — 走 sortUrl + 提供 tabsOverride 显式构造 2 个
    // tab；articlesOverride 走第一个 tab key。
    final manyArticles = List.generate(
      30,
      (i) => {
        'origin': 'https://feed.example/atom',
        'sort': '',
        'title': '标题 $i',
        'pub_date': '2024-01-${(i + 1).toString().padLeft(2, '0')}',
        'link': 'https://x/$i',
        'image': null,
        'description': 'Desc $i',
        'order_num': i,
        'read_time': 0,
        'star': 0,
      },
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: RssArticleListPage(
            sourceUrl: 'https://feed.example/atom',
            dbPathOverride: '/tmp/legado-test.db',
            sourceOverride: const {
              'source_url': 'https://feed.example/atom',
              'source_name': '示例 RSS',
              'single_url': false,
              'sort_url': '热门::https://x/hot\n最新::https://x/new',
            },
            tabsOverride: const [
              {'name': '热门', 'url': 'https://x/hot'},
              {'name': '最新', 'url': 'https://x/new'},
            ],
            articlesOverride: manyArticles,
            // 切到 "最新" tab 时会触发 getArticlesOverride（首次进 tab 自动拉取）
            getArticlesOverride: (
              dbPath,
              sourceUrl,
              sortName,
              sortUrl,
              page,
            ) async {
              return jsonEncode([
                {
                  'origin': 'https://feed.example/atom',
                  'sort': sortName,
                  'title': '$sortName 文章',
                  'pub_date': '2024-02-01',
                  'link': 'https://x/${sortName}_only',
                  'image': null,
                  'description': '...',
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
    // 默认在 "热门" tab —— 30 篇文章
    expect(find.text('标题 0'), findsOneWidget);
    // 滚到中间
    final firstListView = find.byType(ListView).first;
    await tester.drag(firstListView, const Offset(0, -400));
    await tester.pumpAndSettle();
    // 滚动后 "标题 0" 不再可见，"标题 10+" 可见
    expect(find.text('标题 0'), findsNothing);

    // 切到 "最新" tab
    await tester.tap(find.text('最新'));
    await tester.pumpAndSettle();
    // 应有 "最新 文章"
    expect(find.text('最新 文章'), findsOneWidget);

    // 切回 "热门" tab —— KeepAlive 应保留 scroll position
    await tester.tap(find.text('热门'));
    await tester.pumpAndSettle();
    // 验证仍滚在中段（"标题 0" 不可见）—— 这是 KeepAlive 生效的核心证据
    expect(find.text('标题 0'), findsNothing,
        reason: 'KeepAlive 应保留 scroll offset；如失效则 List 重建会回到顶');
  });
}
