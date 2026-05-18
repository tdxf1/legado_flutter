import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/providers.dart';
import 'package:legado_flutter/features/reader/page/delegate/cover_page_delegate.dart';
import 'package:legado_flutter/features/reader/page/delegate/no_anim_page_delegate.dart';
import 'package:legado_flutter/features/reader/page/delegate/page_delegate.dart';
import 'package:legado_flutter/features/reader/page/delegate/simulation_page_delegate.dart';
import 'package:legado_flutter/features/reader/page/page_view.dart';
import 'package:legado_flutter/features/reader/page/page_view_controller.dart';

/// Task X1 — 仿真翻页 currentTouch 真正动起来回归测试
///
/// 修复用户实测的 3 个同源 bug：
///   - Bug E: tap 仿真翻页只看到右下角折一点
///   - Bug D: drag 仿真要拖几乎一屏才翻页
///   - Bug B: 动画期间显示前页（仿真模式表现）
///
/// 覆盖：
///   1. tap → onAnimTick 在动画期间推进 currentTouch（X1.4 + X1.7）
///   2. tap prev 同上（X1.5 + X1.7）
///   3. drag → 松手后从松手位置 lerp 到目标，progress 归一化（X1.6 + X1.7）
///   4. PageDelegate.onAnimTick 默认空实现：cover/noAnim 不抛异常（X1.1）
///   5. cancelDrag / onAnimEnd 清 lerp 字段（X1.9）
///   6. tap 动画结束后 currentTouch 接近目标 (-w, h)（X1.7 收尾）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 构造一个 simulation-mode PageViewWidget，灌入多页内容；返回 controller
  /// 与 delegate ref。pageSize 为 400x600。
  Future<(PageViewController, _DelegateRef)> buildWidget(
      WidgetTester tester) async {
    const settings = ReaderSettings(pageAnim: ReaderPageAnim.simulation);
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
              pageAnim: ReaderPageAnim.simulation,
              debugDelegateSink: (d) => ref.delegate = d,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final longText = (List<String>.generate(
      80,
      (i) => '这是用于翻页测试的中文段落第 $i 段，需要足够长才能让 PageMeasure 切成多页。',
    )).join('\n');
    controller.loadChapter(0, '测试章节', longText);
    await tester.pumpAndSettle();

    expect(ref.delegate, isNotNull,
        reason: 'debugDelegateSink should fire on _createDelegate');
    expect(controller.totalPagesInChapter, greaterThan(1));
    return (controller, ref);
  }

  group('SimulationPageDelegate onAnimTick — tap 路径 lerp currentTouch', () {
    testWidgets(
        'tap next：动画中段 currentTouch.dx 应从 0.9w 减少（lerp 向 -w 推进）',
        (tester) async {
      final (_, ref) = await buildWidget(tester);
      final delegate = ref.delegate! as SimulationPageDelegate;

      // tap 触发 nextPageByAnim → 设虚拟起点 (0.9*400, 0.9*600) = (360, 540)
      delegate.nextPageByAnim(300);
      await tester.pump();

      // X1.4 + X1.7：lerp 起跑状态
      expect(delegate.debugAnimStartTouch, const Offset(360, 540),
          reason: 'tap next 起点应为虚拟起点 (0.9w, 0.9h)');
      expect(delegate.debugAnimTargetTouch, const Offset(-400, 600),
          reason: 'tap next 终点应为屏幕左外侧底边 (-w, h)');
      expect(delegate.debugAnimStartProgress, 0.0,
          reason: 'tap 路径 progress 起跑值应为 0');

      // 跑到大约 1/3 的动画时间 (300ms duration → 100ms)；currentTouch 应已
      // 明显从 (360, 540) 向 (-400, 600) lerp 推进。
      await tester.pump(const Duration(milliseconds: 100));
      expect(delegate.currentTouch.dx, lessThan(360),
          reason: 'tap next 动画推进后 currentTouch.dx 应小于虚拟起点 0.9w');

      await tester.pumpAndSettle();
    });

    testWidgets(
        'tap next 完成后 currentTouch 接近终点 (-w, h)（onAnimTick(1.0) lerp 到末值）',
        (tester) async {
      final (_, ref) = await buildWidget(tester);
      final delegate = ref.delegate! as SimulationPageDelegate;

      delegate.nextPageByAnim(300);
      // 跑到接近 1.0 但还没触发 then(_resetState) 的中间帧 — 用 pump 295ms
      // 让 progress ≈ 0.98+，期间 onAnimTick 已多次被调，currentTouch 已 lerp
      // 接近终点；_resetState 会在 forward 完成的微任务里清 controller 但
      // **不**清 currentTouch（recordTouchUpdate 已经写过最后值）。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 295));

      final cur = delegate.currentTouch;
      // easeOut(0.98) ≈ 0.9996，几乎就是终点
      expect(cur.dx, lessThan(0),
          reason: 'tap next 动画末段 currentTouch.dx 应已越过 0 推进到屏外');

      await tester.pumpAndSettle();
    });

    testWidgets('tap prev：起点 (0, h)，终点 (w, h)，currentTouch.dx 推向 +w',
        (tester) async {
      final (controller, ref) = await buildWidget(tester);
      // 翻到第 2 页让 hasPrev = true
      controller.jumpToPage(1);
      await tester.pumpAndSettle();
      expect(controller.hasPrev, isTrue);

      final delegate = ref.delegate! as SimulationPageDelegate;
      delegate.prevPageByAnim(300);
      await tester.pump();

      // T2 (05-18): 对齐 MD3 setDirection(PREV) → setStartPoint(0, h)；
      // 触摸点起点是屏幕左下角 (0, h)，终点放到屏外右侧 (2w, h)（避免与
      // cornerXY=(w, h) 重合时 _calcPoints 触发 0/0 NaN，视觉效果不变）。
      expect(delegate.debugAnimStartTouch, const Offset(0, 600),
          reason: 'tap prev 起点应为屏幕左下 (0, h)');
      expect(delegate.debugAnimTargetTouch, const Offset(800, 600),
          reason: 'tap prev 终点应为屏外右侧 (2w, h) 避开 corner 奇点');

      await tester.pump(const Duration(milliseconds: 100));
      expect(delegate.currentTouch.dx, greaterThan(0),
          reason: 'tap prev 动画推进后 currentTouch.dx 应大于起点 0');

      await tester.pumpAndSettle();
    });
  });

  group('SimulationPageDelegate onAnimTick — drag-end 路径 lerp', () {
    testWidgets(
        'drag → up：lerp 起点是松手位置，终点 (-w, h)，progress 归一化',
        (tester) async {
      final (_, ref) = await buildWidget(tester);
      final delegate = ref.delegate! as SimulationPageDelegate;

      // 模拟 drag：down 在中央 → 向左 80px（远超 kTouchSlop 18px）→ up
      final gesture = await tester.startGesture(const Offset(200, 300));
      await gesture.moveBy(const Offset(-25, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-55, 0));
      await tester.pump();

      // 松手前 currentTouch 应被 recordTouchUpdate 推进，progress 也已被
      // onDragUpdate 累加（80/400=0.2，但 slop 越过那一帧没累 update）。
      final touchBeforeUp = delegate.currentTouch;
      expect(touchBeforeUp.dx, lessThan(200),
          reason: 'drag 期间 currentTouch 应跟随手指向左移');
      final progressBeforeUp = delegate.dragOffset.abs() / 400.0;
      expect(progressBeforeUp, greaterThan(0));

      await gesture.up();
      // up 触发 onDragEnd → goToNext → _setupDragAnim 写入 lerp 状态
      await tester.pump();

      // X1.6: drag-end 起点应是松手位置，progress 起跑是松手时 controller value
      expect(delegate.debugAnimStartTouch, isNotNull);
      expect(delegate.debugAnimTargetTouch, const Offset(-400, 600),
          reason: 'drag-end next 终点应为 (-w, h)');
      // 松手时 _animStartTouch 应等于松手位置（即上一帧的 currentTouch）
      // 注意：onDragUpdate 期间 animController.value 已被推进，所以
      // _animStartProgress > 0
      expect(delegate.debugAnimStartProgress, greaterThan(0.0),
          reason: 'drag-end 起跑 progress 应大于 0（drag 期间已推进）');

      await tester.pumpAndSettle();
    });
  });

  group('PageDelegate.onAnimTick 默认空实现', () {
    test('NoAnimPageDelegate.onAnimTick(0.5) 不抛异常', () {
      const settings = ReaderSettings();
      final controller = PageViewController(settings: settings);
      addTearDown(controller.dispose);
      final animController = AnimationController(
        vsync: const TestVSync(),
        duration: const Duration(milliseconds: 300),
      );
      addTearDown(animController.dispose);

      final delegate = NoAnimPageDelegate(
        controller: controller,
        settings: settings,
        animController: animController,
      );
      addTearDown(delegate.dispose);

      // 默认空实现 — 调用不应抛异常，也不应改 currentTouch（仍是初始 zero）
      expect(() => delegate.onAnimTick(0.0), returnsNormally);
      expect(() => delegate.onAnimTick(0.5), returnsNormally);
      expect(() => delegate.onAnimTick(1.0), returnsNormally);
      expect(delegate.currentTouch, Offset.zero,
          reason: 'NoAnim 不 override onAnimTick，currentTouch 不应被动到');
    });

    test('CoverPageDelegate.onAnimTick / onAnimEnd 默认空实现可调', () {
      const settings = ReaderSettings(pageAnim: ReaderPageAnim.cover);
      final controller = PageViewController(settings: settings);
      addTearDown(controller.dispose);
      final animController = AnimationController(
        vsync: const TestVSync(),
        duration: const Duration(milliseconds: 300),
      );
      addTearDown(animController.dispose);

      final delegate = CoverPageDelegate(
        controller: controller,
        settings: settings,
        animController: animController,
      );
      addTearDown(delegate.dispose);

      expect(() => delegate.onAnimTick(0.5), returnsNormally);
      expect(() => delegate.onAnimEnd(), returnsNormally);
    });
  });

  group('SimulationPageDelegate cancelDrag / onAnimEnd 清 lerp 字段', () {
    testWidgets('cancelDrag 后 _animStartTouch / _animTargetTouch 清 null',
        (tester) async {
      final (_, ref) = await buildWidget(tester);
      final delegate = ref.delegate! as SimulationPageDelegate;

      // 模拟 drag-then-cancel：先越过 slop 进入 onDragStart，然后 cancel。
      final gesture = await tester.startGesture(const Offset(200, 300));
      await gesture.moveBy(const Offset(-25, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump();

      // 此时 cancel 之前 _animStartTouch 还没设过（drag 还在拖，没到 goToNext）
      // 所以这里测的是：cancelDrag 路径不会因为没有 lerp 状态而抛异常，
      // 并且 cancel 后字段保持 null（即原本就没有，cancel 后也没有）
      await gesture.cancel();
      await tester.pumpAndSettle();

      expect(delegate.debugAnimStartTouch, isNull,
          reason: 'cancelDrag 后 _animStartTouch 应为 null');
      expect(delegate.debugAnimTargetTouch, isNull,
          reason: 'cancelDrag 后 _animTargetTouch 应为 null');
      expect(delegate.debugAnimStartProgress, 0.0);
    });

    testWidgets(
        'tap 动画完成后 onAnimEnd 触发：lerp 字段被清空（避免下次 drag goToNext guard 误判）',
        (tester) async {
      final (_, ref) = await buildWidget(tester);
      final delegate = ref.delegate! as SimulationPageDelegate;

      delegate.nextPageByAnim(300);
      await tester.pump();
      // 动画进行中：lerp 字段非 null
      expect(delegate.debugAnimStartTouch, isNotNull);
      expect(delegate.debugAnimTargetTouch, isNotNull);

      await tester.pumpAndSettle();
      // 动画完成 → onAnimEnd 清空字段
      expect(delegate.debugAnimStartTouch, isNull,
          reason: 'onAnimEnd 应清 _animStartTouch');
      expect(delegate.debugAnimTargetTouch, isNull,
          reason: 'onAnimEnd 应清 _animTargetTouch');
      expect(delegate.debugAnimStartProgress, 0.0,
          reason: 'onAnimEnd 应清 _animStartProgress');
    });
  });

  group('Painter currentTouch 触发重绘（X1.10/X1.11）', () {
    testWidgets(
        'simulation tap 期间 currentTouch 在不同帧不同：painter 实际有重绘',
        (tester) async {
      final (_, ref) = await buildWidget(tester);
      final delegate = ref.delegate! as SimulationPageDelegate;

      delegate.nextPageByAnim(300);
      await tester.pump();
      final t0 = delegate.currentTouch;
      await tester.pump(const Duration(milliseconds: 50));
      final t1 = delegate.currentTouch;
      await tester.pump(const Duration(milliseconds: 100));
      final t2 = delegate.currentTouch;

      // 不同帧 currentTouch 应不同（onAnimTick lerp 推进）
      expect(t1.dx, lessThan(t0.dx),
          reason: '50ms 后 currentTouch.dx 应小于初始（向左推进）');
      expect(t2.dx, lessThan(t1.dx),
          reason: '再 100ms 后 currentTouch.dx 应继续向左推进');

      await tester.pumpAndSettle();
    });
  });
}

/// 持有一个 PageDelegate 引用的小盒子。
class _DelegateRef {
  PageDelegate? delegate;
}
