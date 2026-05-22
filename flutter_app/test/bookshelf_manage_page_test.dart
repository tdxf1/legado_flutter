import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:legado_flutter/core/providers.dart';
import 'package:legado_flutter/features/bookshelf/bookshelf_manage_page.dart';

/// BATCH-27d (05-22): 书架管理批量编辑页测试。
///
/// 8 + 5 testWidgets 覆盖：
///
/// BATCH-27d:
/// 1. 列表渲染 + 长按进选择模式 + Checkbox leading
/// 2. 全选 → 所有 ids 进 _selectedIds
/// 3. 取消（close）→ 退选择模式
/// 4. 删除 actionbar：confirm dialog → batch delete + 总结 SnackBar
/// 5. 删除 actionbar：取消 confirm → 不删
/// 6. 「允许更新」批量调 setBookCanUpdate
/// 7. 「禁用更新」批量调 setBookCanUpdate(false)
/// 8. 「移到分组」弹 GroupPickerDialog → batch setBookGroup
///
/// BATCH-27d-followup:
/// 9. group chips 默认「全部」选中 + 渲染所有书
/// 10. 选「未分组」chip → 仅 group=0 的书可见
/// 11. 区间选（已选 b1 + 长按 b3 → {b1 b2 b3}）
/// 12. openReader=true → 普通模式点书名 push '/reader'
/// 13. openReader=false → 普通模式点书名 no-op
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
    bool? openReader,
    void Function(String bookId)? onReaderPush,
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
            openReaderOverride: openReader,
          ),
        ),
        // BATCH-27d-followup: 测试 push '/reader' 用的 stub 路由。
        GoRoute(
          path: '/reader',
          builder: (context, state) {
            final id = state.uri.queryParameters['bookId'] ?? '';
            onReaderPush?.call(id);
            return Scaffold(
              appBar: AppBar(title: const Text('Reader Stub')),
              body: Text('reader bookId=$id'),
            );
          },
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

    // GroupPickerDialog 显示「选择分组」+「未分组」+ 2 group。
    // 27d-followup 后 AppBar 也有 group chips「未分组/玄幻/都市」，所以
    // 这些文本会重复出现 (chip + dialog option) — 用 descendant 限定到
    // SimpleDialog 范围内查找。
    expect(find.text('选择分组'), findsOneWidget);
    final dialogScope = find.byType(SimpleDialog);
    expect(
      find.descendant(of: dialogScope, matching: find.text('未分组')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialogScope, matching: find.text('玄幻')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialogScope, matching: find.text('都市')),
      findsOneWidget,
    );

    // 选「都市」（dialog 内）
    await tester.tap(
      find.descendant(of: dialogScope, matching: find.text('都市')),
    );
    await tester.pumpAndSettle();

    expect(calls, 5);
    expect(lastGroupId, 2);
    expect(find.text('移到分组完成：成功 5 / 失败 0'), findsOneWidget);
  });

  // ==========================================================================
  // BATCH-27d-followup (05-22): 5 testWidgets
  // ==========================================================================

  /// 27d-followup fixture：5 本书 + group 字段（b1=未分组 / b2 b3=玄幻
  /// id=1 / b4 b5=都市 id=2）。配 2 group fixtures (id=1 玄幻 / id=2
  /// 都市)。
  List<Map<String, dynamic>> fixtureBooksWithGroup() => [
        {'id': 'b1', 'name': '一本好书', 'author': '作者甲', 'group': 0},
        {'id': 'b2', 'name': '另一本', 'author': '作者乙', 'group': 1},
        {'id': 'b3', 'name': '第三本', 'author': '作者丙', 'group': 1},
        {'id': 'b4', 'name': '第四本', 'author': '作者丁', 'group': 2},
        {'id': 'b5', 'name': '第五本', 'author': '作者戊', 'group': 2},
      ];

  testWidgets('BATCH-27d-followup: group chips 默认「全部」选中 + 渲染所有书',
      (tester) async {
    final tmp = Directory.systemTemp
        .createTempSync('legado_flutter_test_27dfu_chip_default_');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    await tester.pumpWidget(buildPage(
      dbPath: '${tmp.path}/x.db',
      docsDir: tmp.path,
      books: fixtureBooksWithGroup(),
      groups: const [
        {'id': 1, 'group_name': '玄幻'},
        {'id': 2, 'group_name': '都市'},
      ],
    ));
    await tester.pumpAndSettle();

    // 4 chips: 全部 / 未分组 / 玄幻 / 都市
    expect(find.byType(ChoiceChip), findsNWidgets(4));
    // 默认「全部」chip selected=true
    final allChip = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, '全部'),
    );
    expect(allChip.selected, isTrue);
    // 5 本书全部可见
    expect(find.text('一本好书'), findsOneWidget);
    expect(find.text('第五本'), findsOneWidget);
  });

  testWidgets('BATCH-27d-followup: 选「未分组」chip → 仅 group=0 可见',
      (tester) async {
    final tmp = Directory.systemTemp
        .createTempSync('legado_flutter_test_27dfu_chip_filter_');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    await tester.pumpWidget(buildPage(
      dbPath: '${tmp.path}/x.db',
      docsDir: tmp.path,
      books: fixtureBooksWithGroup(),
      groups: const [
        {'id': 1, 'group_name': '玄幻'},
        {'id': 2, 'group_name': '都市'},
      ],
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ChoiceChip, '未分组'));
    await tester.pumpAndSettle();

    // 仅 b1 (group=0) 可见
    expect(find.text('一本好书'), findsOneWidget);
    expect(find.text('另一本'), findsNothing);
    expect(find.text('第三本'), findsNothing);
    expect(find.text('第四本'), findsNothing);
    expect(find.text('第五本'), findsNothing);

    // 切「玄幻」 → 仅 b2 b3
    await tester.tap(find.widgetWithText(ChoiceChip, '玄幻'));
    await tester.pumpAndSettle();
    expect(find.text('一本好书'), findsNothing);
    expect(find.text('另一本'), findsOneWidget);
    expect(find.text('第三本'), findsOneWidget);
    expect(find.text('第四本'), findsNothing);
  });

  testWidgets(
      'BATCH-27d-followup: 区间选 (已选 b1 长按 b3 → {b1 b2 b3})',
      (tester) async {
    final tmp = Directory.systemTemp
        .createTempSync('legado_flutter_test_27dfu_range_');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    await tester.pumpWidget(buildPage(
      dbPath: '${tmp.path}/x.db',
      docsDir: tmp.path,
      books: fixtureBooksWithGroup(),
    ));
    await tester.pumpAndSettle();

    // 长按 b1 → 进选择模式 + b1 选中 + _lastTappedId=b1
    await tester.longPress(find.text('一本好书'));
    await tester.pumpAndSettle();
    expect(find.text('选择 1 项'), findsOneWidget);

    // 长按 b3 → 区间 b1..b3 = {b1 b2 b3}
    await tester.longPress(find.text('第三本'));
    await tester.pumpAndSettle();
    expect(find.text('选择 3 项'), findsOneWidget);

    // 验 Checkbox：b1 b2 b3 = checked / b4 b5 = unchecked
    final b1Checkbox = tester.widget<Checkbox>(
      find.descendant(
        of: find.widgetWithText(ListTile, '一本好书'),
        matching: find.byType(Checkbox),
      ),
    );
    final b2Checkbox = tester.widget<Checkbox>(
      find.descendant(
        of: find.widgetWithText(ListTile, '另一本'),
        matching: find.byType(Checkbox),
      ),
    );
    final b3Checkbox = tester.widget<Checkbox>(
      find.descendant(
        of: find.widgetWithText(ListTile, '第三本'),
        matching: find.byType(Checkbox),
      ),
    );
    final b4Checkbox = tester.widget<Checkbox>(
      find.descendant(
        of: find.widgetWithText(ListTile, '第四本'),
        matching: find.byType(Checkbox),
      ),
    );
    expect(b1Checkbox.value, isTrue);
    expect(b2Checkbox.value, isTrue);
    expect(b3Checkbox.value, isTrue);
    expect(b4Checkbox.value, isFalse);

    // 再长按 b5 → 起点 = b3（上次长按） → 区间 b3..b5 全加（追加不清）
    await tester.longPress(find.text('第五本'));
    await tester.pumpAndSettle();
    expect(find.text('选择 5 项'), findsOneWidget);
  });

  testWidgets(
      'BATCH-27d-followup: openReader=true → 普通模式点书名 push /reader',
      (tester) async {
    final tmp = Directory.systemTemp
        .createTempSync('legado_flutter_test_27dfu_open_reader_on_');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    String? pushedBookId;
    await tester.pumpWidget(buildPage(
      dbPath: '${tmp.path}/x.db',
      docsDir: tmp.path,
      books: fixtureBooksWithGroup(),
      openReader: true,
      onReaderPush: (id) => pushedBookId = id,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('一本好书'));
    await tester.pumpAndSettle();

    // /reader stub mounted + bookId 透出
    expect(find.text('Reader Stub'), findsOneWidget);
    expect(pushedBookId, 'b1');
  });

  testWidgets(
      'BATCH-27d-followup: openReader=false → 普通模式点书名 no-op',
      (tester) async {
    final tmp = Directory.systemTemp
        .createTempSync('legado_flutter_test_27dfu_open_reader_off_');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    String? pushedBookId;
    await tester.pumpWidget(buildPage(
      dbPath: '${tmp.path}/x.db',
      docsDir: tmp.path,
      books: fixtureBooksWithGroup(),
      openReader: false,
      onReaderPush: (id) => pushedBookId = id,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('一本好书'));
    await tester.pumpAndSettle();

    // no-op：仍在 BookshelfManagePage（AppBar title 不变）+ stub 未触发
    expect(find.text('书架管理'), findsOneWidget);
    expect(find.text('Reader Stub'), findsNothing);
    expect(pushedBookId, isNull);
  });
}
