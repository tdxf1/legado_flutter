# Task 5 — tap 仿真翻页走完整贝塞尔

## Goal

取消 SimulationPageDelegate 的 `_coverFallback` 分支，让点击翻页（tap）也走
完整的贝塞尔曲线翻页动画，而不是退化成 cover 风格的横向滑出。tap 时合成
一个固定虚拟起点（右下角 / 左下角附近）作为 startTouch，让 _calcCornerXY
能定出页角，整个 onDragStart → onDragUpdate → animController.forward → draw
路径走 SimulationPageDelegate.draw 的完整贝塞尔几何。

属于 MD3 体感复刻 7 任务序列的第 3 个（Phase A 收尾）。

## What I already know

### Flutter 现状

```dart
// simulation_page_delegate.dart:42 (字段)
bool _coverFallback = false;

// simulation_page_delegate.dart:217-229 (tap 入口)
@override
void nextPageByAnim(int animationSpeed) {
  if (isRunning) return;
  _coverFallback = true;        // ← 标记 tap 来源
  super.nextPageByAnim(animationSpeed);
}

@override
void prevPageByAnim(int animationSpeed) {
  if (isRunning) return;
  _coverFallback = true;
  super.prevPageByAnim(animationSpeed);
}

// simulation_page_delegate.dart:296-305 (draw 分支)
if (_coverFallback && !isRunning) {
  _coverFallback = false;
}
if (_coverFallback) {
  _drawCoverStyle(...)   // ← 退化成 cover 几何
  return;
}
// ... 正常贝塞尔 draw
```

`_drawCoverStyle` (line 233-268) + `_drawCoverFallbackShadow` (line 270-284)
两处实现 cover 风格几何 ~50 行——存在的唯一原因是 tap 路径上 startTouch =
Offset.zero，`_calcCornerXY(0, 0)` 会得到 cornerX=0/cornerY=0/isRtOrLb=false，
然后整套贝塞尔几何因 startTouch == cornerXY 而退化成空 Path 错乱。

### Legado MD3 做法（HorizontalPageDelegate.kt:128-146）

```kotlin
override fun nextPageByAnim(animationSpeed: Int) {
    abortAnim()
    if (!hasNext()) return
    setDirection(PageDirection.NEXT)
    val y = when {
        startY > viewHeight / 2 -> viewHeight.toFloat() * 0.9f
        else -> 1f
    }
    readView.setStartPoint(viewWidth.toFloat() * 0.9f, y, false)
    //                      ↑ 虚拟起点在右下角附近 (0.9w, 0.9h)
    onAnimStart(animationSpeed)
}

override fun prevPageByAnim(animationSpeed: Int) {
    abortAnim()
    if (!hasPrev()) return
    setDirection(PageDirection.PREV)
    readView.setStartPoint(0f, viewHeight.toFloat(), false)
    //                      ↑ 虚拟起点在左下角 (0, h)
    onAnimStart(animationSpeed)
}
```

**关键观察**：原版 tap 也走完整贝塞尔，差别仅在合成的虚拟 startPoint。next
方向起点 `(0.9w, 0.9h or 0.1h)`，prev 方向起点 `(0, h)`。这两组坐标喂给
_calcCornerXY 会得到合理的 cornerX/cornerY 让贝塞尔几何正确。

### 当前 Flutter 父类 nextPageByAnim (page_delegate.dart:217-229)

```dart
void nextPageByAnim(int animationSpeed) {
  if (isRunning) return;
  if (!controller.hasNext) {
    onChapterBoundary?.call(PageDirection.next);
    return;
  }
  final size = pageSize.isEmpty ? const Size(400, 600) : pageSize;
  _clearPictures();
  curPicture = _renderPage(size, controller.currentPage);
  nextPicture = _renderPage(size, controller.nextPage);
  prevPicture = _renderPage(size, controller.prevPage);
  goToNext();   // ← 内部 _runAnimation 启动动画
}
```

父类**不**主动调 recordTouchStart，所以 startTouch 保持上次的值（drag
完成后 _resetState 没清 startTouch / currentTouch — 看 page_delegate.dart:183-189
确认；事实上 _resetState 也没碰这两个字段）。tap 路径在第一次 tap 时
startTouch == Offset.zero。

## Requirements

- **R5.1**：移除 `SimulationPageDelegate._coverFallback` 字段、`_drawCoverStyle`、`_drawCoverFallbackShadow` 三段代码（约 60 行）
- **R5.2**：override `nextPageByAnim(int)` / `prevPageByAnim(int)` 时合成虚拟 startTouch（参考 Legado MD3）：
  - next 方向：startTouch = `(pageSize.width * 0.9, pageSize.height * 0.9)`
  - prev 方向：startTouch = `(0.0, pageSize.height)` 或近似
  - 然后调 super.nextPageByAnim / prevPageByAnim（父类的 picture 预渲染 + goToNext 不变）
