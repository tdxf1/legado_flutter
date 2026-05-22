/// BATCH-26c: 底栏「发现」/「订阅」tab 显隐 toggle 集成测试。
///
/// 对齐原 legado `pref_config_other.xml` showDiscovery / showRss
/// SwitchPreference + `MainActivity.kt:364-381` upBottomMenu 行为：
/// toggle 关闭后底栏对应 NavigationDestination 不显示，但路由仍可直接
/// URL 访问（不删 ShellBranch，不破坏 26a 路由结构）。
///
/// 不复用 lib/core/router.dart 的全局 router —— 全局 router 引用了
/// reader_page / source_page 等真实 page，构造时会触发 Provider /
/// FRB 依赖链。这里自建一个最小 router，只保留 4 ShellBranch + 各 stub
/// page，让 _AppShell 的 NavigationBar 可独立验证。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:legado_flutter/core/providers.dart';

/// 最小复刻 lib/core/router.dart `_AppShell` 的核心逻辑：
/// 4 ShellBranch 固定 + NavigationBar destinations 按 toggle 动态生成
/// + view↔branch index 映射 + 关闭被隐藏 branch 时自动 goBranch(0)。
///
/// 与生产 _AppShell 唯一区别：私有类不能跨文件复用，这里改成 public
/// `_TestAppShell`；逻辑一字不差对齐 router.dart。
class _TestAppShell extends ConsumerWidget {
  final StatefulNavigationShell navigationShell;
  const _TestAppShell({required this.navigationShell});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showDiscovery = ref.watch(showDiscoveryProvider);
    final showRss = ref.watch(showRssProvider);

    final visibleBranchIndices = <int>[
      0,
      if (showDiscovery) 1,
      if (showRss) 2,
      3,
    ];

    final viewIndex =
        visibleBranchIndices.indexOf(navigationShell.currentIndex);
    final selectedViewIndex = viewIndex < 0 ? 0 : viewIndex;

    ref.listen<bool>(showDiscoveryProvider, (prev, next) {
      if (!next && navigationShell.currentIndex == 1) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          navigationShell.goBranch(0);
        });
      }
    });
    ref.listen<bool>(showRssProvider, (prev, next) {
      if (!next && navigationShell.currentIndex == 2) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          navigationShell.goBranch(0);
        });
      }
    });

    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedViewIndex,
        onDestinationSelected: (index) {
          final branchIndex = visibleBranchIndices[index];
          navigationShell.goBranch(
            branchIndex,
            initialLocation: branchIndex == navigationShell.currentIndex,
          );
        },
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.library_books_outlined),
            selectedIcon: Icon(Icons.library_books),
            label: '书架',
          ),
          if (showDiscovery)
            const NavigationDestination(
              icon: Icon(Icons.explore_outlined),
              selectedIcon: Icon(Icons.explore),
              label: '发现',
            ),
          if (showRss)
            const NavigationDestination(
              icon: Icon(Icons.rss_feed_outlined),
              selectedIcon: Icon(Icons.rss_feed),
              label: '订阅',
            ),
          const NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: '我的',
          ),
        ],
      ),
    );
  }
}

GoRouter _buildRouter({String initialLocation = '/bookshelf'}) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            _TestAppShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/bookshelf',
              builder: (_, __) =>
                  const Scaffold(body: Text('BOOKSHELF_STUB')),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/explore',
              builder: (_, __) => const Scaffold(body: Text('EXPLORE_STUB')),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/rss',
              builder: (_, __) => const Scaffold(body: Text('RSS_STUB')),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/my',
              builder: (_, __) => const Scaffold(body: Text('MY_STUB')),
            ),
          ]),
        ],
      ),
    ],
  );
}

