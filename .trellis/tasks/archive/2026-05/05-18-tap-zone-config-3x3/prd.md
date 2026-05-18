# 3×3 点击区域配置 (批次 3)

## Goal

把 reader 的点击区从硬编码"左 1/3 prev / 中 1/3 menu / 右 2/3 next" 改成 **3×3 九宫格**，每个槽位独立配置动作。对齐原 Legado MD3 `ClickActionConfigDialog` 的 5 区设计（这里扩展到 9 区，更精细）。

## What I already know

- **原项目**：`ClickActionConfigDialog.kt` 5 区（左/中/右 × 上/下，中间合并）
- **Flutter 现状**：`reader_page.dart:1808-1837` `onTapUp` 内硬编码：
  - `dx < width/3` → prev
  - `dx > width*2/3` → next
  - 否则 → toggle menu
- 没有 y 轴感知；没有可配置；不区分上半屏/下半屏
- Settings 没有 tap zone 字段

## Decision

**3×3 九宫格**比 MD3 的 5 区更精细，且实现成本相同。每个槽位 ENUM:
- `nextPage` / `prevPage` / `showMenu` / `nothing`（本批 4 个动作；后续可扩 朗读/书签/字典 等）

预设 3 套：
1. **默认 Default**：左中右下排 prev / menu / next；其余 menu
2. **经典 Classic**：左半屏 prev / 右半屏 next（无中间 menu — 长按或顶部进 menu）
3. **全屏菜单 Full menu**：9 格全 showMenu（适合不靠 tap 翻页只用音量键的人）

存到 `ReaderSettings.tapZones`（List<int> 长度 9，每个值 0-3 对应 enum）。

## Requirements

1. **新增 ReaderSettings 字段**：`List<int> tapZones`（长度 9，默认 `[2,2,2,2,2,2,1,2,0]` = 默认预设）
   - 索引顺序：`[左上, 上, 右上, 左, 中, 右, 左下, 下, 右下]`
   - 值含义：0=prevPage, 1=nextPage, 2=showMenu, 3=nothing
   - 默认 = "下排"中间 next、左下 prev、其余 menu
2. **`reader_page.dart` `onTapUp` 改造**：根据 (dx, dy) 算 zone idx，从 `tapZones[idx]` 取动作分派
3. **设置面板加"点击区域"对话框**：3×3 网格，每格点击循环 4 个动作；底部 3 个预设按钮 + 自定义说明
4. **保持 PageViewController.onTapPrev/Next fallback** 与现有逻辑一致

## Acceptance Criteria

- [ ] 单测：`zoneIndex(x, y, w, h)` 9 个网格点能正确返回 0-8
- [ ] 单测：`resolveTapZoneAction(zones, idx)` 按 idx 取动作
- [ ] 单测：3 套预设值正确（default / classic / full menu）
- [ ] 单测：ReaderSettings round-trip / fromJson 缺字段 fallback 默认 9 格列表
- [ ] flutter analyze 0 issue
- [ ] flutter test 全绿（≥ 274 = 268 baseline + 至少 6+ 新）
- [ ] 实机：默认布局下点 9 个区域得正确动作；切到经典后中间也翻页

## Definition of Done

- analyze 0 issue / test 全绿
- debug APK 到 dist/
- commit + archive

## Technical Approach

### A. ReaderSettings 字段

```dart
/// 批次 3 (05-18): 阅读器 3×3 点击区域配置。9 个槽位，索引顺序：
/// [0=左上, 1=上, 2=右上, 3=左, 4=中, 5=右, 6=左下, 7=下, 8=右下]。
/// 每个值：0=prevPage / 1=nextPage / 2=showMenu / 3=nothing。
/// 默认 [2,2,2,2,2,2,0,1,1]：左下 prev、下中 next、右下 next、其余 menu。
final List<int> tapZones;
```

默认值 const list `[2,2,2,2,2,2,0,1,1]`（user 习惯：下排操作翻页、上排出菜单）。

