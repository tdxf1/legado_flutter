import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:legado_flutter/core/providers.dart';
import 'package:legado_flutter/features/bookshelf/bookshelf_manage_page.dart';

/// BATCH-27d (05-22): 书架管理批量编辑页测试。
///
/// 8 testWidgets 覆盖：
/// 1. 列表渲染 + 长按进选择模式 + Checkbox leading
/// 2. 全选 → 所有 ids 进 _selectedIds
/// 3. 取消（close）→ 退选择模式
/// 4. 删除 actionbar：confirm dialog → batch delete + 总结 SnackBar
/// 5. 删除 actionbar：取消 confirm → 不删
/// 6. 「允许更新」批量调 setBookCanUpdate
/// 7. 「禁用更新」批量调 setBookCanUpdate(false)
/// 8. 「移到分组」弹 GroupPickerDialog → batch setBookGroup
///
/// 测试目录用 `Directory.systemTemp.createTempSync` 拿唯一路径（对齐
/// BATCH-27a/27c-1/27c-3 决策），`addTearDown` 兜底清理。
void main() {
  Widget buildPage({
    String? dbPath,
    String? docsDir,
    List<Map<String, dynamic>>? books,
    List<Map<String, dynamic>>? groups,
    Future<void> Function({
      required String dbPath,
      required String id,
      required bool deleteFile,
      required String documentsDir,
    })? deleteFn,
    Future<void> Function({
      required String dbPath,
      required String id,
      required bool canUpdate,
    })? setCanUpdateFn,
    Future<void> Function({
      required String dbPath,
      required String id,
      required int groupId,
    })? setBookGroupFn,
    Future<int> Function({
      required String dbPath,
      required String bookId,
    })? clearCacheFn,
  }) {
    final router = GoRouter(
      initialLocation: '/bookshelf-manage',
      routes: [
        GoRoute(
          path: '/bookshelf-manage',
          builder: (context, state) => BookshelfManagePage(
            dbPathOverride: dbPath,
            documentsDirOverride: docsDir,
            booksOverride: books,
            groupsOverride: groups,
            deleteOverride: deleteFn,
            setCanUpdateOverride: setCanUpdateFn,
            setBookGroupOverride: setBookGroupFn,
            clearCacheOverride: clearCacheFn,
          ),
        ),
      ],
    );
    return ProviderScope(
      overrides: [
        if (dbPath != null)
          dbPathProvider.overrideWith((ref) async => dbPath),
      ],
      child: MaterialApp.router(routerConfig: router),
    );
  }

  /// fixture 5 本书
  List<Map<String, dynamic>> fixtureBooks() => [
        {'id': 'b1', 'name': '一本好书', 'author': '作者甲'},
        {'id': 'b2', 'name': '另一本', 'author': '作者乙'},
        {'id': 'b3', 'name': '第三本', 'author': '作者丙'},
        {'id': 'b4', 'name': '第四本', 'author': '作者丁'},
        {'id': 'b5', 'name': '第五本', 'author': '作者戊'},
      ];

  testWidgets('BATCH-27d: 列表渲染 + 长按进选择 + Checkbox leading',
      (tester) async {
    final tmp = Directory.systemTemp
        .createTempSync('legado_flutter_test_27d_render_');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    await tester.pumpWidget(buildPage(
      dbPath: '${tmp.path}/x.db',
      docsDir: tmp.path,
      books: fixtureBooks(),
    ));
    await tester.pumpAndSettle();

    // 普通模式：5 本书都可见 + 没 Checkbox
    expect(find.text('一本好书'), findsOneWidget);
    expect(find.text('第五本'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
    expect(find.text('书架管理'), findsOneWidget); // AppBar title

    // 长按一本 → 进选择模式
    await tester.longPress(find.text('一本好书'));
    await tester.pumpAndSettle();

    // AppBar title 改「选择 1 项」+ close + select_all + delete IconButton
    expect(find.text('选择 1 项'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(find.byIcon(Icons.select_all), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);

    // 5 本书都有 Checkbox（选择模式 leading）
    expect(find.byType(Checkbox), findsNWidgets(5));
  });

  testWidgets('BATCH-27d: 全选 → 所有 ids 进 _selectedIds',
      (tester) async {
    final tmp = Directory.systemTemp
        .createTempSync('legado_flutter_test_27d_selectall_');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    await tester.pumpWidget(buildPage(
      dbPath: '${tmp.path}/x.db',
      docsDir: tmp.path,
      books: fixtureBooks(),
    ));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('一本好书'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.select_all));
    await tester.pumpAndSettle();

    expect(find.text('选择 5 项'), findsOneWidget);
  });

  testWidgets('BATCH-27d: 取消（close）→ 退选择模式',
      (tester) async {
    final tmp = Directory.systemTemp
        .createTempSync('legado_flutter_test_27d_cancel_');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    await tester.pumpWidget(buildPage(
      dbPath: '${tmp.path}/x.db',
      docsDir: tmp.path,
      books: fixtureBooks(),
    ));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('一本好书'));
    await tester.pumpAndSettle();
    expect(find.text('选择 1 项'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.text('选择 1 项'), findsNothing);
    expect(find.text('书架管理'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('BATCH-27d: 删除 actionbar → confirm + batch delete + 总结 SnackBar',
      (tester) async {
    final tmp = Directory.systemTemp
        .createTempSync('legado_flutter_test_27d_delete_');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    int deleteCalls = 0;
    final deletedIds = <String>[];
    await tester.pumpWidget(buildPage(
      dbPath: '${tmp.path}/x.db',
      docsDir: tmp.path,
      books: fixtureBooks(),
      deleteFn: ({
        required String dbPath,
        required String id,
        required bool deleteFile,
        required String documentsDir,
      }) async {
        deleteCalls++;
        deletedIds.add(id);
        // 默认 deleteFile=false（PRD §Q2 决策保守 unchecked）
        expect(deleteFile, isFalse);
      },
    ));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('一本好书'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.select_all));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    // confirm dialog 显示「删除选中的书？」+「同时删除本地源文件」checkbox
    expect(find.text('删除选中的书？'), findsOneWidget);
    expect(find.text('同时删除本地源文件'), findsOneWidget);

    // 点「删除」FilledButton
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(deleteCalls, 5);
    expect(deletedIds, ['b1', 'b2', 'b3', 'b4', 'b5']);
    // 总结 SnackBar
    expect(find.text('批量删除完成：成功 5 / 失败 0'), findsOneWidget);
  });

  testWidgets('BATCH-27d: 删除 actionbar → 取消 confirm → 不删',
      (tester) async {
    final tmp = Directory.systemTemp
        .createTempSync('legado_flutter_test_27d_cancel_delete_');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    int deleteCalls = 0;
    await tester.pumpWidget(buildPage(
      dbPath: '${tmp.path}/x.db',
      docsDir: tmp.path,
      books: fixtureBooks(),
      deleteFn: ({
        required String dbPath,
        required String id,
        required bool deleteFile,
        required String documentsDir,
      }) async {
        deleteCalls++;
      },
    ));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('一本好书'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    // 点「取消」TextButton
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(deleteCalls, 0);
    // 仍在选择模式（取消 confirm 不退选择）
    expect(find.text('选择 1 项'), findsOneWidget);
  });

  testWidgets('BATCH-27d: 「允许更新」→ batch setBookCanUpdate(true)',
      (tester) async {
    final tmp = Directory.systemTemp
        .createTempSync('legado_flutter_test_27d_enable_update_');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    int calls = 0;
    final canUpdates = <bool>[];
    await tester.pumpWidget(buildPage(
      dbPath: '${tmp.path}/x.db',
      docsDir: tmp.path,
      books: fixtureBooks(),
      setCanUpdateFn: ({
        required String dbPath,
        required String id,
        required bool canUpdate,
      }) async {
        calls++;
        canUpdates.add(canUpdate);
      },
    ));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('一本好书'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.select_all));
    await tester.pumpAndSettle();

    // 点「⋮」overflow → 「允许更新」
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('允许更新'));
    await tester.pumpAndSettle();

    expect(calls, 5);
    expect(canUpdates.every((v) => v == true), isTrue);
    expect(find.text('允许更新 完成：成功 5 / 失败 0'), findsOneWidget);
  });

  testWidgets('BATCH-27d: 「禁用更新」→ batch setBookCanUpdate(false)',
      (tester) async {
    final tmp = Directory.systemTemp
        .createTempSync('legado_flutter_test_27d_disable_update_');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    int calls = 0;
    bool? lastCanUpdate;
    await tester.pumpWidget(buildPage(
      dbPath: '${tmp.path}/x.db',
      docsDir: tmp.path,
      books: fixtureBooks(),
      setCanUpdateFn: ({
        required String dbPath,
        required String id,
        required bool canUpdate,
      }) async {
        calls++;
        lastCanUpdate = canUpdate;
      },
    ));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('一本好书'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('禁用更新'));
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(lastCanUpdate, false);
    expect(find.text('禁用更新 完成：成功 1 / 失败 0'), findsOneWidget);
  });

  testWidgets('BATCH-27d: 「移到分组」→ GroupPickerDialog + batch setBookGroup',
      (tester) async {
    final tmp = Directory.systemTemp
        .createTempSync('legado_flutter_test_27d_move_group_');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    int calls = 0;
    int? lastGroupId;
    await tester.pumpWidget(buildPage(
      dbPath: '${tmp.path}/x.db',
      docsDir: tmp.path,
      books: fixtureBooks(),
      groups: const [
        {'id': 1, 'group_name': '玄幻'},
        {'id': 2, 'group_name': '都市'},
      ],
      setBookGroupFn: ({
        required String dbPath,
        required String id,
        required int groupId,
      }) async {
        calls++;
        lastGroupId = groupId;
      },
    ));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('一本好书'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.select_all));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移到分组'));
    await tester.pumpAndSettle();

    // GroupPickerDialog 显示「选择分组」+「未分组」+ 2 group
    expect(find.text('选择分组'), findsOneWidget);
    expect(find.text('未分组'), findsOneWidget);
    expect(find.text('玄幻'), findsOneWidget);
    expect(find.text('都市'), findsOneWidget);

    // 选「都市」
    await tester.tap(find.text('都市'));
    await tester.pumpAndSettle();

    expect(calls, 5);
    expect(lastGroupId, 2);
    expect(find.text('移到分组完成：成功 5 / 失败 0'), findsOneWidget);
  });
}
