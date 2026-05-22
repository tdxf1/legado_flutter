import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/features/bookshelf/bookshelf_page.dart';
import 'package:legado_flutter/core/providers.dart';

/// 批次 13 (05-19): 本地书导入入口测试。
///
/// 覆盖：
/// 1. 顶栏 PopupMenu 出现"导入本地书"菜单项
/// 2. 点选后会触发 `pickFileForLocalImportOverride`
/// 3. 当 pick 返回有效路径，`importLocalBookOverride` 会被调用一次
///    且参数透传正确
///
/// 故意不测真实 FilePicker / FRB / path_provider — 走的是 BookshelfPage
/// 的 *Override 测试钩子，符合 backup_page_test 的同款模式（参见
/// 批次 10 backup_page_test.dart 的 pickFileOverride 用法）。
void main() {
  Widget buildPage({
    required Future<String?> Function() pickFn,
    required Future<String> Function({
      required String dbPath,
      required String filePath,
      required String documentsDir,
    })
        importFn,
  }) {
    return ProviderScope(
      overrides: [
        // bookGroupsProvider / booksByGroupProvider 给空数据，避免走真实 FRB
        bookGroupsProvider.overrideWith((ref) async => const []),
        booksByGroupProvider.overrideWith(
          (ref, key) => Future.value(const <Map<String, dynamic>>[]),
        ),
      ],
      child: MaterialApp(
        home: BookshelfPage(
          dbPathOverride: '/fake/db.sqlite',
          documentsDirOverride: '/fake/docs',
          pickFileForLocalImportOverride: pickFn,
          importLocalBookOverride: importFn,
        ),
      ),
    );
  }

  testWidgets(
      'BookshelfPage PopupMenu contains 导入本地书 and triggers importLocalBookOverride',
      (WidgetTester tester) async {
    var pickCalls = 0;
    var importCalls = 0;
    String? lastDbPath;
    String? lastFilePath;
    String? lastDocsDir;

    await tester.pumpWidget(buildPage(
      pickFn: () async {
        pickCalls++;
        return '/tmp/fake_book.txt';
      },
      importFn: ({
        required String dbPath,
        required String filePath,
        required String documentsDir,
      }) async {
        importCalls++;
        lastDbPath = dbPath;
        lastFilePath = filePath;
        lastDocsDir = documentsDir;
        return '{"book_id":"abcdef12-3456-7890-abcd-ef1234567890"}';
      },
    ));
    await tester.pumpAndSettle();

    // 1. 找到 "更多" PopupMenuButton 并打开
    final moreBtn = find.byTooltip('更多');
    expect(moreBtn, findsOneWidget);
    await tester.tap(moreBtn);
    await tester.pumpAndSettle();

    // 2. 顶栏菜单应有"添加本地书"（BATCH-27a 起对齐原 legado
    // `main_bookshelf.xml menu_add_local` 文案，原 batch-13 的「导入本地书」
    // 改名为「添加本地书」）
    expect(find.text('添加本地书'), findsOneWidget);

    // 3. 点击触发导入流程
    await tester.tap(find.text('添加本地书'));
    // 不用 pumpAndSettle —— 后面有 GoRouter context.push 触发的导航；但
    // 这个 widget 没绑路由（MaterialApp.home），所以 context.push 会报
    // "No GoRouter found"。我们 catch 在 _onImportLocalBook 的 try 里，
    // SnackBar 路径走得通即可。pump 几帧让 microtask 跑完。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(pickCalls, 1);
    expect(importCalls, 1);
    expect(lastFilePath, '/tmp/fake_book.txt');
    expect(lastDbPath, '/fake/db.sqlite');
    expect(lastDocsDir, '/fake/docs');
  });
}
