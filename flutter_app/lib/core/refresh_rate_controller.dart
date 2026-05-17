/// 高刷新率控制器
///
/// 在支持高刷的 Android 机型上申请最高刷新率（通常是 90Hz / 120Hz）。
/// 用于配合仿真翻页等动画做到丝滑跟手。
///
/// 提供三种模式：
/// - [RefreshRateMode.auto]：选择当前分辨率下支持的最高刷新率（默认）
/// - [RefreshRateMode.force120]：强制请求 ≥ 120Hz；不支持时回退到最高
/// - [RefreshRateMode.lock60]：强制锁定 60Hz（兼容/省电）
///
/// 仅在 Android 平台生效，其他平台调用为空操作。
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';

enum RefreshRateMode {
  auto,
  force120,
  lock60,
}

class RefreshRateController {
  RefreshRateController._();

  /// 当前已应用的模式（运行期内存）。仅用于诊断展示。
  static RefreshRateMode? _current;

  /// 已检测到的支持模式列表，懒加载。
  static List<DisplayMode>? _supported;

  /// 应用指定模式。失败不抛异常，仅 debugPrint。
  ///
  /// 该方法是幂等的：重复传入同一 mode 不会重复申请系统调用。
  static Future<void> apply(RefreshRateMode mode) async {
    if (kIsWeb) return;
    if (!Platform.isAndroid) {
      _current = mode;
      return;
    }
    try {
      _supported ??= await FlutterDisplayMode.supported;
      final modes = _supported!;
      if (modes.isEmpty) {
        _current = mode;
        return;
      }
      final picked = _pickMode(modes, mode);
      if (picked == null) {
        _current = mode;
        return;
      }
      await FlutterDisplayMode.setPreferredMode(picked);
      _current = mode;
      debugPrint(
        '[RefreshRate] mode=$mode chose ${picked.refreshRate}Hz '
        '${picked.width}x${picked.height} id=${picked.id}',
      );
    } catch (e) {
      debugPrint('[RefreshRate] apply failed: $e');
    }
  }

  static DisplayMode? _pickMode(List<DisplayMode> modes, RefreshRateMode mode) {
    // Filter to "active resolution" candidates: keep modes whose width/height
    // match one of the largest in the list (avoid switching resolution).
    final maxArea = modes.fold<int>(
      0,
      (acc, m) {
        final area = m.width * m.height;
        return area > acc ? area : acc;
      },
    );
    final sameRes = modes.where((m) => m.width * m.height == maxArea).toList();
    final candidates = sameRes.isEmpty ? modes : sameRes;

    switch (mode) {
      case RefreshRateMode.auto:
        candidates.sort((a, b) => b.refreshRate.compareTo(a.refreshRate));
        return candidates.first;
      case RefreshRateMode.force120:
        // Prefer ≥ 120Hz; if none, fall back to highest.
        final ge120 = candidates.where((m) => m.refreshRate >= 119.5).toList()
          ..sort((a, b) => b.refreshRate.compareTo(a.refreshRate));
        if (ge120.isNotEmpty) return ge120.first;
        candidates.sort((a, b) => b.refreshRate.compareTo(a.refreshRate));
        return candidates.first;
      case RefreshRateMode.lock60:
        // Prefer the mode closest to 60Hz from below (>= 59.5 && <= 60.5).
        DisplayMode? best;
        double bestDiff = double.infinity;
        for (final m in candidates) {
          final diff = (m.refreshRate - 60.0).abs();
          if (diff < bestDiff) {
            bestDiff = diff;
            best = m;
          }
        }
        return best ?? candidates.first;
    }
  }

  /// 当前已应用的模式（用于设置页展示）；未应用过则返回 null。
  static RefreshRateMode? get current => _current;

  /// 系统报告的支持模式列表（按设备返回顺序）。仅诊断用途。
  static List<DisplayMode> get supportedModes =>
      List.unmodifiable(_supported ?? const []);
}

extension RefreshRateModeLabel on RefreshRateMode {
  String get label {
    switch (this) {
      case RefreshRateMode.auto:
        return '自动（最高）';
      case RefreshRateMode.force120:
        return '强制 120Hz';
      case RefreshRateMode.lock60:
        return '锁定 60Hz';
    }
  }

  int get persistIndex => index;

  static RefreshRateMode fromIndex(int? idx) {
    if (idx == null) return RefreshRateMode.auto;
    if (idx < 0 || idx >= RefreshRateMode.values.length) {
      return RefreshRateMode.auto;
    }
    return RefreshRateMode.values[idx];
  }
}
