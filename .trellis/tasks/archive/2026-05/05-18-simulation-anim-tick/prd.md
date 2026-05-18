# Task X1 — 仿真翻页 currentTouch 真正动起来

**用户实测报告 5 个 bug，本批修 3 个同源 bug**：
- Bug E: tap 仿真翻页只看到右下角折一点，看不到完整动画
- Bug D: 手动滑要几乎从左到右滑完整屏才会翻页，仿真动画几乎看不到
- Bug B: 翻页动画依然有概率显示前一页，动画结束后才换后一页（仿真模式表现）

## Goal

让 SimulationPageDelegate 的 `_currentTouch` 在 tap 翻页期间根据 progress
从虚拟起点 lerp 到目标位置，让 `_calcPoints` 的几何随时间动起来；drag 期间
让 `_PageViewPainter.shouldRepaint` 监测 `currentTouch` 变化，确保每次
PointerMove 即使 progress 推进慢也能触发重绘。

## Background — 三个 bug 同源

### 仿真 draw 与其它 delegate 的本质差异

`simulation_page_delegate.dart:282 _calcPoints` 用 `currentTouch.dx/dy`
（line 110-111）算所有贝塞尔顶点。draw 几何**完全由 currentTouch 驱动**，
**与 progress 无关**。

但 `_PageViewPainter.shouldRepaint` (page_view.dart:394) 只看：
- `isRunning`
- `animProgress` 变化
- `direction` 变化
- `currentPage` / `nextPage` / `prevPage` identity 变化
- 排版字段变化

**漏了 `currentTouch`**！

### Bug E (tap 仿真) 详细路径

1. tap 触发 `nextPageByAnim` → `recordTouchStart(0.9w, 0.9h)` 设
   `_currentTouch = (0.9w, 0.9h)`
2. `_calcCornerXY(0.9w, 0.9h)` → cornerX=w, cornerY=h
3. `super.nextPageByAnim` → `_clearPictures + render + goToNext`
4. `goToNext` → `_runAnimation` → `animController.forward(from: 0)`
5. 动画 progress 0 → 1，每帧 painter 重画
6. `_calcPoints` 用 `currentTouch (0.9w, 0.9h)` 算几何 — **每帧都一样**
7. 用户视觉：右下角一个固定的小折角，动画期间无变化
8. progress=1.0 done → `onComplete = goToNextPage` → 切 currentPageIndex
   → `_resetState` → `_clearPictures` → painter 重画 `drawStaticCurrent`
   → 显示新页

用户感觉：动画期间显示前页（其实是几何不变），结束后突然变后页。

### Bug D (drag 仿真) 详细路径

1. PointerDown → 记 _pointerDownPos
2. PointerMove 累计位移越 slop → `recordTouchStart(slop 越过点)` →
   `onDragStart` 渲 picture
3. 后续 PointerMove → `recordTouchUpdate(localPos)` 更新 `_currentTouch`
   → `onDragUpdate(delta.dx)` 累加 `_dragOffset`，progress = dragOffset.abs() / width
4. 用户慢速拖动 100px：`_currentTouch` 已经移动 100px，progress=100/400=0.25
5. `_PageViewPainter.shouldRepaint` 检查 `animProgress != animProgress`：
   旧值 0.0，新值 0.25，触发重绘
6. `_calcPoints` 用新 `currentTouch` 算几何 — 此时**应该**看到中等折角
7. **但是**：`_currentTouch` 由 `recordTouchUpdate` 直接赋值，没人调用
   listener。`_PageViewPainter` 的重绘只靠 progress 推进触发；progress
   推进取决于 `animController.value = progress`，会让 AnimatedBuilder
   重 build → painter shouldRepaint → 重绘
8. 但 progress 慢半拍 + 比例 dragOffset/width 太大 → 重绘节奏跟不上
   currentTouch 真实推进
9. 用户感觉：必须拖一屏宽才看得到完整折角

### Bug B (race) 