- **R5.3**：tap 触发的动画用 SimulationPageDelegate.draw 主路径（贝塞尔），**不**降级
- **R5.4**：保留 PageDelegate.isRunning guard（动画进行中再 tap 直接 return）
- **R5.5**：drag 路径不受影响——drag 走 onDragStart 时 startTouch 已被 recordTouchStart 设过，无需特殊处理
- **R5.6**：合成 startTouch 后调 `_calcCornerXY` 让 cornerX/Y 正确，等同于父类 onDragStart 路径上 simulation 子类 super 调用的逻辑
- **R5.7**：测试覆盖：tap → next 后 cornerX = pageSize.width / cornerY = pageSize.height（右下角）；tap → prev 后 cornerX = 0 / cornerY = pageSize.height（左下角）；动画完成后 controller.currentPage 前进/后退一页
- **R5.8**：`flutter --no-version-check analyze` 0 issue
- **R5.9**：既有 126 个测试无 regression（特别是 reader_page_reentrance_test 和 reader_simulation_finger_track_test 仍全绿）

## Acceptance Criteria

- [ ] `_coverFallback` 字段、`_drawCoverStyle`、`_drawCoverFallbackShadow` 三段代码删除
- [ ] `SimulationPageDelegate.nextPageByAnim` / `prevPageByAnim` 合成虚拟 startTouch + 调父类
- [ ] 新增 widget 测试 `flutter_app/test/reader_simulation_tap_bezier_test.dart`：
  - tap → next: 验证 cornerX/cornerY 合理（右下角）
  - tap → prev: 验证 cornerX/cornerY 合理（左下角）
  - tap → next: pumpAndSettle 后 controller.currentPageIndex 前进 1
  - tap → 动画进行中再 tap 被吞（isRunning guard）
- [ ] analyze 0 issue
- [ ] xvfb-run flutter test 全绿（前 126 + 新增）

## Definition of Done

- 删除 _coverFallback 路径所有代码
- 测试新增 + 既有测试不退化
- analyze 全绿
- 单一 commit message，遵循"第二十三批"格式
- libbridge.so / Rust / FRB 零改动

## Technical Approach

### 总体设计

Plan B：合成虚拟 startTouch + 完整贝塞尔，跟 Legado MD3 1:1 对齐。

```dart
// simulation_page_delegate.dart 重写 nextPageByAnim / prevPageByAnim

@override
void nextPageByAnim(int animationSpeed) {
  if (isRunning) return;
  // R5.2: 合成右下角附近的虚拟起点，让 _calcCornerXY 算出 cornerX=w/cornerY=h
  final size = pageSize.isEmpty ? const Size(400, 600) : pageSize;
  recordTouchStart(
    Offset(size.width * 0.9, size.height * 0.9),
    size,
  );
  super.nextPageByAnim(animationSpeed);
}

@override
void prevPageByAnim(int animationSpeed) {
  if (isRunning) return;
  // R5.2: 合成左下角虚拟起点，cornerX=0/cornerY=h
  final size = pageSize.isEmpty ? const Size(400, 600) : pageSize;
  recordTouchStart(
    Offset(0.0, size.height),
    size,
  );
  super.prevPageByAnim(animationSpeed);
}
```

注意：父类 `nextPageByAnim` 已经做了 `_clearPictures + render cur/next/prev pictures + goToNext`，不需要重复。子类只需要：

1. 在父类调用前先 recordTouchStart 灌虚拟起点
2. super 调父类，等动画启动
3. 父类 `goToNext` → `_runAnimation` → `animController.forward.then(...)` → 动画结束清状态

draw 路径上的 `_calcCornerXY` 由 SimulationPageDelegate 自身的 onDragStart 逻辑驱动——但 tap 路径不调 onDragStart...

**关键洞察**：tap 路径不调 onDragStart，所以 _calcCornerXY 不会被调。为了让 draw
能算出正确的 cornerX/cornerY，需要在 tap 路径上**手动调用** _calcCornerXY。

### 修正方案

```dart
@override
void nextPageByAnim(int animationSpeed) {
  if (isRunning) return;
  final size = pageSize.isEmpty ? const Size(400, 600) : pageSize;
  // R5.2: 合成虚拟起点
  final virtualStart = Offset(size.width * 0.9, size.height * 0.9);
  recordTouchStart(virtualStart, size);
  // R5.6: 让 cornerX/Y 立即正确，draw 不依赖 onDragStart 调用
  _maxLength = math.sqrt(size.width * size.width + size.height * size.height);
  _calcCornerXY(virtualStart.dx, virtualStart.dy);
  super.nextPageByAnim(animationSpeed);
}
```

prev 同理。

### 删除的代码

