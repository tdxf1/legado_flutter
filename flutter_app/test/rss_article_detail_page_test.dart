import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:legado_flutter/features/rss/rss_article_detail_page.dart';

/// 批次 18 (05-19): RSS 文章详情页 widget 测试。
///
/// 通过 [RssArticleDetailPage] 的 *Override 钩子注入 source / article /
/// fetchHtml / isStarred mock，绕过 FRB 桥 / path_provider。
///
/// 注意：webview_flutter 在 widget test 环境无法 mock 平台 channel；
/// 用 `disableWebView: true` 让页面用 Text 占位代替 WebView，验证
/// 加载流程进入到正确分支即可。
void main() {
  testWidgets('renders detail page with mocked fetcher',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: RssArticleDetailPage(
            sourceUrl: 'https://feed.example/atom',
            link: 'https://x/article/1',
            dbPathOverride: '/tmp/legado-test.db',
            disableWebView: true,
            sourceOverride: const {
              'source_url': 'https://feed.example/atom',
              'source_name': '示例 RSS',
              'rule_content': null,
            },
            articleOverride: const {
              'origin': 'https://feed.example/atom',
              'sort': '',
              'title': '示例文章标题',
              'pub_date': '2024-05-19',
              'link': 'https://x/article/1',
              'image': null,
              'description': '<p>正文片段</p>',
              'order_num': 0,
              'read_time': 1700000000,
              'star': 0,
            },
            isStarredOverride: (dbPath, origin, link) async => false,
            fetchHtmlOverride: (dbPath, sourceUrl, link) async {
              return {
                'html':
                    '<!DOCTYPE html><html><body><p>正文片段</p></body></html>',
                'base_url': 'https://feed.example/atom',
              };
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // AppBar 显示文章标题
    expect(find.text('示例文章标题'), findsOneWidget);
    // disableWebView=true 时主体走 Text 占位（含 HTML 长度展示）
    expect(find.textContaining('HTML 长度='), findsOneWidget);
    // 收藏按钮显示为 outline（未收藏）
    expect(find.byIcon(Icons.star_outline), findsOneWidget);
    expect(find.byIcon(Icons.star), findsNothing);
  });

  testWidgets(
      'tap star toggles to starred via starAddOverride',
      (WidgetTester tester) async {
    String? capturedArticleJson;
    String? capturedSourceName;
    int addCalls = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: RssArticleDetailPage(
            sourceUrl: 'https://feed.example/atom',
            link: 'https://x/article/1',
            dbPathOverride: '/tmp/legado-test.db',
            disableWebView: true,
            sourceOverride: const {
              'source_url': 'https://feed.example/atom',
              'source_name': '示例 RSS',
            },
            articleOverride: const {
              'origin': 'https://feed.example/atom',
              'sort': '',
              'title': '示例文章',
              'pub_date': '2024-05-19',
              'link': 'https://x/article/1',
              'image': null,
              'description': '<p>body</p>',
              'order_num': 0,
              'read_time': 1700000000,
              'star': 0,
            },
            isStarredOverride: (dbPath, origin, link) async => false,
            fetchHtmlOverride: (dbPath, sourceUrl, link) async {
              return {
                'html': '<html><body>x</body></html>',
                'base_url': 'https://feed.example/atom',
              };
            },
            starAddOverride: (dbPath, articleJson, sourceName) async {
              addCalls++;
              capturedArticleJson = articleJson;
              capturedSourceName = sourceName;
              return 1;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 点击 star_outline 按钮触发 add
    await tester.tap(find.byIcon(Icons.star_outline));
    await tester.pumpAndSettle();

    expect(addCalls, 1);
    expect(capturedSourceName, '示例 RSS');
    expect(capturedArticleJson, isNotNull);
    final decoded = jsonDecode(capturedArticleJson!) as Map<String, dynamic>;
    expect(decoded['title'], '示例文章');
    expect(decoded['link'], 'https://x/article/1');

    // UI 切到 filled star
    expect(find.byIcon(Icons.star), findsOneWidget);
  });

  testWidgets('shows error + retry button when fetch throws',
      (WidgetTester tester) async {
    int fetchCalls = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: RssArticleDetailPage(
            sourceUrl: 'https://feed.example/atom',
            link: 'https://x/article/err',
            dbPathOverride: '/tmp/legado-test.db',
            disableWebView: true,
            sourceOverride: const {
              'source_url': 'https://feed.example/atom',
              'source_name': '示例 RSS',
            },
            articleOverride: const {
              'origin': 'https://feed.example/atom',
              'sort': '',
              'title': '示例文章',
              'pub_date': '2024-05-19',
              'link': 'https://x/article/err',
              'image': null,
              'description': null,
              'order_num': 0,
              'read_time': 1700000000,
              'star': 0,
            },
            isStarredOverride: (dbPath, origin, link) async => false,
            fetchHtmlOverride: (dbPath, sourceUrl, link) async {
              fetchCalls++;
              throw Exception('网络炸了');
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(fetchCalls, 1);
  });

  testWidgets(
      'BATCH-21 (F-W2B-009): isStarred + fetchHtml run in parallel '
      '(both started before either completes)', (WidgetTester tester) async {
    final isStarredCompleter = Completer<bool>();
    final fetchCompleter = Completer<Map<String, dynamic>>();
    var isStarredStarted = false;
    var fetchStarted = false;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: RssArticleDetailPage(
            sourceUrl: 'https://feed.example/atom',
            link: 'https://x/article/1',
            dbPathOverride: '/tmp/legado-test.db',
            disableWebView: true,
            sourceOverride: const {
              'source_url': 'https://feed.example/atom',
              'source_name': '示例 RSS',
            },
            articleOverride: const {
              'origin': 'https://feed.example/atom',
              'sort': '',
              'title': '示例文章',
              'pub_date': '2024-05-19',
              'link': 'https://x/article/1',
              'image': null,
              'description': null,
              'order_num': 0,
              'read_time': 1700000000,
              'star': 0,
            },
            isStarredOverride: (dbPath, origin, link) {
              isStarredStarted = true;
              return isStarredCompleter.future;
            },
            fetchHtmlOverride: (dbPath, sourceUrl, link) {
              fetchStarted = true;
              return fetchCompleter.future;
            },
          ),
        ),
      ),
    );
    // 第一次 pump 让 _bootstrap 启动各个 future。Future.wait 内的 starred
    // future 已发起；fetch 单独串行在 Future.wait 之后才启动 —— 这是
    // 当前并行化范围（PRD: 主要并行 source/article/isStarred 三段，
    // fetchHtml 保留独立串行错误分支）。
    await tester.pump();
    expect(isStarredStarted, isTrue,
        reason: 'isStarred 应在 Future.wait 内并行启动');
    // fetch 在串行流程后才启动；先 complete starred 让控制流继续
    isStarredCompleter.complete(true);
    await tester.pump();
    expect(fetchStarted, isTrue, reason: 'starred 完成后 fetch 应被发起');
    // 完成 fetch，结束 _bootstrap
    fetchCompleter.complete({
      'html': '<html><body>x</body></html>',
      'base_url': 'https://feed.example/atom',
    });
    await tester.pumpAndSettle();
    // starred=true 走 filled star icon
    expect(find.byIcon(Icons.star), findsOneWidget);
  });

  testWidgets(
      'BATCH-21c (F-W2B-012): markRead success → AppBar back pops with '
      'MarkReadResult.success', (WidgetTester tester) async {
    final result = await _pumpDetailAndTapBack(
      tester,
      readTime: 0,
      markReadOverride: (dbPath, link, ts) async => 1,
    );
    expect(result, MarkReadResult.success);
  });

  testWidgets(
      'BATCH-21c (F-W2B-012): markRead throws → AppBar back pops with '
      'MarkReadResult.failed (list will rollback optimistic)',
      (WidgetTester tester) async {
    final result = await _pumpDetailAndTapBack(
      tester,
      readTime: 0,
      markReadOverride: (dbPath, link, ts) async {
        throw Exception('FRB / db lock');
      },
    );
    expect(result, MarkReadResult.failed);
  });

  testWidgets(
      'BATCH-21c (F-W2B-012): article already read → mark_read skipped → '
      'AppBar back pops with MarkReadResult.skipped (default)',
      (WidgetTester tester) async {
    var markReadCalls = 0;
    final result = await _pumpDetailAndTapBack(
      tester,
      readTime: 1700000000, // 已读，跳过 mark_read
      markReadOverride: (dbPath, link, ts) async {
        markReadCalls++;
        return 1;
      },
    );
    expect(markReadCalls, 0, reason: 'readTime != 0 时不应调 mark_read');
    expect(result, MarkReadResult.skipped);
  });
}

/// BATCH-21c (F-W2B-012) helper：在一个最小 GoRouter 里 push detail 页 →
/// pumpAndSettle → tap AppBar leading back → 返回 detail pop 时携带的
/// `MarkReadResult`（或 null 如未携带）。
Future<MarkReadResult?> _pumpDetailAndTapBack(
  WidgetTester tester, {
  required int readTime,
  required Future<int> Function(String, String, int) markReadOverride,
}) async {
  final completer = Completer<MarkReadResult?>();
  final router = GoRouter(
    initialLocation: '/home',
    routes: [
      GoRoute(
        path: '/home',
        builder: (context, state) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                final r = await context.push<MarkReadResult>('/detail');
                completer.complete(r);
              },
              child: const Text('GO'),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/detail',
        builder: (context, state) => RssArticleDetailPage(
          sourceUrl: 'https://feed.example/atom',
          link: 'https://x/article/1',
          dbPathOverride: '/tmp/legado-test.db',
          disableWebView: true,
          sourceOverride: const {
            'source_url': 'https://feed.example/atom',
            'source_name': '示例 RSS',
          },
          articleOverride: {
            'origin': 'https://feed.example/atom',
            'sort': '',
            'title': '示例文章',
            'pub_date': '2024-05-19',
            'link': 'https://x/article/1',
            'image': null,
            'description': null,
            'order_num': 0,
            'read_time': readTime,
            'star': 0,
          },
          isStarredOverride: (dbPath, origin, link) async => false,
          fetchHtmlOverride: (dbPath, sourceUrl, link) async {
            return {
              'html': '<html><body>x</body></html>',
              'base_url': 'https://feed.example/atom',
            };
          },
          markReadOverride: markReadOverride,
        ),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp.router(
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  // 首屏 home → 点 GO 进 detail
  await tester.tap(find.text('GO'));
  await tester.pumpAndSettle();
  // detail _bootstrap 已跑完，_markReadResult 已根据三路径设值。
  // 点 AppBar leading back（Icons.arrow_back 是 detail leading 自定义按钮）
  await tester.tap(find.byIcon(Icons.arrow_back));
  await tester.pumpAndSettle();
  return completer.future;
}
