import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/features/rule_sub/rule_sub_page.dart';

/// 批次 19 (05-19): 订阅源 RuleSub MVP widget 测试。
///
/// 通过 [RuleSubPage] 的 *Override 钩子注入 fake records + delete mock，
/// 绕过 FRB 桥 / path_provider，验证：
/// 1. 空态：无记录时显示 "暂无订阅源" + "添加订阅源" 按钮。
/// 2. 列表渲染：3 条不同 sub_type 的 ListTile（书源 / RSS / 替换规则
///    label + 各自 icon）。
/// 3. PopupMenuButton 数量 = 3（每条一个）。
void main() {
  testWidgets('RuleSubPage shows empty state when records is empty',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: RuleSubPage(
            dbPathOverride: '/tmp/legado-test.db',
            recordsOverride: const [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('订阅源'), findsOneWidget);
    expect(find.text('暂无订阅源'), findsOneWidget);
    // 空态额外的 "添加订阅源" 按钮
    expect(find.text('添加订阅源'), findsOneWidget);
  });

  testWidgets('RuleSubPage renders three sub_type rows',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: RuleSubPage(
            dbPathOverride: '/tmp/legado-test.db',
            recordsOverride: const [
              {
                'id': 'rs-0',
                'name': '书源订阅',
                'url': 'https://example.com/booksources.json',
                'sub_type': 0,
                'custom_order': 0,
                'created_at': 0,
                'updated_at': 0,
              },
              {
                'id': 'rs-1',
                'name': 'RSS 订阅',
                'url': 'https://example.com/rsssources.json',
                'sub_type': 1,
                'custom_order': 0,
                'created_at': 0,
                'updated_at': 0,
              },
              {
                'id': 'rs-2',
                'name': '替换订阅',
                'url': 'https://example.com/replace.json',
                'sub_type': 2,
                'custom_order': 0,
                'created_at': 0,
                'updated_at': 0,
              },
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 三个名字都渲染
    expect(find.text('书源订阅'), findsOneWidget);
    expect(find.text('RSS 订阅'), findsOneWidget);
    expect(find.text('替换订阅'), findsOneWidget);
    // subtitle 包含 url + " · " + sub_type 标签
    expect(
      find.text('https://example.com/booksources.json · 书源'),
      findsOneWidget,
    );
    expect(
      find.text('https://example.com/rsssources.json · RSS'),
      findsOneWidget,
    );
    expect(
      find.text('https://example.com/replace.json · 替换规则'),
      findsOneWidget,
    );
    // 每条一个 PopupMenuButton（操作菜单）
    expect(find.byType(PopupMenuButton<String>), findsNWidgets(3));
    // 三种 leading icon 各 1 次
    expect(find.byIcon(Icons.source), findsOneWidget);
    expect(find.byIcon(Icons.rss_feed), findsOneWidget);
    expect(find.byIcon(Icons.find_replace), findsOneWidget);
  });

  testWidgets('Tapping delete in popup triggers deleteOverride',
      (WidgetTester tester) async {
    int calls = 0;
    String? lastId;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: RuleSubPage(
            dbPathOverride: '/tmp/legado-test.db',
            recordsOverride: const [
              {
                'id': 'rs-x',
                'name': '示例订阅',
                'url': 'https://example.com/sub.json',
                'sub_type': 0,
                'custom_order': 0,
                'created_at': 0,
                'updated_at': 0,
              },
            ],
            deleteOverride: (db, id) async {
              calls++;
              lastId = id;
              return 1;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 打开 PopupMenu
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    // 点 "删除"
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    // 确认对话框
    await tester.tap(find.text('确定删除'));
    await tester.pumpAndSettle();
    expect(calls, 1, reason: '一次删除应只触发一次 mock');
    expect(lastId, 'rs-x');
  });
}