跟 E 同源 — 仿真 tap 翻页期间 `currentTouch` frozen，看不到几何变化，
"动画期间显示前页"是错觉（其实是几何不动加 progress 推进让 _path0 / _path1
不变）。修 E 即可解决 B。

## Requirements

- **X1.1** PageDelegate 加 `void onAnimTick(double progress)` 默认空实现
- **X1.2** `_runAnimation` 加 listener：每帧调 `onAnimTick(animController.value)`，
  `forward.then` 内 removeListener
- **X1.3** SimulationPageDelegate 加字段 `_animStartTouch` / `_animTargetTouch`
  (Offset?)
- **X1.4** `nextPageByAnim` override：除了现有合成虚拟 startTouch，再设
  `_animStartTouch = virtualStart`、`_animTargetTouch = Offset(-w, h)` 
  （屏幕左外侧底边，对应 next 翻完位置）
- **X1.5** `prevPageByAnim` override：`_animStartTouch = virtualStart (0.1w, 0.9h)`、
  `_animTargetTouch = Offset(w, h)`
- **X1.6** SimulationPageDelegate override `goToNext` / `goToPrev`：
  drag-end 路径在调 super 前记录
  `_animStartTouch = currentTouch`（用户松手位置）、
  `_animTargetTouch = Offset(-w, h)` (next) / `Offset(w, h)` (prev)
- **X1.7** SimulationPageDelegate override `onAnimTick(progress)`：
  - `_animStartTouch` / `_animTargetTouch` 任一为 null → 早 return
  - drag-end 路径上 progress 起点不是 0（forward(from: x)）— 需要把 progress
    重新归一化：`t = (progress - startProgress) / (1 - startProgress)`
    然而我们已经在 `_animStartTouch` 里存"起跑时的当前 touch"，而不是
    "起跑时的 progress=0 对应的 touch"，所以 `t` 直接用 progress 即可，
    起点不在虚拟起点而在 user 松手位置；progress 0 时 currentTouch=松手位置
    （已被 recordTouchUpdate 设过），后续 progress 推进 lerp 到 target
  - 但 forward(from: x) 时 progress 起跑值是 x 不是 0；`t` 应当是
    `(progress - x) / (1 - x)` 重新归一化到 [0, 1]。需要在 onDragEnd 路径
    记录起跑 progress
  - 简化方案：把 lerp 起点和归一化都做在 `_animStartTouch` 上：
    drag-end 时 `_animStartTouch = currentTouch`、`_animStartProgress = animController.value`
    onAnimTick 内 `t = ((progress - _animStartProgress) / (1 - _animStartProgress)).clamp(0, 1)`
    `currentTouch = lerp(_animStartTouch, _animTargetTouch, easeOut(t))`
- **X1.8** Curves: easeOut（贴近 MD3 Scroller 减速曲线视觉感）
- **X1.9** _resetState / cancelDrag 清空 `_animStartTouch / _animTargetTouch / _animStartProgress`
- **X1.10** `_PageViewPainter` 字段加 `Offset currentTouch`，shouldRepaint 加
  `oldDelegate.currentTouch != currentTouch` 比较
- **X1.11** `_PageViewPainter` 构造时传 `delegate.currentTouch`
- **X1.12** `recordTouchUpdate` 后让 painter 能感知到 — 用以下机制之一：
  - **方案 A** (推荐)：page_view.dart `_onPointerMove` 调 `recordTouchUpdate`
    后调 `if (mounted) setState(() {})`。简单直接，AnimatedBuilder 重
    build → painter 拿到新 currentTouch
  - **方案 B**：让 `recordTouchUpdate` 调 `animController.notifyListeners()`
    没 public API。复杂
- **X1.13** 既有 199 个测试无 regression
- **X1.14** 新增 ≥ 5 用例覆盖 onAnimTick / currentTouch lerp / shouldRepaint

## Acceptance Criteria

- [ ] page_delegate.dart 加 onAnimTick + _runAnimation listener
- [ ] simulation_page_delegate.dart 加 _animStartTouch/_animTargetTouch/
      _animStartProgress + nextPageByAnim/prevPageByAnim/goToNext/goToPrev
      override + onAnimTick lerp
