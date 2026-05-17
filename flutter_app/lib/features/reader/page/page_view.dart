import 'package:flutter/material.dart';
import '../../../core/providers.dart';
import 'text_page.dart';
import 'page_view_controller.dart';
import 'delegate/page_delegate.dart';
import 'delegate/no_anim_page_delegate.dart';
import 'delegate/cover_page_delegate.dart';
import 'delegate/slide_page_delegate.dart';
import 'delegate/simulation_page_delegate.dart';
import 'delegate/simulation_degrade_controller.dart';
import 'delegate/fade_page_delegate.dart';
import 'simulation_native_fallback.dart';
class PageViewWidget extends StatefulWidget {
  final PageViewController controller;
  final ReaderSettings settings;
  final int pageAnim;
  final ChapterBoundaryCallback? onChapterBoundary;

  const PageViewWidget({
    super.key,
    required this.controller,
    required this.settings,
    this.pageAnim = 0,
    this.onChapterBoundary,
  });

  @override
  State<PageViewWidget> createState() => _PageViewWidgetState();
}

class _PageViewWidgetState extends State<PageViewWidget>
    with TickerProviderStateMixin {
  late PageDelegate _delegate;
  AnimationController? _animController;
  Size _pageSize = Size.zero;
  SimulationDegradeController? _simDegrade;
  bool _useNativeFallback = false;

  @override
  void initState() {
    super.initState();
    _createDelegate();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(PageViewWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageAnim != widget.pageAnim ||
        oldWidget.settings.effectiveTextColor != widget.settings.effectiveTextColor ||
        oldWidget.settings.effectiveBackgroundColor != widget.settings.effectiveBackgroundColor) {
      _createDelegate();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _simDegrade?.detach();
    _simDegrade = null;
    _animController?.dispose();
    _delegate.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  void _createDelegate() {
    _animController?.dispose();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    final ctrl = widget.controller;
    // PageAnim values follow Legado MD3 native semantics; see
    // [ReaderPageAnim] in core/providers.dart.
    if (widget.pageAnim != ReaderPageAnim.simulation) {
      _simDegrade?.detach();
      _simDegrade = null;
      if (_useNativeFallback) {
        SimulationNativeFallback.instance
            .stop()
            .catchError((e) => debugPrint('[SimNative] stop failed: $e'));
        _useNativeFallback = false;
      }
    }
    switch (widget.pageAnim) {
      case ReaderPageAnim.cover:
        _delegate = CoverPageDelegate(
          controller: ctrl,
          settings: widget.settings,
          animController: _animController!,
          onChapterBoundary: widget.onChapterBoundary,
        );
        break;
      case ReaderPageAnim.slide:
        _delegate = SlidePageDelegate(
          controller: ctrl,
          settings: widget.settings,
          animController: _animController!,
          onChapterBoundary: widget.onChapterBoundary,
        );
        break;
      case ReaderPageAnim.simulation:
        // 复用既有 controller 实例，避免在频繁重建时丢掉降级状态
        _simDegrade?.detach();
        _simDegrade ??= SimulationDegradeController();
        _simDegrade!
          ..reset()
          ..attach(
            onLevelChanged: () {
              if (mounted) setState(() {});
            },
            onFallbackRequested: () {
              if (!mounted) return;
              setState(() => _useNativeFallback = true);
              SimulationNativeFallback.instance
                  .start()
                  .catchError((e) => debugPrint('[SimNative] start failed: $e'));
            },
          );
        _delegate = SimulationPageDelegate(
          controller: ctrl,
          settings: widget.settings,
          animController: _animController!,
          onChapterBoundary: widget.onChapterBoundary,
          degrade: _simDegrade,
        );
        break;
      case ReaderPageAnim.fade:
        _delegate = FadePageDelegate(
          controller: ctrl,
          settings: widget.settings,
          animController: _animController!,
          onChapterBoundary: widget.onChapterBoundary,
        );
        break;
      case ReaderPageAnim.noAnim:
      default:
        _delegate = NoAnimPageDelegate(
          controller: ctrl,
          settings: widget.settings,
          animController: _animController!,
          onChapterBoundary: widget.onChapterBoundary,
        );
    }

    // Bug 2.5: 把 onTapNext/onTapPrev 注入 controller，让外层（reader_page）
    // 点击屏幕左/右 1/3 时通过 delegate 跑动画再切页。
    ctrl.onTapNext = () => _delegate.nextPageByAnim(300);
    ctrl.onTapPrev = () => _delegate.prevPageByAnim(300);
  }

  PageDirection _detectDirection(double velocityX) {
    if (velocityX < -50) return PageDirection.next;
    if (velocityX > 50) return PageDirection.prev;
    return PageDirection.none;
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    if (_pageSize.isEmpty) return;
    final ctrl = widget.controller;
    _delegate.recordTouchStart(details.localPosition, _pageSize);
    _delegate.onDragStart(_pageSize, ctrl.currentPage, ctrl.nextPage, ctrl.prevPage);
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    _delegate.recordTouchUpdate(details.localPosition);
    _delegate.onDragUpdate(details.primaryDelta ?? 0);
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    final dir = _detectDirection(details.primaryVelocity ?? 0);
    _delegate.fling(details.primaryVelocity ?? 0);
    _delegate.onDragEnd(dir);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        _pageSize = size;
        widget.controller.updatePageSize(size);

        return GestureDetector(
          onHorizontalDragStart: _onHorizontalDragStart,
          onHorizontalDragUpdate: _onHorizontalDragUpdate,
          onHorizontalDragEnd: _onHorizontalDragEnd,
          child: AnimatedBuilder(
            animation: Listenable.merge([widget.controller, _animController!]),
            builder: (context, child) {
              return CustomPaint(
                size: size,
                painter: _PageViewPainter(
                  delegate: _delegate,
                  currentPage: widget.controller.currentPage,
                  nextPage: widget.controller.nextPage,
                  prevPage: widget.controller.prevPage,
                  settings: widget.settings,
                  animProgress: _animController!.value,
                  direction: _delegate.direction,
                  isRunning: _delegate.isRunning,
                  totalPages: widget.controller.totalPagesInChapter,
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _PageViewPainter extends CustomPainter {
  final PageDelegate delegate;
  final TextPage? currentPage;
  final TextPage? nextPage;
  final TextPage? prevPage;
  final ReaderSettings settings;
  final double animProgress;
  final PageDirection direction;
  final bool isRunning;
  final int totalPages;

  _PageViewPainter({
    required this.delegate,
    required this.currentPage,
    required this.nextPage,
    required this.prevPage,
    required this.settings,
    required this.animProgress,
    required this.direction,
    required this.isRunning,
    required this.totalPages,
  });

  @override
  void paint(Canvas canvas, Size size) {
    delegate.draw(
      canvas,
      size,
      currentPage: currentPage,
      nextPage: nextPage,
      prevPage: prevPage,
      animProgress: animProgress,
      totalPages: totalPages,
    );
  }

  @override
  bool shouldRepaint(covariant _PageViewPainter oldDelegate) {
    // Repaint when an animation is running, when the page content changes,
    // or when reader settings change. Static pages (noAnim mode at rest)
    // skip the raster pipeline entirely.
    //
    // R8: typesetting fields (fontSize / weight / lineHeight / spacing /
    // padding / paragraphIndent / fontFamily) must trigger a repaint even
    // when the page reference happens to be re-used after a re-measure.
    final oldS = oldDelegate.settings;
    final newS = settings;
    return isRunning ||
        oldDelegate.isRunning != isRunning ||
        oldDelegate.animProgress != animProgress ||
        oldDelegate.direction != direction ||
        !identical(oldDelegate.currentPage, currentPage) ||
        !identical(oldDelegate.nextPage, nextPage) ||
        !identical(oldDelegate.prevPage, prevPage) ||
        oldDelegate.totalPages != totalPages ||
        oldS.effectiveTextColor != newS.effectiveTextColor ||
        oldS.effectiveBackgroundColor != newS.effectiveBackgroundColor ||
        oldS.fontSize != newS.fontSize ||
        oldS.fontWeightIndex != newS.fontWeightIndex ||
        oldS.fontFamily != newS.fontFamily ||
        oldS.letterSpacing != newS.letterSpacing ||
        oldS.lineHeight != newS.lineHeight ||
        oldS.paragraphSpacing != newS.paragraphSpacing ||
        oldS.horizontalPadding != newS.horizontalPadding ||
        oldS.verticalPadding != newS.verticalPadding ||
        oldS.paragraphIndent != newS.paragraphIndent;
  }
}
