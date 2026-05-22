import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/features/bookshelf/bookshelf_page.dart';
import 'package:legado_flutter/core/providers.dart';

/// BATCH-27a (05-22): bookshelf 顶部 PopupMenu 13 项对齐 + 书架布局
/// 对话框 + 导出书架 JSON 测试。
///
/// 13 项严格按原 legado `main_bookshelf.xml` 顺序（搜索单独 IconButton
/// 不进 menu）。6 项灰显占位（更新目录 / 添加远程书 / 添加网络URL /
/// 书架管理 / 导入书架 / 日志）走 enabled: false + 不写 onTap，对齐
/// BATCH-26b 决策。layout 对话框走 BATCH-19a 同款 SimpleDialog +
/// ListTile + check trailing 模式。
///
/// 测试钩子：
/// - `exportBookshelfJsonOverride` 注入假 FRB，避开 RustLib.instance
/// - `exportDocumentsDirectoryOverride` 注入假目录，避开 path_provider
/// - `dbPathOverride` 已在 batch-13 sketch；本批沿用
void main() {
  Widget buildPage({
    required Future<String> Function({required String dbPath})? exportFn,
    String? docsDir,
  }) {
    return ProviderScope(
      overrides: [
        bookGroupsProvider.overrideWith((ref) async => const []),
        booksByGroupProvider.overrideWith(
          (ref, key) => Future.value(const <Map<String, dynamic>>[]),
        ),
      ],
      child: MaterialApp(
        home: BookshelfPage(
          dbPathOverride: '/fake/db.sqlite',
          documentsDirOverride: '/fake/docs',
          exportBookshelfJsonOverride: exportFn,
          exportDocumentsDirectoryOverride: docsDir,
        ),
      ),
    );
  }

  /// 1. PopupMenu 13 项，按原版顺序展示：12 原版项 + flutter 自加「扫码导入」
  /// 插在添加本地书 / 添加远程书之间。搜索仍是 AppBar IconButton（不进 menu）。
  testWidgets('BATCH-27a: PopupMenu 13 items in original order',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildPage(exportFn: null));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();

    // 期望按出现顺序：1 是搜索（IconButton 不在 menu）；menu 中 12 项
    const expectedOrder = <String>[
      '更新目录',
      '添加本地书',
      '添加远程书',
      '添加网络URL',
      '扫码导入',
      '书架管理',
      '缓存/导出',
      '分组管理',
      '书架布局',
      '导出书架',
      '导入书架',
      '日志',
    ];

    // 找到所有 PopupMenuItem 中的 ListTile title Text
    final items = find
        .descendant(
          of: find.byType(PopupMenuItem<String>),
          matching: find.byType(Text),
        )
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .whereType<String>()
        .toList();

    expect(items.length, expectedOrder.length,
        reason: 'PopupMenu 应有 12 项（搜索是 IconButton 不进 menu）');
    for (var i = 0; i < expectedOrder.length; i++) {
      expect(items[i], expectedOrder[i],
          reason: '第 $i 项应为「${expectedOrder[i]}」实际「${items[i]}」');
    }
  });

  /// 2. 灰显占位 enabled: false。
  /// BATCH-27b: update_toc 从灰显改可点 → 灰显 6 → 5。enabled 项 6 → 7。
  /// BATCH-27c: add_remote 从灰显改可点 → 灰显 5 → 4。enabled 项 7 → 8。
  testWidgets('BATCH-27a: disabled placeholder items have enabled=false',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildPage(exportFn: null));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();

    // 期望灰显的 1 项 value（27b 后 update_toc / 27c 后 add_remote /
    // 27d 后 bookshelf_manage / 27e 后 add_url + import_bookshelf 已改可点）
    const disabledValues = <String>[
      'log',
    ];

    for (final v in disabledValues) {
      final widget = tester.widget<PopupMenuItem<String>>(
        find.byWidgetPredicate(
          (w) => w is PopupMenuItem<String> && w.value == v,
        ),
      );
      expect(widget.enabled, isFalse, reason: '$v 应 enabled: false');
    }

    // 期望 enabled 的项也校验对应（对照组），27b 加 update_toc / 27c 加
    // add_remote / 27d 加 bookshelf_manage / 27e 加 add_url + import_bookshelf
    const enabledValues = <String>[
      'update_toc',
      'import_local',
      'add_remote',
      'qr_scan',
      'bookshelf_manage',
      'add_url',
      'import_bookshelf',
      'cache_export',
      'manage_groups',
      'bookshelf_layout',
      'export_bookshelf',
    ];
    for (final v in enabledValues) {
      final widget = tester.widget<PopupMenuItem<String>>(
        find.byWidgetPredicate(
          (w) => w is PopupMenuItem<String> && w.value == v,
        ),
      );
      expect(widget.enabled, isTrue, reason: '$v 应 enabled: true');
    }
  });

  /// 3. 书架布局 SimpleDialog 默认 list 状态：列表项有 check，网格项没。
  testWidgets('BATCH-27a: layout dialog defaults to list with check',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildPage(exportFn: null));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('书架布局'));
    await tester.pumpAndSettle();

    // SimpleDialog 出现
    expect(find.byType(SimpleDialog), findsOneWidget);
    expect(find.text('列表'), findsOneWidget);
    expect(find.text('网格'), findsOneWidget);

    // 默认 _isGridView=false → 列表项 trailing 应有 Icon.check
    final listTile = tester.widget<ListTile>(
      find.ancestor(
        of: find.text('列表'),
        matching: find.byType(ListTile),
      ),
    );
    expect(listTile.trailing, isA<Icon>());
    final listIcon = listTile.trailing as Icon;
    expect(listIcon.icon, Icons.check);

    // 网格项 trailing 应为 null
    final gridTile = tester.widget<ListTile>(
      find.ancestor(
        of: find.text('网格'),
        matching: find.byType(ListTile),
      ),
    );
    expect(gridTile.trailing, isNull);
  });

  /// 4. 切到网格后，对话框关闭 + _isGridView 翻转，AppBar IconButton
  /// 改为 Icons.view_list（list / grid 切换 IconButton 与 _isGridView 同源）。
  testWidgets('BATCH-27a: layout dialog selecting grid flips _isGridView',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildPage(exportFn: null));
    await tester.pumpAndSettle();

    // 默认 list 视图：AppBar IconButton 应是 Icons.grid_view（提示「网格」）
    expect(find.byIcon(Icons.grid_view), findsOneWidget);

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('书架布局'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('网格'));
    await tester.pumpAndSettle();

    // SimpleDialog 关闭
    expect(find.byType(SimpleDialog), findsNothing);

    // AppBar IconButton 切到 Icons.view_list（网格视图状态）
    expect(find.byIcon(Icons.view_list), findsOneWidget);
    expect(find.byIcon(Icons.grid_view), findsNothing);
  });

  /// 5. 选当前已选项不重新设状态：仍在 list 视图。
  testWidgets('BATCH-27a: layout dialog selecting current value is no-op',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildPage(exportFn: null));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.grid_view), findsOneWidget);

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('书架布局'));
    await tester.pumpAndSettle();

    // 选当前已选 list（_isGridView=false）
    await tester.tap(find.text('列表'));
    await tester.pumpAndSettle();

    expect(find.byType(SimpleDialog), findsNothing);
    // 仍是 list 视图 → IconButton 还是 Icons.grid_view
    expect(find.byIcon(Icons.grid_view), findsOneWidget);
  });

  /// 6. 导出书架 — 空书架（FRB 返回 `"[]"`）→ SnackBar「书架为空」+ 不写文件
  testWidgets('BATCH-27a: export empty bookshelf shows 书架为空 SnackBar',
      (WidgetTester tester) async {
    var calls = 0;

    // 用 createTempSync 拿唯一目录（避免 hardcoded /tmp 路径并发跑冲突 +
    // 跨平台写权限差异）；空 path 早返回时本目录应保持空，addTearDown
    // 兜底清理。
    final dir = Directory.systemTemp
        .createTempSync('legado_flutter_test_export_empty_27a_');
    final docsDir = dir.path;
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    await tester.pumpWidget(buildPage(
      docsDir: docsDir,
      exportFn: ({required String dbPath}) async {
        calls++;
        return '[]';
      },
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('导出书架'));
    // SnackBar 默认 4s 自动 dismiss timer 会让 pumpAndSettle 一直等；
    // 改为 pump 几帧让 microtask + 一帧 build 跑完即可校验 SnackBar。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(calls, 1);
    expect(find.text('书架为空'), findsOneWidget);
    expect(File('$docsDir/books.json').existsSync(), isFalse);
  });

  /// 7. 导出书架 — 有书时把 JSON 写到 docs_dir/books.json + SnackBar 含路径
  testWidgets('BATCH-27a: export with books writes file + SnackBar shows path',
      (WidgetTester tester) async {
    // `Directory.systemTemp.createTemp(...)`（async 版）在 widget test 里
    // 会让 `pumpAndSettle()` 卡住（疑似 zone-microtask 与 widget tester
    // FakeAsync 冲突）。改用同步版 `createTempSync(...)`：跑的是 syscall
    // 不进 zone-microtask 链路，且每次拿到唯一目录，避免并发跑测试时
    // hardcoded 路径冲突 / `/tmp` 跨平台写权限差异。
    final dir =
        Directory.systemTemp.createTempSync('legado_flutter_test_export_27a_');
    final docsDir = dir.path;
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    const fakeJson = '''[
  {
    "name": "三国演义",
    "author": "罗贯中",
    "intro": "乱世枭雄"
  }
]''';
    await tester.pumpWidget(buildPage(
      docsDir: docsDir,
      exportFn: ({required String dbPath}) async => fakeJson,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('导出书架'));
    // _onExportBookshelf 在 fake-async zone 跑，需要 pump 把 microtask 推
    // 完；但 file.writeAsString 是真 disk I/O 必须 runAsync 让 wall-clock
    // 走起来。所以两手都来：先 pump 推 microtask 让 await 链推进到
    // writeAsString，然后 runAsync 等 disk 写完，最后再 pump 让 SnackBar
    // build。pumpAndSettle 会被 SnackBar 4s 默认 dismiss timer 卡住，不用。
    final expectedPath = '$docsDir/books.json';
    final file = File(expectedPath);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
    }
    await tester.pump(const Duration(milliseconds: 50));

    expect(file.existsSync(), isTrue,
        reason: 'export 应在 $expectedPath 写入文件');
    expect(file.readAsStringSync(), fakeJson);
    expect(find.text('已导出到 $expectedPath'), findsOneWidget);
  });

  /// 8. 导出失败 → catch + SnackBar「导出失败: ...」。FRB 抛异常被 try
  /// 捕获，SnackBar 不向上抛打断书架页。
  testWidgets('BATCH-27a: export failure shows error SnackBar',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildPage(
      exportFn: ({required String dbPath}) async {
        throw Exception('mock FRB error');
      },
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('导出书架'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 文案以「导出失败:」开头
    expect(
      find.byWidgetPredicate(
        (w) => w is Text && (w.data ?? '').startsWith('导出失败:'),
      ),
      findsOneWidget,
    );
  });
}
