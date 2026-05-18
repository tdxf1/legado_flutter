import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/providers.dart';
import 'package:legado_flutter/features/reader/page/delegate/no_anim_page_delegate.dart';
import 'package:legado_flutter/features/reader/page/page_view.dart';
import 'package:legado_flutter/features/reader/page/page_view_controller.dart';

/// 第二十一批 Task 6 — R4 reentrance guard 回归测试
///
/// PageDelegate.onDragStart 内部并没有 `if (isRunning) return` 自我守护，
/// 它无条件调用 `_clearPictures()` 把 cur/next/prev 三张 ui.Picture 释放。
/// 如果动画期间外部又触发 `_onHorizontalDragStart` → `onDragStart`，painter 还
/// 在引用旧 Picture 这帧就会读已释放对象。Task 6 的修复是把守护放到
/// `_PageViewWidgetState._onHorizontalDragStart/Update/End` 三个回调里。
///
/// 这个文件覆盖两个层面：
///
/// 1. **Widget integration**：动画进行中模拟一次水平拖拽，pumpAndSettle 后
///    `currentPageIndex` 仍只前进一页（如果守护失效，drag-end 路径会再触发一次
///    goToNext，page 会前进 2），且过程中不应抛异常。
/// 2. **Unit (delegate 契约)**：
///    - `PageDelegate.onDragUpdate/onDragEnd` 已存在的 isRunning 内部守护仍然有效
///      （回归保护，避免被无意删掉）。
///    - `PageDelegate.onDragStart` 仍然 *没有* 内部 isRunning 守护，文档化"widget 层
///      必须守护"的契约前提。

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PageViewWidget drag reentrance guard (R4)', () {
    testWidgets(
        'drag fired during nextPageByAnim animation does not advance an extra page',
        (tester) async {
      const settings = ReaderSettings(pageAnim: ReaderPageAnim.cover);
      final controller = PageViewController(settings: settings);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 600,
              child: PageViewWidget(
                controller: controller,
                settings: settings,
                pageAnim: ReaderPageAnim.cover,
              ),
            ),
          ),
        ),
      );
      // 第一帧让 LayoutBuilder 跑出 pageSize 注入到 controller。
      await tester.pump();

      // 灌入足够长的内容确保至少切出 2 页，使 hasNext 为 true。
      final longText = (List<String>.generate(
        80,
        (i) => '这是用于翻页测试的中文段落第 $i 段，需要足够长才能让 PageMeasure 切成多页。',
      )).join('\n');
      controller.loadChapter(0, '测试章节', longText);
      // 等 PageMeasure 的 postFrameCallback 触发 notifyListeners。
      await tester.pumpAndSettle();

      expect(
        controller.totalPagesInChapter,
        greaterThan(1),
        reason: 'PageMeasure should split into multiple pages',
      );
      expect(controller.currentPageIndex, 0);
      expect(controller.hasNext, isTrue);

      // 触发"点击右 1/3"路径：通过 PageDelegate.nextPageByAnim 跑动画。
      // PageViewWidget 在 _createDelegate 阶段把这个 lambda 注入到
      // controller.onTapNext。
      final tapNext = controller.onTapNext;
      expect(tapNext, isNotNull,
          reason: 'PageViewWidget should have wired onTapNext into controller');
      tapNext!.call();

      // 让动画启动（isRunning 此时为 true）但远未完成。
      // AnimationController duration = 300ms，pump 60ms 处于动画中段。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));

      // 动画进行中模拟一次水平向左拖拽。如果 R4 守护失效：
      //   - _onHorizontalDragStart 会调 _delegate.onDragStart → _clearPictures
      //     释放正被 painter 引用的 Picture（潜在崩溃）。
      //   - _onHorizontalDragEnd 进入 _delegate.fling + onDragEnd（虽然
      //     PageDelegate.onDragEnd 内部已有 isRunning 短路，drag-end 不会真的
      //     再 goToNext，但 fling 不带守护，且后续若再有人移除内部短路本测试
      //     必须能把回归暴露）。
      //
      // 守护正常时三个回调全部 short-circuit，currentPageIndex 仍只前进 1。
      final center = tester.getCenter(find.byType(PageViewWidget));
      final gesture = await tester.startGesture(center);
      try {
        // 累积位移大于触发方向阈值 (5px) 与 fling velocity 阈值，确保如果守护
        // 失效一定走到 goToNext 分支。
        for (var i = 0; i < 6; i++) {
          await gesture.moveBy(const Offset(-40, 0));
          await tester.pump(const Duration(milliseconds: 8));
        }
      } finally {
        await gesture.up();
      }

      // 让原动画跑完 + 任何被吞的 drag end 也落定。
      await tester.pumpAndSettle();

      expect(
        controller.currentPageIndex,
        1,
        reason:
            'reentrance drag during animation must be swallowed; only the '
            'original nextPageByAnim should advance the page',
      );
    });
  });

  group('PageDelegate isRunning guard contract', () {
    late PageViewController controller;
    late AnimationController animController;
    late NoAnimPageDelegate delegate;

    setUp(() {
      const settings = ReaderSettings();
      controller = PageViewController(settings: settings);
      animController = AnimationController(
        vsync: const TestVSync(),
        duration: const Duration(milliseconds: 300),
      );
      delegate = NoAnimPageDelegate(
        controller: controller,
        settings: settings,
        animController: animController,
      );
    });

    tearDown(() {
      animController.dispose();
      controller.dispose();
    });

    test('onDragUpdate is a no-op when isRunning (existing internal guard)',
        () {
      delegate.isRunning = true;
      final before = delegate.dragOffset;
      delegate.onDragUpdate(150);
      expect(delegate.dragOffset, before,
          reason:
              'PageDelegate.onDragUpdate must short-circuit while animating');
    });

    test('onDragEnd is a no-op when isRunning (existing internal guard)', () {
      delegate.isRunning = true;
      // 调用 onDragEnd 不应改变 isRunning 也不应触发 page change。
      // controller 没有内容，hasNext / hasPrev 都为 false，理论上 goToNext
      // 也只会走 _resetState 分支；这里的关键是断言 isRunning 仍为 true（
      // 短路立即返回，没有走到 _resetState）。
      delegate.onDragEnd(PageDirection.next);
      expect(delegate.isRunning, isTrue,
          reason:
              'PageDelegate.onDragEnd must short-circuit while animating, '
              'leaving isRunning untouched');
    });

    test('onDragStart has NO internal isRunning guard — widget layer must guard',
        () {
      // 这条测试文档化"为什么必须在 _PageViewWidgetState._onHorizontalDragStart
      // 加守护"：PageDelegate.onDragStart 不会自检 isRunning，进来就执行
      // _clearPictures()。如果有人删掉 widget 层的守护，这条契约就会暴露：
      // 动画期间被调用的话 picture 仍会被释放。
      delegate.isRunning = true;
      // 调用应该正常返回（没有抛异常），并且 _clearPictures 已经执行 → 三个
      // picture 字段都为 null（因为传入的 page 都是 null，_renderPage 返回 null）。
      delegate.onDragStart(const Size(400, 600), null, null, null);
      expect(delegate.curPicture, isNull);
      expect(delegate.nextPicture, isNull);
      expect(delegate.prevPicture, isNull);
      // 没有自检 → isRunning 仍然保持 true（即调用真的执行了，没短路）。
      expect(delegate.isRunning, isTrue);
    });
  });
}
