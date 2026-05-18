import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/providers.dart';
import 'package:legado_flutter/features/reader/page/delegate/page_delegate.dart';
import 'package:legado_flutter/features/reader/page/page_view.dart';
import 'package:legado_flutter/features/reader/page/page_view_controller.dart';

/// 第二十四批 Task 4 — tap 翻页动画时长可配置（PRD R4.1..R4.8）
///
/// 覆盖 5 组用例：
/// 1. 默认值：`const ReaderSettings().pageAnimDurationMs == 300`（对齐 MD3）
/// 2. copyWith 透传 `pageAnimDurationMs`
/// 3. JSON round-trip 字段值保持
/// 4. v4 旧 JSON migrate → fallback 到 300（无破坏性迁移）
/// 5. PageViewWidget 内部 AnimationController.duration 跟随
///    `settings.pageAnimDurationMs` 变化（didUpdateWidget 路径）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReaderSettings.pageAnimDurationMs (R4.1)', () {
    test('默认值 300ms（对齐 Legado MD3 原版）', () {
      const s = ReaderSettings();
      expect(s.pageAnimDurationMs, 300);
    });

    test('构造时显式赋值生效', () {
      const s = ReaderSettings(pageAnimDurationMs: 700);
      expect(s.pageAnimDurationMs, 700);
    });
  });

  group('ReaderSettings.copyWith (R4.2)', () {
    test('copyWith({pageAnimDurationMs: 500}) 透传新值', () {
      const base = ReaderSettings();
      final s = base.copyWith(pageAnimDurationMs: 500);
      expect(s.pageAnimDurationMs, 500);
    });

    test('copyWith 不传 pageAnimDurationMs 时保持原值', () {
      const base = ReaderSettings(pageAnimDurationMs: 800);
      final s = base.copyWith(fontSize: 20);
      expect(s.pageAnimDurationMs, 800);
    });
  });

  group('ReaderSettings JSON 序列化 (R4.2 / R4.3 / R4.7)', () {
    test('toJson 写入 pageAnimDurationMs + settingsVersion 是当前版本', () {
      const s = ReaderSettings(pageAnimDurationMs: 600);
      final j = s.toJson();
      // 批次 1 (05-18): kReaderSettingsCurrentVersion 升到 6 后，老 v5 测试
      // 改为依赖常量值，避免今后每升一版都得回来改这里。
      expect(j['settingsVersion'], kReaderSettingsCurrentVersion);
      expect(j['pageAnimDurationMs'], 600);
    });

    test('round-trip：toJson → fromJson 字段值保持', () {
      const s = ReaderSettings(pageAnimDurationMs: 450);
      final s2 = ReaderSettings.fromJson(s.toJson());
      expect(s2.pageAnimDurationMs, 450);
    });

    test('v4 旧 JSON 缺省 pageAnimDurationMs → fallback 到 300', () {
      // v4 schema 没有 pageAnimDurationMs 字段，fromJson 应该回退到默认值。
      final s = ReaderSettings.fromJson({
        'settingsVersion': 4,
        'pageAnim': ReaderPageAnim.simulation,
        'fontSize': 18.0,
      });
      expect(s.pageAnimDurationMs, 300);
    });

    test('v3 / v2 / v1 旧 JSON 也回退到 300（迁移链不影响新字段）', () {
      for (final v in [1, 2, 3]) {
        final s = ReaderSettings.fromJson({
          'settingsVersion': v,
          'pageAnim': 0,
        });
        expect(s.pageAnimDurationMs, 300,
            reason: 'v$v 旧 JSON 应 fallback 到 300');
      }
    });

    test('kReaderSettingsCurrentVersion >= 5 (pageAnimDurationMs 引入版本 / 之后)', () {
      // 批次 1 (05-18): v5 引入 pageAnimDurationMs；v6 继续递增。这里只断
      // 言"≥ 5"避免与未来更高版本耦合。具体当前版本由 reader_settings_v6_test
      // 单独验证。
      expect(kReaderSettingsCurrentVersion, greaterThanOrEqualTo(5));
    });
  });

  group('PageViewWidget AnimationController.duration 跟随 settings (R4.4 / R4.5 / R4.8)',
      () {
    /// 构造 PageViewWidget；返回 (controller, _DelegateRef)。
    Future<(PageViewController, _DelegateRef)> buildWidget(
      WidgetTester tester,
      ReaderSettings settings,
    ) async {
      final controller = PageViewController(settings: settings);
      addTearDown(controller.dispose);
      final ref = _DelegateRef();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 600,
              child: PageViewWidget(
                controller: controller,
                settings: settings,
                pageAnim: settings.pageAnim,
                debugDelegateSink: (d) => ref.delegate = d,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(ref.delegate, isNotNull,
          reason: 'debugDelegateSink should fire on _createDelegate');
      return (controller, ref);
    }

    testWidgets('初始 duration = settings.pageAnimDurationMs', (tester) async {
      const settings = ReaderSettings(
        pageAnim: ReaderPageAnim.cover,
        pageAnimDurationMs: 500,
      );
      final (_, ref) = await buildWidget(tester, settings);

      expect(ref.delegate!.animController.duration,
          const Duration(milliseconds: 500));
    });

    testWidgets('didUpdateWidget 在 pageAnimDurationMs 变化时刷新 controller duration',
        (tester) async {
      const initial = ReaderSettings(
        pageAnim: ReaderPageAnim.cover,
        pageAnimDurationMs: 300,
      );
      final controller = PageViewController(settings: initial);
      addTearDown(controller.dispose);
      final ref = _DelegateRef();

      Widget buildHost(ReaderSettings s) => MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 400,
                height: 600,
                child: PageViewWidget(
                  controller: controller,
                  settings: s,
                  pageAnim: s.pageAnim,
                  debugDelegateSink: (d) => ref.delegate = d,
                ),
              ),
            ),
          );

      await tester.pumpWidget(buildHost(initial));
      await tester.pump();
      expect(ref.delegate!.animController.duration,
          const Duration(milliseconds: 300));

      // 调整 settings 触发 didUpdateWidget → _createDelegate 重建。
      const updated = ReaderSettings(
        pageAnim: ReaderPageAnim.cover,
        pageAnimDurationMs: 750,
      );
      await tester.pumpWidget(buildHost(updated));
      await tester.pump();

      expect(ref.delegate!.animController.duration,
          const Duration(milliseconds: 750),
          reason:
              'AnimationController duration 应跟随 settings.pageAnimDurationMs 变化');
    });
  });
}

/// 持有一个 PageDelegate 引用的小盒子（与 reader_simulation_tap_bezier_test 同样模式）。
class _DelegateRef {
  PageDelegate? delegate;
}
