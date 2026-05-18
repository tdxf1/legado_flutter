# 仿真翻页 prev 镜像活页书几何 (T2)

## Goal

让仿真翻页的"上一页"动画视觉上像"把刚翻过去的纸盖回来"——cornerXY 锚在屏幕右下角（与 next 相同支点），触摸点从屏幕左下沿底边水平拖到右下，整张纸从全卷起的状态逐渐贴回。对齐 Legado MD3 `SimulationPageDelegate.setDirection(PREV)` 的镜像逻辑。

用户原话："活页书 翻页动画就是一张纸 翻过去盖回来"。

## What I already know

- MD3 `setDirection` (L188-L206) 把 PREV 方向的 cornerXY 强制镜像到右半边
- MD3 `prevPageByAnim` (L140-L146) 流程：`setDirection(PREV)` → `setStartPoint(0, h)` → `onAnimStart`
- MD3 `onAnimStart` (L208-L239) PREV 路径 dx = `viewWidth - touchX = viewWidth`、dy = 0
- 完整轨迹：触摸点从 (0, h) 沿底边滑到 (w, h)；cornerXY = (w, h) 右下
- Flutter 当前 bug：`prevPageByAnim` 用虚拟起点 (0.1w, 0.9h) → `_calcCornerXY` 算出 cornerX=0 左下 → 视觉是"从左下卷出一张新纸"，不是"右下盖回"
- Flutter `_calcCornerXY` 公式与 MD3 `calcCornerXY` 一致（x ≤ w/2 → cornerX=0）；缺的是 setDirection 那层镜像

详见 `research/md3-prev-geometry.md` 逐字代码摘录。

## Requirements

1. **prev tap 几何对齐 MD3**：
   - tap 触发时 cornerXY 锁在 (pageSize.width, pageSize.height) 右下角
   - 虚拟起点 / lerp 起点为 (0, h) 屏幕左下
   - lerp 终点为 (w, h) 屏幕右下
   - isRtOrLb = false（与 next 一致）
2. **prev drag 几何镜像**：用户从屏幕任意位置 drag prev 方向时，cornerXY 也强制锚到右下；现有 _calcCornerXY 直接用 startTouch 的逻辑要被 setDirection 镜像覆盖
3. **next 行为完全不变**：next tap / drag 几何继续走当前路径
4. **跨章 prev 兼容**：跨章 commitToPrevChapter 路径下动画几何与同章 prev 一致

## Acceptance Criteria

- [ ] 单测 prev tap：调 `prevPageByAnim` → `debugCornerX == pageSize.width`、`debugCornerY == pageSize.height`、`debugIsRtOrLb == false`
- [ ] 单测 next tap：调 `nextPageByAnim` → `debugCornerX == pageSize.width`、`debugCornerY == pageSize.height`、`debugIsRtOrLb == false`（next 现状即如此，确保不退化）
- [ ] 单测 prev drag：用户从屏幕左半边 startTouch → cornerX = pageSize.width（强制镜像，不是 0）
- [ ] 单测 prev drag：用户从屏幕右半边 startTouch → cornerX = pageSize.width（与左半边一致）
- [ ] 单测 _animStartTouch / _animTargetTouch 在 prev 路径下分别为 (0, h) / (w, h)
- [ ] 测试套件 225+ 全绿
- [ ] 实机：仿真模式下点屏幕左 1/3 → 看到从左下沿底边卷起的纸张，最终贴到右下角（视觉上是 next 的反向）
- [ ] 实机：仿真模式下从屏幕中间往右 drag → 同样 cornerXY 锚右下，看到纸从右下"撕开"

## Definition of Done

- flutter analyze 0 issue
- xvfb-run flutter test 全绿
- debug APK 实机验证 prev 视觉对齐
- commit 一次 + 任务 archive

## Technical Approach

### A. 引入 setDirection 镜像（核心）

在 `SimulationPageDelegate` 加 `_setDirection(PageDirection)` 方法，对应 MD3 `setDirection`：

```dart
/// 对应 MD3 SimulationPageDelegate.setDirection (L188-L206)。
/// PREV 时强制把 cornerXY 镜像到右半边，让"上一页"动画与 next 共用
/// 右下角支点（视觉效果"翻过去盖回来"）。
void _setDirectionMirrorCorner(PageDirection dir) {
  final size = pageSize.isEmpty ? const Size(400, 600) : pageSize;
  final sx = startTouch.dx;
  if (dir == PageDirection.prev) {
    // 不论用户在哪边落点，最终 cornerX 都 > w/2 → 右半边
    final mirroredX = sx > size.width / 2 ? sx : size.width - sx;
    _calcCornerXY(mirroredX, size.height);
  } else if (dir == PageDirection.next) {
    if (sx < size.width / 2) {
      // next 时左半屏落点也镜像到右半边（次要修复，对齐 MD3）
      _calcCornerXY(size.width - sx, startTouch.dy);
    }
    // 右半屏落点不动（保持现有 _calcCornerXY 输入）
  }
}
```

### B. prevPageByAnim 重构（tap 路径）

```dart
@override
void prevPageByAnim(int animationSpeed) {
  if (isRunning) return;
  final size = pageSize.isEmpty ? const Size(400, 600) : pageSize;
  // 用虚拟 tap 落点触发镜像（与 next 的 (0.9w, 0.9h) 对偶）
  final tapPoint = Offset(size.width * 0.1, size.height * 0.9);
  recordTouchStart(tapPoint, size);  // 设 _startTouch / _currentTouch / _pageSize
  _maxLength = math.sqrt(size.width * size.width + size.height * size.height);
  // ⚠️ 关键：先按 MD3 setDirection 镜像 cornerXY 到右下
  _setDirectionMirrorCorner(PageDirection.prev);
  // 再把虚拟起点重置到左下（对应 MD3 setStartPoint(0, h)）
  recordTouchStart(Offset(0, size.height), size);
  _setupTapAnim(Offset(0, size.height), PageDirection.prev);
  super.prevPageByAnim(animationSpeed);
}
```

