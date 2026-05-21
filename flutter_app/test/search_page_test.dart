import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/features/search/search_page.dart';
import 'package:legado_flutter/core/providers.dart';

void main() {
  Widget buildSearchPage() {
    return ProviderScope(
      overrides: [
        dbDirProvider.overrideWith((ref) => Future.value('.')),
        dbPathProvider.overrideWith((ref) => Future.value('test_legado.db')),
        dbInitializedProvider.overrideWith((ref) => Future.value(true)),
      ],
      child: const MaterialApp(home: SearchPage()),
    );
  }

  testWidgets('SearchPage shows app bar title', (WidgetTester tester) async {
    await tester.pumpWidget(buildSearchPage());
    await tester.pumpAndSettle();
    expect(find.text('搜索'), findsOneWidget);
  });

  testWidgets('SearchPage shows hint text in input field', (WidgetTester tester) async {
    await tester.pumpWidget(buildSearchPage());
    await tester.pumpAndSettle();
    expect(find.text('输入书名或作者'), findsOneWidget);
  });

  testWidgets('SearchPage shows empty state message', (WidgetTester tester) async {
    await tester.pumpWidget(buildSearchPage());
    await tester.pumpAndSettle();
    expect(find.text('输入关键词搜索书籍'), findsOneWidget);
  });

  testWidgets('SearchPage shows search icon prefix', (WidgetTester tester) async {
    await tester.pumpWidget(buildSearchPage());
    await tester.pumpAndSettle();
    // Task X3 后 AppBar action 改用 FilterChip + Icons.search_off / youtube_searched_for，
    // TextField prefixIcon 仍是 Icons.search。所以 Icons.search 默认状态下应该
    // 只剩 1 个（输入框 prefix），AppBar 那个 +1 已迁出。
    expect(find.byIcon(Icons.search), findsOneWidget);
  });

  testWidgets('SearchPage AppBar precision toggle defaults to fuzzy mode', (WidgetTester tester) async {
    await tester.pumpWidget(buildSearchPage());
    await tester.pumpAndSettle();
    // Task X3 — AppBar action 改用 FilterChip：默认 selected=false，avatar 显示
    // Icons.search_off。
    final filterChip = tester.widget<FilterChip>(find.byType(FilterChip));
    expect(filterChip.selected, isFalse);
    expect(find.byIcon(Icons.search_off), findsOneWidget);
    expect(find.byIcon(Icons.youtube_searched_for), findsNothing);
  });

  testWidgets('SearchPage AppBar precision toggle flips to precision mode on tap', (WidgetTester tester) async {
    await tester.pumpWidget(buildSearchPage());
    await tester.pumpAndSettle();
    // Task X3 — 点击 FilterChip 翻转 selected，avatar 切到 Icons.youtube_searched_for。
    await tester.tap(find.byType(FilterChip));
    await tester.pumpAndSettle();
    final filterChip = tester.widget<FilterChip>(find.byType(FilterChip));
    expect(filterChip.selected, isTrue);
    expect(find.byIcon(Icons.youtube_searched_for), findsOneWidget);
    expect(find.byIcon(Icons.search_off), findsNothing);
  });

  testWidgets('SearchPage shows send button', (WidgetTester tester) async {
    await tester.pumpWidget(buildSearchPage());
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.send), findsOneWidget);
  });

  testWidgets('SearchPage does not crash when disposed during async offline search', (WidgetTester tester) async {
    final completer = Completer<bool>();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dbDirProvider.overrideWith((ref) => Future.value('.')),
          dbPathProvider.overrideWith((ref) => Future.value('test_legado.db')),
          dbInitializedProvider.overrideWith((ref) => completer.future),
        ],
        child: const MaterialApp(home: SearchPage()),
      ),
    );
    await tester.pumpAndSettle();

    // Enter text to enable search
    await tester.enterText(find.byType(TextField), 'test');
    await tester.pumpAndSettle();

    // Trigger search (default offline mode) — enters await ref.read(dbInitializedProvider.future)
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    // Search is now suspended on the hanging dbInitializedProvider future

    // Navigate away, disposing SearchPage
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('SAFE'))),
    );
    await tester.pump();

    // Complete the future that SearchPage was awaiting — code resumes at mounted guard
    completer.complete(true);
    await tester.pump();

    // If we reach here without exception, the mounted guard worked
    expect(find.text('SAFE'), findsOneWidget);
  });

  testWidgets('SearchPage can enter text in search field', (WidgetTester tester) async {
    await tester.pumpWidget(buildSearchPage());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'test keyword');
    await tester.pumpAndSettle();

    expect(find.text('test keyword'), findsOneWidget);
  });

  testWidgets(
      'BATCH-21 (F-W2B-019): 连续两次 _doSearch 后 _searchSeq 自增；'
      '旧 future 不覆盖新结果', (WidgetTester tester) async {
    // 让 dbInitializedProvider 永远不完成 → _doSearch 在 await 处悬停
    // 但 ++_searchSeq 已经在 await 前同步执行过。
    final hangingCompleter = Completer<bool>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dbDirProvider.overrideWith((ref) => Future.value('.')),
          dbPathProvider.overrideWith((ref) => Future.value('test_legado.db')),
          dbInitializedProvider.overrideWith((ref) => hangingCompleter.future),
        ],
        child: const MaterialApp(home: SearchPage()),
      ),
    );
    await tester.pumpAndSettle();

    // 第一次搜索：tap send 按钮触发 _doSearch
    await tester.enterText(find.byType(TextField), 'A');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();

    final state = tester.state<State<SearchPage>>(find.byType(SearchPage));
    // ignore: avoid_dynamic_calls
    expect((state as dynamic).debugSearchSeq, 1);
    // ignore: avoid_dynamic_calls
    expect((state as dynamic).debugLastSearchKeyword, 'A');

    // 第二次搜索：此时 _loading=true，send 按钮被 progress 替换；用
    // onSubmitted 路径触发（直接对 TextField 输入新值再走 _doSearch）。
    // 简化：通过 state.dynamic 调用 onSubmitted 回调；或更直接：模拟用户
    // 在不等第一次完成的情况下用 onSubmitted。
    await tester.enterText(find.byType(TextField), 'B');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    // ignore: avoid_dynamic_calls
    expect((state as dynamic).debugSearchSeq, 2,
        reason: '第二次 _doSearch 应自增 seq 到 2');
    // ignore: avoid_dynamic_calls
    expect((state as dynamic).debugLastSearchKeyword, 'B',
        reason: '_lastSearchKeyword 应被新关键词覆盖');

    // 解开 hanging future —— 第一次和第二次的 await 都会拿到 true。
    // 第一次的 await 后会执行 `if (!mounted || seq != _searchSeq) return;`
    // 因为 seq=1 ≠ _searchSeq=2，被拦截，不会改 _loading / 不会回滚
    // _lastSearchKeyword。
    hangingCompleter.complete(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // ignore: avoid_dynamic_calls
    expect((state as dynamic).debugLastSearchKeyword, 'B',
        reason: 'seq 校验保证旧 future 不覆盖新关键词记忆');
  });
}