- [ ] page_view.dart _PageViewPainter 加 currentTouch 比较
- [ ] page_view.dart _onPointerMove 调 setState 触发重绘
- [ ] flutter --no-version-check analyze 0 issue
- [ ] xvfb-run -a flutter --no-version-check test 全绿（199 baseline + ≥ 5 new）

## Definition of Done

- 单一 commit "第二十九批 — 仿真翻页 currentTouch 实时驱动"
- libbridge.so / Rust / FRB 零改动
- 不动其它 delegate（cover/slide/fade/noAnim）draw 几何
- onAnimTick 父类默认空实现，子类只 simulation override

## Technical Approach

### 1. PageDelegate `onAnimTick` 钩子

```dart
abstract class PageDelegate {
  // ... existing
  
  /// 子类钩子：每帧 progress 变化时调用，让 simulation 等需要
  /// 根据 progress 自驱动几何的 delegate 更新内部状态
  /// （如 currentTouch lerp）。默认空实现。
  void onAnimTick(double progress) {}
  
  void _runAnimation(VoidCallback onComplete) {
    if (isRunning) return;
    isRunning = true;
    void tick() => onAnimTick(animController.value);
    animController.addListener(tick);
    animController.forward(from: animController.value).then((_) {
      animController.removeListener(tick);
      onComplete();
      _resetState();
    });
  }
}
```

### 2. SimulationPageDelegate override

```dart
class SimulationPageDelegate extends HorizontalPageDelegate {
  // X1.3 lerp 字段
  Offset? _animStartTouch;
  Offset? _animTargetTouch;
  double _animStartProgress = 0.0;
  
  void _setupTapAnim(Offset virtualStart, PageDirection dir) {
    final size = pageSize.isEmpty ? const Size(400, 600) : pageSize;
    _animStartTouch = virtualStart;
    _animStartProgress = 0.0;  // tap 路径 progress 一定从 0 开始
    _animTargetTouch = dir == PageDirection.next
        ? Offset(-size.width, size.height)
        : Offset(size.width, size.height);
  }
  
  void _setupDragAnim(PageDirection dir) {
    final size = pageSize.isEmpty ? const Size(400, 600) : pageSize;
    _animStartTouch = currentTouch;
    _animStartProgress = animController.value;
    _animTargetTouch = dir == PageDirection.next
        ? Offset(-size.width, size.height)
        : Offset(size.width, size.height);
  }
  
  @override
  void nextPageByAnim(int animationSpeed) {
    if (isRunning) return;
    final size = pageSize.isEmpty ? const Size(400, 600) : pageSize;
    final virtualStart = Offset(size.width * 0.9, size.height * 0.9);
    recordTouchStart(virtualStart, size);
    _maxLength = math.sqrt(size.width * size.width + size.height * size.height);
    _calcCornerXY(virtualStart.dx, virtualStart.dy);
    _setupTapAnim(virtualStart, PageDirection.next);  // ← X1.4
    super.nextPageByAnim(animationSpeed);
  }

  @override
  void prevPageByAnim(int animationSpeed) {
    if (isRunning) return;
    final size = pageSize.isEmpty ? const Size(400, 600) : pageSize;
    final virtualStart = Offset(size.width * 0.1, size.height * 0.9);
    recordTouchStart(virtualStart, size);
    _maxLength = math.sqrt(size.width * size.width + size.height * size.height);
    _calcCornerXY(virtualStart.dx, virtualStart.dy);
    _setupTapAnim(virtualStart, PageDirection.prev);  // ← X1.5
    super.prevPageByAnim(animationSpeed);
  }
  
  @override
  void goToNext() {
    // X1.6: drag-end 路径
    // 同章 / 跨章 / fallback 由 super 处理；这里只在 super 走 _runAnimation
    // 之前注入 lerp 状态。但 super.goToNext 内可能 _resetState（fallback 分支）
    // 此时 _animStartTouch 没意义但也不影响。
    // 区分 tap vs drag 路径：tap 已在 nextPageByAnim 里 setupTapAnim 过；
    // drag 路径调到 goToNext 时 _animStartTouch 可能还是 null。
    if (_animStartTouch == null) {
      _setupDragAnim(PageDirection.next);
    }
    super.goToNext();
  }
  
  @override
  void goToPrev() {
    if (_animStartTouch == null) {
      _setupDragAnim(PageDirection.prev);
    }
    super.goToPrev();
  }
  
  @override
  void onAnimTick(double progress) {
    final start = _animStartTouch;
    final target = _animTargetTouch;
    if (start == null || target == null) return;
    // X1.7: 重新归一化 progress 到 [0, 1]
    final raw = ((progress - _animStartProgress) /
            (1.0 - _animStartProgress))
        .clamp(0.0, 1.0);
    final t = Curves.easeOut.transform(raw);
    final lerped = Offset.lerp(start, target, t)!;
    recordTouchUpdate(lerped);  // 写 _currentTouch
  }
}
```

