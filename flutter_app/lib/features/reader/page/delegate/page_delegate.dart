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

    final totalWidth = animController.upperBound > 0
        ? (animController.upperBound - animController.lowerBound)
        : 300.0;
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

  void dispose();
}
