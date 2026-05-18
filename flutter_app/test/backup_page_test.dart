import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/features/settings/backup_page.dart';

/// 批次 10 (05-19): 备份/恢复页 widget 测试。
///
/// 通过 BackupPage 的 *Override 测试钩子注入 fake 实现，绕过
/// FRB 桥 / file_picker / path_provider，验证：
/// 1. 页面渲染两个 Card（"导出备份" + "导入备份"），且导入按钮在
///    未选 zip 时只显示"选择 zip 文件"按钮，没有"确认导入"按钮。
/// 2. 选 zip 文件后，validate 被调用，UI 显示"识别到 N 项 ...";
///    然后点"确认导入"经 AlertDialog 确认会调到 importBackupOverride
///    一次，且会显示 ImportSummary 摘要。
void main() {
  testWidgets('BackupPage renders two cards and disabled import flow initially',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: BackupPage(
            dbPathOverride: '/tmp/legado-test.db',
            // 这两个不会在本测试里被触发，但传 stub 防误调真实平台通道。
            pickDirectoryOverride: () async => null,
            pickFileOverride: () async => null,
            exportBackupOverride: (_, __) async {},
            importBackupOverride: (_, __) async => '{}',
            validateZipOverride: (_) async => <String>[],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 标题渲染。
    expect(find.text('备份/恢复'), findsOneWidget);
    // 两张 Card 的标题。
    expect(find.text('导出当前书架到 zip'), findsOneWidget);
    expect(find.text('从 zip 恢复书架'), findsOneWidget);
    // 两个主按钮。
    expect(find.text('选择保存目录并导出'), findsOneWidget);
    expect(find.text('选择 zip 文件'), findsOneWidget);
    // 没选 zip 时不应有"确认导入"按钮。
    expect(find.text('确认导入'), findsNothing);
  });

  testWidgets(
      'BackupPage validate after pick + confirm import calls override exactly once',
      (WidgetTester tester) async {
    String? capturedDbPath;
    String? capturedZipPath;
    int importCalls = 0;
    int validateCalls = 0;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: BackupPage(
            dbPathOverride: '/tmp/legado-test.db',
            pickFileOverride: () async => '/tmp/some-backup.zip',
            validateZipOverride: (zip) async {
              validateCalls++;
              return <String>['bookshelf.json', 'bookGroup.json'];
            },
            importBackupOverride: (db, zip) async {
              importCalls++;
              capturedDbPath = db;
              capturedZipPath = zip;
              return '{"books":3,"groups":2,"bookmarks":5,'
                  '"replace_rules":1,"sources":4,"errors":[]}';
            },
            // 不应被触发；传 stub 让生产代码路径不进。
            pickDirectoryOverride: () async => null,
            exportBackupOverride: (_, __) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. 点"选择 zip 文件" → 触发 pickFileOverride + validateZipOverride。
    await tester.tap(find.text('选择 zip 文件'));
    await tester.pumpAndSettle();
    expect(validateCalls, 1, reason: '点选 zip 后必须调一次 validate');
    // UI 显示识别结果。
    expect(find.textContaining('识别到 2 项'), findsOneWidget);
    expect(find.textContaining('bookshelf.json'), findsOneWidget);

    // 2. 点"确认导入" → 出 AlertDialog → 点 dialog 内"导入"。
    await tester.tap(find.text('确认导入'));
    await tester.pumpAndSettle();
    // dialog 出现：标题 + "导入" / "取消" 两个按钮。
    expect(find.text('确认导入'), findsWidgets); // 页面 + dialog 标题
    final importBtn = find.widgetWithText(FilledButton, '导入');
    expect(importBtn, findsOneWidget);
    await tester.tap(importBtn);
    await tester.pumpAndSettle();

    // 3. importBackupOverride 应被调一次，参数正确。
    expect(importCalls, 1);
    expect(capturedDbPath, '/tmp/legado-test.db');
    expect(capturedZipPath, '/tmp/some-backup.zip');

    // 4. SnackBar 显示导入摘要。
    expect(
      find.textContaining('导入完成: 3 本书 / 2 个分组'),
      findsOneWidget,
    );
  });
}
