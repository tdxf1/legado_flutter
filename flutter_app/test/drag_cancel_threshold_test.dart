import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/providers.dart';
import 'package:legado_flutter/features/reader/page/delegate/no_anim_page_delegate.dart';
import 'package:legado_flutter/features/reader/page/page_view_controller.dart';

/// T4 (05-18) — drag 拖拽回滚阈值（last-frame 微动方向）回归测试。
///
/// 对齐 MD3 HorizontalPageDelegate.onScroll 的 isCancel 语义：每帧
/// onDragUpdate 比较当前 delta 与翻页方向，朝翻页反向移动 → cancel；
/// 松手时 onDragEnd 看 _dragCancel 决定 reverse 回滚 vs forward 翻页。
///
/// 用 NoAnimPageDelegate 作为最简 delegate（只关心父类 onDragUpdate /
/// onDragEnd / _dragCancel 状态机，不依赖 draw 几何）。

const _kPageSize = Size(400, 600);

String _longContent(int paragraphs) {
  return List<String>.generate(
    paragraphs,
    (i) =>
        '这是用于翻页测试的中文段落第 $i 段，需要足够长才能让 PageMeasure 切成多页。',
  ).join('\n');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PageDelegate._dragCancel onDragUpdate last-frame 微动方向', () {
    late PageViewController controller;
    late AnimationController animController;
    late NoAnimPageDelegate delegate;

    setUp(() {
      const settings = ReaderSettings();
      controller = PageViewController(settings: settings);
      controller.updatePageSize(_kPageSize);
      animController = AnimationController(
        vsync: const TestVSync(),
        duration: const Duration(milliseconds: 60),
      );
      delegate = NoAnimPageDelegate(
        controller: controller,
        settings: settings,
        animController: animController,
      );
      delegate.updatePageSize(_kPageSize);
      controller.loadChapter(0, '第一章', _longContent(80));
    });

    tearDown(() {
      animController.dispose();
      controller.dispose();
    });

    test('next 方向一直拉（[-30, -30, -30]）→ _dragCancel == false', () {
      delegate.onDragUpdate(-30); // _direction 进入 next（dragOffset=-30）
      delegate.onDragUpdate(-30);
      delegate.onDragUpdate(-30);
      expect(delegate.direction, PageDirection.next);
      expect(delegate.debugDragCancel, isFalse,
          reason: '一直朝翻页方向拉 → 不 cancel');
    });

    test('next 方向最后一帧反拉（[-30, -30, -30, +5]）→ _dragCancel == true',
        () {
      delegate.onDragUpdate(-30);
      delegate.onDragUpdate(-30);
      delegate.onDragUpdate(-30);
      delegate.onDragUpdate(5); // 反向回拉
      expect(delegate.direction, PageDirection.next);
      expect(delegate.debugDragCancel, isTrue,
          reason: '最后一帧朝 next 反向（+） → cancel');
    });

    test('prev 方向一直拉（[+30, +30, +30]）→ _dragCancel == false', () {
      controller.jumpToPage(1); // 让 hasPrev = true
      delegate.onDragUpdate(30);
      delegate.onDragUpdate(30);
      delegate.onDragUpdate(30);
      expect(delegate.direction, PageDirection.prev);
      expect(delegate.debugDragCancel, isFalse);
    });

    test('prev 方向最后一帧反拉（[+30, +30, +30, -5]）→ _dragCancel == true',
        () {
      controller.jumpToPage(1);
      delegate.onDragUpdate(30);
      delegate.onDragUpdate(30);
      delegate.onDragUpdate(30);
      delegate.onDragUpdate(-5);
      expect(delegate.direction, PageDirection.prev);
      expect(delegate.debugDragCancel, isTrue);
    });

    test('delta == 0 不改变 _dragCancel（保持上一帧值）', () {
      delegate.onDragUpdate(-30);
      delegate.onDragUpdate(-30);
      // _dragCancel == false（一直 next 方向）
      delegate.onDragUpdate(0);
      expect(delegate.debugDragCancel, isFalse);

      // 再反拉触发 cancel
      delegate.onDragUpdate(5);
      expect(delegate.debugDragCancel, isTrue);
      // delta=0 不重置 cancel
      delegate.onDragUpdate(0);
      expect(delegate.debugDragCancel, isTrue);
    });
  });

  group('PageDelegate.onDragEnd reverse vs forward', () {
    late PageViewController controller;
    late AnimationController animController;
    late NoAnimPageDelegate delegate;

    setUp(() {
      const settings = ReaderSettings();
      controller = PageViewController(settings: settings);
      controller.updatePageSize(_kPageSize);
      animController = AnimationController(
        vsync: const TestVSync(),
        duration: const Duration(milliseconds: 60),
      );
      delegate = NoAnimPageDelegate(
        controller: controller,
        settings: settings,
        animController: animController,
      );
      delegate.updatePageSize(_kPageSize);
      controller.loadChapter(0, '第一章', _longContent(80));
    });

    tearDown(() {
      animController.dispose();
      controller.dispose();
    });

    testWidgets('drag → up，最后一帧反拉 → reverse 回滚（不翻页）',
        (tester) async {
      // 模拟 drag：累计 -100（next 方向），最后反拉 +5
      delegate.onDragUpdate(-30);
      delegate.onDragUpdate(-30);
      delegate.onDragUpdate(-40);
      delegate.onDragUpdate(5);
      expect(delegate.debugDragCancel, isTrue);
      final beforeIndex = controller.currentPageIndex;
      // animController.value 现在 = (-100+5).abs() / 400 = 0.2375

      delegate.onDragEnd(PageDirection.next);
      // reverse 路径：isRunning=true，等动画跑完
      expect(delegate.isRunning, isTrue);
      await tester.pumpAndSettle();

      // 不翻页
      expect(controller.currentPageIndex, beforeIndex,
          reason: 'cancel 路径不应翻页');
      expect(delegate.isRunning, isFalse, reason: 'reverse 跑完应 reset');
      expect(animController.value, 0.0, reason: 'reverse 终点是 0');
    });

    testWidgets('drag → up，一直朝翻页方向 → forward 翻页',
        (tester) async {
      delegate.onDragUpdate(-30);
      delegate.onDragUpdate(-30);
      delegate.onDragUpdate(-50);
      // 没反拉 → cancel == false
      expect(delegate.debugDragCancel, isFalse);
      final beforeIndex = controller.currentPageIndex;

      delegate.onDragEnd(PageDirection.next);
      expect(delegate.isRunning, isTrue);
      await tester.pumpAndSettle();

      expect(controller.currentPageIndex, beforeIndex + 1,
          reason: 'forward 路径应翻页');
      expect(delegate.isRunning, isFalse);
    });

    testWidgets('drag → up，跨章 boundary cancel 不切章',
        (tester) async {
      // 跳到末页 + 灌入下章
      controller.jumpToPage(controller.totalPagesInChapter - 1);
      controller.setNeighborChapter(
        next: ChapterWindow(
          chapterIndex: 1,
          title: '第二章',
          content: _longContent(40),
        ),
      );
      expect(controller.boundaryNextPage, isNotNull);

      // 拖向下章方向 → 最后反拉
      delegate.onDragUpdate(-30);
      delegate.onDragUpdate(-30);
      delegate.onDragUpdate(5);
      expect(delegate.debugDragCancel, isTrue);

      delegate.onDragEnd(PageDirection.next);
      await tester.pumpAndSettle();

      expect(controller.currentChapterIndex, 0,
          reason: 'cancel 不应切章');
      expect(animController.value, 0.0);
    });

    test('resetState 清 _dragCancel', () {
      delegate.onDragUpdate(-30);
      delegate.onDragUpdate(5);
      expect(delegate.debugDragCancel, isTrue);
      delegate.resetState();
      expect(delegate.debugDragCancel, isFalse);
    });

    test('cancelDrag 清 _dragCancel', () {
      delegate.onDragUpdate(-30);
      delegate.onDragUpdate(5);
      expect(delegate.debugDragCancel, isTrue);
      delegate.cancelDrag();
      expect(delegate.debugDragCancel, isFalse);
    });
  });
}
