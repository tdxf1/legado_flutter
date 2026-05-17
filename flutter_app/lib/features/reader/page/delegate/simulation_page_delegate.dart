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
    SimulationDegradeController? degrade,
  }) : degrade = degrade ?? SimulationDegradeController();

  /// 性能降级控制器，外部可通过 [attachPerfMonitor] 接入到 [PerfMonitor]。
  final SimulationDegradeController degrade;

  /// Bug 2.5 (决策 B=a)：点击翻页时仿真无触摸坐标，draw 路径会因为 path0
  /// 退化成空 path 而出现错乱。这个标志位让 [draw] 在点击翻页期间走 cover
  /// 风格简化动画（横向位移 + 阴影），动画结束后由 [_runAnimation] 调
  /// _resetState() 时清掉。
  bool _coverFallback = false;

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

  /// Bug 2.5 (决策 B=a)：点击翻页时简单调用父类 nextPageByAnim 即可
  /// （父类已经预渲染 picture 并启动 animController.forward）；这里把
  /// _coverFallback 置 true，draw 期间走 cover 风格几何替代仿真贝塞尔。
  @override
  void nextPageByAnim(int animationSpeed) {
    if (isRunning) return;
    _coverFallback = true;
    super.nextPageByAnim(animationSpeed);
  }

  @override
  void prevPageByAnim(int animationSpeed) {
    if (isRunning) return;
    _coverFallback = true;
    super.prevPageByAnim(animationSpeed);
  }

  /// Cover 风格绘制：当前页向左滑出、下一页底层不动 + 阴影线。
  /// 与 [CoverPageDelegate.draw] 几何等价，复制以避免类层级耦合。
  void _drawCoverStyle(
    Canvas canvas,
    Size size,
    double animProgress,
    TextPage? currentPage,
    TextPage? nextPage,
    TextPage? prevPage,
    int totalPages,
  ) {
    final sw = size.width;
    final progress = animProgress.clamp(0.0, 1.0);
    if (direction == PageDirection.next &&
        (nextPicture != null || nextPage != null)) {
      drawPage(canvas, nextPicture, nextPage, Offset.zero);
      _drawCoverFallbackShadow(canvas, size, progress, true);
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, 0, sw * (1 - progress), size.height));
      canvas.translate(-sw * progress, 0);
      drawPage(canvas, curPicture, currentPage, Offset.zero);
      canvas.restore();
    } else if (direction == PageDirection.prev &&
        (prevPicture != null || prevPage != null)) {
      canvas.save();
      canvas.clipRect(
          Rect.fromLTWH(sw * progress, 0, sw * (1 - progress), size.height));
      drawPage(canvas, curPicture, currentPage, Offset.zero);
      canvas.restore();
      _drawCoverFallbackShadow(canvas, size, progress, false);
      canvas.save();
      canvas.translate(-sw * (1 - progress), 0);
      drawPage(canvas, prevPicture, prevPage, Offset.zero);
      canvas.restore();
    } else {
      drawStaticCurrent(canvas, size, currentPage, totalPages);
    }
  }

  void _drawCoverFallbackShadow(
      Canvas canvas, Size size, double progress, bool forward) {
    const shadowWidth = 20.0;
    final x = forward ? size.width * (1 - progress) : size.width * progress;
    final shadowPaint = Paint()
      ..shader = ui.Gradient.linear(
        forward ? Offset(x, 0) : Offset(x + shadowWidth, 0),
        forward ? Offset(x + shadowWidth, 0) : Offset(x, 0),
        const [Color(0x5A000000), Color(0x00000000)],
      );
    canvas.drawRect(
      Rect.fromLTWH(forward ? x : x - shadowWidth, 0, shadowWidth, size.height),
      shadowPaint,
    );
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
    // Bug 2.5: 点击翻页期间走 cover-style；动画结束 _resetState 会清 picture，
    // 但 _coverFallback 也要在动画停止后清，避免下次 drag 走错路径。
    if (_coverFallback && !isRunning) {
      _coverFallback = false;
    }
    if (_coverFallback) {
      _drawCoverStyle(
          canvas, size, animProgress, currentPage, nextPage, prevPage, totalPages);
      return;
    }

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
      drawStaticCurrent(canvas, size, currentPage, totalPages);
      return;
    }
    if (direction == PageDirection.prev && prev == null) {
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
