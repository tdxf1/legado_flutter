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
  ChapterBoundaryCallback? onChapterBoundary;

  bool isRunning = false;
  PageDirection _direction = PageDirection.none;
  double _dragOffset = 0;

  // Pre-rendered page snapshots for smooth animation (accessible from subclasses)
  ui.Picture? curPicture;
  ui.Picture? nextPicture;
  ui.Picture? prevPicture;

  PageDelegate({
    required this.controller,
    required this.settings,
    required this.animController,
    this.onChapterBoundary,
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

  /// 由 [PageViewWidget] 在每次 drag 更新时调用，传入精确坐标。
  void recordTouchUpdate(Offset current) {
    _currentTouch = current;
  }

  /// Record page content into Picture for fast replay during animation
  void onDragStart(Size pageSize, TextPage? cur, TextPage? next, TextPage? prev) {
    _clearPictures();
    curPicture = _renderPage(pageSize, cur);
    nextPicture = _renderPage(pageSize, next);
    prevPicture = _renderPage(pageSize, prev);
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

    final progress = (_dragOffset.abs() / totalWidth).clamp(0.0, 1.0);
    if (_direction == PageDirection.prev && !controller.hasPrev) {
      animController.value = 0;
      return;
    }
    if (_direction == PageDirection.next && !controller.hasNext) {
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

    if (_direction == PageDirection.next) {
      goToNext();
    } else if (_direction == PageDirection.prev) {
      goToPrev();
    } else {
      _resetState();
    }
  }

  void goToNext() {
    if (!controller.hasNext) {
      _resetState();
      onChapterBoundary?.call(PageDirection.next);
      return;
    }
    _direction = PageDirection.next;
    _runAnimation(() => controller.goToNextPage());
  }

  void goToPrev() {
    if (!controller.hasPrev) {
      _resetState();
      onChapterBoundary?.call(PageDirection.prev);
      return;
    }
    _direction = PageDirection.prev;
    _runAnimation(() => controller.goToPrevPage());
  }

  void _runAnimation(VoidCallback onComplete) {
    if (isRunning) return;
    isRunning = true;
    animController.forward(from: animController.value).then((_) {
      onComplete();
      _resetState();
    });
  }

  void _resetState() {
    _direction = PageDirection.none;
    _dragOffset = 0;
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

  /// 程序化"下一页"触发（按键 / 自动翻页 / 点击翻页）。
  ///
  /// Bug 2.5：cover/slide/fade 的 draw 依赖 onDragStart 内生成的
  /// curPicture/nextPicture/prevPicture。点击翻页路径上没有 drag，所以这里
  /// 主动生成一次 picture，让动画期间能正确绘制。
  /// [animationSpeed] 单位毫秒，目前作为 hint，子类可使用。
  void nextPageByAnim(int animationSpeed) {
    if (isRunning) return;
    if (!controller.hasNext) {
      onChapterBoundary?.call(PageDirection.next);
      return;
    }
    final size = pageSize.isEmpty ? const Size(400, 600) : pageSize;
    _clearPictures();
    curPicture = _renderPage(size, controller.currentPage);
    nextPicture = _renderPage(size, controller.nextPage);
    prevPicture = _renderPage(size, controller.prevPage);
    goToNext();
  }

  /// 程序化"上一页"触发（按键 / 自动翻页 / 点击翻页）。
  void prevPageByAnim(int animationSpeed) {
    if (isRunning) return;
    if (!controller.hasPrev) {
      onChapterBoundary?.call(PageDirection.prev);
      return;
    }
    final size = pageSize.isEmpty ? const Size(400, 600) : pageSize;
    _clearPictures();
    curPicture = _renderPage(size, controller.currentPage);
    nextPicture = _renderPage(size, controller.nextPage);
    prevPicture = _renderPage(size, controller.prevPage);
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
