import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import '../../../../core/providers.dart';
import '../text_page.dart';
import '../content_page.dart';
import '../page_view_controller.dart';

typedef ChapterBoundaryCallback = void Function(PageDirection dir);

abstract class PageDelegate {
  final PageViewController controller;
  final ReaderSettings settings;
  final AnimationController animController;

  /// 章末/章首 fallback 路径回调：邻章未灌入或未就绪时调用。
  /// 调用方（ReaderPage）走旧 `_onPageChapterBoundary` 异步加载下一章 →
  /// loadChapter → setState 路径（无动画切章，与现状一致）。
  ChapterBoundaryCallback? onChapterBoundary;

  /// Subtask C：跨章动画完成后的"真切章"回调。delegate 在动画 forward 完成
  /// 时已经调过 [PageViewController.commitToNextChapter] / commitToPrevChapter，
  /// 把邻章提升为 currentChapter；这里通知外层 ReaderPage 同步
  /// `_currentIndex` / `_chapterContent` / saveProgress / 重新预加载新邻章。
  ///
  /// 与 [onChapterBoundary] 的分工：
  ///   - onCrossChapter：邻章已就绪，走完整动画 → controller.commit + 这个回调
  ///   - onChapterBoundary：邻章未就绪，无动画 → 旧 resetState + 这个回调
  ChapterBoundaryCallback? onCrossChapter;

  bool isRunning = false;
  PageDirection _direction = PageDirection.none;
  double _dragOffset = 0;

  /// T4 (05-18): 对应 MD3 `HorizontalPageDelegate.onScroll` 的 isCancel
  /// 字段。每帧 [onDragUpdate] 比较当前 delta 与翻页方向 — 朝**翻页反向**
  /// 移动 → 标 cancel；松手时 [onDragEnd] 看本字段决定 reverse 回滚 vs
  /// forward 翻页。MD3 horizontal/cover/simulation 三种 delegate 共用此
  /// last-frame 微动方向语义，不参考绝对位置百分比 / fling velocity。
  bool _dragCancel = false;

  /// 测试和子类只读访问。
  @visibleForTesting
  bool get debugDragCancel => _dragCancel;

  // Pre-rendered page snapshots for smooth animation (accessible from subclasses)
  ui.Picture? curPicture;
  ui.Picture? nextPicture;
  ui.Picture? prevPicture;

  PageDelegate({
    required this.controller,
    required this.settings,
    required this.animController,
    this.onChapterBoundary,
    this.onCrossChapter,
  });

  PageDirection get direction => _direction;
  double get dragOffset => _dragOffset;

  // ── 触摸坐标，供 simulation 等需要绝对坐标的 delegate 使用 ──
  Offset _startTouch = Offset.zero;
  Offset _currentTouch = Offset.zero;
  Size _pageSize = Size.zero;

  /// 当前拖拽起点（相对 PageView，左上为原点）
  Offset get startTouch => _startTouch;

  /// 当前触摸点
  Offset get currentTouch => _currentTouch;

  /// 当前 PageView 尺寸
  Size get pageSize => _pageSize;

  /// 由 [PageViewWidget] 在每次 drag 起始时调用，传入精确坐标。
  void recordTouchStart(Offset start, Size size) {
    _startTouch = start;
    _currentTouch = start;
    _pageSize = size;
  }

  /// 由 [PageViewWidget] 的 LayoutBuilder 在尺寸确定后同步给 delegate，
  /// 让 tap / 程序化翻页路径（不走 drag → recordTouchStart）也能拿到正确
  /// 的页尺寸渲染 picture。
  ///
  /// 修复：tap 翻页时 [_pageSize] 仍是 [Size.zero] → [nextPageByAnim] 内
  /// 用 fallback 400x600 渲染 nextPicture → 实际屏幕 1080x2400 → 动画期间
  /// 用户只看到左上角 400x600 的下一页，剩下空白；动画结束后 painter 用真
  /// 实尺寸重画 → "动画完才内容才开始变"的体感来源。
  void updatePageSize(Size size) {
    _pageSize = size;
  }

  /// 由 [PageViewWidget] 在每次 drag 更新时调用，传入精确坐标。
  void recordTouchUpdate(Offset current) {
    _currentTouch = current;
  }

