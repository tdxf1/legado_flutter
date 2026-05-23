/// 淡入淡出翻页 delegate
///
/// 当前页与下一页/上一页通过 Opacity 交叉淡入淡出。
/// 不依赖位移计算，最简单的水平 delegate 子类。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../text_page.dart';
import '../page_view_controller.dart';
import 'horizontal_page_delegate.dart';

class FadePageDelegate extends HorizontalPageDelegate {
  FadePageDelegate({
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
    final progress = animProgress.clamp(0.0, 1.0);

    if (direction == PageDirection.next &&
        (nextPicture != null || nextPage != null)) {
      // MD3: draw current page at full alpha (bottom), then incoming page
      // fading in on top with alpha = progress.
      drawPage(canvas, curPicture, currentPage, Offset.zero);
      _drawWithAlpha(canvas, size, nextPicture, nextPage, progress);
    } else if (direction == PageDirection.prev &&
        (prevPicture != null || prevPage != null)) {
      // MD3: draw current page at full alpha (bottom), then incoming page
      // fading in on top with alpha = progress.
      drawPage(canvas, curPicture, currentPage, Offset.zero);
      _drawWithAlpha(canvas, size, prevPicture, prevPage, progress);
    } else {
      drawStaticCurrent(canvas, size, currentPage, totalPages);
    }
  }

  void _drawWithAlpha(
    Canvas canvas,
    Size size,
    ui.Picture? picture,
    TextPage? fallbackPage,
    double alpha,
  ) {
    final clamped = alpha.clamp(0.0, 1.0);
    final paint = Paint()
      ..color = Color.fromRGBO(255, 255, 255, clamped);
    final rect = Offset.zero & size;
    canvas.saveLayer(rect, paint);
    drawPage(canvas, picture, fallbackPage, Offset.zero);
    canvas.restore();
  }

  @override
  void dispose() {}
}
