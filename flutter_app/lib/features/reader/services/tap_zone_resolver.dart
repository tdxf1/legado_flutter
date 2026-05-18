/// 批次 3 (05-18) — 阅读器 3×3 点击区域解析。
///
/// 把 tap 位置 (x, y) 映射到 9 宫格 zone idx，再按 `settings.tapZones[idx]`
/// 解析成动作枚举。逻辑抽成纯函数便于单测，避免依赖 BuildContext / RenderBox。
///
/// 索引顺序（行主序）：
/// ```
///   0 (左上)  1 (上)  2 (右上)
///   3 (左)    4 (中)  5 (右)
///   6 (左下)  7 (下)  8 (右下)
/// ```
///
/// 对齐原 Legado MD3 `ClickActionConfigDialog` 的 5 区设计（这里扩展到 9 区
/// 更精细，但 5 区可由 ChoiceChip 预设映射回来）。
library;

/// 单个 zone 解析出的动作。
///
/// 当前批次只覆盖 4 个动作，后续批次（朗读 / 字典 / 书签 …）可扩。
enum TapZoneAction {
  prevPage,
  nextPage,
  showMenu,
  nothing,
}

/// 把 tap 位置映射到 3×3 zone 索引（0-8）。
///
/// - `(x, y)` 是相对于阅读区左上角的 tap 坐标（与 `details.localPosition` 同
///   坐标系；调用方应保证 `(w, h)` 是同一 RenderBox 的尺寸）。
/// - `(w, h)` 必须是阅读区宽高；`<= 0` 时返回中心 idx=4 兜底，避免除 0。
/// - 越界（x<0 / x>=w / y<0 / y>=h）由 `clamp(0, 2)` 收敛到边界 zone，
///   不会返回 -1 / 9（保证调用方拿到的 idx ∈ [0, 8]）。
int tapZoneIndex(double x, double y, double w, double h) {
  if (w <= 0 || h <= 0) return 4;
  final col = (x / w * 3).floor().clamp(0, 2);
  final row = (y / h * 3).floor().clamp(0, 2);
  return row * 3 + col;
}

/// 解析单个 zone 动作。
///
/// - `idx` 越界（< 0 或 >= zones.length）→ [TapZoneAction.showMenu]
/// - `zones[idx]` 不是 0..3 之一 → [TapZoneAction.showMenu]（损坏值兜底）
TapZoneAction resolveTapAction(List<int> zones, int idx) {
  if (idx < 0 || idx >= zones.length) return TapZoneAction.showMenu;
  switch (zones[idx]) {
    case 0:
      return TapZoneAction.prevPage;
    case 1:
      return TapZoneAction.nextPage;
    case 2:
      return TapZoneAction.showMenu;
    case 3:
      return TapZoneAction.nothing;
    default:
      return TapZoneAction.showMenu;
  }
}
