import 'package:flutter/widgets.dart';

/// `setState` + `mounted` 检查的 syntax sugar 扩展（BATCH-25, F-W2B-021）。
///
/// 异步操作（await network / DB / file IO）后 widget 可能已被 dispose，此时
/// 调 `setState` 会抛 "setState() called after dispose"。原惯用模板：
///
/// ```dart
/// final result = await api.fetch();
/// if (mounted) setState(() => _data = result);
/// ```
///
/// 用本扩展统一改写为：
///
/// ```dart
/// final result = await api.fetch();
/// safeSetState(() => _data = result);
/// ```
///
/// 行为与原模板**完全等价**：mounted=true 时调 setState，mounted=false 时
/// 静默忽略（no-op，不抛异常）。
///
/// **不要** 用本扩展替换 `if (!mounted) return;` 早返回风格 — 早返回常常
/// 守护多行后续操作（不止 setState 一句），换 extension 反而拆碎逻辑。
extension SafeSetState<T extends StatefulWidget> on State<T> {
  /// 仅在 widget 仍然 mounted 时调用 `setState(fn)`。
  /// dispose 后是 no-op，不抛异常。
  void safeSetState(VoidCallback fn) {
    if (!mounted) return;
    // ignore: invalid_use_of_protected_member
    setState(fn);
  }
}
