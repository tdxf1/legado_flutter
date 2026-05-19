// 批次 21 (05-19) — _LiveTestDialog widget tests
//
// 走 source_page.dart 的 @visibleForTesting helper [showLiveTestDialogForTesting]
// 直接弹 _LiveTestDialog（私有 widget），用 [debugLiveTestRunnerOverride] 注入
// 假 LiveTestReport JSON 避免真实 FRB 调用。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/features/source/source_page.dart';

void main() {
  setUp(() {
    debugLiveTestRunnerOverride = null;
  });
  tearDown(() {
    debugLiveTestRunnerOverride = null;
  });

  testWidgets(
      'LiveTest dialog defaults keyword to "测试" and shows 4 stage placeholders',
      (WidgetTester tester) async {
    await _openDialog(tester);

    // 关键字 TextField 默认 "测试"
    expect(find.widgetWithText(TextField, '测试'), findsOneWidget);
    expect(find.text('开始测试'), findsOneWidget);

    // 4 个 stage 占位 ListTile 标签
    expect(find.text('搜索'), findsOneWidget);
    expect(find.text('书籍详情'), findsOneWidget);
    expect(find.text('章节列表'), findsOneWidget);
    expect(find.text('章节内容'), findsOneWidget);

    // "待开始" 占位文本（4 个）
    expect(find.text('待开始'), findsNWidgets(4));
  });

  testWidgets(
      'LiveTest dialog renders 4 stage results when override returns mixed-status JSON',
      (WidgetTester tester) async {
    debugLiveTestRunnerOverride = (
        {required String dbPath,
        required String sourceId,
        required String keyword}) async {
      // mimic Rust LiveTestReport JSON
      return jsonEncode({
        'stages': [
          {
            'stage': 'search',
            'ok': true,
            'latency_ms': 120,
            'sample': '第一本: 三体 / 刘慈欣',
          },
          {
            'stage': 'book_info',
            'ok': true,
            'latency_ms': 150,
            'sample': '三体 / 刘慈欣',
          },
          {
            'stage': 'toc',
            'ok': true,
            'latency_ms': 200,
            'sample': '第一章: 序章 (共 100 章)',
          },
          {
            'stage': 'content',
            'ok': false,
            'latency_ms': 80,
            'error': '网络请求失败: timeout',
          },
        ],
        'static_issues': [],
      });
    };

    await _openDialog(tester);
    await tester.tap(find.text('开始测试'));
    await tester.pumpAndSettle();

    // 3 个绿色 check + 1 个红色 error
    expect(find.byIcon(Icons.check_circle), findsNWidgets(3));
    expect(find.byIcon(Icons.error), findsOneWidget);

    // sample 文字与 latency
    expect(find.textContaining('第一本: 三体'), findsOneWidget);
    expect(find.textContaining('第一章: 序章'), findsOneWidget);
    expect(find.textContaining('网络请求失败'), findsOneWidget);
    expect(find.text('120ms'), findsOneWidget);
    expect(find.text('200ms'), findsOneWidget);
  });
}

Future<void> _openDialog(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () => showLiveTestDialogForTesting(
                ctx,
                dbPath: '/tmp/test.db',
                sourceId: 'src1',
                sourceName: 'Demo Source',
              ),
              child: const Text('OPEN'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('OPEN'));
  await tester.pumpAndSettle();
}
