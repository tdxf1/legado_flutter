import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/providers.dart';

/// 批次 1 (05-18) — `ReaderSettings` v6 schema 升级测试。
///
/// 覆盖：
/// 1. 默认值（screenBrightness = -1.0 跟随系统；keepScreenOn = true）
/// 2. 构造透传 / copyWith
/// 3. toJson 写出含 settingsVersion=6 + 两新字段
/// 4. round-trip toJson → fromJson 字段保持
/// 5. 旧 v5 JSON 缺新字段时回退默认值（不破坏老用户）
/// 6. 旧 v ≤ 4 JSON 也回退到默认值（兼容性）
void main() {
  group('ReaderSettings v6 — defaults', () {
    test('默认 screenBrightness = -1.0（跟随系统）', () {
      const s = ReaderSettings();
      expect(s.screenBrightness, -1.0);
    });

    test('默认 keepScreenOn = true（对齐原 Legado 默认）', () {
      const s = ReaderSettings();
      expect(s.keepScreenOn, true);
    });

    test('显式构造可覆盖默认值', () {
      const s = ReaderSettings(screenBrightness: 0.7, keepScreenOn: false);
      expect(s.screenBrightness, 0.7);
      expect(s.keepScreenOn, false);
    });
  });

  group('ReaderSettings v6 — copyWith', () {
    test('copyWith 单独修改 screenBrightness', () {
      const base = ReaderSettings();
      final s = base.copyWith(screenBrightness: 0.55);
      expect(s.screenBrightness, 0.55);
      // 其它字段未变。
      expect(s.keepScreenOn, base.keepScreenOn);
      expect(s.fontSize, base.fontSize);
    });

    test('copyWith 单独修改 keepScreenOn', () {
      const base = ReaderSettings();
      final s = base.copyWith(keepScreenOn: false);
      expect(s.keepScreenOn, false);
      expect(s.screenBrightness, base.screenBrightness);
    });

    test('copyWith 不传新字段时保持原值', () {
      const base = ReaderSettings(screenBrightness: 0.3, keepScreenOn: false);
      final s = base.copyWith(fontSize: 22);
      expect(s.screenBrightness, 0.3);
      expect(s.keepScreenOn, false);
      expect(s.fontSize, 22);
    });
  });

  group('ReaderSettings v6 — JSON 序列化', () {
    test('settingsVersion 写出 == 7', () {
      const s = ReaderSettings();
      final j = s.toJson();
      expect(j['settingsVersion'], 7);
      expect(kReaderSettingsCurrentVersion, 7);
    });

    test('toJson 写入 screenBrightness + keepScreenOn', () {
      const s = ReaderSettings(screenBrightness: 0.42, keepScreenOn: false);
      final j = s.toJson();
      expect(j['screenBrightness'], 0.42);
      expect(j['keepScreenOn'], false);
    });

    test('round-trip：toJson → fromJson 字段值保持（含两新字段）', () {
      const s = ReaderSettings(
        screenBrightness: 0.7,
        keepScreenOn: false,
        pageAnimDurationMs: 450,
      );
      final s2 = ReaderSettings.fromJson(s.toJson());
      expect(s2.screenBrightness, 0.7);
      expect(s2.keepScreenOn, false);
      expect(s2.pageAnimDurationMs, 450);
    });

    test('round-trip：默认值（-1.0 / true）也能保持', () {
      const s = ReaderSettings();
      final s2 = ReaderSettings.fromJson(s.toJson());
      expect(s2.screenBrightness, -1.0);
      expect(s2.keepScreenOn, true);
    });

    test('v5 旧 JSON 缺 screenBrightness / keepScreenOn → fallback 默认值', () {
      // 模拟 v5 时期写入的 JSON：含 pageAnimDurationMs 但没有 v6 两个字段。
      final s = ReaderSettings.fromJson({
        'settingsVersion': 5,
        'pageAnim': ReaderPageAnim.scroll,
        'pageAnimDurationMs': 350,
        'fontSize': 18.0,
      });
      expect(s.screenBrightness, -1.0,
          reason: 'v5 旧 JSON 缺 screenBrightness 应 fallback 到 -1.0');
      expect(s.keepScreenOn, true,
          reason: 'v5 旧 JSON 缺 keepScreenOn 应 fallback 到 true');
      // v5 已有的字段保持。
      expect(s.pageAnimDurationMs, 350);
    });

    test('v ≤ 4 旧 JSON 也回退到默认值', () {
      for (final v in [1, 2, 3, 4]) {
        final s = ReaderSettings.fromJson({
          'settingsVersion': v,
          'pageAnim': 0,
        });
        expect(s.screenBrightness, -1.0,
            reason: 'v$v 旧 JSON 应 fallback 到 -1.0');
        expect(s.keepScreenOn, true,
            reason: 'v$v 旧 JSON 应 fallback 到 true');
      }
    });

    test('JSON 中 screenBrightness 为 num（int / double）都能还原', () {
      // 防御性测试：JSON 数字解析得到的可能是 int（例如 0 或 1）。
      final s1 = ReaderSettings.fromJson({
        'settingsVersion': 6,
        'screenBrightness': 1, // int
        'keepScreenOn': true,
      });
      expect(s1.screenBrightness, 1.0);

      final s2 = ReaderSettings.fromJson({
        'settingsVersion': 6,
        'screenBrightness': 0.5, // double
        'keepScreenOn': false,
      });
      expect(s2.screenBrightness, 0.5);
      expect(s2.keepScreenOn, false);
    });
  });

  // ── 批次 2 (05-18) — enableVolumeKeyPage / volumeKeyPageOnTts ─────────
  // 仍保 schema=v6（与 batch01 同模式：fromJson 缺字段 fallback 默认值，
  // 不强升 settingsVersion）。
  group('ReaderSettings — 批次 2 音量键翻页字段', () {
    test('默认值：enableVolumeKeyPage=true / volumeKeyPageOnTts=false', () {
      const s = ReaderSettings();
      expect(s.enableVolumeKeyPage, true,
          reason: '对齐原 Legado MD3 AppConfig.volumeKeyPage 默认开启');
      expect(s.volumeKeyPageOnTts, false,
          reason: '对齐 AppConfig.volumeKeyPageOnPlay 默认关闭');
    });

    test('copyWith 单独修改两个字段', () {
      const base = ReaderSettings();
      final a = base.copyWith(enableVolumeKeyPage: false);
      expect(a.enableVolumeKeyPage, false);
      expect(a.volumeKeyPageOnTts, base.volumeKeyPageOnTts);
      final b = base.copyWith(volumeKeyPageOnTts: true);
      expect(b.volumeKeyPageOnTts, true);
      expect(b.enableVolumeKeyPage, base.enableVolumeKeyPage);
    });

    test('toJson 写出两个新字段', () {
      const s = ReaderSettings(
        enableVolumeKeyPage: false,
        volumeKeyPageOnTts: true,
      );
      final j = s.toJson();
      expect(j['enableVolumeKeyPage'], false);
      expect(j['volumeKeyPageOnTts'], true);
    });

    test('round-trip 保持值', () {
      const s = ReaderSettings(
        enableVolumeKeyPage: false,
        volumeKeyPageOnTts: true,
      );
      final s2 = ReaderSettings.fromJson(s.toJson());
      expect(s2.enableVolumeKeyPage, false);
      expect(s2.volumeKeyPageOnTts, true);
    });

    test('v6 旧 JSON 缺新字段 → fallback 到默认值', () {
      // 模拟 batch01 时期写入的 v6 JSON：含 screenBrightness/keepScreenOn
      // 但没有 batch02 两个字段。
      final s = ReaderSettings.fromJson({
        'settingsVersion': 6,
        'screenBrightness': 0.5,
        'keepScreenOn': false,
      });
      expect(s.enableVolumeKeyPage, true,
          reason: 'v6 旧 JSON 缺 enableVolumeKeyPage 应 fallback 到 true');
      expect(s.volumeKeyPageOnTts, false,
          reason: 'v6 旧 JSON 缺 volumeKeyPageOnTts 应 fallback 到 false');
      // batch01 字段保持。
      expect(s.screenBrightness, 0.5);
      expect(s.keepScreenOn, false);
    });
  });

  // ── 批次 3 (05-18) — tapZones（3×3 点击区域配置）─────────────────────
  // 仍保 schema=v6（与 batch01/02 同模式：fromJson 缺字段 fallback 默认列表）。
  group('ReaderSettings — 批次 3 tapZones 字段', () {
    test('默认值：tapZones == ReaderSettings.tapZonesDefault', () {
      const s = ReaderSettings();
      expect(s.tapZones, ReaderSettings.tapZonesDefault);
      expect(s.tapZones.length, 9);
    });

    test('显式构造可覆盖默认值', () {
      const s = ReaderSettings(tapZones: ReaderSettings.tapZonesClassic);
      expect(s.tapZones, ReaderSettings.tapZonesClassic);
    });

    test('copyWith 单独修改 tapZones', () {
      const base = ReaderSettings();
      final s = base.copyWith(tapZones: ReaderSettings.tapZonesFullMenu);
      expect(s.tapZones, ReaderSettings.tapZonesFullMenu);
      // 其它字段保持。
      expect(s.fontSize, base.fontSize);
      expect(s.enableVolumeKeyPage, base.enableVolumeKeyPage);
    });

    test('copyWith 不传 tapZones 时保持原值', () {
      const base = ReaderSettings(tapZones: ReaderSettings.tapZonesClassic);
      final s = base.copyWith(fontSize: 22);
      expect(s.tapZones, ReaderSettings.tapZonesClassic);
      expect(s.fontSize, 22);
    });

    test('toJson 写出 tapZones（List<int> 长度 9）', () {
      const s = ReaderSettings(tapZones: ReaderSettings.tapZonesClassic);
      final j = s.toJson();
      expect(j['tapZones'], isA<List>());
      expect(j['tapZones'], ReaderSettings.tapZonesClassic);
    });

    test('round-trip：toJson → fromJson 字段值保持', () {
      const s = ReaderSettings(tapZones: [0, 1, 2, 3, 0, 1, 2, 3, 0]);
      final s2 = ReaderSettings.fromJson(s.toJson());
      expect(s2.tapZones, [0, 1, 2, 3, 0, 1, 2, 3, 0]);
    });

    test('round-trip：默认值也能保持', () {
      const s = ReaderSettings();
      final s2 = ReaderSettings.fromJson(s.toJson());
      expect(s2.tapZones, ReaderSettings.tapZonesDefault);
    });

    test('v6 旧 JSON 缺 tapZones → fallback 到 tapZonesDefault', () {
      // 模拟 batch01/02 时期写入的 v6 JSON：完全没有 tapZones 字段。
      final s = ReaderSettings.fromJson({
        'settingsVersion': 6,
        'screenBrightness': 0.5,
        'keepScreenOn': false,
        'enableVolumeKeyPage': false,
      });
      expect(s.tapZones, ReaderSettings.tapZonesDefault);
      // batch01/02 字段保持。
      expect(s.screenBrightness, 0.5);
      expect(s.keepScreenOn, false);
      expect(s.enableVolumeKeyPage, false);
    });

    test('v ≤ 5 旧 JSON 也回退到 tapZonesDefault', () {
      for (final v in [1, 2, 3, 4, 5]) {
        final s = ReaderSettings.fromJson({
          'settingsVersion': v,
          'pageAnim': 0,
        });
        expect(s.tapZones, ReaderSettings.tapZonesDefault,
            reason: 'v$v 旧 JSON 应 fallback 到 tapZonesDefault');
      }
    });

    test('JSON 中 tapZones 长度不为 9 → fallback 到 tapZonesDefault', () {
      // 损坏数据防御：用户手改 settings.json 写出长度不对的列表。
      final s = ReaderSettings.fromJson({
        'settingsVersion': 6,
        'tapZones': [0, 1, 2], // length=3，不合法
      });
      expect(s.tapZones, ReaderSettings.tapZonesDefault);
    });

    test('JSON 中 tapZones 不是 List → fallback 到 tapZonesDefault', () {
      final s = ReaderSettings.fromJson({
        'settingsVersion': 6,
        'tapZones': 'not a list',
      });
      expect(s.tapZones, ReaderSettings.tapZonesDefault);
    });

    test('JSON 中 tapZones 元素值越界 → clamp 到 0..3', () {
      final s = ReaderSettings.fromJson({
        'settingsVersion': 6,
        'tapZones': [0, 1, 2, 3, 99, -1, 2, 1, 0],
      });
      expect(s.tapZones, [0, 1, 2, 3, 3, 0, 2, 1, 0]);
    });

    test('JSON 中 tapZones 元素是 num（double）也能还原', () {
      // jsonDecode 偶尔会把 0/1 解为 int，但若来源是别处（例如 yaml）
      // 可能是 double。
      final s = ReaderSettings.fromJson({
        'settingsVersion': 6,
        'tapZones': [0.0, 1.0, 2.0, 3.0, 0.0, 1.0, 2.0, 3.0, 0.0],
      });
      expect(s.tapZones, [0, 1, 2, 3, 0, 1, 2, 3, 0]);
    });

    test('JSON 中 tapZones 元素是非数字 → 该位置兜底 showMenu(2)', () {
      final s = ReaderSettings.fromJson({
        'settingsVersion': 6,
        'tapZones': [0, 'foo', 2, null, 0, 1, 2, 1, 0],
      });
      expect(s.tapZones, [0, 2, 2, 2, 0, 1, 2, 1, 0]);
    });

    test('fromJson 返回的 tapZones 列表是可修改的副本（不与默认 const 共享引用）',
        () {
      // 防御性测试：避免外部 mutate 共享了 const 默认 list 引发 unmodifiable
      // 异常或污染下次默认值。
      final s = ReaderSettings.fromJson({'settingsVersion': 6});
      // 默认 fallback 路径应该返回新的副本。
      expect(() => s.tapZones[0] = 1, returnsNormally);
    });
  });

  // 批次 4 (05-18): autoScrollSpeed / autoPageIntervalSeconds
  group('ReaderSettings — 批次 4 自动翻页字段', () {
    test('默认值: autoScrollSpeed=1, autoPageIntervalSeconds=10', () {
      const s = ReaderSettings();
      expect(s.autoScrollSpeed, 1);
      expect(s.autoPageIntervalSeconds, 10);
    });

    test('copyWith 单独修改两字段', () {
      const a = ReaderSettings();
      final b = a.copyWith(autoScrollSpeed: 5);
      expect(b.autoScrollSpeed, 5);
      expect(b.autoPageIntervalSeconds, 10);

      final c = a.copyWith(autoPageIntervalSeconds: 20);
      expect(c.autoScrollSpeed, 1);
      expect(c.autoPageIntervalSeconds, 20);
    });

    test('toJson 含两字段', () {
      const s = ReaderSettings(
          autoScrollSpeed: 3, autoPageIntervalSeconds: 15);
      final j = s.toJson();
      expect(j['autoScrollSpeed'], 3);
      expect(j['autoPageIntervalSeconds'], 15);
    });

    test('fromJson round-trip', () {
      const s = ReaderSettings(
          autoScrollSpeed: 7, autoPageIntervalSeconds: 25);
      final r = ReaderSettings.fromJson(s.toJson());
      expect(r.autoScrollSpeed, 7);
      expect(r.autoPageIntervalSeconds, 25);
    });

    test('fromJson 缺字段 → 默认 1 / 10', () {
      final s = ReaderSettings.fromJson({'settingsVersion': 6});
      expect(s.autoScrollSpeed, 1);
      expect(s.autoPageIntervalSeconds, 10);
    });

    test('fromJson 越界值被 clamp 到合法区间', () {
      final s1 = ReaderSettings.fromJson({
        'settingsVersion': 6,
        'autoScrollSpeed': 0,
        'autoPageIntervalSeconds': -5,
      });
      expect(s1.autoScrollSpeed, 1, reason: 'speed 0 clamp 到 1');
      expect(s1.autoPageIntervalSeconds, 1, reason: 'interval -5 clamp 到 1');

      final s2 = ReaderSettings.fromJson({
        'settingsVersion': 6,
        'autoScrollSpeed': 100,
        'autoPageIntervalSeconds': 999,
      });
      expect(s2.autoScrollSpeed, 10, reason: 'speed 100 clamp 到 10');
      expect(s2.autoPageIntervalSeconds, 30,
          reason: 'interval 999 clamp 到 30');
    });
  });

  // 批次 5 (05-18): enableLongPressMenu
  group('ReaderSettings — 批次 5 长按菜单字段', () {
    test('默认值: enableLongPressMenu = true', () {
      const s = ReaderSettings();
      expect(s.enableLongPressMenu, true);
    });

    test('copyWith 修改字段', () {
      const a = ReaderSettings();
      final b = a.copyWith(enableLongPressMenu: false);
      expect(b.enableLongPressMenu, false);
      expect(a.enableLongPressMenu, true, reason: '原对象不变');
    });

    test('toJson / fromJson round-trip', () {
      const s = ReaderSettings(enableLongPressMenu: false);
      final r = ReaderSettings.fromJson(s.toJson());
      expect(r.enableLongPressMenu, false);
    });

    test('fromJson 缺字段 fallback true', () {
      final s = ReaderSettings.fromJson({'settingsVersion': 6});
      expect(s.enableLongPressMenu, true);
    });
  });
}
