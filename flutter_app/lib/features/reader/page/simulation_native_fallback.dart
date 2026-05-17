/// 仿真翻页平台原生 fallback
///
/// 当 [SimulationDegradeController] 升到 L3（Dart 层降级仍掉帧）时，由 widget
/// 通过这个 channel 通知原生层切换到 Kotlin 实现的 SimulationPageDelegate。
///
/// 当前阶段以"信号占位"形式实现：
/// - Dart 侧调用 `start()` / `stop()`
/// - Kotlin 侧暂时只回 `not_implemented`，记录日志
/// - 后续可以把 legado-with-MD3 的 `SimulationPageDelegate.kt` 直接 vendor 进来，
///   通过 `AndroidView` 嵌入原生 SurfaceView
///
/// 该接口在非 Android 平台为空操作，不抛异常。
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SimulationNativeFallback {
  SimulationNativeFallback._();

  static final SimulationNativeFallback instance = SimulationNativeFallback._();

  static const _channel = MethodChannel('legado/sim_page');

  bool _started = false;

  bool get isStarted => _started;

  Future<void> start() async {
    if (kIsWeb) return;
    if (!Platform.isAndroid) return;
    if (_started) return;
    try {
      await _channel.invokeMethod<void>('start');
      _started = true;
      debugPrint('[SimNative] started');
    } on PlatformException catch (e) {
      // Native side not implemented yet — degrade silently.
      debugPrint('[SimNative] start failed: ${e.code} ${e.message}');
    } on MissingPluginException catch (e) {
      debugPrint('[SimNative] missing plugin: ${e.message}');
    }
  }

  Future<void> stop() async {
    if (kIsWeb) return;
    if (!Platform.isAndroid) return;
    if (!_started) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException catch (e) {
      debugPrint('[SimNative] stop failed: ${e.code} ${e.message}');
    } on MissingPluginException catch (e) {
      debugPrint('[SimNative] missing plugin: ${e.message}');
    } finally {
      _started = false;
    }
  }
}
