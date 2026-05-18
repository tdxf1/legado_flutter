/// 阅读器物理按键处理（批次 2，05-18）
///
/// 抽成纯函数便于单测：调用方提供 settings + state 标志位 + 翻页回调，
/// 返回 [KeyEventResult.handled] 表示已处理（吞掉事件，不让系统继续派发），
/// 或 [KeyEventResult.ignored] 让系统继续处理（音量调节 / 浏览器快捷键等）。
///
/// 对齐原 Legado MD3 `ReadBookActivity.kt:682-738 onKeyDown` 行为：
/// - VOLUME_UP / PageUp / Arrow Up → prev
/// - VOLUME_DOWN / PageDown / Space / Arrow Down → next
/// - 控件可见时（_controlsVisible == true）不拦截 — 让系统正常处理
/// - 朗读中可选不翻页（`volumeKeyPageOnTts == false` 时把音量键放给系统）
/// - 非 KeyDownEvent（KeyUpEvent / KeyRepeatEvent）一律 ignored，避免长按
///   触发 onKeyUp 也翻页造成连翻 2 次
///
/// PageUp / PageDown / Space / 方向键不受 [ReaderSettings.enableVolumeKeyPage]
/// 影响 — 它们没有系统冲突行为，关闭"音量键翻页"只挡住音量键路径。
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../core/providers.dart';

KeyEventResult handleReaderKeyEvent({
  required KeyEvent event,
  required ReaderSettings settings,
  required bool controlsVisible,
  required bool ttsSpeaking,
  required VoidCallback onPrev,
  required VoidCallback onNext,
}) {
  // 只处理按下事件，KeyUpEvent/KeyRepeatEvent 一律放行，避免 KeyUpEvent 在
  // 同一次按压再触发一次翻页。
  if (event is! KeyDownEvent) return KeyEventResult.ignored;

  // 控件可见时（菜单 / 设置 sheet）不拦截 — 让系统按钮正常工作。
  if (controlsVisible) return KeyEventResult.ignored;

  final key = event.logicalKey;
  final isVolumeKey = key == LogicalKeyboardKey.audioVolumeUp ||
      key == LogicalKeyboardKey.audioVolumeDown;

  if (isVolumeKey) {
    if (!settings.enableVolumeKeyPage) return KeyEventResult.ignored;
    if (ttsSpeaking && !settings.volumeKeyPageOnTts) {
      return KeyEventResult.ignored;
    }
  }

  if (_isPrevKey(key)) {
    onPrev();
    return KeyEventResult.handled;
  }
  if (_isNextKey(key)) {
    onNext();
    return KeyEventResult.handled;
  }
  return KeyEventResult.ignored;
}

bool _isPrevKey(LogicalKeyboardKey k) =>
    k == LogicalKeyboardKey.audioVolumeUp ||
    k == LogicalKeyboardKey.pageUp ||
    k == LogicalKeyboardKey.arrowUp;

bool _isNextKey(LogicalKeyboardKey k) =>
    k == LogicalKeyboardKey.audioVolumeDown ||
    k == LogicalKeyboardKey.pageDown ||
    k == LogicalKeyboardKey.arrowDown ||
    k == LogicalKeyboardKey.space;
