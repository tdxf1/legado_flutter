/// 阅读器 TTS 管理器
///
/// 把阅读器内的 flutter_tts 调用从 widget state 中分离出来。
/// 暴露最小的回调式 API，让 widget 用 setState/通知刷新 UI。
///
/// 使用方式：
///   - 在 State.initState 创建一个实例并 [init]
///   - 在 State.dispose 调用 [dispose]
///   - 调用 [start] / [pause] / [resume] / [stop] 控制朗读
///   - 通过 [isSpeaking] / [isPaused] / [paragraphIndex] 读状态
///   - [onStateChanged] 在内部状态变化时触发，调用方据此 setState
///   - [onChapterEndReached] 在朗读到章节末时触发，调用方负责切下一章
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

class ReaderTtsManager {
  ReaderTtsManager();

  final FlutterTts _tts = FlutterTts();

  bool _initialized = false;
  bool _isSpeaking = false;
  bool _isPaused = false;
  int _paragraphIndex = 0;
  double _rate = 0.5;

  /// 当前朗读章节正文。由调用方在切换章节时通过 [setChapterContent] 注入。
  String _chapterContent = '';

  VoidCallback? _onStateChanged;
  VoidCallback? _onChapterEndReached;

  bool get isSpeaking => _isSpeaking;
  bool get isPaused => _isPaused;
  int get paragraphIndex => _paragraphIndex;
  double get rate => _rate;
  String get chapterContent => _chapterContent;

  /// 初始化引擎（设置中文语言 + 默认语速 + 完成回调）。
  ///
  /// [rate] 范围通常是 0.0 ~ 1.0；不同平台默认值不一致。
  /// 若调用平台不支持中文，引擎会回退到默认语音。
  Future<void> init({
    required double rate,
    VoidCallback? onStateChanged,
    VoidCallback? onChapterEndReached,
  }) async {
    _onStateChanged = onStateChanged;
    _onChapterEndReached = onChapterEndReached;
    _rate = rate;
    try {
      debugPrint('[TTS] init: starting...');
      bool langOk = false;
      for (final code in ['zh-CN', 'zh', 'cmn', 'zh-Hans']) {
        final result = await _tts.setLanguage(code);
        debugPrint('[TTS] setLanguage("$code") returned: $result');
        if (result == 1) {
          langOk = true;
          break;
        }
      }
      if (!langOk) {
        debugPrint('[TTS] No Chinese language matched. Using default voice.');
      }
      final rateResult = await _tts.setSpeechRate(_rate);
      debugPrint('[TTS] setSpeechRate returned: $rateResult');
      _tts.setCompletionHandler(() {
        if (_isSpeaking) {
          nextParagraph();
        }
      });
      _initialized = true;
      debugPrint('[TTS] init: done');
    } catch (e, st) {
      debugPrint('[TTS] init FAILED: $e\n$st');
    }
  }

  /// 注入当前章节正文，TTS 会根据空行切段。
  ///
  /// 切换章节时务必先调用，再调用 [start]。
  void setChapterContent(String content) {
    _chapterContent = content;
  }

  /// 开始从段落 0 朗读当前章节。
  Future<void> start() async {
    if (!_initialized) return;
    try {
      _isSpeaking = true;
      _isPaused = false;
      _paragraphIndex = 0;
      _onStateChanged?.call();
      await _tts.stop();
      await _speakCurrent();
    } catch (e, st) {
      debugPrint('[TTS] start FAILED: $e\n$st');
    }
  }

  Future<void> _speakCurrent() async {
    if (!_isSpeaking) return;
    final paragraphs = _splitParagraphs(_chapterContent);
    if (_paragraphIndex >= paragraphs.length) {
      // Reached end of chapter. Caller is expected to advance the chapter and
      // re-inject content via setChapterContent + speakAfterChapterAdvance.
      _paragraphIndex = 0;
      _onChapterEndReached?.call();
      return;
    }
    final text = paragraphs[_paragraphIndex];
    debugPrint(
      '[TTS] Speaking paragraph $_paragraphIndex: '
      '"${text.length > 30 ? text.substring(0, 30) : text}..."',
    );
    final result = await _tts.speak(text);
    debugPrint('[TTS] speak() result: $result');
  }

  /// 当 [_onChapterEndReached] 回调切换章节并刷新 [setChapterContent] 后，调用此方法继续朗读。
  Future<void> resumeAfterChapterAdvance() async {
    if (!_isSpeaking) return;
    await _speakCurrent();
  }

  void pause() {
    _isPaused = true;
    _tts.pause();
    _onStateChanged?.call();
  }

  Future<void> resume() async {
    if (!_isSpeaking) {
      await start();
      return;
    }
    _isPaused = false;
    _onStateChanged?.call();
    await _speakCurrent();
  }

  void stop() {
    _isSpeaking = false;
    _isPaused = false;
    _tts.stop();
    _onStateChanged?.call();
  }

  /// 切换到下一段并朗读。
  Future<void> nextParagraph() async {
    _paragraphIndex++;
    _onStateChanged?.call();
    await _speakCurrent();
  }

  /// 切换到上一段并朗读。
  Future<void> prevParagraph() async {
    if (_paragraphIndex > 0) {
      _paragraphIndex--;
      _onStateChanged?.call();
      await _tts.stop();
      await _speakCurrent();
    }
  }

  /// 设置语速（运行期生效）。
  Future<void> setRate(double rate) async {
    _rate = rate;
    if (_isSpeaking) {
      await _tts.setSpeechRate(rate);
    }
  }

  /// 释放资源。dispose 后不可继续使用。
  void dispose() {
    try {
      _tts.stop();
    } catch (e) {
      debugPrint('[TTS] stop on dispose failed: $e');
    }
    try {
      _tts.setCompletionHandler(() {});
    } catch (e) {
      debugPrint('[TTS] reset completion handler failed: $e');
    }
    _onStateChanged = null;
    _onChapterEndReached = null;
  }

  static List<String> _splitParagraphs(String content) {
    return content
        .split(RegExp(r'\n+'))
        .where((p) => p.trim().isNotEmpty)
        .toList();
  }
}
