import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:legado_flutter/features/my/my_hub_page.dart';

/// BATCH-26b: /my hub 14 项 + 3 分组验收测试。
///
/// pump 一个最小 GoRouter（initialLocation `/my`），把 5 个目标 path
/// stub 成空 Scaffold（避免触发真实 page 的 Provider / FRB 依赖）。验：
/// - 14 项 ListTile 标题全部可见 + 「设置」/「其它」两个 section header
/// - 灰显项 `enabled: false`（TXT 目录规则 / 字典规则 / 主题模式 /
///   主题设置 / 书签 / 文件管理 / 关于 / 退出 = 8 项）+ Web 服务 (1)
///   `SwitchListTile.onChanged == null`
/// - 已实现项点击跳路由：smoke test「书源管理 → /sources」+
///   补充验「替换净化 → /replace-rules」「阅读记录 → /read-stats」。
///   注：`context.push` 触发的 imperative 跳转不更新 `routerDelegate
///   .currentConfiguration.uri`（go_router 14 行为：uri 不含
///   ImperativeRouteMatch），所以路由验证用 stub 页文本可见性 +
///   `matches.last.matchedLocation` 双保险。
///
/// 不测每项 onTap（PRD 控制范围 3-5 个新测试），剩余 onTap 走静态 grep
/// 检查。
void main() {
  GoRouter buildRouter() {
    return GoRouter(
      initialLocation: '/my',
      routes: [
        GoRoute(
          path: '/my',
          builder: (context, state) => const MyHubPage(),
        ),
        GoRoute(
          path: '/sources',
          builder: (context, state) =>
              const Scaffold(body: Text('SOURCES_STUB')),
        ),
        GoRoute(
          path: '/replace-rules',
          builder: (context, state) =>
              const Scaffold(body: Text('REPLACE_RULES_STUB')),
        ),
        GoRoute(
          path: '/backup',
          builder: (context, state) =>
              const Scaffold(body: Text('BACKUP_STUB')),
        ),
        GoRoute(
          path: '/settings',
          builder: (context, state) =>
              const Scaffold(body: Text('SETTINGS_STUB')),
        ),
        GoRoute(
          path: '/read-stats',
          builder: (context, state) =>
              const Scaffold(body: Text('READ_STATS_STUB')),
        ),
      ],
    );
  }

  /// 验 GoRouter 当前栈顶 match 的 location，兼容 imperative push（不能用
  /// `currentConfiguration.uri.path`，那个永远只反映 base 路径）。
  String topMatchLocation(GoRouter router) {
    final matches = router.routerDelegate.currentConfiguration.matches;
    return matches.last.matchedLocation;
  }

  testWidgets('BATCH-26b: hub 显示 14 项 + 3 分组结构', (tester) async {
    final router = buildRouter();
    await tester.pumpWidget(
      MaterialApp.router(routerConfig: router),
    );
    await tester.pumpAndSettle();

    // hub ListView 默认 800x600 viewport 装不下全部 14 项，逐项
    // scrollUntilVisible 后断言可见（与 settings_page_test 同模式）。
    final scrollable = find.byType(Scrollable).first;
    Future<void> ensureVisible(String label) async {
      await tester.scrollUntilVisible(
        find.text(label),
        100,
        scrollable: scrollable,
      );
    }

    // 第一组 6 项（无 header）
    await ensureVisible('书源管理');
    await ensureVisible('TXT 目录规则');
    await ensureVisible('替换净化');
    await ensureVisible('字典规则');
    await ensureVisible('主题模式');
    await ensureVisible('Web 服务');

    // 「设置」分组 header + 3 项
    await ensureVisible('设置');
    await ensureVisible('备份与恢复');
    await ensureVisible('主题设置');
    await ensureVisible('其他设置');

    // 「其它」分组 header + 5 项
    await ensureVisible('其它');
    await ensureVisible('书签');
    await ensureVisible('阅读记录');
    await ensureVisible('文件管理');
    await ensureVisible('关于');
    await ensureVisible('退出');
  });

  testWidgets('BATCH-26b: 灰显项 enabled false / SwitchListTile onChanged null',
      (tester) async {
    // 14 项 ListTile 在默认 800x600 viewport 装不下，scrollUntilVisible
    // 仅单向滚动 → 改用大尺寸 viewport 让全部 item 一次构建。
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final router = buildRouter();
    await tester.pumpWidget(
      MaterialApp.router(routerConfig: router),
    );
    await tester.pumpAndSettle();

    // 验 8 个灰显 ListTile 的 enabled == false
    final grayTitles = [
      'TXT 目录规则',
      '字典规则',
      '主题模式',
      '主题设置',
      '书签',
      '文件管理',
      '关于',
      '退出',
    ];
    for (final t in grayTitles) {
      final tileFinder = find.ancestor(
        of: find.text(t),
        matching: find.byType(ListTile),
      );
      expect(tileFinder, findsOneWidget,
          reason: '灰显项 "$t" 对应 ListTile 应能找到');
      final tile = tester.widget<ListTile>(tileFinder);
      expect(tile.enabled, false, reason: '"$t" 应 enabled: false');
    }

    // Web 服务 = SwitchListTile，onChanged == null（disabled）
    final switchFinder = find.byType(SwitchListTile);
    expect(switchFinder, findsOneWidget);
    final sw = tester.widget<SwitchListTile>(switchFinder);
    expect(sw.value, false);
    expect(sw.onChanged, isNull);
  });

  testWidgets('BATCH-26b: 已实现项 onTap - 书源管理 → /sources', (tester) async {
    final router = buildRouter();
    await tester.pumpWidget(
      MaterialApp.router(routerConfig: router),
    );
    await tester.pumpAndSettle();

    expect(topMatchLocation(router), '/my');

    final tileFinder = find.widgetWithText(ListTile, '书源管理');
    expect(tileFinder, findsOneWidget);
    await tester.tap(tileFinder);
    await tester.pumpAndSettle();

    expect(topMatchLocation(router), '/sources');
    expect(find.text('SOURCES_STUB'), findsOneWidget);
  });

  testWidgets('BATCH-26b: 已实现项 onTap - 替换净化 → /replace-rules',
      (tester) async {
    final router = buildRouter();
    await tester.pumpWidget(
      MaterialApp.router(routerConfig: router),
    );
    await tester.pumpAndSettle();

    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('替换净化'),
      100,
      scrollable: scrollable,
    );
    await tester.tap(find.widgetWithText(ListTile, '替换净化'));
    await tester.pumpAndSettle();

    expect(topMatchLocation(router), '/replace-rules');
    expect(find.text('REPLACE_RULES_STUB'), findsOneWidget);
  });

  testWidgets('BATCH-26b: 已实现项 onTap - 阅读记录 → /read-stats', (tester) async {
    final router = buildRouter();
    await tester.pumpWidget(
      MaterialApp.router(routerConfig: router),
    );
    await tester.pumpAndSettle();

    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('阅读记录'),
      100,
      scrollable: scrollable,
    );
    await tester.tap(find.widgetWithText(ListTile, '阅读记录'));
    await tester.pumpAndSettle();

    expect(topMatchLocation(router), '/read-stats');
    expect(find.text('READ_STATS_STUB'), findsOneWidget);
  });
}
