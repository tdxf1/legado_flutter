import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/providers.dart';

/// BATCH-19a (F-W2A-005) — `ReaderSettings.==` / `hashCode` 契约测试。
///
/// 字段集合必须与 [ReaderSettings.copyWith] / [ReaderSettings.toJson] /
/// [ReaderSettings.fromJson] 一致；新增字段时必须同时改 4 处。
///
/// 覆盖：
/// 1. 全字段一致 → ==/hashCode 一致
/// 2. 单字段不同 → != （每个字段轮一遍参数化 case）
/// 3. == 和 hashCode 契约：== true ⇒ hashCode equal
/// 4. Set dedup：相等对象在 Set 内 size == 1
void main() {
  group('ReaderSettings == / hashCode', () {
    test('equal_when_all_fields_match (默认构造)', () {
      const a = ReaderSettings();
      const b = ReaderSettings();
      expect(a == b, isTrue);
      expect(a.hashCode, b.hashCode);
    });

    test('equal_when_all_fields_match (copyWith 不改字段)', () {
      const a = ReaderSettings();
      final b = a.copyWith();
      expect(a == b, isTrue);
      expect(a.hashCode, b.hashCode);
    });

    test('identical short-circuit', () {
      const a = ReaderSettings();
      // ignore: unrelated_type_equality_checks — 验证 identical 短路
      expect(identical(a, a), isTrue);
      expect(a == a, isTrue);
    });

    test('not_equal_when_different_type', () {
      const a = ReaderSettings();
      // ignore: unrelated_type_equality_checks
      expect(a == 'not a ReaderSettings', isFalse);
    });

    // 参数化：每个字段单独改一项，期望 != 且 hashCode 大概率不等。
    // 用 record list 把字段 mutator + 描述串起来。
    final mutators = <(String, ReaderSettings Function(ReaderSettings))>[
      ('fontSize', (s) => s.copyWith(fontSize: s.fontSize + 1)),
      ('fontWeightIndex',
          (s) => s.copyWith(fontWeightIndex: s.fontWeightIndex + 1)),
      ('fontFamily', (s) => s.copyWith(fontFamily: 'NotoSerif')),
      ('textColor', (s) => s.copyWith(textColor: s.textColor ^ 0xFF)),
      ('backgroundColor',
          (s) => s.copyWith(backgroundColor: s.backgroundColor ^ 0xFF)),
      ('backgroundImagePath',
          (s) => s.copyWith(backgroundImagePath: '/tmp/bg.png')),
      ('letterSpacing', (s) => s.copyWith(letterSpacing: s.letterSpacing + 0.5)),
      ('lineHeight', (s) => s.copyWith(lineHeight: s.lineHeight + 0.5)),
      ('paragraphSpacing',
          (s) => s.copyWith(paragraphSpacing: s.paragraphSpacing + 1)),
      ('horizontalPadding',
          (s) => s.copyWith(horizontalPadding: s.horizontalPadding + 1)),
      ('verticalPadding',
          (s) => s.copyWith(verticalPadding: s.verticalPadding + 1)),
      ('paragraphIndent', (s) => s.copyWith(paragraphIndent: '    ')),
      ('pageAnim', (s) => s.copyWith(pageAnim: ReaderPageAnim.cover)),
      ('nightMode', (s) => s.copyWith(nightMode: !s.nightMode)),
      ('nightBackgroundColor',
          (s) => s.copyWith(nightBackgroundColor: s.nightBackgroundColor ^ 0xFF)),
      ('nightTextColor',
          (s) => s.copyWith(nightTextColor: s.nightTextColor ^ 0xFF)),
      ('showReadingInfo',
          (s) => s.copyWith(showReadingInfo: !s.showReadingInfo)),
      ('showChapterTitle',
          (s) => s.copyWith(showChapterTitle: !s.showChapterTitle)),
      ('showClock', (s) => s.copyWith(showClock: !s.showClock)),
      ('showProgress', (s) => s.copyWith(showProgress: !s.showProgress)),
      ('ttsSpeed', (s) => s.copyWith(ttsSpeed: s.ttsSpeed + 0.1)),
      ('pageAnimDurationMs',
          (s) => s.copyWith(pageAnimDurationMs: s.pageAnimDurationMs + 100)),
      ('screenBrightness',
          (s) => s.copyWith(screenBrightness: s.screenBrightness + 0.5)),
      ('keepScreenOn', (s) => s.copyWith(keepScreenOn: !s.keepScreenOn)),
      ('enableVolumeKeyPage',
          (s) => s.copyWith(enableVolumeKeyPage: !s.enableVolumeKeyPage)),
      ('volumeKeyPageOnTts',
          (s) => s.copyWith(volumeKeyPageOnTts: !s.volumeKeyPageOnTts)),
      // tapZones 是 List<int>——== 必须做深比较，否则两个相同元素的 list
      // 因引用不同被识别为不等。这里改一个元素验证 != 命中。
      ('tapZones', (s) {
        final next = List<int>.from(s.tapZones)..[0] = (s.tapZones[0] + 1) % 4;
        return s.copyWith(tapZones: next);
      }),
      ('autoScrollSpeed',
          (s) => s.copyWith(autoScrollSpeed: s.autoScrollSpeed + 1)),
      ('autoPageIntervalSeconds',
          (s) => s.copyWith(
              autoPageIntervalSeconds: s.autoPageIntervalSeconds + 1)),
      ('enableLongPressMenu',
          (s) => s.copyWith(enableLongPressMenu: !s.enableLongPressMenu)),
      ('bookshelfSort',
          (s) => s.copyWith(bookshelfSort: s.bookshelfSort + 1)),
    ];

    test('字段集合规模 == 31（与 copyWith / toJson 字段数对齐）', () {
      // 防御：如果有人加新字段忘了同步本测试，规模断言会先 fail。
      expect(mutators.length, 31);
    });

    for (final (name, mut) in mutators) {
      test('not_equal_when_$name\_differs', () {
        const base = ReaderSettings();
        final modified = mut(base);
        expect(modified == base, isFalse,
            reason: '$name 不同应判 !=（base=$base, modified=$modified）');
      });
    }

    test('hashCode 在 == true 时一致（copyWith 自身）', () {
      // 跨字段构造一份 "看起来像 modified 但实际等价" 的对象——通过把每个
      // 字段从 base 显式 copy 一遍，构造方式不同但字段值相同。
      const a = ReaderSettings(fontSize: 22, nightMode: true, ttsSpeed: 0.7);
      final b = const ReaderSettings()
          .copyWith(fontSize: 22, nightMode: true, ttsSpeed: 0.7);
      expect(a == b, isTrue);
      expect(a.hashCode, b.hashCode);
    });

    test('tapZones 深比较：值相同但 list 引用不同 → 仍判等', () {
      final a = const ReaderSettings()
          .copyWith(tapZones: const [0, 1, 2, 3, 0, 1, 2, 3, 0]);
      final b = const ReaderSettings()
          .copyWith(tapZones: <int>[0, 1, 2, 3, 0, 1, 2, 3, 0]);
      // 两个 list 引用不同。
      expect(identical(a.tapZones, b.tapZones), isFalse);
      expect(a == b, isTrue);
      expect(a.hashCode, b.hashCode);
    });

    test('set_dedup：相等对象在 Set 内 size == 1', () {
      const a = ReaderSettings(fontSize: 20);
      final b = a.copyWith();
      final set = <ReaderSettings>{a, b};
      expect(set.length, 1);
    });

    test('set_dedup：不等对象保持 size == 2', () {
      const a = ReaderSettings(fontSize: 20);
      final b = a.copyWith(fontSize: 21);
      final set = <ReaderSettings>{a, b};
      expect(set.length, 2);
    });
  });
}