1. `_coverFallback` 字段 (line 42)
2. nextPageByAnim 内 `_coverFallback = true` (line 220)
3. prevPageByAnim 内 `_coverFallback = true` (line 227)
4. draw 内 cover-fallback 分支 (lines 296-305)
5. `_drawCoverStyle` 方法 (lines 233-268)
6. `_drawCoverFallbackShadow` 方法 (lines 270-284)

总计 ~60 行净删除。

### 关键 file:line

- `flutter_app/lib/features/reader/page/delegate/simulation_page_delegate.dart:42` — _coverFallback 字段
- `flutter_app/lib/features/reader/page/delegate/simulation_page_delegate.dart:217-229` — tap 入口
- `flutter_app/lib/features/reader/page/delegate/simulation_page_delegate.dart:91-112` — onDragStart 计算 _maxLength + _calcCornerXY 的参考
- `flutter_app/lib/features/reader/page/delegate/page_delegate.dart:217-244` — 父类 nextPageByAnim/prevPageByAnim（不动）

### 测试计划

新增 `flutter_app/test/reader_simulation_tap_bezier_test.dart`：

1. **tap next 合成右下角起点**
   - 构造 simulation delegate via debugDelegateSink
   - tap 屏幕右侧 1/3（reader_page 路径太重，直接调 delegate.nextPageByAnim(300)）
   - 等待一帧 pump
   - assert delegate.debugCornerX == pageSize.width
   - assert delegate.debugCornerY == pageSize.height
   - assert delegate.debugIsRtOrLb == false（右下角）

2. **tap prev 合成左下角起点**
   - 同上，调 prevPageByAnim
   - assert debugCornerX == 0
   - assert debugCornerY == pageSize.height
   - assert debugIsRtOrLb == true（左下角）

3. **tap 动画完成后页码前进**
   - tap → pumpAndSettle
   - assert controller.currentPageIndex == 1

4. **tap 重入被吞**
   - tap → 动画中（pump 100ms）→ 再 tap
   - assert delegate.isRunning still true（第二次 tap 被早 return）
   - pumpAndSettle 后 currentPageIndex == 1（不是 2）

### Risk & Mitigation

- **_maxLength / _calcCornerXY 是 private**：可通过测试 hooks（debugCornerX/Y/IsRtOrLb 已在 Task 3 加入）观测
- **drag 路径不受影响**：drag 时 _onPointerMove 在 slop 越过那一刻调 recordTouchStart + _delegate.onDragStart()，simulation 子类的 onDragStart override（line 91-103）调 _calcCornerXY(start.dx, start.dy)。tap 路径合成虚拟起点也不会与 drag 起点冲突（每次 tap/drag 开始都重写 startTouch）
- **Picture 渲染时机**：父类 nextPageByAnim 在 super 调用内做 _clearPictures + 重新 render，覆盖 tap 之前可能残留的 picture——OK
- **fade 0.1 阈值**：审计后**不动**——Flutter 当前用 _dragOffset > 5 / < -5 即触发方向，比 MD3 0.1 progress (~50px) 更灵敏，照搬反而劣化。已在 Task 6 PRD 中记录此决策

## Decision (ADR-lite)

**Context**: simulation tap 路径上当前用 cover-fallback 简化几何，因为 tap 时 startTouch=Offset.zero 让 _calcCornerXY 退化。两个候选：A=保留 cover-fallback 但拉长 duration（视觉不仿真）、B=合成虚拟 startPoint 走完整贝塞尔（与 Legado MD3 1:1）。

**Decision**: Plan B — 合成虚拟 startPoint 走完整贝塞尔。

**Consequences**:
- 净删除 ~60 行 cover-fallback 代码
- tap 路径与 drag 路径视觉一致（用户感觉不到"点击和拖拽是不同动画"）
- 需要在子类 nextPageByAnim/prevPageByAnim 里手动调 _calcCornerXY（不能完全靠 super）
- 风险：合成的虚拟起点选择不当会让贝塞尔几何看起来僵硬。MD3 选 0.9w 是因为留出页角空间显示折角；近似 1.0w/1.0h 会让折角紧贴右下边缘看起来太"卷"

## Out of Scope

- 不改 fade 阈值（Flutter 现状 5px 比 MD3 ~50px 更灵敏，符合现代 Material 体感）
- 不改 AnimationController duration（仍 300ms；可调时长是 Task 4 的范围）
- 不改 cover/slide/fade/noAnim delegate 的 nextPageByAnim/prevPageByAnim
- 不动 ReaderPage 外层 GestureDetector
- 不动 Rust / FRB / libbridge.so
- 不重写 simulation_page_delegate.draw 的主贝塞尔几何

## Technical Notes

### 命令前缀

- `flutter --no-version-check analyze`
- `xvfb-run -a flutter --no-version-check test`
- 工作目录 flutter_app/

## Research References

无（Legado MD3 HorizontalPageDelegate.nextPageByAnim/prevPageByAnim 已在 PRD 引用）。
