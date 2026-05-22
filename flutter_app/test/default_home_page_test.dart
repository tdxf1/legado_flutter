/// BATCH-26d: 启动默认页（defaultHomePage）测试。
///
/// 对齐原 legado `pref_config_other.xml` defaultHomePage NameListPreference
/// + `MainActivity.kt:385-398` upHomePage()。覆盖：
///
/// 1. enum key round-trip — 4 个 enum 值 `.key` ⇄ `fromKey` 等价
/// 2. fromKey unknown / 空串 → bookshelf 兜底
/// 3. applyDefaultHomePage 行为表 — 4 enum × showDiscovery/showRss 组合
///    8 个核心 case，验跳转/不跳契约
/// 4. SettingsPage UI — 「主页」分组下「启动默认页」ListTile + 4 选对话框
/// 5. 选「发现」→ provider state == DefaultHomePage.explore + SnackBar 提示
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:legado_flutter/core/providers.dart';
import 'package:legado_flutter/features/settings/settings_page.dart';

/// Tmp path_provider 实现（与 search_precision_test 同款），让 SettingsPage
/// 内部不传 directory 调 saveDefaultHomePageToDisk 时不撞 MissingPlugin /
/// 真平台 IO（widget test 无真实 channel 实现）。
class _TmpPathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _TmpPathProvider(this.tmpDir);
  final String tmpDir;

  @override
  Future<String?> getApplicationDocumentsPath() async => tmpDir;

  @override
  Future<String?> getApplicationSupportPath() async => tmpDir;

  @override
  Future<String?> getTemporaryPath() async => tmpDir;

  @override
  Future<String?> getApplicationCachePath() async => tmpDir;

  @override
  Future<String?> getDownloadsPath() async => tmpDir;

  @override
  Future<String?> getLibraryPath() async => tmpDir;

  @override
  Future<String?> getExternalStoragePath() async => tmpDir;
}

/// 自建一个最小 router：4 ShellBranch 各自挂一个 stub page，让
/// [applyDefaultHomePage] 能在测试里安全 `router.go(...)`，避免引用
/// 真实 router（依赖 reader / source / FRB）。
GoRouter _buildRouter({String initialLocation = '/bookshelf'}) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(
        path: '/bookshelf',
        builder: (_, __) => const Scaffold(body: Text('BOOKSHELF_STUB')),
      ),
      GoRoute(
        path: '/explore',
        builder: (_, __) => const Scaffold(body: Text('EXPLORE_STUB')),
      ),
      GoRoute(
        path: '/rss',
        builder: (_, __) => const Scaffold(body: Text('RSS_STUB')),
      ),
      GoRoute(
        path: '/my',
        builder: (_, __) => const Scaffold(body: Text('MY_STUB')),
      ),
    ],
  );
}

String _topMatchLocation(GoRouter router) {
  final matches = router.routerDelegate.currentConfiguration.matches;
  return matches.last.matchedLocation;
}

