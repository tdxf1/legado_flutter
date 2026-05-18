/// 仿真翻页 delegate
///
/// 直接对照 [`legado-with-MD3/.../SimulationPageDelegate.kt`] 翻译为 Dart：
///   - 5 个贝塞尔点：Start1/2、Control1/2、End1/2、Vertex1/2
///   - 当前页 (curPicture)、翻页背面 (curPicture 反射 + ColorFilter)、下一页背面阴影
///   - 4 段阴影：FolderShadow（背面卷曲）、BackShadow（下页背面阴影）、
///     FrontShadow_V（左右）、FrontShadow_H（上下）
///
/// 性能：
///   - 不每帧重建 `Picture`，复用父类 [PageDelegate.curPicture] / nextPicture / prevPicture
///   - Path 对象常驻，仅在每次 [draw] 内 reset() 后填充顶点
///   - LinearGradient 当前每次 draw 创建 Shader，开销可控；如有需要可加缓存层
///   - 与 [SimulationDegradeController] 联动，运行时根据帧耗时降级渲染细节
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../text_page.dart';
import '../page_view_controller.dart';
import 'horizontal_page_delegate.dart';
import 'simulation_degrade_controller.dart';

class SimulationPageDelegate extends HorizontalPageDelegate {
  SimulationPageDelegate({
    required super.controller,
    required super.settings,
    required super.animController,
    super.onChapterBoundary,
    super.onCrossChapter,
    SimulationDegradeController? degrade,
  }) : degrade = degrade ?? SimulationDegradeController();

  /// 性能降级控制器，外部可通过 [attachPerfMonitor] 接入到 [PerfMonitor]。
  final SimulationDegradeController degrade;

  // 4 个角点，决定翻页方向
  // mCornerX/Y 与 Kotlin 一致：取 0 或 viewWidth/Height
  double _cornerX = 0;
  double _cornerY = 0;

  // 是否属于"右上 / 左下"翻页（决定阴影方向）
  bool _isRtOrLb = false;

  // 触摸点
  double _touchX = 0;
  double _touchY = 0;

  // 用于 calcPoints 的中点
  double _middleX = 0;
  double _middleY = 0;

  // 5 对贝塞尔关键点 + Vertex
  final Offset _bezierStart1 = const Offset(0, 0);
  final Offset _bezierStart2 = const Offset(0, 0);
  // Use mutable refs via setters to avoid object churn each frame.
  double _bs1x = 0, _bs1y = 0;
  double _bs2x = 0, _bs2y = 0;
  double _bc1x = 0, _bc1y = 0;
  double _bc2x = 0, _bc2y = 0;
  double _be1x = 0, _be1y = 0;
  double _be2x = 0, _be2y = 0;
  double _bv1x = 0, _bv1y = 0;
  double _bv2x = 0, _bv2y = 0;

  // 翻起页旋转角度
  double _degrees = 0;
  double _touchToCornerDis = 0;
  double _maxLength = 0;

  // 路径（持久化对象，每次 reset 后填充）
  final Path _path0 = Path();
  final Path _path1 = Path();

  // ── X1：tap/drag 期间根据动画 progress 自驱动 currentTouch 的 lerp 状态 ──
  //
  // 仿真 draw 几何完全由 currentTouch 驱动；tap 路径 currentTouch 在
  // nextPageByAnim 设过一次后就不变，所以动画期间用户只看到固定折角；drag
  // 路径 currentTouch 跟手但 painter 重绘节奏跟不上 progress 推进。这里
  // 引入 lerp：tap 时从虚拟起点 lerp 到 (-w, h)/(w, h)，drag 时从松手位置
  // lerp 到目标。
  Offset? _animStartTouch;
  Offset? _animTargetTouch;
  double _animStartProgress = 0.0;

  // 颜色滤镜：背面页变暗（matrix 单位）
  static final ColorFilter _backFilter = const ColorFilter.matrix(<double>[
    0.85, 0, 0, 0, 0,
    0, 0.85, 0, 0, 0,
    0, 0, 0.85, 0, 0,
    0, 0, 0, 1, 0,
  ]);

