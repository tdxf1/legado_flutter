// 批次 21 (05-19) — _LiveTestDialog widget tests
//
// 走 source_page.dart 的 @visibleForTesting helper [showLiveTestDialogForTesting]
// 直接弹 _LiveTestDialog（私有 widget）。
//
// BATCH-20 (F-W2B-020)：原 module-level mutable `debugLiveTestRunnerOverride`
// 删除，改为通过 `ProviderScope.overrides` 注入 fake [SourceValidationService]
// 替代真实 FRB 调用。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/core/services/source_validation_service.dart';
import 'package:legado_flutter/features/source/source_page.dart';

/// 测试用 fake：返回构造时配的固定 JSON。无 JSON 设置时不应该被调（默认场景）。
class _FakeSourceValidationService extends SourceValidationService {
  final String? returnJson;
  const _FakeSourceValidationService([this.returnJson]);

  @override
  Future<String> validateLive({
    required String dbPath,
    required String sourceId,
    required String keyword,
  }) async {
    if (returnJson == null) {
      throw StateError('fake validateLive 未配置 returnJson 但被调用');
    }
    return returnJson!;
  }
}

void main() {
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
    final mockJson = jsonEncode({
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

    await _openDialog(
      tester,
      service: _FakeSourceValidationService(mockJson),
    );
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

Future<void> _openDialog(
  WidgetTester tester, {
  SourceValidationService? service,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (service != null)
          sourceValidationServiceProvider.overrideWithValue(service)
        else
          // 默认场景：测试只验证 dialog UI 占位，不应触发 validateLive。
          sourceValidationServiceProvider.overrideWithValue(
            const _FakeSourceValidationService(),
          ),
      ],
      child: MaterialApp(
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
    ),
  );
  await tester.tap(find.text('OPEN'));
  await tester.pumpAndSettle();
}
