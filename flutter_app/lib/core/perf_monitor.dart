/// 帧耗时监控
///
/// 包裹 [SchedulerBinding.addTimingsCallback]，提供滑动窗口式的帧耗时统计。
/// 用于仿真翻页等动画在低端机型上自动降级。
///
/// 设计要点：
/// - 单实例（`PerfMonitor.instance`），避免重复注册 callback
/// - 订阅者用 [VoidCallback] 形式注册，每次有新一批 [FrameTiming] 到达时触发
/// - 内部维护 [windowSize] 大小的最近帧耗时滑动窗口（默认 30 帧）
/// - 提供 [recentBuildPlusRasterMs] 取近似总耗时（build+raster, in ms）
///
/// 注意：FrameTiming 由 engine 在 raster thread 完成后回调，不是同步的。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

class PerfMonitor {
  PerfMonitor._() {
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  static final PerfMonitor instance = PerfMonitor._();

  /// 最近 N 帧的滑动窗口长度。
  static const int windowSize = 30;

  final List<double> _frameMs = <double>[];

  final Set<VoidCallback> _listeners = <VoidCallback>{};

  /// 总帧数计数（仅诊断）
  int _totalFrames = 0;

  /// 注册帧耗时变化监听。返回的回调用于注销。
  VoidCallback addListener(VoidCallback listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void _onTimings(List<FrameTiming> timings) {
    if (timings.isEmpty) return;
    for (final t in timings) {
      // build + raster 总耗时（含 GPU），单位毫秒
      final ms = (t.totalSpan.inMicroseconds) / 1000.0;
      _frameMs.add(ms);
      if (_frameMs.length > windowSize) {
        _frameMs.removeAt(0);
      }
      _totalFrames++;
    }
    for (final listener in _listeners) {
      try {
        listener();
      } catch (e) {
        debugPrint('[PerfMonitor] listener error: $e');
      }
    }
  }

  /// 当前窗口内全部帧耗时（ms）。返回的是只读副本。
  List<double> get recentBuildPlusRasterMs => List.unmodifiable(_frameMs);

  /// 当前窗口的平均帧耗时（ms）。窗口为空返回 0。
  double get averageMs {
    if (_frameMs.isEmpty) return 0;
    var sum = 0.0;
    for (final v in _frameMs) {
      sum += v;
    }
    return sum / _frameMs.length;
  }

  /// 当前窗口内连续超过 [thresholdMs] 的帧数（从尾部开始往前数）。
  int trailingSlowFrames(double thresholdMs) {
    var count = 0;
    for (var i = _frameMs.length - 1; i >= 0; i--) {
      if (_frameMs[i] > thresholdMs) {
        count++;
      } else {
        break;
      }
    }
    return count;
  }

  /// 总累计帧数（用于调试）
  int get totalFrames => _totalFrames;

  /// 重置滑动窗口（不影响已注册的 listener）。
  void reset() {
    _frameMs.clear();
  }
}
