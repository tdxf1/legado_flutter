/// 批次 3 (05-18) — 阅读器 3×3 点击区域解析单测。
///
/// 覆盖：
/// 1. tapZoneIndex 9 个网格点的中心 / 四角 / 四边都映射到正确 idx (0..8)
/// 2. 边界 / 越界 / w==0 / h==0 兜底
/// 3. resolveTapAction 4 个枚举值映射 + 越界 idx + 损坏值 → showMenu
/// 4. 三套预设值正确（length 9 + 内容对齐 PRD）
import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/providers.dart';
import 'package:legado_flutter/features/reader/services/tap_zone_resolver.dart';

void main() {
  group('tapZoneIndex — 9 个采样点（300×300 阅读区）', () {
    // 每格 100×100。采样点取格子中心 (50, 150, 250)，预期 idx = row*3+col。
    test('左上 (50,50) → 0', () {
      expect(tapZoneIndex(50, 50, 300, 300), 0);
    });
    test('上 (150,50) → 1', () {
      expect(tapZoneIndex(150, 50, 300, 300), 1);
    });
    test('右上 (250,50) → 2', () {
      expect(tapZoneIndex(250, 50, 300, 300), 2);
    });
    test('左 (50,150) → 3', () {
      expect(tapZoneIndex(50, 150, 300, 300), 3);
    });
    test('中 (150,150) → 4', () {
      expect(tapZoneIndex(150, 150, 300, 300), 4);
    });
    test('右 (250,150) → 5', () {
      expect(tapZoneIndex(250, 150, 300, 300), 5);
    });
    test('左下 (50,250) → 6', () {
      expect(tapZoneIndex(50, 250, 300, 300), 6);
    });
    test('下 (150,250) → 7', () {
      expect(tapZoneIndex(150, 250, 300, 300), 7);
    });
    test('右下 (250,250) → 8', () {
      expect(tapZoneIndex(250, 250, 300, 300), 8);
    });
  });

  group('tapZoneIndex — 边界 & 兜底', () {
    test('(0, 0) → 0（左上角）', () {
      expect(tapZoneIndex(0, 0, 300, 300), 0);
    });
    test('(w-ε, h-ε) → 8（右下角）', () {
      expect(tapZoneIndex(299.9, 299.9, 300, 300), 8);
    });
    test('x == w 边界 → clamp 到 col=2', () {
      // x/w == 1.0 → floor = 3 → clamp(0,2) = 2
      expect(tapZoneIndex(300, 50, 300, 300), 2);
    });
    test('x > w 越界 → clamp 到 col=2', () {
      expect(tapZoneIndex(500, 50, 300, 300), 2);
    });
    test('x < 0 越界 → clamp 到 col=0', () {
      expect(tapZoneIndex(-10, 50, 300, 300), 0);
    });
    test('w == 0 → 中心 idx=4 兜底（避免除 0）', () {
      expect(tapZoneIndex(50, 50, 0, 300), 4);
    });
    test('h == 0 → 中心 idx=4 兜底', () {
      expect(tapZoneIndex(50, 50, 300, 0), 4);
    });
    test('w 与 h 同为 0 → 中心 idx=4 兜底', () {
      expect(tapZoneIndex(0, 0, 0, 0), 4);
    });
    test('非方形阅读区（400×600）也能正确切 9 格', () {
      // col 边界 400/3 ≈ 133.33 / 266.67；row 边界 600/3 = 200 / 400。
      expect(tapZoneIndex(60, 100, 400, 600), 0); // 左上
      expect(tapZoneIndex(200, 100, 400, 600), 1); // 上
      expect(tapZoneIndex(350, 100, 400, 600), 2); // 右上
      expect(tapZoneIndex(60, 300, 400, 600), 3); // 左
      expect(tapZoneIndex(200, 500, 400, 600), 7); // 下
    });
  });

  group('resolveTapAction — 4 个枚举值映射', () {
    test('zones[idx] == 0 → prevPage', () {
      expect(resolveTapAction([0, 1, 2, 3, 0, 1, 2, 3, 0], 4),
          TapZoneAction.prevPage);
    });
    test('zones[idx] == 1 → nextPage', () {
      expect(resolveTapAction([0, 1, 2, 3, 0, 1, 2, 3, 0], 5),
          TapZoneAction.nextPage);
    });
    test('zones[idx] == 2 → showMenu', () {
      expect(resolveTapAction([0, 1, 2, 3, 0, 1, 2, 3, 0], 2),
          TapZoneAction.showMenu);
    });
    test('zones[idx] == 3 → nothing', () {
      expect(resolveTapAction([0, 1, 2, 3, 0, 1, 2, 3, 0], 3),
          TapZoneAction.nothing);
    });
  });

  group('resolveTapAction — 越界 / 损坏值', () {
    test('idx < 0 → showMenu', () {
      expect(resolveTapAction(ReaderSettings.tapZonesDefault, -1),
          TapZoneAction.showMenu);
    });
    test('idx >= length → showMenu', () {
      expect(resolveTapAction(ReaderSettings.tapZonesDefault, 9),
          TapZoneAction.showMenu);
    });
    test('zones 长度不足 → 越界 idx 仍 showMenu', () {
      expect(resolveTapAction([0, 1, 2], 5), TapZoneAction.showMenu);
    });
    test('zones[idx] == 99（损坏值）→ showMenu 兜底', () {
      expect(resolveTapAction([99, 99, 99, 99, 99, 99, 99, 99, 99], 4),
          TapZoneAction.showMenu);
    });
    test('zones[idx] == -1（损坏值）→ showMenu 兜底', () {
      expect(resolveTapAction([-1, -1, -1, -1, -1, -1, -1, -1, -1], 4),
          TapZoneAction.showMenu);
    });
  });

  group('ReaderSettings 三套点击区域预设', () {
    test('tapZonesDefault 长度 == 9 且元素对齐 PRD', () {
      expect(ReaderSettings.tapZonesDefault, [2, 2, 2, 2, 2, 2, 0, 1, 1]);
      expect(ReaderSettings.tapZonesDefault.length, 9);
    });
    test('tapZonesClassic 长度 == 9 且元素对齐 PRD', () {
      expect(ReaderSettings.tapZonesClassic, [0, 0, 0, 0, 2, 1, 1, 1, 1]);
      expect(ReaderSettings.tapZonesClassic.length, 9);
    });
    test('tapZonesFullMenu 长度 == 9 且全 showMenu', () {
      expect(ReaderSettings.tapZonesFullMenu, [2, 2, 2, 2, 2, 2, 2, 2, 2]);
      expect(ReaderSettings.tapZonesFullMenu.length, 9);
    });

    test('每个预设的元素值都在 0..3 范围内', () {
      for (final preset in [
        ReaderSettings.tapZonesDefault,
        ReaderSettings.tapZonesClassic,
        ReaderSettings.tapZonesFullMenu,
      ]) {
        for (final v in preset) {
          expect(v, inInclusiveRange(0, 3));
        }
      }
    });

    test('默认预设：左下 prev / 下中 next / 右下 next', () {
      final p = ReaderSettings.tapZonesDefault;
      expect(resolveTapAction(p, 6), TapZoneAction.prevPage,
          reason: '左下 = 上一页');
      expect(resolveTapAction(p, 7), TapZoneAction.nextPage, reason: '下中 = 下一页');
      expect(resolveTapAction(p, 8), TapZoneAction.nextPage, reason: '右下 = 下一页');
      // 上半 + 中排都是 menu
      for (final i in [0, 1, 2, 3, 4, 5]) {
        expect(resolveTapAction(p, i), TapZoneAction.showMenu, reason: 'idx=$i');
      }
    });

    test('经典预设：上半 prev / next，中间 menu，下半 next', () {
      final p = ReaderSettings.tapZonesClassic;
      // 上排 + 左 = prev
      for (final i in [0, 1, 2, 3]) {
        expect(resolveTapAction(p, i), TapZoneAction.prevPage, reason: 'idx=$i');
      }
      expect(resolveTapAction(p, 4), TapZoneAction.showMenu);
      // 右 + 下排 = next
      for (final i in [5, 6, 7, 8]) {
        expect(resolveTapAction(p, i), TapZoneAction.nextPage, reason: 'idx=$i');
      }
    });

    test('全屏菜单预设：9 格全 showMenu', () {
      final p = ReaderSettings.tapZonesFullMenu;
      for (var i = 0; i < 9; i++) {
        expect(resolveTapAction(p, i), TapZoneAction.showMenu, reason: 'idx=$i');
      }
    });
  });
}
