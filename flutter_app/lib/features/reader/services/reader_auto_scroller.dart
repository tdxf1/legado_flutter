/// 自动滚动 / 自动翻页器
///
/// 支持两种模式（与 reader 渲染模式对齐）：
/// - **滚动模式**：每 50ms 推进 [pixelsPerStep] 像素，靠
///   [ScrollController.jumpTo] 平滑滚动
/// - **分页模式**：每 [pageIntervalMs] 触发一次 [onPageTick]，由
///   调用方在回调里调 PageViewController.onTapNext
///
/// 不直接持 ScrollController，而是接受一个 [ScrollController] getter，
/// 这样调用方可以在不同 mode 下切换底层 scroller 而不影响本控制器。
///
/// 批次 4 (05-18): 从纯滚动 helper 升级到双模 helper，对齐原 Legado MD3
/// `AutoPager.kt` + `AutoReadDialog.kt` 的功能。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

class ReaderAutoScroller {
  ReaderAutoScroller({
    required this.controller,
    required this.onChanged,
    this.onPageTick,
    this.pixelsPerStep = 1.0,
    this.pageIntervalMs = 10000,
  });

  /// 由调用方提供：每次步进时获取当前的 ScrollController。
  /// 允许 widget 在 widget rebuild 时换 controller。
  final ValueGetter<ScrollController?> controller;

  /// 状态变化回调（调用方据此 setState 刷新 UI）。
  final VoidCallback onChanged;

  /// 分页模式回调；为 null 表示禁用分页路径（[toggle] scroll=false 时
  /// 立即 _stop）。调用方应在回调里调 PageViewController.onTapNext。
  final VoidCallback? onPageTick;

  /// 滚动模式每 [stepInterval] 推进的像素数。1.0 像素 / 50ms ≈ 20 px/s。
  /// 调用方可在运行时（如 settings 变化）直接修改此字段。
  double pixelsPerStep;

  /// 分页模式两次 [onPageTick] 之间的间隔（毫秒）。
  /// 调用方可在运行时直接修改此字段。
  int pageIntervalMs;

  Timer? _timer;
  bool _running = false;
  bool _scrollMode = true;

  /// 滚动模式步进周期。
  static const Duration stepInterval = Duration(milliseconds: 50);

  bool get isRunning => _running;

  /// 当前是否走滚动路径（true）或分页路径（false）。仅在 [_running] 时有意义。
  @visibleForTesting
  bool get debugIsScrollMode => _scrollMode;

  /// 切换运行状态。
  /// [scroll]=true 走滚动路径；false 走分页路径（依赖 [onPageTick]）。
  void toggle({bool scroll = true}) {
    if (_running) {
      _stop();
    } else {
      _start(scroll: scroll);
    }
  }

  /// 强制停止。idempotent。
  void stop() => _stop();

  void _start({required bool scroll}) {
    if (_running) return;
    if (!scroll && onPageTick == null) {
      // 分页模式但没有 callback → 无操作
      return;
    }
    _running = true;
    _scrollMode = scroll;
    onChanged();
    if (scroll) {
      _scheduleNextScroll();
    } else {
      _scheduleNextPage();
    }
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    if (!_running) return;
    _running = false;
    onChanged();
  }

  void _scheduleNextScroll() {
    _timer = Timer(stepInterval, _stepScroll);
  }

  void _stepScroll() {
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
    c.jumpTo(currentScroll + pixelsPerStep);
    _scheduleNextScroll();
  }

  void _scheduleNextPage() {
    _timer = Timer(Duration(milliseconds: pageIntervalMs), _stepPage);
  }

  void _stepPage() {
    if (!_running) return;
    final cb = onPageTick;
    if (cb == null) {
      _stop();
      return;
    }
    cb();
    if (!_running) return; // 回调可能内部触发 stop
    _scheduleNextPage();
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _running = false;
  }
}