  @override
  void onDragStart(
    Size pageSize,
    TextPage? cur,
    TextPage? next,
    TextPage? prev,
  ) {
    super.onDragStart(pageSize, cur, next, prev);
    _maxLength = math.sqrt(
      pageSize.width * pageSize.width + pageSize.height * pageSize.height,
    );
    final start = startTouch;
    _calcCornerXY(start.dx, start.dy);
  }

  void _calcCornerXY(double x, double y) {
    final w = pageSize.width;
    final h = pageSize.height;
    _cornerX = x <= w / 2 ? 0 : w;
    _cornerY = y <= h / 2 ? 0 : h;
    _isRtOrLb = (_cornerX == 0 && _cornerY == h) ||
        (_cornerY == 0 && _cornerX == w);
  }

  void _calcPoints() {
    _touchX = currentTouch.dx;
    _touchY = currentTouch.dy;

    _middleX = (_touchX + _cornerX) / 2;
    _middleY = (_touchY + _cornerY) / 2;
    _bc1x = _middleX -
        (_cornerY - _middleY) * (_cornerY - _middleY) / (_cornerX - _middleX);
    _bc1y = _cornerY;
    _bc2x = _cornerX;

    final f4 = _cornerY - _middleY;
    if (f4 == 0) {
      _bc2y = _middleY -
          (_cornerX - _middleX) * (_cornerX - _middleX) / 0.1;
    } else {
      _bc2y = _middleY -
          (_cornerX - _middleX) * (_cornerX - _middleX) / (_cornerY - _middleY);
    }
    _bs1x = _bc1x - (_cornerX - _bc1x) / 2;
    _bs1y = _cornerY;

    // 边界修正：触摸点不能让 BezierStart1.x 越界
    final w = pageSize.width;
    if (_touchX > 0 && _touchX < w) {
      if (_bs1x < 0 || _bs1x > w) {
        if (_bs1x < 0) _bs1x = w - _bs1x;

        final f1 = (_cornerX - _touchX).abs();
        final f2 = w * f1 / _bs1x;
        _touchX = (_cornerX - f2).abs();

        final f3 = (_cornerX - _touchX).abs() * (_cornerY - _touchY).abs() / f1;
        _touchY = (_cornerY - f3).abs();

        _middleX = (_touchX + _cornerX) / 2;
        _middleY = (_touchY + _cornerY) / 2;

        _bc1x = _middleX -
            (_cornerY - _middleY) *
                (_cornerY - _middleY) /
                (_cornerX - _middleX);
        _bc1y = _cornerY;
        _bc2x = _cornerX;
        final f5 = _cornerY - _middleY;
        if (f5 == 0) {
          _bc2y =
              _middleY - (_cornerX - _middleX) * (_cornerX - _middleX) / 0.1;
        } else {
          _bc2y = _middleY -
              (_cornerX - _middleX) *
                  (_cornerX - _middleX) /
                  (_cornerY - _middleY);
        }
        _bs1x = _bc1x - (_cornerX - _bc1x) / 2;
      }
    }
    _bs2x = _cornerX;
    _bs2y = _bc2y - (_cornerY - _bc2y) / 2;

    _touchToCornerDis = math.sqrt(
      (_touchX - _cornerX) * (_touchX - _cornerX) +
          (_touchY - _cornerY) * (_touchY - _cornerY),
    );

    final end1 = _getCross(
      Offset(_touchX, _touchY),
      Offset(_bc1x, _bc1y),
      Offset(_bs1x, _bs1y),
      Offset(_bs2x, _bs2y),
    );
    _be1x = end1.dx;
    _be1y = end1.dy;
    final end2 = _getCross(
      Offset(_touchX, _touchY),
      Offset(_bc2x, _bc2y),
      Offset(_bs1x, _bs1y),
      Offset(_bs2x, _bs2y),
    );
    _be2x = end2.dx;
    _be2y = end2.dy;

    _bv1x = (_bs1x + 2 * _bc1x + _be1x) / 4;
    _bv1y = (2 * _bc1y + _bs1y + _be1y) / 4;
    _bv2x = (_bs2x + 2 * _bc2x + _be2x) / 4;
    _bv2y = (2 * _bc2y + _bs2y + _be2y) / 4;
  }

