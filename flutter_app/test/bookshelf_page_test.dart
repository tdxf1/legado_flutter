import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/features/bookshelf/bookshelf_page.dart';
import 'package:legado_flutter/core/providers.dart';

void main() {
  /// 批次 7 起书架页用 [bookGroupsProvider] + [booksByGroupProvider] 渲染。
  /// 批次 8 起 [booksByGroupProvider] family key 升级为 `(int, int)` record
  /// `(groupId, sortOrder)`。下面 override 把 family 当作 `(groupId, sort)` 二元组
  /// 处理，但 widget test 里只 mock 出当前 sortOrder=0 的数据即可（默认 settings）。
  ///
  /// 为了在 widget test 里完全脱离 FRB 原生绑定，本帮助函数同时覆盖：
  /// - `bookGroupsProvider`：默认空（即仅显示"全部" + "未分组"两个虚拟 Tab）
  /// - `booksByGroupProvider((-1, 0))` / `((0, 0))`：当前 Tab 的视图
  ///
  /// `booksFutureBuilder` 每次调用都生成新的 future（避免错误 future 共享
  /// 带来 AsyncError 二次抛出导致 test framework 误报失败）。
  Widget buildBookshelfPage({
    List<Map<String, dynamic>>? books,
    List<Map<String, dynamic>>? groups,
    Future<List<Map<String, dynamic>>> Function()? booksFutureBuilder,
  }) {
    final groupList = groups ?? <Map<String, dynamic>>[];
    final bookList = books ?? <Map<String, dynamic>>[];
    return ProviderScope(
      overrides: [
        bookGroupsProvider.overrideWith((ref) async => groupList),
        booksByGroupProvider.overrideWith(
          (ref, key) =>
              booksFutureBuilder != null ? booksFutureBuilder() : Future.value(bookList),
        ),
      ],
      child: const MaterialApp(home: BookshelfPage()),
    );
  }

  testWidgets('BookshelfPage shows loading indicator', (WidgetTester tester) async {
    await tester.pumpWidget(buildBookshelfPage(
      booksFutureBuilder: () => Future.delayed(
          const Duration(seconds: 1), () => <Map<String, dynamic>>[]),
    ));
    // 让 bookGroupsProvider 完成（空），TabBar 出现，但 booksByGroupProvider 仍 pending
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('BookshelfPage shows error message', (WidgetTester tester) async {
    await tester.pumpWidget(buildBookshelfPage(
      booksFutureBuilder: () => Future.error('Connection failed'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('加载失败: Connection failed'), findsWidgets);
  });

  testWidgets('BookshelfPage shows app bar title', (WidgetTester tester) async {
    await tester.pumpWidget(buildBookshelfPage());
    await tester.pumpAndSettle();
    expect(find.text('书架'), findsOneWidget);
  });

  testWidgets('BookshelfPage shows empty message when no books', (WidgetTester tester) async {
    await tester.pumpWidget(buildBookshelfPage());
    await tester.pumpAndSettle();
    expect(find.text('书架为空，去搜索添加书籍吧'), findsWidgets);
  });

  testWidgets('BookshelfPage shows book with name and author', (WidgetTester tester) async {
    final books = [
      <String, dynamic>{
        'id': 'book1',
        'name': 'Test Book',
        'author': 'Test Author',
        'chapter_count': 42,
      },
    ];

    await tester.pumpWidget(buildBookshelfPage(books: books));
    await tester.pumpAndSettle();

    // 全部 Tab 默认在前，渲染该书
    expect(find.text('Test Book'), findsWidgets);
    expect(find.text('Test Author'), findsWidgets);
    expect(find.text('42章'), findsWidgets);
  });

  testWidgets('BookshelfPage shows multiple books', (WidgetTester tester) async {
    final books = [
      <String, dynamic>{
        'id': 'book1',
        'name': 'First Book',
        'author': 'Author One',
        'chapter_count': 10,
      },
      <String, dynamic>{
        'id': 'book2',
        'name': 'Second Book',
        'author': 'Author Two',
        'chapter_count': 20,
      },
    ];

    await tester.pumpWidget(buildBookshelfPage(books: books));
    await tester.pumpAndSettle();

    expect(find.text('First Book'), findsWidgets);
    expect(find.text('Second Book'), findsWidgets);
    expect(find.text('10章'), findsWidgets);
    expect(find.text('20章'), findsWidgets);
  });

  testWidgets('BookshelfPage shows book icon and handles null fields',
      (WidgetTester tester) async {
    final books = [
      <String, dynamic>{
        'id': 'book1',
        'name': null,
        'author': null,
        'chapter_count': null,
      },
    ];

    await tester.pumpWidget(buildBookshelfPage(books: books));
    await tester.pumpAndSettle();

    expect(find.text('未知书名'), findsWidgets);
    expect(find.text('未知作者'), findsWidgets);
    expect(find.text('0章'), findsWidgets);
    expect(find.byIcon(Icons.book), findsWidgets);
  });

  // ==========================================================
  // 批次 7 新增：分组 TabBar 测试
  // ==========================================================

  testWidgets('BookshelfPage renders default 全部/未分组 tabs', (WidgetTester tester) async {
    await tester.pumpWidget(buildBookshelfPage());
    await tester.pumpAndSettle();
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('未分组'), findsOneWidget);
  });

  testWidgets('BookshelfPage shows user groups as additional tabs',
      (WidgetTester tester) async {
    final groups = [
      <String, dynamic>{'id': 1, 'name': '玄幻', 'sort_order': 0},
      <String, dynamic>{'id': 2, 'name': '科幻', 'sort_order': 1},
    ];
    await tester.pumpWidget(buildBookshelfPage(groups: groups));
    await tester.pumpAndSettle();
    // 系统 Tab + 用户 Tab 一起出现
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('未分组'), findsOneWidget);
    expect(find.text('玄幻'), findsOneWidget);
    expect(find.text('科幻'), findsOneWidget);
  });

  // ==========================================================
  // 批次 8 (05-19): 排序菜单交互测试
  // ==========================================================

  testWidgets(
      'BookshelfPage sort icon opens dialog and persists chosen sort to ReaderSettings',
      (WidgetTester tester) async {
    // 用容器 ProviderScope 暴露 readerSettingsProvider，让本测试能直接读
    // 排序设置变化（不依赖 disk persistence）。
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bookGroupsProvider.overrideWith((ref) async => const []),
          booksByGroupProvider.overrideWith(
              (ref, key) => Future.value(const <Map<String, dynamic>>[])),
        ],
        child: Consumer(builder: (context, ref, _) {
          container = ProviderScope.containerOf(context);
          return const MaterialApp(home: BookshelfPage());
        }),
      ),
    );
    await tester.pumpAndSettle();

    // 初始默认 sort=0
    expect(container.read(readerSettingsProvider).bookshelfSort, 0);
    expect(container.read(bookshelfSortProvider), 0);

    // 点排序图标
    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    expect(find.text('书架排序'), findsOneWidget);
    // 6 个选项都在
    for (final label in ['默认', '名称', '作者', '加入时间', '上次阅读', '章节数']) {
      expect(find.text(label), findsOneWidget);
    }

    // 选 "章节数" → bookshelfSort 写为 5
    await tester.tap(find.text('章节数'));
    await tester.pumpAndSettle();
    expect(container.read(readerSettingsProvider).bookshelfSort, 5);
    expect(container.read(bookshelfSortProvider), 5);
  });

  testWidgets('ReaderSettings.copyWith preserves bookshelfSort when not set',
      (WidgetTester tester) async {
    // 单元测试：copyWith 不传 bookshelfSort 应保留原值（v7 字段同其它字段
    // 一致行为），避免菜单切到非 sort 选项时 sort 被默认值覆盖回 0。
    const orig = ReaderSettings(bookshelfSort: 3);
    final copied = orig.copyWith(fontSize: 22.0);
    expect(copied.bookshelfSort, 3);
    expect(copied.fontSize, 22.0);
  });

  test('ReaderSettings.fromJson missing bookshelfSort falls back to 0', () {
    // 老 JSON（v ≤ 6）没有 bookshelfSort 字段 — fromJson 必须 fallback 0。
    final settings = ReaderSettings.fromJson(<String, dynamic>{
      'settingsVersion': 6,
      'fontSize': 18.0,
    });
    expect(settings.bookshelfSort, 0);
    final settingsV7 = ReaderSettings.fromJson(<String, dynamic>{
      'settingsVersion': 7,
      'bookshelfSort': 4,
    });
    expect(settingsV7.bookshelfSort, 4);
  });
}