  /// Record page content into Picture for fast replay during animation
  void onDragStart(Size pageSize, TextPage? cur, TextPage? next, TextPage? prev) {
    _clearPictures();
    curPicture = _renderPage(pageSize, cur);
    // C.4: 章末 / 章首边界场景下 controller.nextPage / prevPage 是 null，
    // 但邻章已经通过 setNeighborChapter 灌入；此时 fallback 到
    // boundaryNextPage / boundaryPrevPage 渲染邻章首/末页，让动画过程中
    // nextPicture / prevPicture 不为 null，实现完整跨章动画。
    final effectiveNext = next ?? controller.boundaryNextPage;
    nextPicture = _renderPage(pageSize, effectiveNext);
    final effectivePrev = prev ?? controller.boundaryPrevPage;
    prevPicture = _renderPage(pageSize, effectivePrev);
  }

  /// Release pre-rendered resources
  void clearPagePictures() {
    _clearPictures();
  }

  void _clearPictures() {
    curPicture?.dispose();
    nextPicture?.dispose();
    prevPicture?.dispose();
    curPicture = null;
    nextPicture = null;
    prevPicture = null;
  }

  ui.Picture? _renderPage(Size pageSize, TextPage? page) {
    if (page == null) return null;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, pageSize.width, pageSize.height));
    ContentPagePainter(page: page, settings: settings).paint(canvas, pageSize);
    return recorder.endRecording();
  }

  /// Draw a pre-rendered page at a translated position (uses Picture if available)
  void drawPage(Canvas canvas, ui.Picture? picture, TextPage? fallbackPage, Offset offset) {
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    if (picture != null) {
      canvas.drawPicture(picture);
    } else if (fallbackPage != null) {
      final clipRect = canvas.getDestinationClipBounds();
      final size = clipRect.isEmpty ? const Size(400, 600) : Size(clipRect.width, clipRect.height);
      canvas.translate(-offset.dx, -offset.dy);
      canvas.restore();
      canvas.save();
      canvas.translate(offset.dx, offset.dy);
      ContentPagePainter(page: fallbackPage, settings: settings).paint(canvas, size);
    }
    canvas.restore();
  }

  void onDragUpdate(double delta) {
    if (isRunning) return;
    _dragOffset += delta;

    // Bug 2 fix: 用页面宽度作为 progress 分母。
    // 之前用 animController.upperBound - lowerBound（默认 0~1），导致拖
    // 1 像素 progress 直接 = 1.0，看起来没动画过程。pageSize.width 是真正
    // 的横向像素长度，drag 1px → progress = 1/width，平滑跟手。
    final totalWidth = pageSize.width > 0 ? pageSize.width : 300.0;

    if (_dragOffset > 5 && _direction == PageDirection.none) {
      _direction = PageDirection.prev;
    } else if (_dragOffset < -5 && _direction == PageDirection.none) {
      _direction = PageDirection.next;
    }

    // T4 (05-18): 每帧覆盖 _dragCancel — last-frame 微动方向决定松手时
    // 是回滚还是翻页（对齐 MD3 HorizontalPageDelegate.onScroll
    // `isCancel = (NEXT && sumX>lastX) || (PREV && sumX<lastX)`）。
    // - next 方向（手指持续向左拉 → delta < 0）：当前帧 delta > 0 表示
    //   手指向**右**回拉 → 朝翻页反向 → cancel = true
    // - prev 方向（手指持续向右拉 → delta > 0）：当前帧 delta < 0 表示
    //   手指向**左**回拉 → 朝翻页反向 → cancel = true
    // delta == 0（少见，多 touch 数据丢帧）保留上一帧值不动。
    if (_direction == PageDirection.next && delta != 0) {
      _dragCancel = delta > 0;
    } else if (_direction == PageDirection.prev && delta != 0) {
      _dragCancel = delta < 0;
    }

    final progress = (_dragOffset.abs() / totalWidth).clamp(0.0, 1.0);
    // Subtask C：drag 期间 progress 推进的"边界守门"。同章 hasPrev/hasNext
    // 不通过时，如果 controller 的 boundaryPrevPage / boundaryNextPage
    // 已就绪（外层灌过邻章），允许 progress 继续推进，让用户在跨章拖动
    // 时也能看到完整动画；都没有时再 pin 在 0（与旧行为一致）。
    if (_direction == PageDirection.prev &&
        !controller.hasPrev &&
        controller.boundaryPrevPage == null) {
      animController.value = 0;
      return;
    }
    if (_direction == PageDirection.next &&
        !controller.hasNext &&
        controller.boundaryNextPage == null) {
      animController.value = 0;
      return;
    }
    animController.value = progress;
  }

  void onDragEnd(PageDirection detectedDir) {
    if (isRunning) return;

    if (_direction == PageDirection.none) {
      _direction = detectedDir;
    }

    if (_direction == PageDirection.none) {
      resetState();
      return;
    }

    // T4 (05-18): _dragCancel = true 时走回滚分支 — animController 从
    // 当前 progress reverse 到 0，不调 controller.goToNextPage / 不切章。
    // 对齐 MD3 horizontal/cover/simulation 三种 delegate 的"last-frame
    // 微动方向决定翻页 vs 回滚"语义。
    if (_dragCancel) {
      _runReverseAnimation();
      return;
    }

    if (_direction == PageDirection.next) {
      goToNext();
    } else if (_direction == PageDirection.prev) {
      goToPrev();
    } else {
      resetState();
    }
  }

  /// T4 (05-18): drag-cancel 路径的反向动画 — animController 从当前
  /// progress reverse 到 0，跑完后 resetState。不调 controller 翻页 /
  /// commit / onChapterBoundary —— 用户拖了一半反悔，所以什么都不发生。
  void _runReverseAnimation() {
    if (isRunning) return;
    isRunning = true;
    void tick() => onAnimTick(animController.value);
    animController.addListener(tick);
    animController.reverse(from: animController.value).then((_) {
      animController.removeListener(tick);
      resetState();
      onAnimEnd();
    });
  }

  void goToNext() {
    // 同章：直接走 goToNextPage（旧路径）
    if (controller.hasNext) {
      _direction = PageDirection.next;
      _runAnimation(() => controller.goToNextPage());
      return;
    }
    // 跨章动画路径：邻章已 measure 好（外层调过 setNeighborChapter），
    // 走完整 forward 动画后调 commitToNextChapter 切章 + 通知外层。
    if (controller.boundaryNextPage != null) {
      _direction = PageDirection.next;
      _runAnimation(() {
        controller.commitToNextChapter();
        onCrossChapter?.call(PageDirection.next);
      });
      return;
    }
    // fallback：邻章未就绪，旧 boundary 路径（无动画 setState）。
    resetState();
    onChapterBoundary?.call(PageDirection.next);
  }

  void goToPrev() {
    // 同章：直接走 goToPrevPage
    if (controller.hasPrev) {
      _direction = PageDirection.prev;
      _runAnimation(() => controller.goToPrevPage());
      return;
    }
    // 跨章动画路径
    if (controller.boundaryPrevPage != null) {
      _direction = PageDirection.prev;
      _runAnimation(() {
        controller.commitToPrevChapter();
        onCrossChapter?.call(PageDirection.prev);
      });
      return;
    }
    // fallback
    resetState();
    onChapterBoundary?.call(PageDirection.prev);
  }

  /// 子类钩子（X1.1）：每帧 progress 变化时调用，让 simulation 等需要根据
  /// progress 自驱动几何的 delegate 更新内部状态（如 currentTouch lerp）。
  /// 默认空实现 — cover/slide/fade/noAnim 不需要。
  void onAnimTick(double progress) {}

  /// 子类钩子（X1.9）：动画 forward 完成 + onComplete + resetState 之后调用。
  /// simulation 用它清理 lerp 字段（_animStartTouch 等），避免上次 anim 残留
  /// 让下一次 drag 路径的 `if (_animStartTouch == null)` guard 误判。
  /// 默认空实现。
  void onAnimEnd() {}

  void _runAnimation(VoidCallback onComplete) {
    if (isRunning) return;
    isRunning = true;
    void tick() => onAnimTick(animController.value);
    animController.addListener(tick);
    animController.forward(from: animController.value).then((_) {
      animController.removeListener(tick);
      onComplete();
      resetState();
      onAnimEnd();
    });
  }

  void resetState() {
    _direction = PageDirection.none;
    _dragOffset = 0;
    _dragCancel = false; // T4 (05-18): 清 drag-cancel flag
    isRunning = false;
    animController.value = 0;
    _clearPictures();
  }

  void draw(
    Canvas canvas,
    Size size, {
    required TextPage? currentPage,
    required TextPage? nextPage,
    required TextPage? prevPage,
    required double animProgress,
    required int totalPages,
  });

  // ── 兼容 Legado MD3 PageDelegate 的额外接口（默认空实现，子类可覆盖） ──

  /// 中断进行中的动画。仿真翻页等带 fling 的 delegate 需要在外部触发翻页时
  /// 立即停止当前动画并复位。
  void abortAnim() {
    if (animController.isAnimating) {
      animController.stop();
    }
    isRunning = false;
  }

  /// 取消当前未完成的 drag 周期，复位 [_direction] / [_dragOffset] /
  /// [animController.value] 并释放预渲染 picture。
  ///
  /// 调用语义对应 Android `MotionEvent.ACTION_CANCEL`：onDragStart 已经被
  /// widget 层触发（slop 已越过、picture 已分配、animController.value 被
  /// onDragUpdate 推进），但用户后续的 PointerCancel 中止了手势。
  /// 如果不复位，下一次 drag 会在 stale `_dragOffset` / `_direction` 上累加，
  /// 出现"刚 down 就翻半页"的 ghost-progress 现象。
  ///
  /// 与 [abortAnim] 的区别：abortAnim 只停 anim、置 isRunning=false，
  /// **不**复位 direction/offset/picture。cancelDrag 是 Listener 层 cancel
  /// 路径用的"完整复位"。
  void cancelDrag() {
    if (animController.isAnimating) {
      animController.stop();
    }
    _direction = PageDirection.none;
    _dragOffset = 0;
    _dragCancel = false; // T4 (05-18): 清 drag-cancel flag
    isRunning = false;
    animController.value = 0;
    _clearPictures();
  }

  /// 程序化"下一页"触发（按键 / 自动翻页 / 点击翻页）。
  ///
  /// Bug 2.5：cover/slide/fade 的 draw 依赖 onDragStart 内生成的
  /// curPicture/nextPicture/prevPicture。点击翻页路径上没有 drag，所以这里
  /// 主动生成一次 picture，让动画期间能正确绘制。
  /// [animationSpeed] 单位毫秒，目前作为 hint，子类可使用。
  ///
  /// Subtask C：章末时如果 boundaryNextPage 已就绪，使用其渲染 nextPicture
  /// 让跨章 tap 翻页也能播放完整动画；都没有时回 fallback boundary callback。
  void nextPageByAnim(int animationSpeed) {
    if (isRunning) return;
    // fallback：同章无下页 + 邻章未灌入 → 走旧 boundary 路径。
    if (!controller.hasNext && controller.boundaryNextPage == null) {
      debugPrint('[PageDelegate] nextPageByAnim: fallback boundary (no hasNext + no boundaryNextPage)');
      onChapterBoundary?.call(PageDirection.next);
      return;
    }
    final size = pageSize.isEmpty ? const Size(400, 600) : pageSize;
    _clearPictures();
    curPicture = _renderPage(size, controller.currentPage);
    final effectiveNext = controller.nextPage ?? controller.boundaryNextPage;
    nextPicture = _renderPage(size, effectiveNext);
    final effectivePrev = controller.prevPage ?? controller.boundaryPrevPage;
    prevPicture = _renderPage(size, effectivePrev);
    debugPrint('[PageDelegate] nextPageByAnim: hasNext=${controller.hasNext} cur=$curPicture next=$nextPicture prev=$prevPicture');
    goToNext();
  }

  /// 程序化"上一页"触发（按键 / 自动翻页 / 点击翻页）。
  ///
  /// Subtask C：章首时如果 boundaryPrevPage 已就绪走完整动画。
  void prevPageByAnim(int animationSpeed) {
    if (isRunning) return;
    if (!controller.hasPrev && controller.boundaryPrevPage == null) {
      debugPrint('[PageDelegate] prevPageByAnim: fallback boundary (no hasPrev + no boundaryPrevPage)');
      onChapterBoundary?.call(PageDirection.prev);
      return;
    }
    final size = pageSize.isEmpty ? const Size(400, 600) : pageSize;
    _clearPictures();
    curPicture = _renderPage(size, controller.currentPage);
    final effectiveNext = controller.nextPage ?? controller.boundaryNextPage;
    nextPicture = _renderPage(size, effectiveNext);
    final effectivePrev = controller.prevPage ?? controller.boundaryPrevPage;
    prevPicture = _renderPage(size, effectivePrev);
    debugPrint('[PageDelegate] prevPageByAnim: hasPrev=${controller.hasPrev} cur=$curPicture next=$nextPicture prev=$prevPicture');
    goToPrev();
  }

  /// fling 滑动钩子。Cover/Slide 的 horizontal delegate 走 [animController]
  /// 走完动画即可；仿真翻页等需要按速度自定义动画曲线时请覆盖。
  void fling(double velocity) {
    // No-op by default. Horizontal delegates rely on [onDragEnd] which
    // calls goToNext/goToPrev based on direction; that already triggers the
    // anim controller in [_runAnimation].
  }

  void dispose();
}
