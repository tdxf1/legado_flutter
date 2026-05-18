/// 批次 2 (05-18) — 阅读器物理按键翻页 [handleReaderKeyEvent] 单测。
///
/// 用纯函数 + mock VoidCallback 计数器跑核心矩阵：按键映射、控件可见时
/// 不拦截、enableVolumeKeyPage 开关、朗读时音量键放给系统等。
///
/// 不 pump widget — 只测纯逻辑，避免依赖 Flutter binding / plugin。
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/providers.dart';
import 'package:legado_flutter/features/reader/services/reader_key_handler.dart';

KeyDownEvent _down(LogicalKeyboardKey key) => KeyDownEvent(
      // physicalKey 不参与 handleReaderKeyEvent 的判定，给个 dummy 即可。
      physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: key,
      timeStamp: Duration.zero,
    );

KeyUpEvent _up(LogicalKeyboardKey key) => KeyUpEvent(
      physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: key,
      timeStamp: Duration.zero,
    );

class _Counter {
  int prev = 0;
  int next = 0;
  VoidCallback get onPrev => () => prev++;
  VoidCallback get onNext => () => next++;
}

void main() {
  group('handleReaderKeyEvent — 默认设置（enableVolumeKeyPage=true / volumeKeyPageOnTts=false）', () {
    const settings = ReaderSettings();

    test('VOLUME_DOWN → next（handled，调用 onNext 一次）', () {
      final c = _Counter();
      final result = handleReaderKeyEvent(
        event: _down(LogicalKeyboardKey.audioVolumeDown),
        settings: settings,
        controlsVisible: false,
        ttsSpeaking: false,
        onPrev: c.onPrev,
        onNext: c.onNext,
      );
      expect(result, KeyEventResult.handled);
      expect(c.next, 1);
      expect(c.prev, 0);
    });

    test('VOLUME_UP → prev（handled，调用 onPrev 一次）', () {
      final c = _Counter();
      final result = handleReaderKeyEvent(
        event: _down(LogicalKeyboardKey.audioVolumeUp),
        settings: settings,
        controlsVisible: false,
        ttsSpeaking: false,
        onPrev: c.onPrev,
        onNext: c.onNext,
      );
      expect(result, KeyEventResult.handled);
      expect(c.prev, 1);
      expect(c.next, 0);
    });

    test('PageDown → next', () {
      final c = _Counter();
      final result = handleReaderKeyEvent(
        event: _down(LogicalKeyboardKey.pageDown),
        settings: settings,
        controlsVisible: false,
        ttsSpeaking: false,
        onPrev: c.onPrev,
        onNext: c.onNext,
      );
      expect(result, KeyEventResult.handled);
      expect(c.next, 1);
    });

    test('PageUp → prev', () {
      final c = _Counter();
      final result = handleReaderKeyEvent(
        event: _down(LogicalKeyboardKey.pageUp),
        settings: settings,
        controlsVisible: false,
        ttsSpeaking: false,
        onPrev: c.onPrev,
        onNext: c.onNext,
      );
      expect(result, KeyEventResult.handled);
      expect(c.prev, 1);
    });

    test('Space → next', () {
      final c = _Counter();
      final result = handleReaderKeyEvent(
        event: _down(LogicalKeyboardKey.space),
        settings: settings,
        controlsVisible: false,
        ttsSpeaking: false,
        onPrev: c.onPrev,
        onNext: c.onNext,
      );
      expect(result, KeyEventResult.handled);
      expect(c.next, 1);
    });

    test('ArrowDown → next', () {
      final c = _Counter();
      final result = handleReaderKeyEvent(
        event: _down(LogicalKeyboardKey.arrowDown),
        settings: settings,
        controlsVisible: false,
        ttsSpeaking: false,
        onPrev: c.onPrev,
        onNext: c.onNext,
      );
      expect(result, KeyEventResult.handled);
      expect(c.next, 1);
    });

    test('ArrowUp → prev', () {
      final c = _Counter();
      final result = handleReaderKeyEvent(
        event: _down(LogicalKeyboardKey.arrowUp),
        settings: settings,
        controlsVisible: false,
        ttsSpeaking: false,
        onPrev: c.onPrev,
        onNext: c.onNext,
      );
      expect(result, KeyEventResult.handled);
      expect(c.prev, 1);
    });
  });

  group('handleReaderKeyEvent — 守卫条件', () {
    test('controlsVisible == true → 任何键 ignored，不调回调', () {
      const settings = ReaderSettings();
      final c = _Counter();
      // 4 个键全部测试一遍：volume / pageUp / pageDown / space
      for (final key in [
        LogicalKeyboardKey.audioVolumeDown,
        LogicalKeyboardKey.audioVolumeUp,
        LogicalKeyboardKey.pageDown,
        LogicalKeyboardKey.space,
      ]) {
        final result = handleReaderKeyEvent(
          event: _down(key),
          settings: settings,
          controlsVisible: true,
          ttsSpeaking: false,
          onPrev: c.onPrev,
          onNext: c.onNext,
        );
        expect(result, KeyEventResult.ignored, reason: 'key=$key');
      }
      expect(c.prev, 0);
      expect(c.next, 0);
    });

    test('enableVolumeKeyPage == false → 音量键 ignored（让系统调音量）', () {
      const settings = ReaderSettings(enableVolumeKeyPage: false);
      final c = _Counter();
      final downResult = handleReaderKeyEvent(
        event: _down(LogicalKeyboardKey.audioVolumeDown),
        settings: settings,
        controlsVisible: false,
        ttsSpeaking: false,
        onPrev: c.onPrev,
        onNext: c.onNext,
      );
      final upResult = handleReaderKeyEvent(
        event: _down(LogicalKeyboardKey.audioVolumeUp),
        settings: settings,
        controlsVisible: false,
        ttsSpeaking: false,
        onPrev: c.onPrev,
        onNext: c.onNext,
      );
      expect(downResult, KeyEventResult.ignored);
      expect(upResult, KeyEventResult.ignored);
      expect(c.next, 0);
      expect(c.prev, 0);
    });

    test(
        'enableVolumeKeyPage == false → Space / PageDown 仍翻页（不受此开关影响）',
        () {
      const settings = ReaderSettings(enableVolumeKeyPage: false);
      final c = _Counter();
      final spaceResult = handleReaderKeyEvent(
        event: _down(LogicalKeyboardKey.space),
        settings: settings,
        controlsVisible: false,
        ttsSpeaking: false,
        onPrev: c.onPrev,
        onNext: c.onNext,
      );
      final pageDownResult = handleReaderKeyEvent(
        event: _down(LogicalKeyboardKey.pageDown),
        settings: settings,
        controlsVisible: false,
        ttsSpeaking: false,
        onPrev: c.onPrev,
        onNext: c.onNext,
      );
      expect(spaceResult, KeyEventResult.handled);
      expect(pageDownResult, KeyEventResult.handled);
      expect(c.next, 2);
    });

    test('ttsSpeaking + volumeKeyPageOnTts == false → 音量键 ignored（默认）',
        () {
      const settings = ReaderSettings(); // volumeKeyPageOnTts 默认 false
      final c = _Counter();
      final result = handleReaderKeyEvent(
        event: _down(LogicalKeyboardKey.audioVolumeDown),
        settings: settings,
        controlsVisible: false,
        ttsSpeaking: true,
        onPrev: c.onPrev,
        onNext: c.onNext,
      );
      expect(result, KeyEventResult.ignored);
      expect(c.next, 0);
    });

    test('ttsSpeaking + volumeKeyPageOnTts == true → 音量键仍翻页', () {
      const settings = ReaderSettings(volumeKeyPageOnTts: true);
      final c = _Counter();
      final result = handleReaderKeyEvent(
        event: _down(LogicalKeyboardKey.audioVolumeDown),
        settings: settings,
        controlsVisible: false,
        ttsSpeaking: true,
        onPrev: c.onPrev,
        onNext: c.onNext,
      );
      expect(result, KeyEventResult.handled);
      expect(c.next, 1);
    });

    test('ttsSpeaking + Space 仍翻页（朗读不影响 Space 键）', () {
      const settings = ReaderSettings();
      final c = _Counter();
      final result = handleReaderKeyEvent(
        event: _down(LogicalKeyboardKey.space),
        settings: settings,
        controlsVisible: false,
        ttsSpeaking: true,
        onPrev: c.onPrev,
        onNext: c.onNext,
      );
      expect(result, KeyEventResult.handled);
      expect(c.next, 1);
    });
  });

  group('handleReaderKeyEvent — 事件类型守卫', () {
    test('KeyUpEvent 一律 ignored（避免长按触发 onKeyUp 又翻一次）', () {
      const settings = ReaderSettings();
      final c = _Counter();
      final result = handleReaderKeyEvent(
        event: _up(LogicalKeyboardKey.audioVolumeDown),
        settings: settings,
        controlsVisible: false,
        ttsSpeaking: false,
        onPrev: c.onPrev,
        onNext: c.onNext,
      );
      expect(result, KeyEventResult.ignored);
      expect(c.next, 0);
    });

    test('无关键（A、B、F1、Enter）→ ignored', () {
      const settings = ReaderSettings();
      final c = _Counter();
      for (final key in [
        LogicalKeyboardKey.keyA,
        LogicalKeyboardKey.keyB,
        LogicalKeyboardKey.f1,
        LogicalKeyboardKey.enter,
      ]) {
        final result = handleReaderKeyEvent(
          event: _down(key),
          settings: settings,
          controlsVisible: false,
          ttsSpeaking: false,
          onPrev: c.onPrev,
          onNext: c.onNext,
        );
        expect(result, KeyEventResult.ignored, reason: 'key=$key');
      }
      expect(c.prev, 0);
      expect(c.next, 0);
    });
  });
}