并且要在 base `_resetState` 里清 `_animStartTouch` 等三字段。这个其实在
SimulationPageDelegate 自己加一个 `_clearAnimState()` 然后 override
父类 `_resetState` 不太好（_resetState 是 private fn）。改方案：
- `_resetState` 改为 `@protected` 或者加 hook `void onResetState()` 让子类 override
- 或者直接：simulation override `_runAnimation` 自己清状态

最简：在 `_runAnimation.then` 完成后已经调过 onAnimTick(1.0) lerp 到终点，
然后 `_resetState`（base）清 controller / direction / pictures。lerp 字段
保留无害（下一次 nextPageByAnim 会重新设）。

但 `cancelDrag` 路径要清，避免 cancel 后下一次 drag 错乱。在 simulation
子类 override cancelDrag：

```dart
@override
void cancelDrag() {
  _animStartTouch = null;
  _animTargetTouch = null;
  _animStartProgress = 0.0;
  super.cancelDrag();
}
```

`_resetState` 完成时也加同样清理。但 `_resetState` 是 private…

解决：在 `_runAnimation.then` 内调 `onAnimComplete()` 钩子（默认空实现），
simulation override 它清 lerp 字段。但更简单的做法：让 lerp 字段在每次
新 anim 启动时由 `_setupTapAnim/_setupDragAnim` 重置（已经 OK），所以不用
专门清。**只在 cancelDrag 路径清**（避免 cancel 后 _animTargetTouch 残留
让下次 drag 异常）。

### 3. _PageViewPainter currentTouch

```dart
// page_view.dart _PageViewPainter
class _PageViewPainter extends CustomPainter {
  // ... existing
  final Offset currentTouch;  // ← X1.10
  
  _PageViewPainter({
    // ...
    required this.currentTouch,
  });
  
  @override
  bool shouldRepaint(covariant _PageViewPainter oldDelegate) {
    final oldS = oldDelegate.settings;
    final newS = settings;
    return isRunning ||
        oldDelegate.animProgress != animProgress ||
        oldDelegate.currentTouch != currentTouch ||  // ← X1.10
        oldDelegate.direction != direction ||
        // ... existing
  }
}

// 构造时
return CustomPaint(
  size: size,
  painter: _PageViewPainter(
    delegate: _delegate,
    currentTouch: _delegate.currentTouch,  // ← X1.11
    // ... existing
  ),
);
```

### 4. _onPointerMove 触发重绘

```dart
void _onPointerMove(PointerMoveEvent e) {
  // ... existing slop machine
  _delegate.recordTouchUpdate(e.localPosition);
  _delegate.onDragUpdate(e.delta.dx);
  // X1.12: 让 painter 感知 currentTouch 变化
  if (mounted) setState(() {});
}
```

setState 会 trigger LayoutBuilder → CustomPaint 重 build → painter 拿到
新 currentTouch → shouldRepaint → 重绘。

### 测试计划

新增 `flutter_app/test/simulation_anim_tick_test.dart`：

