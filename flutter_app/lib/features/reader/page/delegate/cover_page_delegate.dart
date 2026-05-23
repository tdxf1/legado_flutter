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
    super.onCrossChapter,
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
    // MD3: shadow width 30px, color 0x66111111 → 0x00000000 (dark gray to transparent)
    const shadowWidth = 30.0;
    final x = forward ? size.width * (1 - progress) : size.width * progress;
    // Both NEXT and PREV: gradient always from dark (near current-page edge) to transparent (away)
    // MD3 uses LEFT_RIGHT orientation for both directions.
    final shadowPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(x, 0),
        Offset(x + shadowWidth, 0),
        const [Color(0x66111111), Color(0x00000000)],
      );
    canvas.drawRect(
      Rect.fromLTWH(x, 0, shadowWidth, size.height),
      shadowPaint,
    );
  }

  @override
  void dispose() {}
}
