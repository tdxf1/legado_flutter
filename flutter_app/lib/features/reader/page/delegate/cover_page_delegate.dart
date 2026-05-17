import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../text_page.dart';
import '../page_view_controller.dart';
import 'horizontal_page_delegate.dart';

class CoverPageDelegate extends HorizontalPageDelegate {
  CoverPageDelegate({
    required super.controller,
    required super.settings,
    required super.animController,
    super.onChapterBoundary,
  });

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
    final sw = size.width;
    final progress = animProgress.clamp(0.0, 1.0);

    if (direction == PageDirection.next && (nextPicture != null || nextPage != null)) {
      // Next page sits underneath (full size, no transform)
      drawPage(canvas, nextPicture, nextPage, Offset.zero);
      _drawCoverShadow(canvas, size, progress, true);
      // Current page slides right, clipped to show only the left portion
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, 0, sw * (1 - progress), size.height));
      canvas.translate(-sw * progress, 0);
      drawPage(canvas, curPicture, currentPage, Offset.zero);
      canvas.restore();
    } else if (direction == PageDirection.prev && (prevPicture != null || prevPage != null)) {
      // Prev page slides in from left, covering current page
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(sw * progress, 0, sw * (1 - progress), size.height));
      drawPage(canvas, curPicture, currentPage, Offset.zero);
      canvas.restore();
      _drawCoverShadow(canvas, size, progress, false);
      canvas.save();
      canvas.translate(-sw * (1 - progress), 0);
      drawPage(canvas, prevPicture, prevPage, Offset.zero);
      canvas.restore();
    } else {
      drawStaticCurrent(canvas, size, currentPage, totalPages);
    }
  }

  void _drawCoverShadow(Canvas canvas, Size size, double progress, bool forward) {
    final shadowWidth = 20.0;
    final x = forward ? size.width * (1 - progress) : size.width * progress;
    final shadowPaint = Paint()
      ..shader = ui.Gradient.linear(
        forward ? Offset(x, 0) : Offset(x + shadowWidth, 0),
        forward ? Offset(x + shadowWidth, 0) : Offset(x, 0),
        [Colors.black.withAlpha(90), Colors.transparent],
      );
    canvas.drawRect(
      Rect.fromLTWH(forward ? x : x - shadowWidth, 0, shadowWidth, size.height),
      shadowPaint,
    );
  }

  @override
  void dispose() {}
}
