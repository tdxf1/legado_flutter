/// 仿真翻页性能降级管理
///
/// 与 [PerfMonitor] 联动，根据近期帧耗时把仿真翻页的视觉复杂度逐级降低。
///
/// 降级阶梯：
/// - **L0**：完整效果（折页阴影 + 颜色矩阵反射 + 多段阴影）
/// - **L1**：折页阴影简化为 2 段（节省一次 saveLayer + gradient）
/// - **L2**：禁用颜色矩阵反射，背面直接绘制原 Picture（节省 ColorFilter 开销）
/// - **L3**：触发 platform channel fallback（由 widget 层在收到信号后切换实现）
///
/// 触发条件（每次帧 timing 回调时检查）：
/// - 滑动窗口最近 30 帧
/// - 连续 5 帧超过当前刷新率对应的目标耗时（120Hz=8.33ms，60Hz=16.67ms） → 升级一档
/// - 连续 30 帧低于目标耗时 60% → 自动恢复一档（避免长期降级）
library;

import 'package:flutter/foundation.dart';

import '../../../../core/perf_monitor.dart';

enum SimulationDegradeLevel {
  l0,
  l1,
  l2,
  l3,
}

class SimulationDegradeController {
  SimulationDegradeController({
    double frameBudgetMs = _defaultBudget120Hz,
    int slowThreshold = 5,
    int recoverThreshold = 30,
  })  : _frameBudgetMs = frameBudgetMs,
        _slowThreshold = slowThreshold,
        _recoverThreshold = recoverThreshold;

  /// 120fps 默认目标 8.33ms，可在运行时通过 [setFrameBudget] 切到 60Hz=16.67ms。
  static const double _defaultBudget120Hz = 8.33;

  double _frameBudgetMs;
  final int _slowThreshold;
  final int _recoverThreshold;

  SimulationDegradeLevel _level = SimulationDegradeLevel.l0;
  int _consecutiveFast = 0;

  VoidCallback? _unsubscribe;
  VoidCallback? _onLevelChanged;
  VoidCallback? _onFallbackRequested;

  SimulationDegradeLevel get level => _level;

  /// Whether to render the folder shadow at all. Equivalent to
  /// `folderShadowSegments > 0`.
  bool get useFolderShadow => folderShadowSegments > 0;

  /// 折页阴影段数：决定 SimulationPageDelegate 在折页背面绘制多少个等高
  /// 渐变小矩形（vendor MD3 的多段阴影做法），段数越多观感越平滑。
  ///
  /// - L0：6 段（最细腻）
  /// - L1：2 段（中端机省 4 次 saveLayer/gradient）
  /// - L2：2 段（仍画阴影但禁用颜色滤镜，见 [useBackColorFilter]）
  /// - L3：0 段（完全跳过；同时通过 [shouldFallbackToNative] 切到原生绘制）
  int get folderShadowSegments {
    switch (_level) {
      case SimulationDegradeLevel.l0:
        return 6;
      case SimulationDegradeLevel.l1:
      case SimulationDegradeLevel.l2:
        return 2;
      case SimulationDegradeLevel.l3:
        return 0;
    }
  }

  /// L2 起禁用颜色矩阵反射。
  bool get useBackColorFilter =>
      _level == SimulationDegradeLevel.l0 ||
      _level == SimulationDegradeLevel.l1;

  /// L3：widget 层应该用 platform channel fallback。
  bool get shouldFallbackToNative => _level == SimulationDegradeLevel.l3;

  /// 当前刷新率改变时调用，重设帧耗时预算。
  void setFrameBudget(double ms) {
    _frameBudgetMs = ms;
  }

  /// 注册到 [PerfMonitor.instance]，开始监测。
  /// [onLevelChanged] 在档位变化时触发；[onFallbackRequested] 在升到 L3 时触发。
  void attach({
    VoidCallback? onLevelChanged,
    VoidCallback? onFallbackRequested,
  }) {
    _onLevelChanged = onLevelChanged;
    _onFallbackRequested = onFallbackRequested;
    _unsubscribe = PerfMonitor.instance.addListener(_onTimings);
  }

  void detach() {
    _unsubscribe?.call();
    _unsubscribe = null;
    _onLevelChanged = null;
    _onFallbackRequested = null;
  }

  /// 强制重置回 L0（一般在切换章节、设置变化时调用，给系统一次重新评估机会）。
  void reset() {
    final changed = _level != SimulationDegradeLevel.l0;
    _level = SimulationDegradeLevel.l0;
    _consecutiveFast = 0;
    if (changed) _onLevelChanged?.call();
  }

  void _onTimings() {
    final monitor = PerfMonitor.instance;
    final slowCount = monitor.trailingSlowFrames(_frameBudgetMs);
    if (slowCount >= _slowThreshold) {
      _stepDown();
      return;
    }
    final avg = monitor.averageMs;
    if (avg > 0 && avg < _frameBudgetMs * 0.6) {
      _consecutiveFast++;
      if (_consecutiveFast >= _recoverThreshold) {
        _stepUp();
        _consecutiveFast = 0;
      }
    } else {
      _consecutiveFast = 0;
    }
  }

  void _stepDown() {
    final next = _level.index + 1;
    if (next >= SimulationDegradeLevel.values.length) return;
    _level = SimulationDegradeLevel.values[next];
    debugPrint('[SimDegrade] step down → ${_level.name}');
    _onLevelChanged?.call();
    if (_level == SimulationDegradeLevel.l3) {
      _onFallbackRequested?.call();
    }
  }

  void _stepUp() {
    final prev = _level.index - 1;
    if (prev < 0) return;
    _level = SimulationDegradeLevel.values[prev];
    debugPrint('[SimDegrade] step up → ${_level.name}');
    _onLevelChanged?.call();
  }
}