void main() {
  // 全局 tmp path_provider：共享同一 tmpDir，避免每个 test 各自创建
  // （json_store 的 _writeLock 是 module-level，跨 test 串行化）。每个
  // setUp / tearDown 在 dir 上 ensure / clean。
  late Directory tmpDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmpDir =
        await Directory.systemTemp.createTemp('default_home_page_test_');
    PathProviderPlatform.instance = _TmpPathProvider(tmpDir.path);

    // settings_page 内部 _checkNotificationPermission 会调
    // NotificationService 走 platform channel；mock 掉避免抛 MissingPlugin。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('legado/notifications'),
      (MethodCall call) async {
        if (call.method == 'hasPermission') return false;
        return null;
      },
    );
  });

  tearDown(() async {
    if (tmpDir.existsSync()) {
      await tmpDir.delete(recursive: true);
    }
  });

  // disk persistence 组放在最前：测试里调 [SettingsPage] 的对话框会触发
  // fire-and-forget [saveDefaultHomePageToDisk]，写盘 Future 在 testWidgets
  // 的 fake-async zone 里挂着不会自然完成，会污染 module-level
  // [_writeLock] 拖死后续 plain `test()` 的 disk IO。把 disk 测试放在
  // settings UI 之前能避免这个跨测试串扰。
  group('BATCH-26d: disk persistence round-trip', () {
    test('save + load 4 个 enum 值', () async {
      final tempDir =
          Directory.systemTemp.createTempSync('default_home_page_rt_').path;
      try {
        for (final v in DefaultHomePage.values) {
          await saveDefaultHomePageToDisk(v, directory: tempDir);
          final loaded = await loadDefaultHomePageFromDisk(directory: tempDir);
          expect(loaded, v, reason: '$v round-trip 应该等价');
        }
      } finally {
        Directory(tempDir).deleteSync(recursive: true);
      }
    });

    test('load 不存在 → bookshelf 兜底', () async {
      final tempDir = Directory.systemTemp
          .createTempSync('default_home_page_rt_empty_')
          .path;
      try {
        final loaded = await loadDefaultHomePageFromDisk(directory: tempDir);
        expect(loaded, DefaultHomePage.bookshelf);
      } finally {
        Directory(tempDir).deleteSync(recursive: true);
      }
    });
  });

  group('BATCH-26d: enum key 与 fromKey', () {
    test('enum key round-trip — 4 个值都能 fromKey 还原', () {
      for (final v in DefaultHomePage.values) {
        expect(DefaultHomePageX.fromKey(v.key), v,
            reason: 'fromKey(${v.key}) 应回到 $v');
      }
      // 同时校验 4 个具体字面量，避免后续 refactor 漏改时静默通过
      expect(DefaultHomePageX.fromKey('bookshelf'), DefaultHomePage.bookshelf);
      expect(DefaultHomePageX.fromKey('explore'), DefaultHomePage.explore);
      expect(DefaultHomePageX.fromKey('rss'), DefaultHomePage.rss);
      expect(DefaultHomePageX.fromKey('my'), DefaultHomePage.my);
    });

    test('fromKey unknown / 空串 → bookshelf 兜底', () {
      expect(DefaultHomePageX.fromKey('garbage'), DefaultHomePage.bookshelf);
      expect(DefaultHomePageX.fromKey(''), DefaultHomePage.bookshelf);
      expect(DefaultHomePageX.fromKey('Bookshelf'), DefaultHomePage.bookshelf,
          reason: 'key 是 case-sensitive，大小写不匹配也 fallback');
      expect(DefaultHomePageX.fromKey('BOOKSHELF'), DefaultHomePage.bookshelf);
    });

    test('label / routePath 对齐原 legado arrays.xml + 26a 路径', () {
      expect(DefaultHomePage.bookshelf.label, '书架');
      expect(DefaultHomePage.explore.label, '发现');
      expect(DefaultHomePage.rss.label, '订阅');
      expect(DefaultHomePage.my.label, '我的');

      expect(DefaultHomePage.bookshelf.routePath, '/bookshelf');
      expect(DefaultHomePage.explore.routePath, '/explore');
      expect(DefaultHomePage.rss.routePath, '/rss');
      expect(DefaultHomePage.my.routePath, '/my');
    });
  });

  group('BATCH-26d: applyDefaultHomePage 行为表', () {
    testWidgets('bookshelf → 永远不跳（4 个 toggle 状态都不动 location）',
        (tester) async {
      // 用 MaterialApp.router 触发 GoRouter 初始化，否则 currentConfiguration
      // 在 build 前为空。
      final router = _buildRouter();
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      for (final showD in [true, false]) {
        for (final showR in [true, false]) {
          applyDefaultHomePage(
            router,
            DefaultHomePage.bookshelf,
            showDiscovery: showD,
            showRss: showR,
          );
          await tester.pumpAndSettle();
          expect(_topMatchLocation(router), '/bookshelf',
              reason: 'bookshelf showD=$showD showR=$showR 不应跳转');
        }
      }
    });

    testWidgets('explore + showDiscovery=true → 跳 /explore', (tester) async {
      final router = _buildRouter();
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      applyDefaultHomePage(
        router,
        DefaultHomePage.explore,
        showDiscovery: true,
        showRss: true,
      );
      await tester.pumpAndSettle();
      expect(_topMatchLocation(router), '/explore');
    });

    testWidgets('explore + showDiscovery=false → 保留 /bookshelf 不跳',
        (tester) async {
      final router = _buildRouter();
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      applyDefaultHomePage(
        router,
        DefaultHomePage.explore,
        showDiscovery: false,
        showRss: true, // showRss 不影响
      );
      await tester.pumpAndSettle();
      expect(_topMatchLocation(router), '/bookshelf',
          reason: '原版 upHomePage 在 toggle 关闭时保留 bookshelf 兜底');
    });

    testWidgets('rss + showRss=true → 跳 /rss', (tester) async {
      final router = _buildRouter();
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      applyDefaultHomePage(
        router,
        DefaultHomePage.rss,
        showDiscovery: true,
        showRss: true,
      );
      await tester.pumpAndSettle();
      expect(_topMatchLocation(router), '/rss');
    });

    testWidgets('rss + showRss=false → 保留 /bookshelf 不跳', (tester) async {
      final router = _buildRouter();
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      applyDefaultHomePage(
        router,
        DefaultHomePage.rss,
        showDiscovery: true,
        showRss: false,
      );
      await tester.pumpAndSettle();
      expect(_topMatchLocation(router), '/bookshelf',
          reason: '原版 upHomePage 在 toggle 关闭时保留 bookshelf 兜底');
    });

    testWidgets('my → 永远跳（不论 toggle 状态）', (tester) async {
      for (final showD in [true, false]) {
        for (final showR in [true, false]) {
          final router = _buildRouter();
          await tester.pumpWidget(MaterialApp.router(routerConfig: router));
          await tester.pumpAndSettle();

          applyDefaultHomePage(
            router,
            DefaultHomePage.my,
            showDiscovery: showD,
            showRss: showR,
          );
          await tester.pumpAndSettle();
          expect(_topMatchLocation(router), '/my',
              reason: 'my tab 永久可见 showD=$showD showR=$showR 都应跳');
        }
      }
    });
  });

  group('BATCH-26d: SettingsPage UI', () {
    testWidgets('「主页」分组含「启动默认页」ListTile + 默认 subtitle = 书架',
        (tester) async {
      // 800x2400 viewport 让全部 item 一帧构建（与 settings_page_test
      // 同模式）。
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: SettingsPage()),
        ),
      );
      await tester.pumpAndSettle();

      // ListTile 标题可见
      expect(find.text('启动默认页'), findsOneWidget);
      // 默认 subtitle = 书架（DefaultHomePage.bookshelf.label）
      expect(find.text('书架'), findsOneWidget);
    });

    testWidgets('点击「启动默认页」弹 4 选对话框', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: SettingsPage()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('启动默认页'));
      await tester.pumpAndSettle();

      // 对话框 title
      expect(find.text('启动默认页'), findsAtLeastNWidgets(1));
      // 4 个选项
      expect(find.text('书架'), findsAtLeastNWidgets(1));
      expect(find.text('发现'), findsOneWidget);
      expect(find.text('订阅'), findsOneWidget);
      expect(find.text('我的'), findsOneWidget);
      // 默认值是 bookshelf，对应 ListTile 应有 check 图标
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('选「发现」→ provider state == explore + SnackBar 提示',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: SettingsPage()),
        ),
      );
      await tester.pumpAndSettle();

      // 初始 provider state
      expect(container.read(defaultHomePageProvider),
          DefaultHomePage.bookshelf);

      // 打开对话框
      await tester.tap(find.text('启动默认页'));
      await tester.pumpAndSettle();

      // 点击「发现」选项 — 这一步会触发 fire-and-forget
      // saveDefaultHomePageToDisk 写盘。
      await tester.tap(find.text('发现'));
      await tester.pumpAndSettle();

      // provider state 切换
      expect(container.read(defaultHomePageProvider),
          DefaultHomePage.explore);
      // SnackBar 文案
      expect(find.text('已设为「发现」(下次启动生效)'), findsOneWidget);
    });

    testWidgets('选当前值不变 → state 不动 + 不弹 SnackBar', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: SettingsPage()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('启动默认页'));
      await tester.pumpAndSettle();

      // 默认是 bookshelf；选「书架」（同当前值）
      // 对话框里「书架」是 ListTile title，AppBar / subtitle 也都是「书架」
      // 文案；用 last 元素（对话框是最后 push 进 widget tree 的）。
      await tester.tap(find.text('书架').last);
      await tester.pumpAndSettle();

      expect(container.read(defaultHomePageProvider),
          DefaultHomePage.bookshelf);
      expect(find.text('已设为「书架」(下次启动生效)'), findsNothing,
          reason: '同当前值时不应弹 SnackBar');
    });
  });
}