```dart
// 预设
static const List<int> tapZonesDefault = [2,2,2,2,2,2,0,1,1];
static const List<int> tapZonesClassic = [0,0,0,0,2,1,1,1,1];  // 上左 prev 上右 next，中间 menu
static const List<int> tapZonesFullMenu = [2,2,2,2,2,2,2,2,2];
```

### B. 抽 zone 计算 + 派发

新建 `lib/features/reader/services/tap_zone_resolver.dart`:
```dart
/// 把 tap 位置映射到 3×3 zone 索引（0-8）。
int tapZoneIndex(double x, double y, double w, double h) {
  final col = (x / w * 3).floor().clamp(0, 2);
  final row = (y / h * 3).floor().clamp(0, 2);
  return row * 3 + col;
}

/// 解析单个 zone 动作。返回 ENUM。
enum TapZoneAction { prevPage, nextPage, showMenu, nothing }

TapZoneAction resolveTapAction(List<int> zones, int idx) {
  if (idx < 0 || idx >= zones.length) return TapZoneAction.showMenu;
  switch (zones[idx]) {
    case 0: return TapZoneAction.prevPage;
    case 1: return TapZoneAction.nextPage;
    case 2: return TapZoneAction.showMenu;
    case 3: return TapZoneAction.nothing;
    default: return TapZoneAction.showMenu;
  }
}
```

### C. ReaderPage 改造

`reader_page.dart:1810` `onTapUp`：
```dart
onTapUp: (details) {
  if (!isPage) {
    _toggleControls();
    return;
  }
  final size = (context.findRenderObject() as RenderBox?)?.size;
  if (size == null) {
    _toggleControls();
    return;
  }
  final idx = tapZoneIndex(details.localPosition.dx, details.localPosition.dy, size.width, size.height);
  final action = resolveTapAction(_settings.tapZones, idx);
  switch (action) {
    case TapZoneAction.prevPage:
      _doTapPrev();
      break;
    case TapZoneAction.nextPage:
      _doTapNext();
      break;
    case TapZoneAction.showMenu:
      _toggleControls();
      break;
    case TapZoneAction.nothing:
      break;
  }
},
```

抽 helper：
```dart
void _doTapPrev() {
  final pvc = _pageViewController;
  if (pvc == null) return;
  if (pvc.onTapPrev != null) {
    pvc.onTapPrev!();
  } else if (!pvc.goToPrevPage()) {
    _onPageChapterBoundary(PageDirection.prev);
  }
}
void _doTapNext() {
  final pvc = _pageViewController;
  if (pvc == null) return;
  if (pvc.onTapNext != null) {
    pvc.onTapNext!();
  } else if (!pvc.goToNextPage()) {
    _onPageChapterBoundary(PageDirection.next);
  }
}
```

### D. 配置 UI

`reader_settings_sheet.dart` 加 "点击区域" 按钮 → 弹 dialog：
- 3×3 网格，每格显示当前动作（图标+文字）
- 点击循环切换：prev → next → menu → nothing → prev
- 底部 3 个 ChoiceChip 预设：默认 / 经典 / 全屏菜单
- 取消 / 确定按钮

### E. 测试

`test/tap_zone_resolver_test.dart`：
- `tapZoneIndex`：9 个采样点（中心、四角、四边）→ 正确 idx
- `resolveTapAction`：4 个值 + 越界
- 3 套预设：默认/经典/全屏菜单的元素值
- ReaderSettings round-trip 含 tapZones；fromJson 缺字段 fallback default

## Out of Scope

- 长按 / 双击区域配置（原项目支持）
- 更多动作（朗读 / 字典 / 书签）—— 等批次 5（长按文字菜单）和后续
- y 轴位置之外的额外维度（如压力 / 多指）

## Research References

- `feature-gap-reader-bookshelf-source.md` §1.8（点击区域 / 音量键）

## Notes

不动 reader_settings_sheet 的"屏幕"/"按键"段；只追加"点击区域"按钮。dialog 实现可以单独建一个 widget 文件 `widgets/tap_zone_config_dialog.dart`。