### C. nextPageByAnim 兼容性核验

next 当前用 `(0.9w, 0.9h)` → `_calcCornerXY` 算出 (w, h) 右下。MD3 没要求 next 走 setDirection 镜像（startX > w/2 时 setDirection 内 NEXT 分支不动作）。**next 完全保留现状，不改**。

### D. drag prev 路径

`onDragStart` 当前在 horizontal_page_delegate / page_delegate 调用，simulation override 没特殊处理 drag prev。需要在 `SimulationPageDelegate.onDragStart` 加镜像逻辑：

```dart
@override
void onDragStart(Size pageSize, TextPage? cur, TextPage? next, TextPage? prev) {
  super.onDragStart(pageSize, cur, next, prev);
  _maxLength = math.sqrt(pageSize.width * pageSize.width + pageSize.height * pageSize.height);
  final start = startTouch;
  // 旧实现直接 _calcCornerXY(start.dx, start.dy)；
  // 这里改为按 setDirection 镜像。drag 阶段方向尚未确定（_direction == none），
  // 走 next 几何（不镜像）；onDragUpdate 检测到 PREV 方向后再镜像。
  _calcCornerXY(start.dx, start.dy);
}
```

实际方向在 `onDragUpdate` 决定（dragOffset > 5 = prev / < -5 = next）。决定方向那一刻调 `_setDirectionMirrorCorner`：

```dart
@override
void onDragUpdate(double delta) {
  final priorDir = direction;
  super.onDragUpdate(delta);
  if (priorDir == PageDirection.none && direction != PageDirection.none) {
    // 方向首次确定 → 应用 MD3 setDirection 镜像
    _setDirectionMirrorCorner(direction);
  }
}
```

### E. lerp 起点终点

`_setupTapAnim` 当前：
```dart
_animTargetTouch = dir == PageDirection.next
    ? Offset(-size.width, size.height)
    : Offset(size.width, size.height);
```

next 终点 (-w, h) 屏外左侧；prev 终点 (w, h) 右下。next 不变。
prev 路径 `_setupTapAnim(Offset(0, size.height), PageDirection.prev)`：
- _animStartTouch = (0, h) ✅
- _animTargetTouch = (w, h) ✅（公式不变）
- _animStartProgress = 0.0 ✅

drag prev 的 `_setupDragAnim` 也用 `currentTouch` 作 _animStartTouch、(w, h) 作 _animTargetTouch——正确。

## Decision (ADR-lite)

**Context**: prev tap 视觉是"从左下卷出一张新纸"，不是用户期望的"右下角的纸盖回来"。根因是 `_calcCornerXY` 直接吃 tap 落点 (0.1w, 0.9h) → cornerX=0 左下，缺 MD3 setDirection 那层镜像。

**Decision**:
1. 引入 `_setDirectionMirrorCorner(PageDirection)` 方法，对应 MD3 `SimulationPageDelegate.setDirection` L188-L206
2. `prevPageByAnim`：tap 落点 → 镜像 corner 到右下 → 重置触摸点到 (0, h) → 跑动画
3. `onDragUpdate` 在方向首次确定那一刻调用镜像逻辑
4. **next 完全不动**——已是右下角 corner、与 PREV 现在共用支点

**Consequences**:
- prev 视觉正确（活页书翻过去盖回来）
- next/prev 几何对称（同 cornerXY，touchPoint 反向 lerp）
- 跨章 prev 路径自然继承（commitToPrevChapter 后 currentPage 是上章末页，再 prevPageByAnim 走相同几何）
- drag prev 要等方向确定后才镜像 corner——slop 越过那一刻可能有一帧 corner 跳变，但对仿真贝塞尔几乎不可见（progress 很小、几何变化小）

## Out of Scope

- T4（drag 回滚阈值）— 独立任务
- 仿真翻页 NEXT 优化（已经对齐 MD3）
- cover/slide/fade 三种翻页的 prev 行为（它们没有"折角"概念，几何无差异）

## Technical Notes

### 关键文件

- `flutter_app/lib/features/reader/page/delegate/simulation_page_delegate.dart` — 加 `_setDirectionMirrorCorner` + 重写 `prevPageByAnim` + `onDragUpdate` 钩子
- 现有 `debugCornerX / debugCornerY / debugIsRtOrLb` 已暴露 visibleForTesting
- 现有 `_setupTapAnim` / `_setupDragAnim` lerp 状态机不动

### 测试文件

`test/simulation_*.dart` 中找一个最贴合的，加 prev 几何测试。

### 风险点

1. drag PREV 方向首次确定那一刻镜像 corner 可能短暂闪烁——实测验证；如有可在 onDragStart 时**预测性**走 PREV 镜像（用户大概率向右滑 = prev）
2. 跨章 prev：邻章 commit 后 currentPage 已切换，prev 动画此时再起新一轮，几何要重新算——但 commit 后 isRunning=false，下一次 prevPageByAnim 会重新跑完整流程（含 setDirection 镜像），无残留
3. 现有单测 `delegate_cross_chapter_test.dart` 跨章 prev 路径要核验 cornerXY 期望值

## Research References

- [`research/md3-prev-geometry.md`](research/md3-prev-geometry.md) — MD3 SimulationPageDelegate setDirection / prevPageByAnim / onAnimStart 逐字代码 + 几何推导
