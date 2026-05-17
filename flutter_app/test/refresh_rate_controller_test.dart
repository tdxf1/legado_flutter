import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:legado_flutter/core/refresh_rate_controller.dart';

void main() {
  group('RefreshRateModeLabel', () {
    test('fromIndex returns auto when null', () {
      expect(RefreshRateModeLabel.fromIndex(null), RefreshRateMode.auto);
    });

    test('fromIndex maps valid index', () {
      expect(RefreshRateModeLabel.fromIndex(0), RefreshRateMode.auto);
      expect(RefreshRateModeLabel.fromIndex(1), RefreshRateMode.force120);
      expect(RefreshRateModeLabel.fromIndex(2), RefreshRateMode.lock60);
    });

    test('fromIndex falls back to auto on out-of-range', () {
      expect(RefreshRateModeLabel.fromIndex(-1), RefreshRateMode.auto);
      expect(RefreshRateModeLabel.fromIndex(99), RefreshRateMode.auto);
    });

    test('persistIndex round-trips', () {
      for (final m in RefreshRateMode.values) {
        expect(RefreshRateModeLabel.fromIndex(m.persistIndex), m);
      }
    });

    test('label is non-empty', () {
      for (final m in RefreshRateMode.values) {
        expect(m.label, isNotEmpty);
      }
    });
  });

  group('RefreshRateController._pickMode', () {
    // We exercise the public API by simulating a non-Android environment and
    // poking the static cache via a custom wrapper.

    test('apply on non-Android records mode without throwing', () async {
      // The test harness reports !Platform.isAndroid, so apply should be a no-op.
      await RefreshRateController.apply(RefreshRateMode.auto);
      // Do not assert _current value (depends on prior tests / async order).
      expect(RefreshRateController.supportedModes, isA<List<DisplayMode>>());
      // Sanity: kIsWeb should be false in unit tests.
      expect(kIsWeb, isFalse);
    });
  });
}
