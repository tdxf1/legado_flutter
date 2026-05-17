/// 自动滚动器
///
/// 独立的滚动循环 helper，用于阅读器"自动翻页/自动滚动"功能。
/// 每 50ms 推进 1.0 像素（极慢、稳定的连续滚动）。
///
/// 不直接持 ScrollController，而是接受一个 [ScrollController] getter，
/// 这样调用方可以在不同 mode 下切换底层 scroller 而不影响本控制器。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

class ReaderAutoScroller {
  ReaderAutoScroller({
    required this.controller,
    required this.onChanged,
  });

  /// 由调用方提供：每次步进时获取当前的 ScrollController。
  /// 允许 widget 在 widget rebuild 时换 controller。
  final ValueGetter<ScrollController?> controller;

  /// 状态变化回调（调用方据此 setState 刷新 UI）。
  final VoidCallback onChanged;

  Timer? _timer;
  bool _running = false;

  /// 单步推进的像素数。1.0 像素 / 50ms ≈ 20 px/s，是较温和的自动滚动速度。
  static const double stepPx = 1.0;

  /// 步进周期。
  static const Duration stepInterval = Duration(milliseconds: 50);

  bool get isRunning => _running;

  /// 切换运行状态。
  void toggle() {
    if (_running) {
      _stop();
    } else {
      _start();
    }
  }

  void _start() {
    if (_running) return;
    _running = true;
    onChanged();
    _scheduleNext();
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    if (!_running) return;
    _running = false;
    onChanged();
  }

  void _scheduleNext() {
    _timer = Timer(stepInterval, _step);
  }

  void _step() {
    if (!_running) return;
    final c = controller();
    if (c == null || !c.hasClients) {
      _stop();
      return;
    }
    final maxScroll = c.position.maxScrollExtent;
    final currentScroll = c.position.pixels;
    if (currentScroll >= maxScroll) {
      _stop();
      return;
    }
    c.jumpTo(currentScroll + stepPx);
    _scheduleNext();
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _running = false;
  }
}
