import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../../../core/providers.dart';
import '../../../core/widgets/safe_setstate.dart';
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

  /// Subtask C：跨章动画完成后的"真切章"回调（与 [onChapterBoundary]
  /// 共存，分工：邻章已就绪走动画 + 这个 callback；邻章未就绪 fallback
  /// 走 [onChapterBoundary]）。
  final ChapterBoundaryCallback? onCrossChapter;

  /// Bug 3: MD3 isCompleted 门控 — 当前章排版完成前阻断 touch 事件。
  /// 默认 true 保持向后兼容（非 reader_page 调用方不受影响）。
  final bool isPageLayoutReady;

  /// Test-only sink. Whenever the internal [PageDelegate] is (re)created,
  /// this callback is invoked with the fresh instance so widget tests can
  /// observe `startTouch`, `isRunning`, etc. without exposing private state.
  ///
  /// Production callers leave this null; the field is annotated with
  /// [visibleForTesting] to keep static-analysis happy.
  @visibleForTesting
  final ValueChanged<PageDelegate>? debugDelegateSink;

  const PageViewWidget({
    super.key,
    required this.controller,
    required this.settings,
    this.pageAnim = 0,
    this.onChapterBoundary,
    this.onCrossChapter,
    this.isPageLayoutReady = true,
    this.debugDelegateSink,
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

  // Slop state machine (Task 3 — slop-startpoint).
  //
  // We replaced GestureDetector(onHorizontalDrag*) with a raw Listener so the
  // delegate's startTouch reflects the *slop-crossed* pointer position, not
  // the pointer-down position. Mirrors Legado MD3
  // HorizontalPageDelegate.onTouch's `setStartPoint(event.x, event.y, false)`
  // when isMoved first flips true.
  bool _slopExceeded = false;
  Offset? _pointerDownPos;
  int? _activePointerId;
  VelocityTracker? _velocityTracker;

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
        oldWidget.settings.effectiveBackgroundColor != widget.settings.effectiveBackgroundColor ||
        oldWidget.settings.pageAnimDurationMs != widget.settings.pageAnimDurationMs) {
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
    safeSetState(() {});
  }

  void _createDelegate() {
    _animController?.dispose();
    _animController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: widget.settings.pageAnimDurationMs),
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
          onCrossChapter: widget.onCrossChapter,
        );
        break;
      case ReaderPageAnim.slide:
        _delegate = SlidePageDelegate(
          controller: ctrl,
          settings: widget.settings,
          animController: _animController!,
          onChapterBoundary: widget.onChapterBoundary,
          onCrossChapter: widget.onCrossChapter,
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
                safeSetState(() {});
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
          onCrossChapter: widget.onCrossChapter,
          degrade: _simDegrade,
        );
        break;
      case ReaderPageAnim.fade:
        _delegate = FadePageDelegate(
          controller: ctrl,
          settings: widget.settings,
          animController: _animController!,
          onChapterBoundary: widget.onChapterBoundary,
          onCrossChapter: widget.onCrossChapter,
        );
        break;
      case ReaderPageAnim.noAnim:
      default:
        _delegate = NoAnimPageDelegate(
          controller: ctrl,
          settings: widget.settings,
          animController: _animController!,
          onChapterBoundary: widget.onChapterBoundary,
          onCrossChapter: widget.onCrossChapter,
        );
    }

    // Bug 2.5: 把 onTapNext/onTapPrev 注入 controller，让外层（reader_page）
    // 点击屏幕左/右 1/3 时通过 delegate 跑动画再切页。
    // 动画时长由 settings.pageAnimDurationMs 决定（与 AnimationController
    // duration 一致），用户在设置面板调节滑块即可改变 tap / drag fling 时长。
    final animMs = widget.settings.pageAnimDurationMs;
    ctrl.onTapNext = () => _delegate.nextPageByAnim(animMs);
    ctrl.onTapPrev = () => _delegate.prevPageByAnim(animMs);

    // Test-only hook — see [PageViewWidget.debugDelegateSink].
    widget.debugDelegateSink?.call(_delegate);
  }

  PageDirection _detectDirection(double velocityX) {
    if (velocityX < -50) return PageDirection.next;
    if (velocityX > 50) return PageDirection.prev;
    return PageDirection.none;
  }

  // ── Pointer handlers (Task 3) ──────────────────────────────────────
  //
  // Why raw Listener instead of GestureDetector.onHorizontalDrag*:
  //   * `DragStartDetails.localPosition` always reports the pointer-down
  //     position, not the slop-crossed position. SimulationPageDelegate
  //     needs the *slop-crossed* position to anchor the page corner under
  //     the finger; otherwise the curl visibly snaps from the down-frame
  //     coordinate to the user's actual drag origin.
  //   * Listener does not participate in the gesture arena, so the outer
  //     ReaderPage GestureDetector(onTapUp) keeps working untouched.
  //
  // Reentrance guard (Task 6 / commit 862d4c8) is preserved: every handler
  // short-circuits while `_delegate.isRunning` so an in-flight animation's
  // ui.Picture references are never released by a fresh onDragStart.

  void _onPointerDown(PointerDownEvent e) {
    if (_delegate.isRunning) return;
    if (_activePointerId != null) return; // multi-touch: track primary only
    _activePointerId = e.pointer;
    _slopExceeded = false;
    _pointerDownPos = e.localPosition;
    _velocityTracker = VelocityTracker.withKind(e.kind);
    _velocityTracker!.addPosition(e.timeStamp, e.localPosition);
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_delegate.isRunning) return;
    if (e.pointer != _activePointerId) return;
    if (_pageSize.isEmpty) return;
    _velocityTracker?.addPosition(e.timeStamp, e.localPosition);

    if (!_slopExceeded) {
      final downPos = _pointerDownPos;
      if (downPos == null) return;
      final delta = e.localPosition - downPos;
      const slop = kTouchSlop;
      if (delta.distanceSquared > slop * slop) {
        _slopExceeded = true;
        // R3.2: pin startTouch to the slop-crossed position, not the
        // pointer-down position.
        final ctrl = widget.controller;
        _delegate.recordTouchStart(e.localPosition, _pageSize);
        _delegate.onDragStart(
            _pageSize, ctrl.currentPage, ctrl.nextPage, ctrl.prevPage);
      } else {
        return;
      }
    }

    _delegate.recordTouchUpdate(e.localPosition);
    _delegate.onDragUpdate(e.delta.dx);
    // X1.12：仿真翻页 draw 几何完全由 currentTouch 驱动，但
    // _PageViewPainter.shouldRepaint 默认只看 progress / direction 等。
    // drag 期间用户手指快速推进时 progress 推进节奏跟不上 currentTouch，
    // 需要主动 setState 让 LayoutBuilder → CustomPaint 重 build → painter
    // 拿到新 currentTouch 触发 shouldRepaint。
    safeSetState(() {});
  }

  void _onPointerUp(PointerUpEvent e) {
    if (e.pointer != _activePointerId) return;
    _activePointerId = null;
    if (!_slopExceeded) {
      // R3.4: tap path — let the outer ReaderPage GestureDetector handle it.
      _slopExceeded = false;
      _pointerDownPos = null;
      _velocityTracker = null;
      return;
    }
    _slopExceeded = false;
    _pointerDownPos = null;
    final tracker = _velocityTracker;
    _velocityTracker = null;
    // R3.6: animation already running — swallow.
    if (_delegate.isRunning) return;
    final velocity =
        tracker?.getVelocity().pixelsPerSecond.dx ?? 0.0;
    final dir = _detectDirection(velocity);
    _delegate.fling(velocity);
    _delegate.onDragEnd(dir);
  }

  void _onPointerCancel(PointerCancelEvent e) {
    if (e.pointer != _activePointerId) return;
    _activePointerId = null;
    final wasSlopExceeded = _slopExceeded;
    _slopExceeded = false;
    _pointerDownPos = null;
    _velocityTracker = null;
    // R3.5: do not call fling/onDragEnd — avoid spurious page flips.
    //
    // BUT: if slop already crossed, `onDragStart` allocated three ui.Pictures
    // and `onDragUpdate` already mutated `_direction` / `_dragOffset` /
    // `animController.value`. Without an explicit reset, the next drag would
    // accumulate onto stale state ("ghost progress" — page appears to jump
    // half-way on first move). `cancelDrag` releases pictures and zeroes the
    // delegate; only call it when we know onDragStart actually ran.
    if (wasSlopExceeded && !_delegate.isRunning) {
      _delegate.cancelDrag();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Bug 3: MD3 isCompleted 门控 — 排版完成前阻断所有触摸事件
    if (!widget.isPageLayoutReady) {
      return IgnorePointer(
        child: _buildContent(context),
      );
    }
    return _buildContent(context);
  }

  Widget _buildContent(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        _pageSize = size;
        widget.controller.updatePageSize(size);
        // 关键修复：同步把 size 灌给 delegate，让 tap / 程序化翻页路径
        // （不走 onDragStart → recordTouchStart）也能用真实尺寸渲染 picture。
        // 否则 nextPageByAnim 里 pageSize.isEmpty 走 fallback 400x600 →
        // 动画期间只在左上角显示下一页内容，剩下空白；动画结束后真实尺寸
        // 重画 → 用户感知"动画完内容才开始变"。
        _delegate.updatePageSize(size);

        return Listener(
          // translucent: don't claim hit-region exclusively, so the outer
          // ReaderPage GestureDetector(onTapUp) still receives taps that
          // never crossed the slop threshold (R3.4 / R3.8).
          behavior: HitTestBehavior.translucent,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerCancel,
          child: AnimatedBuilder(
            // F-W2A-012 子项 1 (BATCH-19c): Listenable.merge 拆层评估后
            // 保留现状。Controller 7 处 notifyListeners 调用点全部是低
            // 频离散事件——
            //   1. setNeighborChapter (邻章注入)        每次跨章 1 次
            //   2. commitToNextChapter (跨章前进)       每次跨章 1 次
            //   3. commitToPrevChapter (跨章后退)       每次跨章 1 次
            //   4. jumpToPage (TOC 跳转)                每次用户跳章 1 次
            //   5. goToNextPage (章内翻页)              每次 tap/翻页 1 次
            //   6. goToPrevPage (章内翻页)              每次 tap/翻页 1 次
            //   7. _measureChapter (BATCH-19c phase-aware)
            //                                            每次章节加载 1 次
            // —— 实际并发上限 ≈ 用户 tap 频率（≤ 3-5 次/秒）。合并 listenable
            // 引入的"无效 painter rebuild"成本（合并后 controller notify
            // 触发 _PageViewPainter rebuild，但 shouldRepaint 大部分字段
            // 都比上次相等）可忽略，只在 anim 跑完后偶尔多一次空跑。
            //
            // 嵌套方案（外 anim-only / 内 controller-only）每帧 anim 仍
            // 重建内层 builder + painter，并不省 paint；仅在 anim **未跑**
            // 时收益（controller 单独 notify 不触发 painter）。但已经分析
            // 那种情况频率极低，不值嵌套引入的复杂度。
            //
            // 复评触发条件：若未来引入 controller 高频更新（例如滚动
            // 同步进度条 / 实时书签 hover 高亮），单 controller notify
            // 频率超过 10 次/秒，重新拆嵌套。
            // 详见 .trellis/spec/flutter-app/quality-and-anti-patterns.md
            // 「Reader 渲染边界 (BATCH-19c)」。
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
                  currentTouch: _delegate.currentTouch,
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

  /// X1.10/X1.11：仿真翻页 draw 几何完全由 [PageDelegate.currentTouch] 驱动，
  /// painter 必须把 currentTouch 纳入 shouldRepaint 比较，否则 tap 路径
  /// （progress 推进但 currentTouch 也在 lerp）的几何变化会被 oldDelegate
  /// 缓存吞掉。其它 delegate 不读 currentTouch，传 Offset.zero 是无害的。
  final Offset currentTouch;

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
    required this.currentTouch,
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
    //
    // R33: removed the redundant `oldDelegate.isRunning != isRunning`
    // term — `isRunning ||` already covers the "currently animating"
    // case, and the transition `true → false` only matters once the
    // animation framework stops driving frames anyway.
    final oldS = oldDelegate.settings;
    final newS = settings;
    return isRunning ||
        oldDelegate.animProgress != animProgress ||
        oldDelegate.currentTouch != currentTouch ||
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
