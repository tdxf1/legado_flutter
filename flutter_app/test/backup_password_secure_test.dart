import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/core/security/secure_storage.dart';
import 'package:legado_flutter/features/settings/webdav_config_page.dart';

import '_secure_storage_fake.dart';

/// BATCH-03b (F-W1A-020): 备份密码迁移到 secure_storage 的核心路径覆盖。
///
/// 与 BATCH-03 webdav_password 同模式：load 优先 secure_storage，miss 时
/// 回退 FRB 旧路径并触发一次性迁移 + 清理 legado_local.json；save 直接走
/// writeSecret。FRB funcId 71/72 binary contract 保留以备未来 backup zip
/// 加密复用，但 dart 端不再主动调（除迁移路径）。
///
/// 4 case：
/// 1. load 路径：secure_storage 命中直接用，不触发 FRB
/// 2. load 路径：secure_storage miss + FRB 有值 → 触发迁移 + 清理
/// 3. load 路径：secure_storage miss + FRB 也空 → 空串
/// 4. save 路径：writeSecret 命中，FRB setBackupPassword 不被调
void main() {
  late InMemorySecureStorage secureStorageFake;

  setUp(() {
    secureStorageFake = InMemorySecureStorage();
    setSecureStorageOverrideForTest(secureStorageFake);
  });

  tearDown(() {
    setSecureStorageOverrideForTest(null);
  });

  testWidgets(
    'backup_password load: secure_storage 命中直接用',
    (WidgetTester tester) async {
      final tmp = Directory.systemTemp.createTempSync('bpw-secure-hit-');

      // 预置 secure_storage 中已有 backup_password
      secureStorageFake.debugStore['backup_password'] = 'cached';

      int getCalls = 0;
      int setCalls = 0;

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: WebDavConfigPage(
              configDirOverride: tmp.path,
              webdavCheckOverride: ({
                required String url,
                required String user,
                required String password,
              }) async {},
              getBackupPasswordOverride: ({required String documentsDir}) async {
                getCalls++;
                return 'should-not-read';
              },
              setBackupPasswordOverride: (
                  {required String documentsDir, required String password}) async {
                setCalls++;
              },
            ),
          ),
        ),
      );

      // 等 _loadConfig 完成
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // secure_storage 命中：FRB 不应被调
      expect(getCalls, 0,
          reason: 'secure_storage 命中时不应回退 FRB getBackupPassword');
      expect(setCalls, 0,
          reason: 'secure_storage 命中时不应触发清理路径');

      // _backupPwdCtl.text 应该是 'cached' —— 通过 TextField 显示文本断言
      // (备份密码字段是第 5 个 TextField, index 4)
      final tf = tester.widget<TextField>(find.byType(TextField).at(4));
      expect(tf.controller?.text, 'cached');

      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    },
  );

  testWidgets(
    'backup_password load: secure_storage miss + FRB 有值 → 触发迁移',
    (WidgetTester tester) async {
      final tmp = Directory.systemTemp.createTempSync('bpw-secure-miss-frb-hit-');

      // secure_storage 空（fake 默认）
      int getCalls = 0;
      int setCalls = 0;
      String? capturedClearPassword;
      String? capturedClearDir;

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: WebDavConfigPage(
              configDirOverride: tmp.path,
              webdavCheckOverride: ({
                required String url,
                required String user,
                required String password,
              }) async {},
              getBackupPasswordOverride: ({required String documentsDir}) async {
                getCalls++;
                return 'legacy'; // 旧 legado_local.json 中有值
              },
              setBackupPasswordOverride: (
                  {required String documentsDir, required String password}) async {
                setCalls++;
                capturedClearDir = documentsDir;
                capturedClearPassword = password;
              },
            ),
          ),
        ),
      );

      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // FRB get 被调一次取出 legacy 值
      expect(getCalls, 1, reason: 'secure_storage miss 时应调 FRB getBackupPassword');
      // FRB set 被调一次清理（传空串）
      expect(setCalls, 1,
          reason: 'FRB 有值时应调 setBackupPassword 传空串清理 legado_local.json');
      expect(capturedClearPassword, '',
          reason: '清理路径必须传空串');
      expect(capturedClearDir, tmp.path);

      // secure_storage 已写入迁移值
      expect(secureStorageFake.debugStore['backup_password'], 'legacy',
          reason: '迁移路径应把 legacy 值写入 secure_storage');

      // _backupPwdCtl.text 应该填回 legacy
      final tf = tester.widget<TextField>(find.byType(TextField).at(4));
      expect(tf.controller?.text, 'legacy');

      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    },
  );

  testWidgets(
    'backup_password load: secure_storage miss + FRB 也空 → 空串',
    (WidgetTester tester) async {
      final tmp = Directory.systemTemp.createTempSync('bpw-secure-miss-frb-empty-');

      int getCalls = 0;
      int setCalls = 0;

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: WebDavConfigPage(
              configDirOverride: tmp.path,
              webdavCheckOverride: ({
                required String url,
                required String user,
                required String password,
              }) async {},
              getBackupPasswordOverride: ({required String documentsDir}) async {
                getCalls++;
                return ''; // 旧 legado_local.json 也无值（首次配置）
              },
              setBackupPasswordOverride: (
                  {required String documentsDir, required String password}) async {
                setCalls++;
              },
            ),
          ),
        ),
      );

      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // FRB get 调一次确认空
      expect(getCalls, 1);
      // 不触发迁移路径，FRB set 不应被调
      expect(setCalls, 0,
          reason: 'legacy 也空时不应触发清理路径');

      // secure_storage 仍为空
      expect(secureStorageFake.debugStore.containsKey('backup_password'), isFalse,
          reason: '双空场景不应写入 secure_storage');

      // _backupPwdCtl.text 应该是空串
      final tf = tester.widget<TextField>(find.byType(TextField).at(4));
      expect(tf.controller?.text, '');

      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    },
  );

  testWidgets(
    'backup_password save: writeSecret 命中',
    (WidgetTester tester) async {
      final tmp = Directory.systemTemp.createTempSync('bpw-secure-save-');

      int setCalls = 0;

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: WebDavConfigPage(
              configDirOverride: tmp.path,
              webdavCheckOverride: ({
                required String url,
                required String user,
                required String password,
              }) async {},
              getBackupPasswordOverride: ({required String documentsDir}) async => '',
              setBackupPasswordOverride: (
                  {required String documentsDir, required String password}) async {
                setCalls++;
              },
            ),
          ),
        ),
      );

      // 等 _loadConfig 完成
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // 填 URL（保存校验要求非空）+ 备份密码
      await tester.enterText(find.byType(TextField).at(0),
          'https://example.com/dav/');
      await tester.enterText(find.byType(TextField).at(4), 'newpass');
      await tester.pump();

      // 点保存
      await tester.tap(find.text('保存'));
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
      }

      // secure_storage 写入 newpass
      expect(secureStorageFake.debugStore['backup_password'], 'newpass',
          reason: 'save 路径应把备份密码写到 secure_storage');
      // FRB setBackupPassword 不应被调
      expect(setCalls, 0,
          reason: 'BATCH-03b 后 save 不再走 FRB setBackupPassword');

      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    },
  );
}
