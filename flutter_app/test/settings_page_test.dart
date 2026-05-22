import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/features/settings/settings_page.dart';

/// BATCH-18f (F-W2B-016)：验证 settings_page "工具"段含 6 项 ListTile。
///
/// 5 项原本在 bookshelf AppBar PopupMenu 重组到此（备份/恢复 / 阅读统计 /
/// 缓存管理 / RSS 收藏 / 订阅源），与既有的 replace_rules 共置。本 test
/// 仅断言 ListTile 存在 — 不测 onTap 触发 GoRouter 跳转，那需要更大的
/// router setup（每条路由的目标 page 已在各自 page test 里覆盖）。
void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('legado/notifications'),
      (MethodCall call) async {
        if (call.method == 'hasPermission') return false;
        return null;
      },
    );
  });

  testWidgets('SettingsPage 工具段含 6 项 ListTile', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();

    // 工具段 ListTile 可能在 viewport 外（页面 ListView 较长）— 用
    // ensureVisible 滚到位再断言。
    final scrollable = find.byType(Scrollable).first;

    Future<void> ensureVisible(String label) async {
      await tester.scrollUntilVisible(
        find.text(label),
        100,
        scrollable: scrollable,
      );
    }

    // BATCH-18f 重组后的 5 项
    await ensureVisible('备份/恢复');
    expect(find.text('备份/恢复'), findsOneWidget);

    await ensureVisible('阅读统计');
    expect(find.text('阅读统计'), findsOneWidget);

    await ensureVisible('缓存管理');
    expect(find.text('缓存管理'), findsOneWidget);

    await ensureVisible('RSS 收藏');
    expect(find.text('RSS 收藏'), findsOneWidget);

    await ensureVisible('订阅源');
    expect(find.text('订阅源'), findsOneWidget);

    // 既有的 replace_rules
    await ensureVisible('替换规则');
    expect(find.text('替换规则'), findsOneWidget);
  });

  testWidgets('SettingsPage 工具段 6 项 ListTile 都有 chevron_right',
      (tester) async {
    // BATCH-26c (05-22): 加完「主页」段（2 SwitchListTile + Section
    // header）后默认 800x600 viewport 装不下 chevron_right 段。改用
    // 大尺寸 viewport 让全部 item 一次构建（与 my_hub_page_test
    // 同模式）。
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();

    // 工具段 6 个 ListTile 应都有 trailing chevron_right；通知 / 主题
    // RadioListTile / 关于 段 / 主页 SwitchListTile 不带 chevron_right。
    expect(find.byIcon(Icons.chevron_right), findsAtLeastNWidgets(6));
  });
}
