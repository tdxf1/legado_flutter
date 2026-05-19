import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
