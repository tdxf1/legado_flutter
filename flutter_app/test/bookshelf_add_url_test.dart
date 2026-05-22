import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/features/bookshelf/bookshelf_page.dart';
import 'package:legado_flutter/core/providers.dart';

/// BATCH-27e (05-22): add_url + import_bookshelf 测试。
///
/// 2 testWidgets：
/// 1. PopupMenu add_url + import_bookshelf 已 enabled
/// 2. add_url onTap 弹 _AddUrlDialog
void main() {
  Widget buildPage() {
    return ProviderScope(
      overrides: [
        bookGroupsProvider.overrideWith((ref) async => const []),
        booksByGroupProvider.overrideWith(
          (ref, key) => Future.value(const <Map<String, dynamic>>[]),
        ),
      ],
      child: const MaterialApp(
        home: BookshelfPage(
          dbPathOverride: '/fake/db.sqlite',
          documentsDirOverride: '/fake/docs',
        ),
      ),
    );
  }

  testWidgets(
      'BATCH-27e: PopupMenu add_url + import_bookshelf are enabled',
      (tester) async {
    await tester.pumpWidget(buildPage());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();

    for (final v in ['add_url', 'import_bookshelf']) {
      final widget = tester.widget<PopupMenuItem<String>>(
        find.byWidgetPredicate(
          (w) => w is PopupMenuItem<String> && w.value == v,
        ),
      );
      expect(widget.enabled, isTrue,
          reason: '$v 应在 BATCH-27e 后 enabled');
    }
  });

  testWidgets('BATCH-27e: add_url PopupMenu onTap 弹 _AddUrlDialog',
      (tester) async {
    await tester.pumpWidget(buildPage());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();

    // 点「添加网络URL」→ 弹 AlertDialog
    await tester.tap(find.text('添加网络URL'));
    await tester.pumpAndSettle();

    expect(find.text('添加网络URL'), findsWidgets);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '添加'), findsOneWidget);
  });
}
