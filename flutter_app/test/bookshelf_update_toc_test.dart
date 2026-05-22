import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/features/bookshelf/bookshelf_page.dart';
import 'package:legado_flutter/core/providers.dart';
import 'package:legado_flutter/core/update_toc_runner.dart';

/// BATCH-27b (05-22): bookshelf「更新目录」批量任务 widget 测试。
///
/// 覆盖：
/// 1. PopupMenu「更新目录」从灰显改可点 (BATCH-27a 测试已校验，本文件
///    校验 onSelected 实际触发 enqueue 路径)
/// 2. filter local books（origin/source_id 为 'local' 不入队 → SnackBar
///    「无可刷新的书」）
/// 3. enqueue 命中：选「更新目录」→ 调 updateBookTocOverride → SnackBar
///    「已开始刷新目录（N 本）」
/// 4. AppBar transient badge 在 isRunning 时显示
/// 5. isDone 后 invalidate providers + SnackBar「目录刷新完成：成 X / 失 Y」
///
/// 测试钩子：
/// - `dbPathOverride`：避开 path_provider
/// - `updateBookTocOverride`：注入假 FRB，runner.worker 内调用此函数
/// - `booksByGroupProvider.overrideWith`：注入测试 fixture（含 local + 远程
///   两类书）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    UpdateTocRunner().resetForTest();
  });

  Widget buildPage({
    required List<Map<String, dynamic>> books,
    UpdateBookTocFn? updateFn,
  }) {
    return ProviderScope(
      overrides: [
        bookGroupsProvider.overrideWith((ref) async => const []),
        booksByGroupProvider.overrideWith(
          (ref, key) => Future.value(books),
        ),
      ],
      child: MaterialApp(
        home: BookshelfPage(
          dbPathOverride: '/fake/db.sqlite',
          documentsDirOverride: '/fake/docs',
          updateBookTocOverride: updateFn,
        ),
      ),
    );
  }

  /// 1. PopupMenu「更新目录」可点（27b 改可点） + onSelected 触发 enqueue。
  testWidgets(
      'BATCH-27b: 更新目录 menu item enabled and triggers enqueue',
      (WidgetTester tester) async {
    final calls = <String>[];
    Future<int> fakeFn(
        {required String dbPath, required String bookId}) async {
      // 让 worker 不在同一 microtask 内全跑完，给「已开始刷新目录」
      // SnackBar 留 frame 显示
      await Future<void>.delayed(const Duration(milliseconds: 50));
      calls.add(bookId);
      return 1;
    }

    await tester.pumpWidget(buildPage(
      books: [
        {
          'id': 'b1',
          'name': '远程书一',
          'source_id': 'real_source_uuid',
          'can_update': true,
        },
        {
          'id': 'b2',
          'name': '远程书二',
          'source_id': 'real_source_uuid',
          'can_update': true,
        },
      ],
      updateFn: fakeFn,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();

    // 验「更新目录」item enabled
    final menuItem = tester.widget<PopupMenuItem<String>>(
      find.byWidgetPredicate(
        (w) => w is PopupMenuItem<String> && w.value == 'update_toc',
      ),
    );
    expect(menuItem.enabled, isTrue);

    // 选 → 弹「已开始刷新目录（2 本）」SnackBar；之后批次跑完会被
    // 「目录刷新完成」覆盖（hideCurrentSnackBar）。两个都验。
    await tester.tap(find.text('更新目录'));
    // _onUpdateToc 内有多个 await（ref.read 拿 books / dbPath），每次都
    // 让步给 microtask；多 pump 让链条推到 SnackBar.show。
    for (int i = 0; i < 5; i++) {
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 30));
    expect(find.byWidgetPredicate(
      (w) => w is Text && (w.data ?? '').startsWith('已开始刷新目录'),
    ), findsOneWidget,
        reason: '_onUpdateToc 弹首条 SnackBar，先于 worker 完成');

    // 多 pump 让 worker 跑完 + 完成 SnackBar 覆盖
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(calls.toSet(), {'b1', 'b2'},
        reason: 'updateBookTocOverride 应被调用 2 次（每本 1 次）');
    expect(find.byWidgetPredicate(
      (w) => w is Text && (w.data ?? '').contains('目录刷新完成'),
    ), findsOneWidget, reason: '完成后应弹「目录刷新完成：成 2 / 失 0」');
  });

  /// 2. filter 排除 local books / can_update=false → 整批没有可刷的书 →
  ///    SnackBar「当前 Tab 无可刷新的书」+ 不调 FRB。
  testWidgets('BATCH-27b: filter excludes local books / cannot-update',
      (WidgetTester tester) async {
    int callCount = 0;
    Future<int> fakeFn(
        {required String dbPath, required String bookId}) async {
      callCount++;
      return 1;
    }

    await tester.pumpWidget(buildPage(
      books: [
        // local book — source_id='local' 应被 filter 掉
        {
          'id': 'b_local',
          'name': '本地 TXT',
          'source_id': 'local',
          'can_update': true,
        },
        // can_update=false 也被 filter 掉
        {
          'id': 'b_no_update',
          'name': '远端但禁更新',
          'source_id': 'real',
          'can_update': false,
        },
        // source_id 空 → 同 local 处理
        {
          'id': 'b_empty_source',
          'name': '空 source',
          'source_id': '',
          'can_update': true,
        },
      ],
      updateFn: fakeFn,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新目录'));
    for (int i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.text('当前 Tab 无可刷新的书'), findsOneWidget);
    expect(callCount, 0, reason: '本地书 / 不可更新书不应触发 FRB');
  });

  /// 3. AppBar transient badge：进度中显示 + 跑完消失。
  testWidgets('BATCH-27b: transient badge shows during run and hides after',
      (WidgetTester tester) async {
    Future<int> fakeFn(
        {required String dbPath, required String bookId}) async {
      // 微小延迟让 in-flight 持续到至少一帧
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return 1;
    }

    await tester.pumpWidget(buildPage(
      books: [
        {
          'id': 'b1',
          'name': '书一',
          'source_id': 'src',
          'can_update': true,
        },
        {
          'id': 'b2',
          'name': '书二',
          'source_id': 'src',
          'can_update': true,
        },
      ],
      updateFn: fakeFn,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新目录'));
    // 推 1-2 微 frame 让 enqueue + first progress emit 完成
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    // badge 应显示 — 找 CircularProgressIndicator + 内部「N/M」label
    expect(find.byType(CircularProgressIndicator), findsOneWidget,
        reason: '_isUpdatingToc=true 时应有 transient 转圈');

    // 等批次跑完
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    // 跑完后 isRunning=false → badge 不渲染
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'isDone 后 transient badge 应消失');
  });

  /// 4. isDone 后 SnackBar「目录刷新完成：成 X / 失 Y」+ invalidate providers。
  testWidgets('BATCH-27b: completion SnackBar shows success/fail counts',
      (WidgetTester tester) async {
    Future<int> fakeFn(
        {required String dbPath, required String bookId}) async {
      if (bookId == 'b_fail') throw Exception('mock fail');
      return 1;
    }

    await tester.pumpWidget(buildPage(
      books: [
        {
          'id': 'b1',
          'name': '书一',
          'source_id': 'src',
          'can_update': true,
        },
        {
          'id': 'b_fail',
          'name': '书二',
          'source_id': 'src',
          'can_update': true,
        },
        {
          'id': 'b3',
          'name': '书三',
          'source_id': 'src',
          'can_update': true,
        },
      ],
      updateFn: fakeFn,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新目录'));
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    // 完成 SnackBar 应含「目录刷新完成：成 2 / 失 1」
    expect(
      find.byWidgetPredicate(
        (w) => w is Text && (w.data ?? '').contains('目录刷新完成：成 2 / 失 1'),
      ),
      findsOneWidget,
      reason: 'b1/b3 成功 b_fail 失败 → 成 2 / 失 1',
    );
  });
}
