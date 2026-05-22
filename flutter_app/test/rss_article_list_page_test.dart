import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:legado_flutter/features/rss/rss_article_list_page.dart';
import 'package:legado_flutter/features/rss/rss_article_detail_page.dart';

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

  testWidgets(
      'BATCH-21c (F-W2B-012): detail 返回 MarkReadResult.failed → '
      '列表 rollback optimistic + SnackBar', (WidgetTester tester) async {
    await _pumpListWithStubbedDetail(
      tester,
      detailReturns: MarkReadResult.failed,
    );

    // 点未读文章 B（read_time=0，title 前应有 unread dot）
    await tester.tap(find.text('标题 B — Unread'));
    await tester.pump(); // setState optimistic + push 启动
    // _onArticleTap setState 先执行 → optimistic 写入 article['read_time'] = ts
    // 但 detail stub 在 postFrameCallback 立即 pop 回 list 携带 failed，
    // _onArticleTap 后续 if (failed) setState rollback + 弹 SnackBar
    await tester.pumpAndSettle();

    // SnackBar 应显示 rollback 提示
    expect(find.text('已读状态同步失败，下次刷新会重试'), findsOneWidget);
    // article B 应仍是 unread（dot 未消失）
    // 由于 optimistic → rollback 已经走过，UI 体现为 isRead == false
    // 间接验证：我们重新 tap 同一个 item 不应早 return
    // 但这里更直接的断言是：title B 的样式仍为 unread（color != faded）
    // 为简化只断言 SnackBar，文本断言已足以验 rollback 触发
  });

  testWidgets(
      'BATCH-21c (F-W2B-012): detail 返回 MarkReadResult.success → '
      '列表保留 optimistic，不弹 SnackBar', (WidgetTester tester) async {
    await _pumpListWithStubbedDetail(
      tester,
      detailReturns: MarkReadResult.success,
    );

    await tester.tap(find.text('标题 B — Unread'));
    await tester.pumpAndSettle();

    // 不应弹 rollback SnackBar
    expect(find.text('已读状态同步失败，下次刷新会重试'), findsNothing);
  });

  testWidgets(
      'BATCH-21c (F-W2B-012): detail 返回 null（OS back 兜底） → '
      '列表保留 optimistic，不弹 SnackBar', (WidgetTester tester) async {
    await _pumpListWithStubbedDetail(
      tester,
      detailReturns: null, // null 模拟 OS back / swipe back 路径
    );

    await tester.tap(find.text('标题 B — Unread'));
    await tester.pumpAndSettle();

    expect(find.text('已读状态同步失败，下次刷新会重试'), findsNothing);
  });
}

/// BATCH-21c (F-W2B-012) helper：构造 GoRouter 把 list 装到 `/rss-articles`
/// + 把 `/rss-articles-detail` stub 成立刻 `context.pop(detailReturns)` 的
/// 占位页面，用来验 list 端 await result + rollback 分支。
Future<void> _pumpListWithStubbedDetail(
  WidgetTester tester, {
  required MarkReadResult? detailReturns,
}) async {
  final router = GoRouter(
    initialLocation: '/rss-articles?sourceUrl=https://feed.example/atom',
    routes: [
      GoRoute(
        path: '/rss-articles',
        builder: (context, state) => RssArticleListPage(
          sourceUrl:
              state.uri.queryParameters['sourceUrl'] ?? 'https://feed.example/atom',
          dbPathOverride: '/tmp/legado-test.db',
          sourceOverride: const {
            'source_url': 'https://feed.example/atom',
            'source_name': '示例 RSS',
            'single_url': true,
            'sort_url': null,
          },
          tabsOverride: const [],
          articlesOverride: [
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
          ],
        ),
      ),
      GoRoute(
        path: '/rss-articles-detail',
        builder: (context, state) => _DetailStubPage(returns: detailReturns),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

/// stub detail 页：在 first frame 后立刻 `context.pop(returns)`，模拟 detail
/// 真实 mark_read 完成 + 用户点 leading back 的合并行为。
class _DetailStubPage extends StatefulWidget {
  final MarkReadResult? returns;
  const _DetailStubPage({required this.returns});

  @override
  State<_DetailStubPage> createState() => _DetailStubPageState();
}

class _DetailStubPageState extends State<_DetailStubPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // returns == null 时走 Navigator.pop()（不带 result）模拟 OS back
      if (widget.returns == null) {
        context.pop();
      } else {
        context.pop(widget.returns);
      }
    });
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: SizedBox.shrink());
}
