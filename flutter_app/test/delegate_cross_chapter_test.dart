import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/providers.dart';
import 'package:legado_flutter/features/reader/page/delegate/no_anim_page_delegate.dart';
import 'package:legado_flutter/features/reader/page/delegate/page_delegate.dart';
import 'package:legado_flutter/features/reader/page/page_view.dart';
import 'package:legado_flutter/features/reader/page/page_view_controller.dart';

/// 第二十七批 Task 2C — PageDelegate 跨章动画路径回归测试
///
/// 覆盖 PRD C.1..C.8：
///
/// 1. goToNext **同章** 路径：调 controller.goToNextPage（旧行为不变）
/// 2. goToNext **章末 + 邻章就绪** 路径：动画跑完调 commitToNextChapter +
///    onCrossChapter 回调；onChapterBoundary fallback 不被触发
/// 3. goToNext **章末 + 邻章 null** 路径：fallback 触发 onChapterBoundary，
///    不调 commit
/// 4. goToPrev 三分支镜像
/// 5. nextPageByAnim 跨章成功：currentChapterIndex 提升 1
/// 6. PageViewWidget 把 onCrossChapter 透传到 delegate
///
/// 测试用 [NoAnimPageDelegate] 作为最简 delegate（只关心父类状态机；
/// 不依赖具体的 draw 几何）。AnimationController 用 TestVSync。
/// PageMeasure 在 _kPageSize=(400, 600) 下能切出真页。

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

  group('PageDelegate.goToNext 三分支', () {
    late PageViewController controller;
    late AnimationController animController;
    late NoAnimPageDelegate delegate;
    late List<PageDirection> boundaryCalls;
    late List<PageDirection> crossCalls;

    setUp(() {
      const settings = ReaderSettings();
      controller = PageViewController(settings: settings);
      controller.updatePageSize(_kPageSize);
      animController = AnimationController(
        vsync: const TestVSync(),
        // Short duration to keep tester.pumpAndSettle quick.
        duration: const Duration(milliseconds: 60),
      );
      boundaryCalls = [];
      crossCalls = [];
      delegate = NoAnimPageDelegate(
        controller: controller,
        settings: settings,
        animController: animController,
        onChapterBoundary: boundaryCalls.add,
        onCrossChapter: crossCalls.add,
      );
    });

    tearDown(() {
      animController.dispose();
      controller.dispose();
    });

    testWidgets('同章 hasNext → controller.goToNextPage，currentPageIndex+1',
        (tester) async {
      controller.loadChapter(0, '第一章', _longContent(80));
      await tester.pumpAndSettle();
      expect(controller.totalPagesInChapter, greaterThan(1),
          reason: 'PageMeasure should split into multiple pages');
      expect(controller.currentPageIndex, 0);
      expect(controller.hasNext, isTrue);

      delegate.goToNext();
      // 跑动画前 isRunning 应该为 true（_runAnimation 已置位）。
      expect(delegate.isRunning, isTrue);
      // 让 60ms 动画跑完。
      await tester.pumpAndSettle();

      expect(controller.currentPageIndex, 1,
          reason: '同章 next → currentPageIndex 应 +1');
      // 同章不应触发任何 boundary callback。
      expect(boundaryCalls, isEmpty);
      expect(crossCalls, isEmpty,
          reason: '同章不算跨章，onCrossChapter 不应被调');
      expect(delegate.isRunning, isFalse,
          reason: '动画结束应 _resetState 把 isRunning 复位');
    });

    testWidgets(
        '章末 + boundaryNextPage 就绪 → commitToNextChapter + onCrossChapter',
        (tester) async {
      controller.loadChapter(0, '第一章', _longContent(40));
      await tester.pumpAndSettle();
      // 跳到章末。
      controller.jumpToPage(controller.totalPagesInChapter - 1);
      // 灌入下一章。
      controller.setNeighborChapter(
        next: ChapterWindow(
          chapterIndex: 1,
          title: '第二章',
          content: _longContent(40),
        ),
      );
      expect(controller.hasNext, isFalse);
      expect(controller.boundaryNextPage, isNotNull,
          reason: '章末 + 邻章已灌 → boundaryNextPage 应可用');

      delegate.goToNext();
      expect(delegate.isRunning, isTrue);
      await tester.pumpAndSettle();

      expect(controller.currentChapterIndex, 1,
          reason: 'commit 后 currentChapterIndex 提升');
      expect(controller.currentPageIndex, 0,
          reason: 'commit 后定位到新章首页');
      expect(crossCalls, [PageDirection.next],
          reason: '动画完成应触发 onCrossChapter(next)');
      expect(boundaryCalls, isEmpty,
          reason: '邻章已就绪走 cross 路径，不应触发 fallback boundary');
    });

    testWidgets(
        '章末 + boundaryNextPage == null → onChapterBoundary fallback，不切章',
        (tester) async {
      controller.loadChapter(0, '第一章', _longContent(40));
      await tester.pumpAndSettle();
      controller.jumpToPage(controller.totalPagesInChapter - 1);
      // 不灌邻章。
      expect(controller.boundaryNextPage, isNull);

      delegate.goToNext();
      // fallback 路径走 _resetState（不跑动画）+ 立刻 callback。
      expect(delegate.isRunning, isFalse);
      await tester.pumpAndSettle();

      expect(controller.currentChapterIndex, 0,
          reason: 'fallback 路径不应改 controller 状态');
      expect(boundaryCalls, [PageDirection.next],
          reason: 'fallback 应触发 onChapterBoundary');
      expect(crossCalls, isEmpty,
          reason: 'fallback 路径不应触发 onCrossChapter');
    });
  });

  group('PageDelegate.goToPrev 三分支', () {
    late PageViewController controller;
    late AnimationController animController;
    late NoAnimPageDelegate delegate;
    late List<PageDirection> boundaryCalls;
    late List<PageDirection> crossCalls;

    setUp(() {
      const settings = ReaderSettings();
      controller = PageViewController(settings: settings);
      controller.updatePageSize(_kPageSize);
      animController = AnimationController(
        vsync: const TestVSync(),
        duration: const Duration(milliseconds: 60),
      );
      boundaryCalls = [];
      crossCalls = [];
      delegate = NoAnimPageDelegate(
        controller: controller,
        settings: settings,
        animController: animController,
        onChapterBoundary: boundaryCalls.add,
        onCrossChapter: crossCalls.add,
      );
    });

    tearDown(() {
      animController.dispose();
      controller.dispose();
    });

    testWidgets('同章 hasPrev → controller.goToPrevPage，currentPageIndex-1',
        (tester) async {
      controller.loadChapter(0, '第一章', _longContent(80));
      await tester.pumpAndSettle();
      controller.jumpToPage(2);
      expect(controller.hasPrev, isTrue);

      delegate.goToPrev();
      await tester.pumpAndSettle();

      expect(controller.currentPageIndex, 1);
      expect(boundaryCalls, isEmpty);
      expect(crossCalls, isEmpty);
    });

    testWidgets(
        '章首 + boundaryPrevPage 就绪 → commitToPrevChapter + onCrossChapter',
        (tester) async {
      controller.loadChapter(1, '第二章', _longContent(40));
      await tester.pumpAndSettle();
      // 在章首（默认 page 0）。
      expect(controller.hasPrev, isFalse);
      controller.setNeighborChapter(
        prev: ChapterWindow(
          chapterIndex: 0,
          title: '第一章',
          content: _longContent(40),
        ),
      );
      expect(controller.boundaryPrevPage, isNotNull);

      delegate.goToPrev();
      expect(delegate.isRunning, isTrue);
      await tester.pumpAndSettle();

      expect(controller.currentChapterIndex, 0,
          reason: 'commit 后切到上一章');
      // 上一章定位到末页。
      expect(controller.currentPageIndex,
          controller.totalPagesInChapter - 1,
          reason: 'commitToPrevChapter 应定位到上一章末页');
      expect(crossCalls, [PageDirection.prev]);
      expect(boundaryCalls, isEmpty);
    });

    testWidgets(
        '章首 + boundaryPrevPage == null → onChapterBoundary fallback',
        (tester) async {
      controller.loadChapter(1, '第二章', _longContent(40));
      await tester.pumpAndSettle();
      expect(controller.boundaryPrevPage, isNull);

      delegate.goToPrev();
      await tester.pumpAndSettle();

      expect(controller.currentChapterIndex, 1);
      expect(boundaryCalls, [PageDirection.prev]);
      expect(crossCalls, isEmpty);
    });
  });

  group('PageDelegate.nextPageByAnim / prevPageByAnim 跨章', () {
    late PageViewController controller;
    late AnimationController animController;
    late NoAnimPageDelegate delegate;
    late List<PageDirection> boundaryCalls;
    late List<PageDirection> crossCalls;

    setUp(() {
      const settings = ReaderSettings();
      controller = PageViewController(settings: settings);
      controller.updatePageSize(_kPageSize);
      animController = AnimationController(
        vsync: const TestVSync(),
        duration: const Duration(milliseconds: 60),
      );
      boundaryCalls = [];
      crossCalls = [];
      delegate = NoAnimPageDelegate(
        controller: controller,
        settings: settings,
        animController: animController,
        onChapterBoundary: boundaryCalls.add,
        onCrossChapter: crossCalls.add,
      );
    });

    tearDown(() {
      animController.dispose();
      controller.dispose();
    });

    testWidgets(
        'nextPageByAnim 章末 + 邻章就绪 → 跨章成功，currentChapterIndex+1',
        (tester) async {
      controller.loadChapter(0, '第一章', _longContent(40));
      await tester.pumpAndSettle();
      controller.jumpToPage(controller.totalPagesInChapter - 1);
      controller.setNeighborChapter(
        next: ChapterWindow(
          chapterIndex: 1,
          title: '第二章',
          content: _longContent(40),
        ),
      );

      delegate.nextPageByAnim(60);
      // nextPageByAnim 内部会调 goToNext → _runAnimation → forward。
      expect(delegate.isRunning, isTrue);
      await tester.pumpAndSettle();

      expect(controller.currentChapterIndex, 1);
      expect(crossCalls, [PageDirection.next]);
      expect(boundaryCalls, isEmpty);
    });

    testWidgets(
        'nextPageByAnim 章末 + 邻章 null → fallback boundary',
        (tester) async {
      controller.loadChapter(0, '第一章', _longContent(40));
      await tester.pumpAndSettle();
      controller.jumpToPage(controller.totalPagesInChapter - 1);

      delegate.nextPageByAnim(60);
      // fallback 路径不进入 isRunning（也不调 goToNext）。
      expect(delegate.isRunning, isFalse);
      expect(boundaryCalls, [PageDirection.next]);
      expect(crossCalls, isEmpty);
    });

    testWidgets(
        'prevPageByAnim 章首 + 邻章就绪 → 跨章成功，currentChapterIndex-1',
        (tester) async {
      controller.loadChapter(1, '第二章', _longContent(40));
      await tester.pumpAndSettle();
      controller.setNeighborChapter(
        prev: ChapterWindow(
          chapterIndex: 0,
          title: '第一章',
          content: _longContent(40),
        ),
      );

      delegate.prevPageByAnim(60);
      expect(delegate.isRunning, isTrue);
      await tester.pumpAndSettle();

      expect(controller.currentChapterIndex, 0);
      expect(crossCalls, [PageDirection.prev]);
    });
  });

  group('PageDelegate.onDragStart 章末/章首使用 boundary fallback 渲染', () {
    test('章末 + boundaryNextPage 就绪 → nextPicture != null', () {
      const settings = ReaderSettings();
      final controller = PageViewController(settings: settings);
      addTearDown(controller.dispose);
      controller.updatePageSize(_kPageSize);
      final animController = AnimationController(
        vsync: const TestVSync(),
        duration: const Duration(milliseconds: 60),
      );
      addTearDown(animController.dispose);
      final delegate = NoAnimPageDelegate(
        controller: controller,
        settings: settings,
        animController: animController,
      );

      controller.loadChapter(0, '第一章', _longContent(40));
      // measure 是同步的（PageMeasure.measureChapter 在线程内同步）。
      controller.jumpToPage(controller.totalPagesInChapter - 1);
      controller.setNeighborChapter(
        next: ChapterWindow(
          chapterIndex: 1,
          title: '第二章',
          content: _longContent(40),
        ),
      );

      // controller.nextPage 是 null（同章无下页），但 boundaryNextPage
      // 应该不为 null。
      expect(controller.nextPage, isNull);
      expect(controller.boundaryNextPage, isNotNull);

      // 模拟 widget 层的 onDragStart 调用：next 传 controller.nextPage（null），
      // delegate 内部应 fallback 到 boundaryNextPage 渲染。
      delegate.onDragStart(_kPageSize, controller.currentPage,
          controller.nextPage, controller.prevPage);

      expect(delegate.curPicture, isNotNull);
      expect(delegate.nextPicture, isNotNull,
          reason: '章末 + 邻章就绪 → nextPicture 应通过 boundary fallback 渲染');
    });

    test('章首 + boundaryPrevPage 就绪 → prevPicture != null', () {
      const settings = ReaderSettings();
      final controller = PageViewController(settings: settings);
      addTearDown(controller.dispose);
      controller.updatePageSize(_kPageSize);
      final animController = AnimationController(
        vsync: const TestVSync(),
        duration: const Duration(milliseconds: 60),
      );
      addTearDown(animController.dispose);
      final delegate = NoAnimPageDelegate(
        controller: controller,
        settings: settings,
        animController: animController,
      );

      controller.loadChapter(1, '第二章', _longContent(40));
      controller.setNeighborChapter(
        prev: ChapterWindow(
          chapterIndex: 0,
          title: '第一章',
          content: _longContent(40),
        ),
      );
      expect(controller.prevPage, isNull);
      expect(controller.boundaryPrevPage, isNotNull);

      delegate.onDragStart(_kPageSize, controller.currentPage,
          controller.nextPage, controller.prevPage);

      expect(delegate.prevPicture, isNotNull,
          reason: '章首 + 邻章就绪 → prevPicture 应通过 boundary fallback 渲染');
    });
  });

  group('PageViewWidget onCrossChapter 透传', () {
    testWidgets('onCrossChapter 传到 delegate', (tester) async {
      const settings = ReaderSettings(pageAnim: ReaderPageAnim.noAnim);
      final controller = PageViewController(settings: settings);
      addTearDown(controller.dispose);
      final calls = <PageDirection>[];
      PageDelegate? captured;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 600,
              child: PageViewWidget(
                controller: controller,
                settings: settings,
                pageAnim: ReaderPageAnim.noAnim,
                onCrossChapter: calls.add,
                debugDelegateSink: (d) => captured = d,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(captured, isNotNull,
          reason: 'PageViewWidget should expose its delegate');
      // delegate.onCrossChapter 应该被赋值。直接调一下看是否到 calls。
      expect(captured!.onCrossChapter, isNotNull);
      captured!.onCrossChapter!(PageDirection.next);
      expect(calls, [PageDirection.next]);
    });
  });
}