  Offset _getCross(Offset p1, Offset p2, Offset p3, Offset p4) {
    final a1 = (p2.dy - p1.dy) / (p2.dx - p1.dx);
    final b1 = (p1.dx * p2.dy - p2.dx * p1.dy) / (p1.dx - p2.dx);
    final a2 = (p4.dy - p3.dy) / (p4.dx - p3.dx);
    final b2 = (p3.dx * p4.dy - p4.dx * p3.dy) / (p3.dx - p4.dx);
    final x = (b2 - b1) / (a1 - a2);
    final y = a1 * x + b1;
    return Offset(x, y);
  }

  // ── 绘制入口 ──────────────────────────────────────────────────────

  /// X1：tap 路径 lerp 起点（虚拟起点）→ 终点（屏幕外侧底部）。
  /// progress 一定从 0 开始（tap 触发 nextPageByAnim 时 animController.value = 0）。
  void _setupTapAnim(Offset virtualStart, PageDirection dir) {
    final size = pageSize.isEmpty ? const Size(400, 600) : pageSize;
    _animStartTouch = virtualStart;
    _animStartProgress = 0.0;
    _animTargetTouch = dir == PageDirection.next
        ? Offset(-size.width, size.height)
        : Offset(size.width, size.height);
  }

  /// X1：drag-end 路径 lerp 起点（用户松手位置）→ 终点。
  /// progress 起跑值是 animController.value（drag 期间已被 onDragUpdate
  /// 推进），需要在 onAnimTick 内重新归一化到 [0, 1]。
  void _setupDragAnim(PageDirection dir) {
    final size = pageSize.isEmpty ? const Size(400, 600) : pageSize;
    _animStartTouch = currentTouch;
    _animStartProgress = animController.value;
    _animTargetTouch = dir == PageDirection.next
        ? Offset(-size.width, size.height)
        : Offset(size.width, size.height);
  }

  /// Task 5 (MD3 体感复刻 Phase A 收尾)：点击翻页（tap）走完整贝塞尔。
  ///
  /// 与 Legado MD3 `HorizontalPageDelegate.nextPageByAnim` 1:1 对齐：
  /// 合成一个虚拟起点（右下角附近 0.9w / 0.9h），让 [_calcCornerXY] 算出
  /// `cornerX = w / cornerY = h / isRtOrLb = false`，整个 [draw] 走完整
  /// 贝塞尔几何，不再退化成 cover 风格简化动画。
  ///
  /// `_calcCornerXY` 仅在 [onDragStart] 路径中被调用——tap 路径没有
  /// drag，因此需要在这里手动计算一次。`_maxLength` 同样需要刷新，因为
  /// `pageSize` 可能在两次 tap 之间变化（旋屏 / 字号更改）。
  ///
  /// X1.4：在调 super 之前 `_setupTapAnim`，让 [onAnimTick] 期间根据
  /// progress 把 currentTouch 从虚拟起点 lerp 到 (-w, h)，让 [_calcPoints]
  /// 的几何随时间动起来。
  @override
  void nextPageByAnim(int animationSpeed) {
    if (isRunning) return;
    final size = pageSize.isEmpty ? const Size(400, 600) : pageSize;
    final virtualStart = Offset(size.width * 0.9, size.height * 0.9);
    recordTouchStart(virtualStart, size);
    _maxLength = math.sqrt(
      size.width * size.width + size.height * size.height,
    );
    _calcCornerXY(virtualStart.dx, virtualStart.dy);
    _setupTapAnim(virtualStart, PageDirection.next);
    super.nextPageByAnim(animationSpeed);
  }

