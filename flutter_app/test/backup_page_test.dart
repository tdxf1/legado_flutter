import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/core/services/backup_api_client.dart';
import 'package:legado_flutter/core/services/file_picker_service.dart';
import 'package:legado_flutter/features/settings/backup_page.dart';

/// 批次 10 (05-19): 备份/恢复页 widget 测试。
///
/// BATCH-20 (F-W2B-004)：原 10 个 `*Override` 构造函数测试钩子全部删除，
/// 改为通过 `ProviderScope.overrides` 注入 [_FakeBackupApiClient] +
/// [_FakeFilePickerService]，绕过真实 FRB 桥 / file_picker / path_provider。
///
/// 验证点：
/// 1. 页面渲染两个 Card（"导出备份" + "导入备份"），且导入按钮在
///    未选 zip 时只显示"选择 zip 文件"按钮，没有"确认导入"按钮。
/// 2. 选 zip 文件后，validate 被调用，UI 显示"识别到 N 项 ...";
///    然后点"确认导入"经 AlertDialog 确认会调到 fake importBackup
///    一次，且会显示 ImportSummary 摘要。

/// 测试用 fake：所有方法默认抛 UnimplementedError，调用方按需 override。
class _FakeBackupApiClient extends BackupApiClient {
  final Future<void> Function({required String dbPath, required String outZipPath})?
      onExport;
  final Future<String> Function({required String dbPath, required String zipPath})?
      onImport;
  final Future<List<String>> Function({required String zipPath})? onValidate;

  const _FakeBackupApiClient({
    this.onExport,
    this.onImport,
    this.onValidate,
  });

  @override
  Future<void> exportBackup({
    required String dbPath,
    required String outZipPath,
  }) {
    if (onExport == null) {
      throw UnimplementedError('exportBackup not configured');
    }
    return onExport!(dbPath: dbPath, outZipPath: outZipPath);
  }

  @override
  Future<String> importBackup({
    required String dbPath,
    required String zipPath,
  }) {
    if (onImport == null) {
      throw UnimplementedError('importBackup not configured');
    }
    return onImport!(dbPath: dbPath, zipPath: zipPath);
  }

  @override
  Future<List<String>> validateZip({required String zipPath}) {
    if (onValidate == null) {
      throw UnimplementedError('validateZip not configured');
    }
    return onValidate!(zipPath: zipPath);
  }
}

class _FakeFilePickerService extends FilePickerService {
  final Future<String?> Function()? onPickZipFile;

  const _FakeFilePickerService({
    this.onPickZipFile,
  });

  @override
  Future<String?> pickDirectory() => Future.value(null);

  @override
  Future<String?> pickZipFile() {
    if (onPickZipFile == null) return Future.value(null);
    return onPickZipFile!();
  }
}

void main() {
  testWidgets('BackupPage renders two cards and disabled import flow initially',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backupApiClientProvider.overrideWithValue(
            _FakeBackupApiClient(
              onExport: ({required String dbPath, required String outZipPath}) async {},
              onImport: ({required String dbPath, required String zipPath}) async => '{}',
              onValidate: ({required String zipPath}) async => <String>[],
            ),
          ),
          filePickerServiceProvider.overrideWithValue(
            const _FakeFilePickerService(),
          ),
        ],
        child: const MaterialApp(
          home: BackupPage(
            dbPathOverride: '/tmp/legado-test.db',
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
      'BackupPage validate after pick + confirm import calls fake exactly once',
      (WidgetTester tester) async {
    String? capturedDbPath;
    String? capturedZipPath;
    int importCalls = 0;
    int validateCalls = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backupApiClientProvider.overrideWithValue(
            _FakeBackupApiClient(
              onExport: ({required String dbPath, required String outZipPath}) async {},
              onValidate: ({required String zipPath}) async {
                validateCalls++;
                return <String>['bookshelf.json', 'bookGroup.json'];
              },
              onImport: ({required String dbPath, required String zipPath}) async {
                importCalls++;
                capturedDbPath = dbPath;
                capturedZipPath = zipPath;
                return '{"books":3,"groups":2,"bookmarks":5,'
                    '"replace_rules":1,"sources":4,"errors":[]}';
              },
            ),
          ),
          filePickerServiceProvider.overrideWithValue(
            _FakeFilePickerService(
              onPickZipFile: () async => '/tmp/some-backup.zip',
            ),
          ),
        ],
        child: const MaterialApp(
          home: BackupPage(
            dbPathOverride: '/tmp/legado-test.db',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. 点"选择 zip 文件" → 触发 fake pickZipFile + validateZip。
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

    // 3. importBackup 应被调一次，参数正确。
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
