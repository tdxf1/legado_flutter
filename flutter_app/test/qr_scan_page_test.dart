import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/features/qr/qr_scan_page.dart';

/// 批次 20 (05-19): QR 扫码页 widget 测试。
///
/// 通过 [QrScanPage] 的 *Override 钩子注入假扫描结果 + 假 import 实现，
/// 绕过 mobile_scanner 真相机 / FRB 桥 / dio HTTP，验证：
/// 1. AppBar 标题
/// 2. scanResultOverride 注入"识别为 bookSource"协议 → 弹"确认导入" dialog
/// 3. dialog 显示类型 / URL 字符串
void main() {
  testWidgets('QrScanPage shows AppBar title', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: QrScanPage(
            // 测试模式：跳过真实相机
            scanResultOverride: 'invalid-noop',
            dbPathOverride: '/tmp/legado-test.db',
          ),
        ),
      ),
    );
    // pump 一次让 PostFrameCallback 跑（会触发 _onDetect → 未识别 dialog）
    await tester.pump();
    expect(find.text('扫码导入'), findsOneWidget);
  });

  testWidgets(
      'scanResultOverride with legado bookSource protocol shows confirm dialog',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: QrScanPage(
            scanResultOverride:
                'legado://import/bookSource?src=https://example.com/x.json',
            dbPathOverride: '/tmp/legado-test.db',
          ),
        ),
      ),
    );
    // pumpAndSettle 让 PostFrameCallback + showDialog 全部 settle
    await tester.pumpAndSettle();
    // AlertDialog "确认导入"
    expect(find.text('确认导入'), findsOneWidget);
    // 类型行
    expect(find.text('类型：书源'), findsOneWidget);
    // URL 行（SelectableText）
    expect(find.text('https://example.com/x.json'), findsOneWidget);
    // 操作按钮
    expect(find.text('导入'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
  });

  testWidgets('unrecognized scan result shows error dialog with raw text',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: QrScanPage(
            scanResultOverride: 'random-text-not-a-protocol',
            dbPathOverride: '/tmp/legado-test.db',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('未识别为 Legado 协议'), findsOneWidget);
    expect(find.text('random-text-not-a-protocol'), findsOneWidget);
  });

  testWidgets(
      'permissionDeniedOverride=true → 显示拒绝 UI + 系统设置引导文案',
      (WidgetTester tester) async {
    // BATCH-05 (F-W2B-058): 注入"权限被拒"状态测试。
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: QrScanPage(
            permissionDeniedOverride: true,
            dbPathOverride: '/tmp/legado-test.db',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('相机权限被拒绝'), findsOneWidget);
    expect(find.textContaining('系统设置'), findsOneWidget);
    expect(find.text('返回'), findsOneWidget);
    // 不显示扫码界面文案
    expect(find.text('将二维码对准框内'), findsNothing);
  });

  testWidgets(
      'legado:// with file:// src is rejected as unrecognized (BATCH-05)',
      (WidgetTester tester) async {
    // BATCH-05 (F-W2B-002): scheme 白名单 —— file:// 经 protocol parser
    // 校验后被当成"未识别"，弹未识别 dialog。
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: QrScanPage(
            scanResultOverride:
                'legado://import/bookSource?src=file:///etc/passwd',
            dbPathOverride: '/tmp/legado-test.db',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 越界 scheme 走 parseLegadoQrPayload 返 null → 未识别 dialog
    expect(find.text('未识别为 Legado 协议'), findsOneWidget);
  });

  testWidgets(
      'confirm dialog shows SSRF warning for private host (BATCH-05)',
      (WidgetTester tester) async {
    // BATCH-05 (F-W2B-002): rfc1918 host 触发警告。
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: QrScanPage(
            scanResultOverride:
                'legado://import/bookSource?src=http://192.168.1.1/x.json',
            dbPathOverride: '/tmp/legado-test.db',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('确认导入'), findsOneWidget);
    // host class 警告
    expect(find.textContaining('内网/本地地址'), findsOneWidget);
  });

  testWidgets(
      'confirm dialog has NO SSRF warning for public host (BATCH-05)',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: QrScanPage(
            scanResultOverride:
                'legado://import/bookSource?src=https://example.com/x.json',
            dbPathOverride: '/tmp/legado-test.db',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('确认导入'), findsOneWidget);
    expect(find.textContaining('内网/本地地址'), findsNothing);
  });
}
