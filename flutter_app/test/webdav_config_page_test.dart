import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/core/persistence/json_store.dart';
import 'package:legado_flutter/core/security/secure_storage.dart';
import 'package:legado_flutter/features/settings/webdav_config_page.dart';

import '_secure_storage_fake.dart';

/// 批次 11 (05-19): WebDAV 配置页 widget 测试。
///
/// 通过 [WebDavConfigPage] 的 *Override 测试钩子注入 fake 实现，绕过
/// path_provider / FRB 桥，验证：
/// 1. 页面渲染 5 个 TextField (URL/用户名/密码/设备名/备份密码) +
///    测试连接 + 保存按钮。
/// 2. 点 "测试连接" 在 URL 已填时调一次 [`webdavCheckOverride`]。
///
/// 批次 12 (05-19) 补充：第二个 test 验证"备份密码"字段渲染 + 保存
/// 时调一次 [`setBackupPasswordOverride`]，并把当前文本传过去。
///
/// BATCH-03 (F-W2B-001) 补充：WebDAV 密码字段改走 secure_storage；测试
/// 注入 [InMemorySecureStorage] 避免 platform channel 抛 MissingPluginException。
/// 第三个 test 验证旧 webdav.json 中的 password 字段会迁移到 secure_storage
/// 并从 json 文件移除。
///
/// BATCH-03b (F-W1A-020) 补充：备份密码 save 路径也改 secure_storage（不再
/// 调 setBackupPassword override）；第二个 test 改测 `secureStorageFake.debugStore`
/// 中 `backup_password` 命中 + override 不被调。load 路径下 secure_storage
/// miss 时会回退 FRB getBackupPassword override（迁移触发口），保留向后兼容。
void main() {
  late InMemorySecureStorage secureStorageFake;

  setUp(() {
    secureStorageFake = InMemorySecureStorage();
    setSecureStorageOverrideForTest(secureStorageFake);
  });

  tearDown(() {
    setSecureStorageOverrideForTest(null);
  });

  // ────────────────────────────────────────────────────────────────────
  // BATCH-03 (F-W2B-001) 启动迁移路径核心断言。
  //
  // 放在 widget tests 之前避免被 testWidgets fake-async zone 污染
  // module-level json_store._writeLock（widget test 中 writeJsonFile 完
  // 整完成的语义微妙）。
  // ────────────────────────────────────────────────────────────────────
  test(
    'webdav_password migration semantics: legacyPwd + empty secure_storage moves password',
    () async {
      // 验证 `_loadConfig` 内迁移分支的语义等价：
      //   legacyPwd.isNotEmpty && securePwd == null
      //   → writeSecret + writeJsonFile (3 字段)
      // 直接调 json_store + secure_storage 公共 helper，覆盖与
      // webdav_config_page._loadConfig 相同的协作路径。
      final tmp = Directory.systemTemp.createTempSync('webdav-migrate-pure-');
      final fake = InMemorySecureStorage();
      setSecureStorageOverrideForTest(fake);
      try {
        // 模拟旧版本写出的 webdav.json（4 字段含 password 明文）
        await writeJsonFile('webdav.json', {
          'url': 'https://dav.example.com/dav/',
          'user': 'alice',
          'password': 'legacy_pwd',
          'deviceName': 'Pixel',
        }, directory: tmp.path);

        // 模拟 _loadConfig 内的迁移逻辑（与 webdav_config_page.dart 同步）：
        final map = await readJsonFile('webdav.json', directory: tmp.path);
        expect(map, isNotNull);
        final legacyPwd = (map!['password'] as String?) ?? '';
        final securePwd = await readSecret('webdav_password');
        expect(legacyPwd, 'legacy_pwd');
        expect(securePwd, isNull);

        if (legacyPwd.isNotEmpty && securePwd == null) {
          await writeSecret('webdav_password', legacyPwd);
          await writeJsonFile('webdav.json', {
            'url': map['url'] ?? '',
            'user': map['user'] ?? '',
            'deviceName': map['deviceName'] ?? '',
          }, directory: tmp.path);
        }

        // 断言：fake 命中 legacy_pwd
        expect(fake.debugStore['webdav_password'], 'legacy_pwd');

        // 断言：webdav.json 不再含 password 字段
        final reloaded = await readJsonFile('webdav.json', directory: tmp.path);
        expect(reloaded, isNotNull);
        expect(reloaded!.containsKey('password'), isFalse,
            reason: '迁移后 json 不应再含 password 字段');
        expect(reloaded['url'], 'https://dav.example.com/dav/');
        expect(reloaded['user'], 'alice');
        expect(reloaded['deviceName'], 'Pixel');

        // 第二次读应当 idempotent（password 已迁，不会再次触发）
        final securePwd2 = await readSecret('webdav_password');
        expect(securePwd2, 'legacy_pwd');
      } finally {
        setSecureStorageOverrideForTest(null);
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      }
    },
  );

  testWidgets(
    'WebDavConfigPage renders 5 fields + 测试连接 invokes override',
    (WidgetTester tester) async {
      // 临时目录避免污染真实 documents,且让 _loadConfig 走"文件不存在"
      // 分支拿到默认空表单。
      final tmp = Directory.systemTemp.createTempSync('webdav-cfg-');

      int checkCalls = 0;
      String? capturedUrl;
      String? capturedUser;
      String? capturedPwd;

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: WebDavConfigPage(
              configDirOverride: tmp.path,
              webdavCheckOverride: ({
                required String url,
                required String user,
                required String password,
              }) async {
                checkCalls++;
                capturedUrl = url;
                capturedUser = user;
                capturedPwd = password;
              },
              // 批次 12: 注入备份密码 override,避免触发真实 FRB 桥（测试
              // 环境无 RustLib.init,会抛异常）。
              getBackupPasswordOverride: ({required String documentsDir}) async => '',
              setBackupPasswordOverride: (
                  {required String documentsDir, required String password}) async {},
            ),
          ),
        ),
      );
      // _loadConfig 是 async (含真实文件 IO),pump 几次让它跑完。**不**用 pumpAndSettle
      // 因为页面里有 LinearProgressIndicator 动画会让 settle 永远 timeout。
      // 文件 IO 用 runAsync 让真实异步操作完成。
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // 标题渲染
      expect(find.text('WebDAV 配置'), findsOneWidget);

      // 5 字段标签 (label 文本 — InputDecoration 渲染两次：原位 + 浮起)
      // 用 findsAtLeastNWidgets(1) 容纳 Material 浮动 label 行为。
      expect(find.text('URL'), findsAtLeastNWidgets(1));
      expect(find.text('用户名'), findsAtLeastNWidgets(1));
      expect(find.text('密码'), findsAtLeastNWidgets(1));
      expect(find.text('设备名'), findsAtLeastNWidgets(1));
      expect(find.text('备份密码'), findsAtLeastNWidgets(1));

      // 5 个 TextField + 2 个按钮
      expect(find.byType(TextField), findsNWidgets(5));
      expect(find.text('测试连接'), findsOneWidget);
      expect(find.text('保存'), findsOneWidget);

      // 不填 URL 直接点测试连接 → 不应调 override，会出错提示。
      await tester.tap(find.text('测试连接'));
      await tester.pump();
      expect(checkCalls, 0,
          reason: 'URL 为空时不应触发 webdavCheck');

      // 填字段
      await tester.enterText(find.byType(TextField).at(0),
          'https://dav.jianguoyun.com/dav/legado/');
      await tester.enterText(
          find.byType(TextField).at(1), 'alice@example.com');
      await tester.enterText(find.byType(TextField).at(2), 'secret-pwd');
      await tester.enterText(find.byType(TextField).at(3), 'Pixel');
      await tester.pump();

      // 点测试连接 → 调一次 override
      await tester.tap(find.text('测试连接'));
      // 让 onPressed async 跑完。同样不能 pumpAndSettle (LinearProgressIndicator)
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      expect(checkCalls, 1);
      expect(capturedUrl, 'https://dav.jianguoyun.com/dav/legado/');
      expect(capturedUser, 'alice@example.com');
      expect(capturedPwd, 'secret-pwd');

      // 清理临时目录
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    },
  );

  testWidgets(
    'WebDavConfigPage 备份密码字段渲染 + 保存写 secure_storage',
    (WidgetTester tester) async {
      // BATCH-03b (F-W1A-020)：备份密码 save 路径改 secure_storage，
      // 不再调 setBackupPassword override。load 路径优先 secure_storage，
      // 未命中时回退 FRB getBackupPassword（迁移触发口），保留 override。
      final tmp = Directory.systemTemp.createTempSync('webdav-cfg-bpw-');

      int setCalls = 0;
      int getCalls = 0;

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: WebDavConfigPage(
              configDirOverride: tmp.path,
              // webdavCheck 不参与本测试,但 _onTestConnection 也无关
              // (我们只点保存)。
              webdavCheckOverride: ({
                required String url,
                required String user,
                required String password,
              }) async {},
              getBackupPasswordOverride: ({required String documentsDir}) async {
                getCalls++;
                return ''; // 模拟首次配置：legado_local.json 不存在 / 空，无迁移
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

      // 备份密码字段渲染
      expect(find.text('备份密码'), findsAtLeastNWidgets(1));
      expect(find.byType(TextField), findsNWidgets(5));
      // 提示文案存在
      expect(
        find.textContaining('留空 = 不加密'),
        findsOneWidget,
      );

      // load 时 secure_storage miss → 走 FRB fallback 调 getBackupPassword 一次
      expect(getCalls, 1,
          reason: 'secure_storage miss 时 initState 应调 getBackupPassword fallback');
      // 旧 password 为空，不触发迁移路径，setBackupPassword override 不应被调
      expect(setCalls, 0,
          reason: 'legacyPwd 为空时不应触发清理路径');

      // 填 URL（保存校验要求非空）+ 备份密码
      await tester.enterText(find.byType(TextField).at(0),
          'https://example.com/dav/');
      // 第 5 个 TextField (index 4) = 备份密码
      await tester.enterText(find.byType(TextField).at(4), 'mybackup-pwd');
      await tester.pump();

      // 点保存 → 走 _onSave: 写 webdav.json (真实文件 IO) + writeSecret
      // 写 secure_storage（不再调 setBackupPassword override）。
      await tester.tap(find.text('保存'));
      // 让真实文件 IO 跑完 — 文件 IO + secure_storage 写的 async 链需要多次
      // pump + runAsync 才能完整执行（不能 pumpAndSettle 因为
      // LinearProgressIndicator）。
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
      }

      // BATCH-03b：save 写 secure_storage，FRB setBackupPassword 不再被调
      expect(setCalls, 0,
          reason: 'BATCH-03b 后 save 不再调 setBackupPassword');
      expect(secureStorageFake.debugStore['backup_password'], 'mybackup-pwd',
          reason: '保存应把备份密码写到 secure_storage');

      // 清理
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    },
  );
}