1. **SimulationPageDelegate.nextPageByAnim 启动后 onAnimTick 推进 currentTouch**
   - setup delegate + tap nextPageByAnim → pump 100ms → assert
     currentTouch.dx < 0.9 * pageWidth（已经从 0.9w 滑过中线）
   - pumpAndSettle → assert currentTouch.dx 接近 -pageWidth

2. **prevPageByAnim 同理**
   - currentTouch.dx > 0.1 * pageWidth → 接近 pageWidth

3. **drag-end 路径**
   - 模拟 drag 一段距离松手 → currentTouch 起点是松手位置 → 推进到 -w/h

4. **PageDelegate.onAnimTick 默认空实现**
   - NoAnimPageDelegate / CoverPageDelegate 不 override，instance 实例调
     onAnimTick(0.5) 不抛异常（默认空）

5. **_PageViewPainter.shouldRepaint(currentTouch 变化)**
   - 构造两个 painter 实例，currentTouch 不同其它字段相同 → shouldRepaint=true

### Risk & Mitigation

- **Curves.easeOut 选择**：MD3 Scroller 用 LinearInterpolator。但 Flutter
  端 lerp 用 Curves.easeOut 视觉更顺；如果用户感觉不自然可下次改 linear。
  **决策**：先用 easeOut，PRD 决策可调
- **drag-fling 起点 progress 归一化**：用 `_animStartProgress` 字段记起跑
  progress 重新归一化 [0,1]，避免 jump
- **多次 cancel 残留**：cancelDrag 内显式清 lerp 字段
- **既有 simulation 测试**：reader_simulation_finger_track_test 用
  debug-* getter 验证 cornerXY，与 currentTouch 无关；reader_simulation_tap_bezier_test
  也是测 cornerXY；都不应受 lerp 改动影响。但 tap_bezier_test #3 验证
  `currentChapterIndex 前进 1`，这个是动画结束 onComplete 调
  goToNextPage 的结果，与 currentTouch 无关，应仍通过

### Out of Scope

- Bug C (prev 跨章预拉) — Task X2
- Bug A (精确搜索可见性) — Task X3
- 仿真 prev 几何不对称（draw 内 prev/cur 互换的语义）
- cover/slide/fade/noAnim delegate 不动
- AnimationController duration 已在 Task 4 可配，不再动
- Rust / FRB / libbridge.so

## Decision (ADR-lite)

**Context**: 仿真 draw 几何由 currentTouch 驱动，但 painter shouldRepaint
依赖 progress；tap 路径 currentTouch 在 nextPageByAnim 后 frozen，drag 路径
currentTouch 跟手但 painter 重绘节奏跟不上。

**Decision**: 加 `onAnimTick(progress)` 抽象钩子让 simulation 子类自驱动
currentTouch lerp；painter shouldRepaint 加 currentTouch 比较；
_onPointerMove 调 setState 让 drag 期间每帧重绘。

**Consequences**:
- 优点：仿真 tap/drag 都能看到完整动画；架构清晰可扩展
- 缺点：onAnimTick 是 PageDelegate 新增 hook，所有子类隐式继承默认空实现
- Curves.easeOut 是 Flutter 友好的减速曲线，与 MD3 LinearInterpolator 不
  完全一致但视觉 OK

## Technical Notes

### 关键 file:line

- `flutter_app/lib/features/reader/page/delegate/page_delegate.dart:226-233` — _runAnimation
- `flutter_app/lib/features/reader/page/delegate/simulation_page_delegate.dart:220-247` — nextPageByAnim/prevPageByAnim
- `flutter_app/lib/features/reader/page/delegate/simulation_page_delegate.dart:282-296` — draw 用 _calcPoints
- `flutter_app/lib/features/reader/page/page_view.dart:229-298` — pointer handlers
- `flutter_app/lib/features/reader/page/page_view.dart:342-413` — _PageViewPainter

### 命令前缀

- `flutter --no-version-check analyze`
- `xvfb-run -a flutter --no-version-check test`
- 工作目录 flutter_app/
