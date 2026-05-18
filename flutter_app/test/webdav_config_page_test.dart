import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/features/settings/webdav_config_page.dart';

/// 批次 11 (05-19): WebDAV 配置页 widget 测试。
///
/// 通过 [WebDavConfigPage] 的 *Override 测试钩子注入 fake 实现，绕过
/// path_provider / FRB 桥，验证：
/// 1. 页面渲染 4 个 TextField (URL/用户名/密码/设备名) + 测试连接 + 保存按钮。
/// 2. 点 "测试连接" 在 URL 已填时调一次 [`webdavCheckOverride`]。
void main() {
  testWidgets(
    'WebDavConfigPage renders 4 fields + 测试连接 invokes override',
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

      // 4 字段标签 (label 文本 — InputDecoration 渲染两次：原位 + 浮起)
      // 用 findsAtLeastNWidgets(1) 容纳 Material 浮动 label 行为。
      expect(find.text('URL'), findsAtLeastNWidgets(1));
      expect(find.text('用户名'), findsAtLeastNWidgets(1));
      expect(find.text('密码'), findsAtLeastNWidgets(1));
      expect(find.text('设备名'), findsAtLeastNWidgets(1));

      // 4 个 TextField + 2 个按钮
      expect(find.byType(TextField), findsNWidgets(4));
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
}
