import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/features/rss/rss_source_manage_page.dart';

/// 批次 16 (05-19): RSS 源管理页 widget 测试。
///
/// 通过 [RssSourceManagePage] 的 *Override 钩子注入 fake records +
/// setEnabled / delete mock，绕过 FRB 桥 / path_provider，验证：
/// 1. 空态：无记录时显示 "暂无 RSS 源" + "导入 RSS 源" 按钮。
/// 2. 列表渲染：分组 Section + ListTile（switch + name + url）。
/// 3. 切 enabled：tap Switch → setEnabledOverride 被调一次。
void main() {
  testWidgets('RssSourceManagePage shows empty state when records is empty',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: RssSourceManagePage(
            dbPathOverride: '/tmp/legado-test.db',
            recordsOverride: const [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('RSS 源管理'), findsOneWidget);
    expect(find.text('暂无 RSS 源'), findsOneWidget);
    // 空态额外的"导入 RSS 源"按钮
    expect(find.text('导入 RSS 源'), findsOneWidget);
  });

  testWidgets('RssSourceManagePage renders grouped list',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: RssSourceManagePage(
            dbPathOverride: '/tmp/legado-test.db',
            recordsOverride: const [
              {
                'source_url': 'https://feed.example/atom',
                'source_name': '示例 RSS',
                'source_group': '科技',
                'enabled': true,
              },
              {
                'source_url': 'https://feed2.example/rss',
                'source_name': 'RSS 2',
                'source_group': '科技',
                'enabled': false,
              },
              {
                'source_url': 'https://feed3.example/rss',
                'source_name': 'RSS 3',
                'source_group': null,
                'enabled': true,
              },
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 分组 section 名 + 计数
    expect(find.text('科技 (2)'), findsOneWidget);
    expect(find.text('未分组 (1)'), findsOneWidget);
    // 三条 ListTile
    expect(find.text('示例 RSS'), findsOneWidget);
    expect(find.text('RSS 2'), findsOneWidget);
    expect(find.text('RSS 3'), findsOneWidget);
    // url subtitle
    expect(find.text('https://feed.example/atom'), findsOneWidget);
    // Switch 数量 = 3
    expect(find.byType(Switch), findsNWidgets(3));
  });

  testWidgets('toggling Switch calls setEnabledOverride exactly once',
      (WidgetTester tester) async {
    int calls = 0;
    String? lastUrl;
    bool? lastEnabled;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: RssSourceManagePage(
            dbPathOverride: '/tmp/legado-test.db',
            recordsOverride: const [
              {
                'source_url': 'https://feed.example/atom',
                'source_name': '示例 RSS',
                'source_group': '科技',
                'enabled': true,
              },
            ],
            setEnabledOverride: (db, url, enabled) async {
              calls++;
              lastUrl = url;
              lastEnabled = enabled;
              return 1;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Switch), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(calls, 1, reason: '一次切换应只触发一次 mock');
    expect(lastUrl, 'https://feed.example/atom');
    expect(lastEnabled, false, reason: '从 true 切到 false');
  });
}