  @override
  void prevPageByAnim(int animationSpeed) {
    if (isRunning) return;
    final size = pageSize.isEmpty ? const Size(400, 600) : pageSize;
    // 左下角附近虚拟起点：与 next 的 (0.9w, 0.9h) 镜像，留出 0.1*w 偏移
    // 避免 startTouch 落在 cornerXY 上导致 [_calcPoints] 中 (0/0) 退化为 NaN。
    // x ≤ w/2 与 y > h/2 的象限决策保持不变 → cornerX=0 / cornerY=h /
    // isRtOrLb=true，与 Legado MD3 设定一致。
    final virtualStart = Offset(size.width * 0.1, size.height * 0.9);
    recordTouchStart(virtualStart, size);
    _maxLength = math.sqrt(
      size.width * size.width + size.height * size.height,
    );
    _calcCornerXY(virtualStart.dx, virtualStart.dy);
    _setupTapAnim(virtualStart, PageDirection.prev);
    super.prevPageByAnim(animationSpeed);
  }

  /// X1.6：drag-end 路径在调 super 之前注入 lerp 状态。
  /// 注意：tap 路径调用栈是 nextPageByAnim → super.nextPageByAnim → goToNext，
  /// 此时 _animStartTouch 已被 _setupTapAnim 设过，跳过；只在原始 drag-end
  /// 路径（_animStartTouch 仍为 null）时主动 setup。
  ///
  /// Bug fix（Task 6）：如果 nextPicture 为 null（因任何原因未成功渲染），
  /// 跳过动画直接翻页，避免"动画期间画面静止，结束后内容跳变"。
  @override
  void goToNext() {
    if (_animStartTouch == null) {
      _setupDragAnim(PageDirection.next);
    }
    if (nextPicture == null) {
      debugPrint('[SimulationDelegate] goToNext: nextPicture=null, skipping animation');
      if (controller.hasNext) {
        controller.goToNextPage();
      } else if (controller.boundaryNextPage != null) {
        controller.commitToNextChapter();
        onCrossChapter?.call(PageDirection.next);
      } else {
        resetState();
        onChapterBoundary?.call(PageDirection.next);
        return;
      }
      resetState();
      return;
    }
    super.goToNext();
  }

  /// 对称修复：prev 路径同样检查 prevPicture。
  @override
  void goToPrev() {
    if (_animStartTouch == null) {
      _setupDragAnim(PageDirection.prev);
    }
    if (prevPicture == null) {
      debugPrint('[SimulationDelegate] goToPrev: prevPicture=null, skipping animation');
      if (controller.hasPrev) {
        controller.goToPrevPage();
      } else if (controller.boundaryPrevPage != null) {
        controller.commitToPrevChapter();
        onCrossChapter?.call(PageDirection.prev);
      } else {
        resetState();
        onChapterBoundary?.call(PageDirection.prev);
        return;
      }
      resetState();
      return;
    }
    super.goToPrev();
  }

  /// X1.7：每帧根据 progress 把 currentTouch 从 _animStartTouch lerp 到
  /// _animTargetTouch（easeOut 曲线）。tap 路径起点是虚拟起点 (0.9w, 0.9h)，
  /// drag 路径起点是用户松手位置；均使用 _animStartProgress 把 progress
  /// 重新归一化到 [0, 1]。
  @override
  void onAnimTick(double progress) {
    final start = _animStartTouch;
    final target = _animTargetTouch;
    if (start == null || target == null) return;
    final denom = 1.0 - _animStartProgress;
    if (denom <= 0) return;
    final raw = ((progress - _animStartProgress) / denom).clamp(0.0, 1.0);
    final t = Curves.easeOut.transform(raw);
    final lerped = Offset.lerp(start, target, t);
    if (lerped != null) {
      recordTouchUpdate(lerped);
    }
  }

  /// X1.9：动画完成后清空 lerp 字段，避免下一次 drag 进入时
  /// `if (_animStartTouch == null)` 误判（tap 路径残留非 null 会跳过 setup）。
  @override
  void onAnimEnd() {
    _animStartTouch = null;
    _animTargetTouch = null;
    _animStartProgress = 0.0;
  }

