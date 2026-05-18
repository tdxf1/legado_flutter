import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/providers.dart';
import 'package:legado_flutter/features/reader/page/delegate/page_delegate.dart';
import 'package:legado_flutter/features/reader/page/delegate/simulation_page_delegate.dart';
import 'package:legado_flutter/features/reader/page/page_view.dart';
import 'package:legado_flutter/features/reader/page/page_view_controller.dart';

/// 第二十二批 Task 3 — slop-startpoint 回归测试
///
/// 三组用例：
///
/// 1. **Unit `_calcCornerXY` (via `debugCalcCornerXY` 包装)** — 4 个角点 ×
///    4 个 startPoint 输入，确保仿真折角的几何输入正确。
/// 2. **Widget integration (slop 越过)** — 模拟 pointer down 在屏幕中央 → move
///    到屏幕一侧，越过 [kTouchSlop] 后 delegate.startTouch 必须是越过点而不是
///    down 点。
/// 3. **Widget integration (tap 路径不退化)** — 仅 down/up 不越过 slop，delegate
///    既不应触发 onDragStart 也不应进入 isRunning。

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SimulationPageDelegate._calcCornerXY 4 角点', () {
    late PageViewController controller;
    late AnimationController animController;
    late SimulationPageDelegate delegate;

    setUp(() {
      const settings = ReaderSettings(pageAnim: ReaderPageAnim.simulation);
      controller = PageViewController(settings: settings);
      animController = AnimationController(
        vsync: const TestVSync(),
        duration: const Duration(milliseconds: 300),
      );
      delegate = SimulationPageDelegate(
        controller: controller,
        settings: settings,
        animController: animController,
      );
    });

    tearDown(() {
      animController.dispose();
      controller.dispose();
    });

    test('startPoint=(50, 100), pageSize=(400, 600) → 左上 (0,0), notRtOrLb',
        () {
      delegate.debugCalcCornerXY(const Offset(50, 100), const Size(400, 600));
      expect(delegate.debugCornerX, 0);
      expect(delegate.debugCornerY, 0);
      expect(delegate.debugIsRtOrLb, isFalse,
          reason: '左上角不属于右上/左下对角线');
    });

    test('startPoint=(350, 100), pageSize=(400, 600) → 右上 (400,0), isRtOrLb',
        () {
      delegate.debugCalcCornerXY(const Offset(350, 100), const Size(400, 600));
      expect(delegate.debugCornerX, 400);
      expect(delegate.debugCornerY, 0);
      expect(delegate.debugIsRtOrLb, isTrue);
    });

    test('startPoint=(50, 500), pageSize=(400, 600) → 左下 (0,600), isRtOrLb',
        () {
      delegate.debugCalcCornerXY(const Offset(50, 500), const Size(400, 600));
      expect(delegate.debugCornerX, 0);
      expect(delegate.debugCornerY, 600);
      expect(delegate.debugIsRtOrLb, isTrue);
    });

    test(
        'startPoint=(350, 500), pageSize=(400, 600) → 右下 (400,600), notRtOrLb',
        () {
      delegate.debugCalcCornerXY(const Offset(350, 500), const Size(400, 600));
      expect(delegate.debugCornerX, 400);
      expect(delegate.debugCornerY, 600);
      expect(delegate.debugIsRtOrLb, isFalse);
    });
  });

  group('PageViewWidget Listener slop state machine', () {
    /// 构造一个有内容的 simulation-mode PageViewWidget；返回 (controller, delegate ref)。
    Future<(PageViewController, _DelegateRef)> _buildWidget(
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

      // 灌足够长内容，多页可翻。
      final longText = (List<String>.generate(
        80,
        (i) => '这是用于翻页测试的中文段落第 $i 段，需要足够长才能让 PageMeasure 切成多页。',
      )).join('\n');
      controller.loadChapter(0, '测试章节', longText);
      await tester.pumpAndSettle();

      expect(ref.delegate, isNotNull,
          reason: 'debugDelegateSink should fire on _createDelegate');
      return (controller, ref);
    }

    testWidgets(
        'slop 越过：startTouch 是越过点而非 down 点 (move-left → next direction)',
        (tester) async {
      final (controller, ref) = await _buildWidget(tester);
      expect(controller.totalPagesInChapter, greaterThan(1));

      final delegate = ref.delegate!;
      // down 在屏幕中心；move 到左侧 50px (> kTouchSlop 18)。
      const downAt = Offset(200, 300);

      final gesture = await tester.startGesture(downAt);
      // 一次 moveBy 18+1=19 像素就跨过 slop；额外再多移动一点确保 onDragUpdate
      // 也跑过一遍。
      await gesture.moveBy(const Offset(-19, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump();

      // R3.2: startTouch 应是 slop 越过那一刻位置 (199 ≈ 200 - 19, 300)，
      // 不应等于 down 点 (200, 300)。
      expect(delegate.startTouch, isNot(equals(downAt)),
          reason: 'startTouch 不应等于 pointer-down 坐标');
      // 只看 dx：down 时 200，slop 越过那一帧 ≈ 181 (200 - 19)。
      expect(delegate.startTouch.dx, lessThan(200),
          reason: 'slop-crossed dx 必须比 down dx 小（向左移动）');

      // 也验证最后 currentTouch 跟踪到第二次 moveBy 之后的位置（约 200-49=151）。
      expect(delegate.currentTouch.dx, lessThan(delegate.startTouch.dx),
          reason: 'currentTouch 应跟随后续 move 累积位移');

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('slop 越过 (move-right → prev direction)', (tester) async {
      final (controller, ref) = await _buildWidget(tester);
      // 翻到第 2 页让 hasPrev = true，以便走 prev 方向分支
      controller.jumpToPage(1);
      await tester.pumpAndSettle();
      expect(controller.hasPrev, isTrue);

      final delegate = ref.delegate!;
      const downAt = Offset(200, 300);

      final gesture = await tester.startGesture(downAt);
      await gesture.moveBy(const Offset(19, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();

      expect(delegate.startTouch, isNot(equals(downAt)));
      expect(delegate.startTouch.dx, greaterThan(200),
          reason: 'slop-crossed 在右移路径上 dx 应大于 down dx');

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('tap 路径不退化：down + up 但不移动，不触发 onDragStart',
        (tester) async {
      final (_, ref) = await _buildWidget(tester);
      final delegate = ref.delegate!;

      // 初始：startTouch 没被设过，应为 Offset.zero；isRunning false。
      expect(delegate.startTouch, Offset.zero);
      expect(delegate.isRunning, isFalse);

      // 模拟单纯的 tap：down + up，无 move。
      final gesture = await tester.startGesture(const Offset(200, 300));
      await tester.pump(const Duration(milliseconds: 10));
      await gesture.up();
      await tester.pumpAndSettle();

      // 没越过 slop → 不应调 _delegate.recordTouchStart / onDragStart。
      // startTouch 仍是初始 (0,0)；direction 仍是 none；isRunning 仍 false。
      expect(delegate.startTouch, Offset.zero,
          reason: 'tap 不应改变 startTouch');
      expect(delegate.direction, PageDirection.none,
          reason: 'tap 不应触发翻页');
      expect(delegate.isRunning, isFalse);
    });

    testWidgets('slop 未越过：micro-move (< kTouchSlop) 不触发 onDragStart',
        (tester) async {
      final (_, ref) = await _buildWidget(tester);
      final delegate = ref.delegate!;

      final gesture = await tester.startGesture(const Offset(200, 300));
      // 故意小于 kTouchSlop (18px) 的位移：5px。
      await gesture.moveBy(const Offset(5, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(delegate.startTouch, Offset.zero,
          reason: 'sub-slop move 不应触发 recordTouchStart');
      expect(delegate.isRunning, isFalse);
    });

    testWidgets('多指：第二指 events 被忽略（只跟踪 primary pointer）',
        (tester) async {
      final (_, ref) = await _buildWidget(tester);
      final delegate = ref.delegate!;

      // primary：在中央 down，越过 slop 向左拖。
      final primary = await tester.startGesture(const Offset(200, 300));
      await primary.moveBy(const Offset(-25, 0));
      await tester.pump();

      final pxAfterPrimaryMove = delegate.currentTouch.dx;

      // secondary：从 (50, 100) down 然后大幅移动；此时 primary 仍持着。
      final secondary = await tester.startGesture(const Offset(50, 100));
      await secondary.moveBy(const Offset(-200, 0));
      await tester.pump();

      // currentTouch 不应被 secondary 干扰。
      expect(delegate.currentTouch.dx, pxAfterPrimaryMove,
          reason: 'secondary pointer 移动不应污染 primary 的 currentTouch');

      await secondary.up();
      await primary.up();
      await tester.pumpAndSettle();
    });

    testWidgets(
        'cancel-after-slop：onDragStart 已跑过 → cancel 必须复位 delegate '
        '（dragOffset/direction/picture）',
        (tester) async {
      final (_, ref) = await _buildWidget(tester);
      final delegate = ref.delegate!;

      // 1) 越过 slop 触发 onDragStart + 多次 onDragUpdate，让 delegate 内
      //    `_dragOffset` 累积、`_direction` 被设为 next、picture 被分配。
      final gesture = await tester.startGesture(const Offset(200, 300));
      await gesture.moveBy(const Offset(-25, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump();

      // sanity：drag 已经在跑（direction 已经被 onDragUpdate 推到 next）。
      expect(delegate.direction, PageDirection.next,
          reason: '左拖累计 > 5 px 应触发 next 方向');
      expect(delegate.dragOffset.abs(), greaterThan(5),
          reason: 'dragOffset 应被 onDragUpdate 累积');
      expect(delegate.curPicture, isNotNull,
          reason: 'onDragStart 应已分配 curPicture');

      // 2) Cancel 而不是 up（模拟 PointerCancel：触摸被系统抢走、scroll
      //    parent 接管手势等场景）。
      await gesture.cancel();
      await tester.pumpAndSettle();

      // 3) cancel 之后，delegate 必须完全复位 — 否则下一次 drag 会从 stale
      //    `_dragOffset` / `_direction` 起跳，出现"半页 ghost progress"。
      expect(delegate.direction, PageDirection.none,
          reason: 'cancelDrag 必须把 _direction 复位到 none');
      expect(delegate.dragOffset, 0,
          reason: 'cancelDrag 必须把 _dragOffset 清零');
      expect(delegate.isRunning, isFalse);
      expect(delegate.curPicture, isNull,
          reason: 'cancelDrag 必须释放预渲染 picture');
      expect(delegate.nextPicture, isNull);
      expect(delegate.prevPicture, isNull);
    });
  });
}

/// 持有一个 PageDelegate 引用的小盒子，避免在 closure 里直接捕获 late 变量。
class _DelegateRef {
  PageDelegate? delegate;
}
