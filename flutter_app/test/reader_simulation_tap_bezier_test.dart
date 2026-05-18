import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/providers.dart';
import 'package:legado_flutter/features/reader/page/delegate/page_delegate.dart';
import 'package:legado_flutter/features/reader/page/delegate/simulation_page_delegate.dart';
import 'package:legado_flutter/features/reader/page/page_view.dart';
import 'package:legado_flutter/features/reader/page/page_view_controller.dart';

/// 第二十三批 Task 5 — tap 仿真翻页走完整贝塞尔的回归测试
///
/// 删除 `_coverFallback` 后，[SimulationPageDelegate.nextPageByAnim] /
/// [SimulationPageDelegate.prevPageByAnim] 必须合成虚拟起点并手动调用
/// `_calcCornerXY`，让 [SimulationPageDelegate.draw] 走完整贝塞尔几何。
/// 该文件覆盖 4 组用例：
///
/// 1. tap → next 合成右下角虚拟起点 → cornerX = w / cornerY = h / isRtOrLb = false
/// 2. tap → prev 合成左下角虚拟起点 → cornerX = 0 / cornerY = h / isRtOrLb = true
/// 3. tap → next pumpAndSettle 后 currentPageIndex 前进 1
/// 4. tap → 动画进行中再 tap：第二次 tap 被 `isRunning` guard 吞掉，
///    pumpAndSettle 后页码仍只前进 1（不是 2）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 构造一个有内容的 simulation-mode PageViewWidget；返回 (controller, delegate ref)。
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
    expect(controller.totalPagesInChapter, greaterThan(1),
        reason: 'PageMeasure should split into multiple pages');
    return (controller, ref);
  }

  group('SimulationPageDelegate tap → 完整贝塞尔几何', () {
    testWidgets('tap next：合成右下角虚拟起点 (cornerX=w, cornerY=h, !isRtOrLb)',
        (tester) async {
      final (controller, ref) = await buildWidget(tester);
      final delegate = ref.delegate! as SimulationPageDelegate;

      expect(controller.hasNext, isTrue);

      // 直接调 delegate.nextPageByAnim 模拟"点击屏幕右 1/3"路径。
      delegate.nextPageByAnim(300);
      await tester.pump();

      // R5.2 / R5.6: 虚拟起点 (0.9w, 0.9h) = (360, 540) 落在右下半区
      // → cornerX = w (400), cornerY = h (600), isRtOrLb = false
      expect(delegate.debugCornerX, 400,
          reason: '右下半区的虚拟起点应映射到右边角 cornerX = pageSize.width');
      expect(delegate.debugCornerY, 600,
          reason: '右下半区的虚拟起点应映射到下边角 cornerY = pageSize.height');
      expect(delegate.debugIsRtOrLb, isFalse,
          reason: '右下角不属于右上/左下对角线');

      // 让动画跑完，避免污染下一个 test。
      await tester.pumpAndSettle();
    });

    testWidgets('tap prev：MD3 镜像 cornerXY 锚右下 (cornerX=w, cornerY=h, !isRtOrLb)',
        (tester) async {
      final (controller, ref) = await buildWidget(tester);
      // 先翻到第 2 页让 hasPrev = true
      controller.jumpToPage(1);
      await tester.pumpAndSettle();
      expect(controller.hasPrev, isTrue);

      final delegate = ref.delegate! as SimulationPageDelegate;

      delegate.prevPageByAnim(300);
      await tester.pump();

      // T2 (05-18): 对齐 MD3 SimulationPageDelegate.setDirection(PREV)
      // L188-L206 的镜像逻辑。tap prev 触发后 cornerXY 应该锚到右下角
      // (w, h)（与 next 共用支点），让"上一页"动画视觉上像 next 的反向
      // 镜像（活页书"翻过去盖回来"）。
      expect(delegate.debugCornerX, 400,
          reason: 'PREV 方向镜像后 cornerX 应为 pageSize.width');
      expect(delegate.debugCornerY, 600,
          reason: 'PREV 方向 cornerY 应为 pageSize.height');
      expect(delegate.debugIsRtOrLb, isFalse,
          reason: 'cornerXY = (w, h) 属于右下角，isRtOrLb 应为 false');

      await tester.pumpAndSettle();
    });

    testWidgets('tap next pumpAndSettle 后 currentPageIndex 前进 1',
        (tester) async {
      final (controller, ref) = await buildWidget(tester);
      expect(controller.currentPageIndex, 0);

      final delegate = ref.delegate! as SimulationPageDelegate;
      delegate.nextPageByAnim(300);

      // 动画启动后还没走完。
      await tester.pump();
      expect(delegate.isRunning, isTrue,
          reason: 'tap 触发动画后 isRunning 应为 true');

      // 跑完动画 → page advance。
      await tester.pumpAndSettle();
      expect(controller.currentPageIndex, 1,
          reason: 'tap 完成后页码应前进一页');
      expect(delegate.isRunning, isFalse,
          reason: '动画完成后 isRunning 应回到 false');
    });

    testWidgets(
        'tap 重入被吞：动画进行中再 tap 不会前进 2 页 (isRunning guard)',
        (tester) async {
      final (controller, ref) = await buildWidget(tester);
      expect(controller.currentPageIndex, 0);

      final delegate = ref.delegate! as SimulationPageDelegate;
      delegate.nextPageByAnim(300);
      await tester.pump();

      // AnimationController duration = 300ms，pump 100ms 处于动画中段。
      await tester.pump(const Duration(milliseconds: 100));
      expect(delegate.isRunning, isTrue,
          reason: '第一次 tap 触发的动画此时仍在跑');

      // 动画进行中再次 tap → 应被早 return。
      delegate.nextPageByAnim(300);
      await tester.pump();
      expect(delegate.isRunning, isTrue,
          reason: '第二次 tap 应被吞掉（isRunning guard），动画状态不变');

      await tester.pumpAndSettle();
      expect(controller.currentPageIndex, 1,
          reason: '只有第一次 tap 应推进页码，第二次被吞');
    });
  });
}

/// 持有一个 PageDelegate 引用的小盒子，避免在 closure 里直接捕获 late 变量。
class _DelegateRef {
  PageDelegate? delegate;
}