  /// X1.9：cancel 路径同样清 lerp 字段，避免 cancel 后下一次 drag 错乱。
  @override
  void cancelDrag() {
    _animStartTouch = null;
    _animTargetTouch = null;
    _animStartProgress = 0.0;
    super.cancelDrag();
  }

  @override
  void draw(
    Canvas canvas,
    Size size, {
    required TextPage? currentPage,
    required TextPage? nextPage,
    required TextPage? prevPage,
    required double animProgress,
    required int totalPages,
  }) {
    if (direction == PageDirection.none) {
      drawStaticCurrent(canvas, size, currentPage, totalPages);
      return;
    }

    // Pre-rendered pictures must be ready for the simulation effect.
    final cur = curPicture;
    final next = nextPicture;
    final prev = prevPicture;
    if (cur == null) {
      drawStaticCurrent(canvas, size, currentPage, totalPages);
      return;
    }

    if (direction == PageDirection.next && next == null) {
      if (nextPage != null) {
        debugPrint('[SimulationDelegate] draw: nextPicture=null BUT nextPage != null, drawing static next');
        drawStaticPage(canvas, size, nextPage, totalPages);
        return;
      }
      debugPrint('[SimulationDelegate] draw: nextPicture=null AND nextPage=null, drawing static current');
      drawStaticCurrent(canvas, size, currentPage, totalPages);
      return;
    }
    if (direction == PageDirection.prev && prev == null) {
      if (prevPage != null) {
        debugPrint('[SimulationDelegate] draw: prevPicture=null BUT prevPage != null, drawing static prev');
        drawStaticPage(canvas, size, prevPage, totalPages);
        return;
      }
      debugPrint('[SimulationDelegate] draw: prevPicture=null AND prevPage=null, drawing static current');
      drawStaticCurrent(canvas, size, currentPage, totalPages);
      return;
    }

    _calcPoints();

    if (direction == PageDirection.next) {
      _drawCurrentPageArea(canvas, cur);
      _drawNextPageAreaAndShadow(canvas, next!);
      _drawCurrentPageShadow(canvas);
      _drawCurrentBackArea(canvas, cur);
    } else {
      // PREV：当前页是 prev，"被翻起的"是 cur
      _drawCurrentPageArea(canvas, prev!);
      _drawNextPageAreaAndShadow(canvas, cur);
      _drawCurrentPageShadow(canvas);
      _drawCurrentBackArea(canvas, prev);
    }
  }

