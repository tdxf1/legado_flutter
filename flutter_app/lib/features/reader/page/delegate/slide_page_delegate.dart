import 'package:flutter/material.dart';
import '../text_page.dart';
import '../page_view_controller.dart';
import 'horizontal_page_delegate.dart';

class SlidePageDelegate extends HorizontalPageDelegate {
  SlidePageDelegate({
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
      // Current page slides left (outgoing)
      drawPage(canvas, curPicture, currentPage, Offset(-sw * progress, 0));
      // Next page slides in from right
      drawPage(canvas, nextPicture, nextPage, Offset(sw * (1 - progress), 0));
    } else if (direction == PageDirection.prev && (prevPicture != null || prevPage != null)) {
      // Current page slides right (outgoing)
      drawPage(canvas, curPicture, currentPage, Offset(sw * progress, 0));
      // Prev page slides in from left
      drawPage(canvas, prevPicture, prevPage, Offset(-sw * (1 - progress), 0));
    } else {
      drawStaticCurrent(canvas, size, currentPage, totalPages);
    }
  }

  @override
  void dispose() {}
}
