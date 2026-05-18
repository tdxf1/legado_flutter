/// Task X3 — 精确搜索可见性。
///
/// 校验 PRD 要求：
///   1. AppBar 用 FilterChip(label: '精确') 替代 IconButton（更显眼）
///   2. 默认 _precisionMode=false → FilterChip.selected = false
///   3. 点击 FilterChip → _precisionMode 翻转 + SnackBar 显示
///   4. _doSearch 后 _lastSearchKeyword 被记忆（通过 debug getter 验证）
///   5. toggle 后用记忆 keyword 重跑（即便 TextField 已被清空也能重过滤）
///
/// 这里用真正构造的 SearchPage widget 来验证 UI 行为。`_doSearch` 走的
/// 离线路径需要 dbInitializedProvider / dbPathProvider 等 Riverpod overrides，
/// 用 future.delayed 让异步搜索悬停在 await 处即可观察前置的 keyword 写入
/// 副作用 + SnackBar 文本，不依赖真实 Rust API。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/core/providers.dart';
import 'package:legado_flutter/features/search/search_page.dart';

Widget _buildSearchPage({Completer<bool>? dbInitCompleter}) {
  return ProviderScope(
    overrides: [
      dbDirProvider.overrideWith((ref) => Future.value('.')),
      dbPathProvider.overrideWith((ref) => Future.value('test_legado.db')),
      dbInitializedProvider.overrideWith(
        (ref) => dbInitCompleter?.future ?? Future.value(true),
      ),
    ],
    child: const MaterialApp(home: SearchPage()),
  );
}

void main() {
  testWidgets('AppBar 用 FilterChip(label: "精确") 替代 IconButton',
      (WidgetTester tester) async {
    await tester.pumpWidget(_buildSearchPage());
    await tester.pumpAndSettle();
    expect(find.byType(FilterChip), findsOneWidget);
    expect(find.text('精确'), findsOneWidget);
  });

  testWidgets('默认 _precisionMode=false → FilterChip.selected = false',
      (WidgetTester tester) async {
    await tester.pumpWidget(_buildSearchPage());
    await tester.pumpAndSettle();
    final chip = tester.widget<FilterChip>(find.byType(FilterChip));
    expect(chip.selected, isFalse);
  });

  testWidgets('点击 FilterChip → selected 翻转 (false → true)',
      (WidgetTester tester) async {
    await tester.pumpWidget(_buildSearchPage());
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilterChip>(find.byType(FilterChip)).selected,
      isFalse,
    );

    await tester.tap(find.byType(FilterChip));
    // 一个 pump 让 setState 生效；再 pump 让 SnackBar slide-in 第一帧出现
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      tester.widget<FilterChip>(find.byType(FilterChip)).selected,
      isTrue,
      reason: '点击后 _precisionMode 应翻转为 true',
    );

    // SnackBar 文本应已 mount 进 widget tree
    expect(find.text('已切换到精确搜索'), findsOneWidget,
        reason: 'toggle 切换到精确应弹 SnackBar');

    // 让 SnackBar duration(1s) 走完，避免清理告警
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('再次点击 FilterChip → selected 翻转回 false',
      (WidgetTester tester) async {
    await tester.pumpWidget(_buildSearchPage());
    await tester.pumpAndSettle();

    // 第一次：到精确
    await tester.tap(find.byType(FilterChip));
    await tester.pump();
    expect(
      tester.widget<FilterChip>(find.byType(FilterChip)).selected,
      isTrue,
    );

    // 等第一条 SnackBar 完整生命周期走完（duration 1s + 进出 transition），
    // 让 MessengerState 队列清空
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    // 第二次：回到模糊
    await tester.tap(find.byType(FilterChip));
    await tester.pump();

    expect(
      tester.widget<FilterChip>(find.byType(FilterChip)).selected,
      isFalse,
      reason: '第二次点击 _precisionMode 应翻转回 false',
    );

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('_doSearch 后 _lastSearchKeyword 被记忆',
      (WidgetTester tester) async {
    // 让 dbInitializedProvider 永远不完成 → _doSearch 在 await 处悬停，
    // 但 `_lastSearchKeyword = keyword` 已经在 await 之前同步执行过。
    final hangingCompleter = Completer<bool>();

    await tester.pumpWidget(
      _buildSearchPage(dbInitCompleter: hangingCompleter),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '斗破苍穹');
    await tester.pumpAndSettle();

    // 触发 _doSearch（默认 offline 模式 → 走 dbInitializedProvider）
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump(); // 让 setState(loading=true) + 同步赋值生效

    // 通过 debug getter 验证记忆字段
    final state = tester.state<State<SearchPage>>(find.byType(SearchPage));
    // ignore: avoid_dynamic_calls
    expect((state as dynamic).debugLastSearchKeyword, '斗破苍穹');

    // 不调 pumpAndSettle 收尾（hanging future 会让它超时）；解开 future
    // 让 widget 收尾。即使 dispose 时 mounted=false 也能干净退出。
    hangingCompleter.complete(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets(
      'toggle 时 _lastSearchKeyword 非空 → 把 keyword 写回 TextField 并重跑',
      (WidgetTester tester) async {
    // 第一次搜索：用 hanging completer 让 _doSearch 在 await 前已经写入
    // _lastSearchKeyword。
    final firstCompleter = Completer<bool>();
    await tester.pumpWidget(
      _buildSearchPage(dbInitCompleter: firstCompleter),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '玄幻');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    // 此时 _lastSearchKeyword == '玄幻'

    // 用户清空了 TextField
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();

    // 点击 FilterChip 切换精确模式：toggle 应把 _lastSearchKeyword 写回
    // controller 并重跑 _doSearch。
    await tester.tap(find.byType(FilterChip));
    await tester.pump();

    // controller.text 应被恢复成记忆 keyword
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, '玄幻',
        reason: 'toggle 时应把 _lastSearchKeyword 写回 TextField');

    // 解开 hanging future（仍然是同一个 firstCompleter，dbInitializedProvider
    // 是 family-less provider，两次 _doSearch 共享同一个 future）
    if (!firstCompleter.isCompleted) firstCompleter.complete(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets(
      '_lastSearchKeyword 为空时 toggle 只切换状态，TextField 仍为空',
      (WidgetTester tester) async {
    await tester.pumpWidget(_buildSearchPage());
    await tester.pumpAndSettle();

    // 用户从未搜索过，直接点 FilterChip
    await tester.tap(find.byType(FilterChip));
    await tester.pump();

    // 状态翻转
    expect(
      tester.widget<FilterChip>(find.byType(FilterChip)).selected,
      isTrue,
    );
    // TextField 仍空（toggle 不会无中生有写入）
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, isEmpty);

    // 让 SnackBar 走完
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });
}