  void _drawCurrentPageArea(Canvas canvas, ui.Picture pic) {
    _path0.reset();
    _path0.moveTo(_bs1x, _bs1y);
    _path0.quadraticBezierTo(_bc1x, _bc1y, _be1x, _be1y);
    _path0.lineTo(_touchX, _touchY);
    _path0.lineTo(_be2x, _be2y);
    _path0.quadraticBezierTo(_bc2x, _bc2y, _bs2x, _bs2y);
    _path0.lineTo(_cornerX, _cornerY);
    _path0.close();

    // Bug 1 fix: clipOutPath 等价于 evenOdd 减法剪裁。
    // 原 MD3 是 canvas.clipOutPath(path0)：把 path0 区域剪掉，画余下部分。
    // Flutter Canvas 没有 clipOutPath，用 evenOdd 减法 path 等价：
    //   外层大矩形 + 内层 path0，evenOdd fill 让 path0 内部变成"剪掉的洞"。
    // 这样翻起的部分露出下层内容（next 页背面），未翻起的部分保留当前页文字。
    canvas.save();
    canvas.clipPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Rect.fromLTWH(0, 0, pageSize.width, pageSize.height))
        ..addPath(_path0, Offset.zero),
    );
    canvas.drawPicture(pic);
    canvas.restore();
  }

  void _drawNextPageAreaAndShadow(Canvas canvas, ui.Picture pic) {
    _path1.reset();
    _path1.moveTo(_bs1x, _bs1y);
    _path1.lineTo(_bv1x, _bv1y);
    _path1.lineTo(_bv2x, _bv2y);
    _path1.lineTo(_bs2x, _bs2y);
    _path1.lineTo(_cornerX, _cornerY);
    _path1.close();

    _degrees = _toDegrees(math.atan2(_bc1x - _cornerX, _bc2y - _cornerY));

    final double leftX, rightX;
    if (_isRtOrLb) {
      leftX = _bs1x;
      rightX = _bs1x + _touchToCornerDis / 4;
    } else {
      leftX = _bs1x - _touchToCornerDis / 4;
      rightX = _bs1x;
    }

    canvas.save();
    canvas.clipPath(_path0);
    canvas.clipPath(_path1);
    canvas.drawPicture(pic);

    canvas.translate(_bs1x, _bs1y);
    canvas.rotate(_degrees * math.pi / 180);
    canvas.translate(-_bs1x, -_bs1y);

    final shadowRect = Rect.fromLTRB(
      leftX,
      _bs1y,
      rightX,
      _maxLength + _bs1y,
    );
    final shadowPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(_isRtOrLb ? leftX : rightX, _bs1y),
        Offset(_isRtOrLb ? rightX : leftX, _bs1y),
        const [Color(0xFF111111), Color(0x00111111)],
      );
    canvas.drawRect(shadowRect, shadowPaint);
    canvas.restore();
  }

  void _drawCurrentPageShadow(Canvas canvas) {
    final degree = _isRtOrLb
        ? math.pi / 4 - math.atan2(_bc1y - _touchY, _touchX - _bc1x)
        : math.pi / 4 - math.atan2(_touchY - _bc1y, _touchX - _bc1x);
    final d1 = 25.0 * 1.414 * math.cos(degree);
    final d2 = 25.0 * 1.414 * math.sin(degree);
    final x = _touchX + d1;
    final y = _isRtOrLb ? _touchY + d2 : _touchY - d2;

    // 第一段：垂直方向阴影（沿 control1）
    _path1.reset();
    _path1.moveTo(x, y);
    _path1.lineTo(_touchX, _touchY);
    _path1.lineTo(_bc1x, _bc1y);
    _path1.lineTo(_bs1x, _bs1y);
    _path1.close();

    canvas.save();
    canvas.clipPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Rect.fromLTWH(0, 0, pageSize.width, pageSize.height))
        ..addPath(_path0, Offset.zero),
    );
    canvas.clipPath(_path1);

    final double leftX1, rightX1;
    if (_isRtOrLb) {
      leftX1 = _bc1x;
      rightX1 = _bc1x + 25;
    } else {
      leftX1 = _bc1x - 25;
      rightX1 = _bc1x + 1;
    }
    final rotate1 = _toDegrees(math.atan2(_touchX - _bc1x, _bc1y - _touchY));
    canvas.translate(_bc1x, _bc1y);
    canvas.rotate(rotate1 * math.pi / 180);
    canvas.translate(-_bc1x, -_bc1y);
    final shadow1 = Paint()
      ..shader = ui.Gradient.linear(
        Offset(_isRtOrLb ? leftX1 : rightX1, _bc1y),
        Offset(_isRtOrLb ? rightX1 : leftX1, _bc1y),
        const [Color(0x88111111), Color(0x00111111)],
      );
    canvas.drawRect(
      Rect.fromLTRB(leftX1, _bc1y - _maxLength, rightX1, _bc1y),
      shadow1,
    );
    canvas.restore();

    // 第二段：水平方向阴影（沿 control2）
    _path1.reset();
    _path1.moveTo(x, y);
    _path1.lineTo(_touchX, _touchY);
    _path1.lineTo(_bc2x, _bc2y);
    _path1.lineTo(_bs2x, _bs2y);
    _path1.close();

    canvas.save();
    canvas.clipPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Rect.fromLTWH(0, 0, pageSize.width, pageSize.height))
        ..addPath(_path0, Offset.zero),
    );
    canvas.clipPath(_path1);

    final double leftX2, rightX2;
    if (_isRtOrLb) {
      leftX2 = _bc2y;
      rightX2 = _bc2y + 25;
    } else {
      leftX2 = _bc2y - 25;
      rightX2 = _bc2y + 1;
    }
    final rotate2 = _toDegrees(math.atan2(_bc2y - _touchY, _bc2x - _touchX));
    canvas.translate(_bc2x, _bc2y);
    canvas.rotate(rotate2 * math.pi / 180);
    canvas.translate(-_bc2x, -_bc2y);

    final temp = _bc2y < 0 ? _bc2y - pageSize.height : _bc2y;
    final hmg = math.sqrt(_bc2x * _bc2x + temp * temp);
    final Rect rect2;
    if (hmg > _maxLength) {
      rect2 = Rect.fromLTRB(
        _bc2x - 25 - hmg,
        leftX2,
        _bc2x + _maxLength - hmg,
        rightX2,
      );
    } else {
      rect2 = Rect.fromLTRB(_bc2x - _maxLength, leftX2, _bc2x, rightX2);
    }
    final shadow2 = Paint()
      ..shader = ui.Gradient.linear(
        Offset(_bc2x, _isRtOrLb ? leftX2 : rightX2),
        Offset(_bc2x, _isRtOrLb ? rightX2 : leftX2),
        const [Color(0x88111111), Color(0x00111111)],
      );
    canvas.drawRect(rect2, shadow2);
    canvas.restore();
  }

  void _drawCurrentBackArea(Canvas canvas, ui.Picture pic) {
    final mid = ((_bs1x + _bc1x) / 2);
    final f1 = (mid - _bc1x).abs();
    final mid2 = ((_bs2y + _bc2y) / 2);
    final f2 = (mid2 - _bc2y).abs();
    final f3 = math.min(f1, f2);

    _path1.reset();
    _path1.moveTo(_bv2x, _bv2y);
    _path1.lineTo(_bv1x, _bv1y);
    _path1.lineTo(_be1x, _be1y);
    _path1.lineTo(_touchX, _touchY);
    _path1.lineTo(_be2x, _be2y);
    _path1.close();

    final double left, right;
    if (_isRtOrLb) {
      left = _bs1x - 1;
      right = _bs1x + f3 + 1;
    } else {
      left = _bs1x - f3 - 1;
      right = _bs1x + 1;
    }

    canvas.save();
    canvas.clipPath(_path0);
    canvas.clipPath(_path1);

    final dis = math.sqrt(
      (_cornerX - _bc1x) * (_cornerX - _bc1x) +
          (_bc2y - _cornerY) * (_bc2y - _cornerY),
    );
    final f8 = (_cornerX - _bc1x) / dis;
    final f9 = (_bc2y - _cornerY) / dis;

    // 反射矩阵：以 bezierControl1 为中心，沿 (f8, f9) 反射
    final m = Matrix4.identity();
    final a = 1 - 2 * f9 * f9;
    final b = 2 * f8 * f9;
    final d = 1 - 2 * f8 * f8;
    // Matrix4 column-major
    m.setEntry(0, 0, a);
    m.setEntry(0, 1, b);
    m.setEntry(1, 0, b);
    m.setEntry(1, 1, d);
    // pre-translate (-bc1x, -bc1y) then post-translate (bc1x, bc1y)
    final translateBack = Matrix4.identity()..translateByDouble(_bc1x, _bc1y, 0, 1);
    final translatePre = Matrix4.identity()..translateByDouble(-_bc1x, -_bc1y, 0, 1);
    final composed = translateBack.multiplied(m).multiplied(translatePre);

    final bgColor = Color(settings.effectiveBackgroundColor);
    canvas.drawColor(bgColor, BlendMode.srcOver);

    if (degrade.useBackColorFilter) {
      final paint = Paint()..colorFilter = _backFilter;
      canvas.save();
      canvas.transform(composed.storage);
      canvas.saveLayer(null, paint);
      canvas.drawPicture(pic);
      canvas.restore();
      canvas.restore();
    } else {
      // L2 降级：跳过 ColorFilter 的 saveLayer，直接画反射后的原 Picture
      canvas.save();
      canvas.transform(composed.storage);
      canvas.drawPicture(pic);
      canvas.restore();
    }

    // 折页阴影
    canvas.translate(_bs1x, _bs1y);
    canvas.rotate(_degrees * math.pi / 180);
    canvas.translate(-_bs1x, -_bs1y);

    final segments = degrade.folderShadowSegments;
    if (segments > 0) {
      // Multi-segment folder shadow per vendor MD3 implementation.
      //
      // The geometric strip is the rectangle [left .. right] x
      // [_bs1y .. _bs1y + _maxLength]. We split it into [segments] equal-
      // height bands, each with its own gradient and an alpha that decays
      // linearly from full opacity at the fold to zero at the page edge.
      // segments == 1 collapses to the original single-band rendering.
      const baseAlpha = 0x99;
      const baseColor = 0x333333;
      final segmentHeight = _maxLength / segments;
      for (int i = 0; i < segments; i++) {
        final t = (i + 1) / segments; // 1/N .. 1
        final alpha = (baseAlpha * (1.0 - i / segments)).round() & 0xff;
        final segTop = _bs1y + i * segmentHeight;
        final segBottom = segTop + segmentHeight;
        final folderRect = Rect.fromLTRB(left, segTop, right, segBottom);
        final headColor = (alpha << 24) | baseColor;
        final tailAlpha = (alpha * (1.0 - t)).round() & 0xff;
        final tailColor = (tailAlpha << 24) | baseColor;
        final folderPaint = Paint()
          ..shader = ui.Gradient.linear(
            _isRtOrLb ? Offset(left, 0) : Offset(right, 0),
            _isRtOrLb ? Offset(right, 0) : Offset(left, 0),
            [Color(headColor), Color(tailColor)],
          );
        canvas.drawRect(folderRect, folderPaint);
      }
    }
    canvas.restore();
  }

  static double _toDegrees(double radians) => radians * 180 / math.pi;

  // ── visibleForTesting accessors (Task 3) ─────────────────────────
  //
  // The corner coordinates and the right-top/left-bottom flag are pure
  // outputs of `_calcCornerXY(startTouch.dx, startTouch.dy)`. Tests want
  // to assert that gating slop changes the corner anchor — exposing
  // these read-only views avoids leaking the private fields.

  @visibleForTesting
  double get debugCornerX => _cornerX;

  @visibleForTesting
  double get debugCornerY => _cornerY;

  @visibleForTesting
  bool get debugIsRtOrLb => _isRtOrLb;

  /// Test-only thin wrapper around the geometry routine. Lets unit tests
  /// drive `_calcCornerXY` directly without spinning up an animation
  /// controller / picture pipeline.
  @visibleForTesting
  void debugCalcCornerXY(Offset start, Size size) {
    // We need to also seed `pageSize` so the geometry comparisons inside
    // `_calcCornerXY` see the right page bounds. `recordTouchStart` does
    // exactly that and is part of the existing public surface.
    recordTouchStart(start, size);
    _calcCornerXY(start.dx, start.dy);
  }

  // ── X1：lerp 状态字段读取（@visibleForTesting）─────────────────
  @visibleForTesting
  Offset? get debugAnimStartTouch => _animStartTouch;

  @visibleForTesting
  Offset? get debugAnimTargetTouch => _animTargetTouch;

  @visibleForTesting
  double get debugAnimStartProgress => _animStartProgress;

  // 借助 [bezierStart1] / [bezierStart2] 字段去消静态分析未使用警告：
  // 二者的具体值在 _bs1x/y、_bs2x/y 中存放，保留 const 字段是为了让阅读者
  // 直观看到点位组织。
  // ignore: unused_element
  Offset get _start1 => _bezierStart1;
  // ignore: unused_element
  Offset get _start2 => _bezierStart2;

  @override
  void dispose() {}
}