Widget _wrapApp(
  GoRouter router, {
  bool? showDiscovery,
  bool? showRss,
}) {
  return ProviderScope(
    overrides: [
      if (showDiscovery != null)
        showDiscoveryProvider.overrideWith((ref) => showDiscovery),
      if (showRss != null) showRssProvider.overrideWith((ref) => showRss),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

String _topMatchLocation(GoRouter router) {
  final matches = router.routerDelegate.currentConfiguration.matches;
  return matches.last.matchedLocation;
}

void main() {
  testWidgets('BATCH-26c: default true → 4 destinations', (tester) async {
    final router = _buildRouter();
    await tester.pumpWidget(_wrapApp(router));
    await tester.pumpAndSettle();

    final navBar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(navBar.destinations.length, 4,
        reason: 'default toggle=true → 4 个底栏 destination');
    expect(find.text('书架'), findsOneWidget);
    expect(find.text('发现'), findsOneWidget);
    expect(find.text('订阅'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
  });

  testWidgets('BATCH-26c: showDiscovery=false → 3 destinations 且无「发现」label',
      (tester) async {
    final router = _buildRouter();
    await tester.pumpWidget(_wrapApp(router, showDiscovery: false));
    await tester.pumpAndSettle();

    final navBar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(navBar.destinations.length, 3,
        reason: '关闭 showDiscovery → 底栏只剩 书架/订阅/我的');
    expect(find.text('书架'), findsOneWidget);
    expect(find.text('发现'), findsNothing,
        reason: '「发现」NavigationDestination 不应渲染');
    expect(find.text('订阅'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
  });

  testWidgets('BATCH-26c: showRss=false → 3 destinations 且无「订阅」label',
      (tester) async {
    final router = _buildRouter();
    await tester.pumpWidget(_wrapApp(router, showRss: false));
    await tester.pumpAndSettle();

    final navBar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(navBar.destinations.length, 3,
        reason: '关闭 showRss → 底栏只剩 书架/发现/我的');
    expect(find.text('书架'), findsOneWidget);
    expect(find.text('发现'), findsOneWidget);
    expect(find.text('订阅'), findsNothing,
        reason: '「订阅」NavigationDestination 不应渲染');
    expect(find.text('我的'), findsOneWidget);
  });

  testWidgets('BATCH-26c: 同时关闭 → 2 destinations 仅 书架+我的',
      (tester) async {
    final router = _buildRouter();
    await tester.pumpWidget(
      _wrapApp(router, showDiscovery: false, showRss: false),
    );
    await tester.pumpAndSettle();

    final navBar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(navBar.destinations.length, 2,
        reason: '两个都关 → 底栏只剩 书架/我的');
    expect(find.text('书架'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
    expect(find.text('发现'), findsNothing);
    expect(find.text('订阅'), findsNothing);
  });

  testWidgets(
      'BATCH-26c: 当前在 /explore 时关闭 showDiscovery → 自动跳书架',
      (tester) async {
    // 启动 router 直接落在 /explore（branch index 1）。
    final router = _buildRouter(initialLocation: '/explore');
    // 用 ProviderScope.overrides 让 showDiscovery 一开始 true（让 /explore
    // 正常进入），稍后通过 container 翻转 toggle，触发 ref.listen 路径。
    final container = ProviderContainer(
      overrides: [
        showDiscoveryProvider.overrideWith((ref) => true),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(_topMatchLocation(router), '/explore',
        reason: '初始化时栈顶 match 应是 /explore');

    // 翻转 toggle → ref.listen 排 postFrame goBranch(0)
    container.read(showDiscoveryProvider.notifier).state = false;
    await tester.pumpAndSettle();

    // 应自动切回书架 branch（branch index 0 → /bookshelf）
    expect(_topMatchLocation(router), '/bookshelf',
        reason: '关闭 showDiscovery 后应自动 goBranch(0) 回到书架');

    // NavigationBar 已收缩到 3 destinations
    final navBar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(navBar.destinations.length, 3);
    expect(find.text('发现'), findsNothing);
  });
}
