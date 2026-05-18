import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/providers.dart';

void main() {
  group('ReaderPageAnim.migrateFromV1 (v1 → v4)', () {
    test('legacy 0 (无动画) → noAnim', () {
      expect(ReaderPageAnim.migrateFromV1(0), ReaderPageAnim.noAnim);
    });
    test('legacy 2 (覆盖) → cover', () {
      expect(ReaderPageAnim.migrateFromV1(2), ReaderPageAnim.cover);
    });
    test('legacy 3 (平移) → slide', () {
      expect(ReaderPageAnim.migrateFromV1(3), ReaderPageAnim.slide);
    });
    test('其它 → noAnim', () {
      expect(ReaderPageAnim.migrateFromV1(1), ReaderPageAnim.noAnim);
      expect(ReaderPageAnim.migrateFromV1(99), ReaderPageAnim.noAnim);
      expect(ReaderPageAnim.migrateFromV1(-5), ReaderPageAnim.noAnim);
    });
  });

  group('ReaderPageAnim.migrateFromV2 (v2 → v4)', () {
    test('cover/slide/simulation 不变', () {
      expect(ReaderPageAnim.migrateFromV2(0), ReaderPageAnim.cover);
      expect(ReaderPageAnim.migrateFromV2(1), ReaderPageAnim.slide);
      expect(ReaderPageAnim.migrateFromV2(2), ReaderPageAnim.simulation);
    });
    test('legacy 3 (scroll, 旧版的分页内滚动) → noAnim', () {
      expect(ReaderPageAnim.migrateFromV2(3), ReaderPageAnim.noAnim);
    });
    test('legacy 4 (fade) → 3 (fade)', () {
      expect(ReaderPageAnim.migrateFromV2(4), ReaderPageAnim.fade);
    });
    test('legacy 5 (noAnim) → 4 (noAnim)', () {
      expect(ReaderPageAnim.migrateFromV2(5), ReaderPageAnim.noAnim);
    });
    test('其它 → noAnim', () {
      expect(ReaderPageAnim.migrateFromV2(99), ReaderPageAnim.noAnim);
      expect(ReaderPageAnim.migrateFromV2(-1), ReaderPageAnim.noAnim);
    });
  });

  group('ReaderPageAnim.migrateFromV3 (v3 → v4)', () {
    test('v3 0..4 verbatim', () {
      expect(ReaderPageAnim.migrateFromV3(0), ReaderPageAnim.cover);
      expect(ReaderPageAnim.migrateFromV3(1), ReaderPageAnim.slide);
      expect(ReaderPageAnim.migrateFromV3(2), ReaderPageAnim.simulation);
      expect(ReaderPageAnim.migrateFromV3(3), ReaderPageAnim.fade);
      expect(ReaderPageAnim.migrateFromV3(4), ReaderPageAnim.noAnim);
    });
    test('out-of-range clamps to v3 max (noAnim)', () {
      // v3 没有 scroll，所以哪怕 v4 加了 scroll=5，从 v3 升上来也不能跳过
      // 显式选择直接落到 noAnim。
      expect(ReaderPageAnim.migrateFromV3(99), ReaderPageAnim.noAnim);
      expect(ReaderPageAnim.migrateFromV3(5), ReaderPageAnim.noAnim);
    });
  });

  group('overlayPageModeOnAnim (PageMode 折叠成 anim=scroll)', () {
    test('旧 pageMode=0 (continuousScroll) 强制覆盖为 scroll', () {
      expect(
        overlayPageModeOnAnim(oldPageMode: 0, currentAnim: ReaderPageAnim.cover),
        ReaderPageAnim.scroll,
      );
    });
    test('旧 pageMode=1 (tapChapter / page in v3) 不动 anim', () {
      expect(
        overlayPageModeOnAnim(oldPageMode: 1, currentAnim: ReaderPageAnim.cover),
        ReaderPageAnim.cover,
      );
    });
    test('旧 pageMode=2 (page in v1/v2) 不动 anim', () {
      expect(
        overlayPageModeOnAnim(oldPageMode: 2, currentAnim: ReaderPageAnim.simulation),
        ReaderPageAnim.simulation,
      );
    });
  });

  group('ReaderSettings.fromJson 全链路迁移', () {
    test('v1 (no version) + pageMode=0 (continuousScroll) → anim=scroll', () {
      final s = ReaderSettings.fromJson({'pageMode': 0, 'pageAnim': 0});
      expect(s.pageAnim, ReaderPageAnim.scroll);
      expect(s.isScrollMode, isTrue);
    });

    test('v1 + pageMode=1 (tapChapter) + pageAnim=0 → noAnim', () {
      // tapChapter 不是 continuousScroll，因此不覆盖；pageAnim 0 → noAnim
      final s = ReaderSettings.fromJson({'pageMode': 1, 'pageAnim': 0});
      expect(s.pageAnim, ReaderPageAnim.noAnim);
    });

    test('v1 + pageMode=2 (page) + pageAnim=2 (cover) → cover', () {
      final s = ReaderSettings.fromJson({'pageMode': 2, 'pageAnim': 2});
      expect(s.pageAnim, ReaderPageAnim.cover);
    });

    test('v2 + pageMode=0 + pageAnim=2 (simulation) → scroll (overlay 优先)', () {
      final s = ReaderSettings.fromJson({
        'settingsVersion': 2,
        'pageMode': 0,
        'pageAnim': 2,
      });
      expect(s.pageAnim, ReaderPageAnim.scroll);
    });

    test('v2 + pageMode=2 + pageAnim=2 (simulation) → simulation', () {
      final s = ReaderSettings.fromJson({
        'settingsVersion': 2,
        'pageMode': 2,
        'pageAnim': 2,
      });
      expect(s.pageAnim, ReaderPageAnim.simulation);
    });

    test('v3 + pageMode=0 + pageAnim=0 → scroll', () {
      final s = ReaderSettings.fromJson({
        'settingsVersion': 3,
        'pageMode': 0,
        'pageAnim': 0,
      });
      expect(s.pageAnim, ReaderPageAnim.scroll);
    });

    test('v3 + pageMode=1 + pageAnim=2 (simulation) → simulation', () {
      final s = ReaderSettings.fromJson({
        'settingsVersion': 3,
        'pageMode': 1, // page in v3
        'pageAnim': 2,
      });
      expect(s.pageAnim, ReaderPageAnim.simulation);
    });

    test('v4 + pageAnim=5 (scroll) → scroll verbatim', () {
      final s = ReaderSettings.fromJson({
        'settingsVersion': 4,
        'pageAnim': 5,
      });
      expect(s.pageAnim, ReaderPageAnim.scroll);
      expect(s.isScrollMode, isTrue);
    });

    test('v4 clamps out-of-range pageAnim to max=5', () {
      final s = ReaderSettings.fromJson({
        'settingsVersion': 4,
        'pageAnim': 999,
      });
      expect(s.pageAnim, ReaderPageAnim.max);
      expect(ReaderPageAnim.max, 5);
    });

    test('toJson 总是写 kReaderSettingsCurrentVersion，且没有 pageMode 字段', () {
      const s = ReaderSettings(pageAnim: ReaderPageAnim.scroll);
      final j = s.toJson();
      expect(j['settingsVersion'], kReaderSettingsCurrentVersion);
      expect(j['pageAnim'], ReaderPageAnim.scroll);
      expect(j.containsKey('pageMode'), isFalse);
    });

    test('round-trip: v1 continuousScroll → 当前版本 scroll 持久', () {
      final v1 = {'pageMode': 0, 'pageAnim': 0};
      final s1 = ReaderSettings.fromJson(v1);
      final j2 = s1.toJson();
      final s2 = ReaderSettings.fromJson(j2);
      expect(s2.pageAnim, ReaderPageAnim.scroll);
      expect(j2['settingsVersion'], kReaderSettingsCurrentVersion);
    });

    test('round-trip: v3 page+simulation → v4 simulation', () {
      final v3 = {
        'settingsVersion': 3,
        'pageMode': 1,
        'pageAnim': 2,
      };
      final s1 = ReaderSettings.fromJson(v3);
      final j2 = s1.toJson();
      final s2 = ReaderSettings.fromJson(j2);
      expect(s2.pageAnim, ReaderPageAnim.simulation);
    });
  });

  group('ReaderPageAnim labels', () {
    test('共 6 项 (含 scroll)', () {
      expect(ReaderPageAnim.labels.length, 6);
      for (var i = ReaderPageAnim.min; i <= ReaderPageAnim.max; i++) {
        expect(ReaderPageAnim.labels[i], isNotNull);
        expect(ReaderPageAnim.labels[i], isNotEmpty);
      }
    });

    test('max == 5 (scroll)', () {
      expect(ReaderPageAnim.max, 5);
      expect(ReaderPageAnim.scroll, 5);
    });

    test('scroll label = "滚动"', () {
      expect(ReaderPageAnim.labels[ReaderPageAnim.scroll], '滚动');
    });
  });

  group('ReaderSettings.isScrollMode', () {
    test('默认为 scroll → isScrollMode=true', () {
      const s = ReaderSettings();
      expect(s.isScrollMode, isTrue);
    });

    test('其它 anim → isScrollMode=false', () {
      for (final a in [
        ReaderPageAnim.cover,
        ReaderPageAnim.slide,
        ReaderPageAnim.simulation,
        ReaderPageAnim.fade,
        ReaderPageAnim.noAnim,
      ]) {
        expect(ReaderSettings(pageAnim: a).isScrollMode, isFalse,
            reason: 'anim=$a should not be scroll mode');
      }
    });
  });

  group('ReaderRenderMode (P3-5)', () {
    test('scroll → continuous; everything else → paged', () {
      expect(
          ReaderSettings(pageAnim: ReaderPageAnim.scroll).renderMode,
          ReaderRenderMode.continuous);
      for (final a in [
        ReaderPageAnim.cover,
        ReaderPageAnim.slide,
        ReaderPageAnim.simulation,
        ReaderPageAnim.fade,
        ReaderPageAnim.noAnim,
      ]) {
        expect(ReaderSettings(pageAnim: a).renderMode,
            ReaderRenderMode.paged,
            reason: 'anim=$a should render as paged');
      }
    });

    test('isScrollMode is an alias of renderMode == continuous', () {
      for (final a in [
        ReaderPageAnim.cover,
        ReaderPageAnim.slide,
        ReaderPageAnim.simulation,
        ReaderPageAnim.fade,
        ReaderPageAnim.noAnim,
        ReaderPageAnim.scroll,
      ]) {
        final s = ReaderSettings(pageAnim: a);
        expect(s.isScrollMode,
            s.renderMode == ReaderRenderMode.continuous);
      }
    });
  });
}
