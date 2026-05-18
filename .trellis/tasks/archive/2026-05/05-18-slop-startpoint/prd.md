# Task 3 — 仿真翻页起点跟手 (slop 越过重置 startPoint)

## Goal

让 `PageViewWidget` 在水平拖动手势越过 `kTouchSlop` 那一刻才记录 startPoint，
而不是在用户 pointer down 时就记录。这样 SimulationPageDelegate 的
`_calcCornerXY` 拿到的是"用户开始有效拖动的位置"，仿真折角自然跟随手指起始
位置而不是固定在 down 那一帧的偶然坐标——视觉上手指刚动一下页角就同步翘起，
没有"先跳一下"违和感。

属于 MD3 体感复刻 7 任务序列的第 2 个（Phase A 高 ROI 项）。

## What I already know

### Flutter 现状

```dart
// page_view.dart:163-186 (Task 6 已加 isRunning guard)
void _onHorizontalDragStart(DragStartDetails details) {
  if (_delegate.isRunning) return;
  if (_pageSize.isEmpty) return;
  final ctrl = widget.controller;
  _delegate.recordTouchStart(details.localPosition, _pageSize);  // ← details.localPosition 是 down 时坐标
  _delegate.onDragStart(_pageSize, ctrl.currentPage, ctrl.nextPage, ctrl.prevPage);
}

// page_view.dart:196-201 (build)
return GestureDetector(
  onHorizontalDragStart: _onHorizontalDragStart,
  onHorizontalDragUpdate: _onHorizontalDragUpdate,
  onHorizontalDragEnd: _onHorizontalDragEnd,
  ...
);
```

GestureDetector.onHorizontalDragStart 的触发时机**就是 slop 越过那一刻**
（HorizontalDragGestureRecognizer 内部用 kTouchSlop≈18 判断 + winning gesture
arena），但 `DragStartDetails.localPosition` 给的是 `_initialPosition`
（pointer down 时位置），**不是 slop 越过时位置**。这就是 Legado 原版那段
`readView.setStartPoint(event.x, event.y, false)` 在 isMoved 第一次变 true
时重置起点的等价问题。

### Legado MD3 做法（参考实现）

```kotlin
// HorizontalPageDelegate.kt:80-103
if (!isMoved) {
    val deltaX = (focusX - startX).toInt()
    val deltaY = (focusY - startY).toInt()
    val distance = deltaX * deltaX + deltaY * deltaY
    isMoved = distance > slopSquare
    if (isMoved) {
        if (sumX - startX > 0) { ... setDirection(PageDirection.PREV) }
        else { ... setDirection(PageDirection.NEXT) }
        readView.setStartPoint(event.x, event.y, false)  // ← 关键
    }
}
```

`SimulationPageDelegate.onTouch:165-170` 只在 ACTION_DOWN 调 `calcCornerXY(event.x, event.y)`，
但 `setDirection`（在 isMoved=true 时被调用）会再次重新算
`calcCornerXY(startX, viewHeight.toFloat())` 等——拿的是已经被 setStartPoint
覆盖过的新 startX/Y。

### Flutter 当前代码路径

`SimulationPageDelegate.onDragStart` (`simulation_page_delegate.dart:91-103`)
直接拿 `startTouch`（即 PageDelegate._startTouch）调 `_calcCornerXY(start.dx, start.dy)`。
只要 startTouch 是"slop 越过点"而不是"pointer down 点"，整套贝塞尔几何就会
正确。

## Requirements

- **R3.1**：水平拖动从 pointer down 开始追踪坐标，但**不**立刻调 `_delegate.onDragStart`/`recordTouchStart`
- **R3.2**：当累计位移 (dx² + dy²) 超过 `kTouchSlop²` 那一刻，用**当前 pointer 位置**作为 startTouch 灌进 delegate；同帧调 `_delegate.onDragStart`
- **R3.3**：之后每次 pointer move 调 `_delegate.recordTouchUpdate(currentPos)` + `_delegate.onDragUpdate(deltaX)`
- **R3.4**：pointer up 时如果 slop 已越过，正常调 `fling + onDragEnd`；如果 slop 未越过，等同于 tap，**不动**翻页（外层 ReaderPage 的 GestureDetector.onTapUp 仍会触发点击翻页）
- **R3.5**：pointer cancel 等同 up 但不调 fling/onDragEnd，直接复位本地状态
- **R3.6**：保留 Task 6 的 `isRunning` guard 行为（动画进行中所有 pointer events 直接吞掉）
- **R3.7**：所有水平 delegate（cover/slide/simulation/fade/noAnim）共享这套手势层逻辑——无需在 delegate 内重复改
- **R3.8**：不打破现有 ReaderPage 外层 onTapUp 翻页（点击屏幕左/右 1/3 区域翻页）
- **R3.9**：velocity 估算用 Flutter 内置 VelocityTracker，传给 `_delegate.fling`

## Acceptance Criteria

- [ ] `page_view.dart` 把 GestureDetector(onHorizontalDrag*) 替换为 Listener(onPointerDown/Move/Up/Cancel)
- [ ] slop 越过点作为 startTouch 灌进 delegate
- [ ] 单测：`SimulationPageDelegate._calcCornerXY` 在不同 startPoint 输入下产生预期 cornerX/Y/_isRtOrLb
- [ ] widget 测试：模拟 pointer down 在屏幕中央 → move 到左侧（越过 slop） → assert delegate.startTouch 是越过点而不是中央点；同样 move 到右侧验证翻页方向
- [ ] tap 路径不退化（点击屏幕左 1/3 / 右 1/3 / 中间仍按现有行为，外层 GestureDetector 接管）
- [ ] `flutter --no-version-check analyze` 0 issue
- [ ] `xvfb-run flutter --no-version-check test` 全绿（含新增）+ 既有 116 个测试无 regression
- [ ] reader_page_reentrance_test.dart 仍通过（Task 6 引入的 guard 不被破坏）

## Definition of Done

- 测试新增 + 既有测试不退化
- analyze 全绿
- 单一 commit message，遵循"第二十二批"格式
- libbridge.so / Rust 端零改动
- 不动 PageDelegate 子类（只改 page_view.dart 手势层）

## Technical Approach

### 总体设计

把 PageViewWidget 内的 `GestureDetector` 改成 `Listener` + 手动 slop 状态机。
GestureDetector 之前依赖 `kTouchSlop`（≈ 18 dp）做"是不是真的开始拖"的判断；
Listener 没有这层抽象，必须自己写。

```dart
class _PageViewWidgetState extends State<PageViewWidget> {
  // ... existing fields ...

  // Slop 状态机
  bool _slopExceeded = false;
  Offset? _pointerDownPos;
  int? _activePointerId;
  late VelocityTracker _velocityTracker;

  void _onPointerDown(PointerDownEvent e) {
    if (_delegate.isRunning) return;
    if (_activePointerId != null) return;  // 多指：只跟踪 primary
    _activePointerId = e.pointer;
    _slopExceeded = false;
    _pointerDownPos = e.localPosition;
    _velocityTracker = VelocityTracker.withKind(e.kind);
    _velocityTracker.addPosition(e.timeStamp, e.localPosition);
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_delegate.isRunning) return;
    if (e.pointer != _activePointerId) return;
    if (_pageSize.isEmpty) return;
    _velocityTracker.addPosition(e.timeStamp, e.localPosition);

    if (!_slopExceeded) {
      final delta = e.localPosition - _pointerDownPos!;
      final slop = kTouchSlop;
      if (delta.distanceSquared > slop * slop) {
        _slopExceeded = true;
        // R3.2: 用 slop 越过那一刻的位置作为 startTouch
        _delegate.recordTouchStart(e.localPosition, _pageSize);
        final ctrl = widget.controller;
        _delegate.onDragStart(_pageSize, ctrl.currentPage, ctrl.nextPage, ctrl.prevPage);
      } else {
        return;
      }
    }

    _delegate.recordTouchUpdate(e.localPosition);
    _delegate.onDragUpdate(e.delta.dx);
  }

  void _onPointerUp(PointerUpEvent e) {
    if (e.pointer != _activePointerId) return;
    _activePointerId = null;
    if (!_slopExceeded) {
      _slopExceeded = false;
      return;  // tap 路径，由外层 GestureDetector 处理
    }
    if (_delegate.isRunning) {
      _slopExceeded = false;
      return;
    }
    final velocity = _velocityTracker.getVelocity().pixelsPerSecond.dx;
    final dir = _detectDirection(velocity);
    _delegate.fling(velocity);
    _delegate.onDragEnd(dir);
    _slopExceeded = false;
  }

  void _onPointerCancel(PointerCancelEvent e) {
    if (e.pointer != _activePointerId) return;
    _activePointerId = null;
    _slopExceeded = false;
    // R3.5: cancel 时不调 fling/onDragEnd，避免误翻页
  }
}
```

build 改为：

```dart
return Listener(
  onPointerDown: _onPointerDown,
  onPointerMove: _onPointerMove,
  onPointerUp: _onPointerUp,
  onPointerCancel: _onPointerCancel,
  behavior: HitTestBehavior.opaque,
  child: AnimatedBuilder(...),
);
```

### 关键 file:line

- `flutter_app/lib/features/reader/page/page_view.dart:163-201` — 三个 drag callback + GestureDetector build
- `flutter_app/lib/features/reader/page/delegate/page_delegate.dart:50-60` — recordTouchStart/Update 接口（不动）
- `flutter_app/lib/features/reader/page/delegate/simulation_page_delegate.dart:91-112` — onDragStart 调 _calcCornerXY（不动，自然受益）

### 测试计划

新增 `flutter_app/test/reader_simulation_finger_track_test.dart`:

1. **单测 `_calcCornerXY` (从 SimulationPageDelegate 访问内部状态)**
   - 给 startPoint=(50, 100), pageSize=(400, 600) → 期望 cornerX=0, cornerY=0, isRtOrLb=false
   - 给 startPoint=(350, 100), pageSize=(400, 600) → 期望 cornerX=400, cornerY=0, isRtOrLb=true (右上)
   - 给 startPoint=(50, 500), pageSize=(400, 600) → 期望 cornerX=0, cornerY=600, isRtOrLb=true (左下)
   - 给 startPoint=(350, 500), pageSize=(400, 600) → 期望 cornerX=400, cornerY=600, isRtOrLb=false (右下)

2. **widget 集成 (slop 越过)**
   - 构造 PageViewWidget + 真实 controller + simulation 模式
   - `tester.startGesture` at (200, 300) → moveBy(50, 0) (50px > kTouchSlop 18)
   - assert `delegate.startTouch.dx > 200`（slop 越过那一刻已经走过 18+px）
   - assert `delegate.startTouch != Offset(200, 300)`

3. **widget 集成 (tap 路径不退化)**
   - 构造 PageViewWidget
   - `tester.tap` at (200, 300) → 没有 drag
   - assert `delegate.isRunning == false`（不应触发翻页动画；tap 由外层处理）

### Risk & Mitigation

- **VelocityTracker API**：Flutter 默认 import 在 `package:flutter/gestures.dart`；如需 `kind` 区分 trackpad/touch，用 `VelocityTracker.withKind(e.kind)`；旧版 fallback 用 `VelocityTracker()`。Pin 到 `withKind` (Flutter 2.5+ 都有)
- **多指**：原版处理 multi-touch focal point，本次只跟踪 primary pointer。如果用户两指同时按，第二指的 events 直接忽略——Legado 原版同样行为
- **Tap 兼容性**：已审计 — 外层 ReaderPage 在 `reader_page.dart:1479-1508` 用 `GestureDetector(behavior: HitTestBehavior.opaque, onTapUp: ...)` 处理点击翻页（左/右 1/3 区域），**外层只有 onTapUp 没有 onHorizontalDrag\***。Flutter Listener 不参与 gesture arena 竞争，只被动订阅 raw events。Listener 不消费 tap，外层 onTapUp 仍能触发。Listener 的 `HitTestBehavior` 设 `opaque` 还是 `translucent` 都可以，原 GestureDetector 没传 behavior 用默认值 `deferToChild`，等价语义 — 直接用 `HitTestBehavior.translucent` 最安全
- **`shouldRepaint` 触发**：现有 AnimatedBuilder 仍 listen `widget.controller + _animController`，Listener 不影响 repaint 链路

### Out of Scope

- 不改 SimulationPageDelegate / 其它 delegate（startPoint 变了，几何自动跟）
- 不改 AnimationController duration / curve
- 不改 abortAnim
- 不动 ReaderPage 外层 GestureDetector 的 onTapUp 路径
- 不引入新的偏好项 (如"是否启用 slop 跟手"无开关)
- 不改 Rust / FRB 桥接

## Decision (ADR-lite)

**Context**: GestureDetector.onHorizontalDragStart 的 details.localPosition 给 down 时坐标，不是 slop 越过坐标，导致仿真翻页起点固定，跟手感差。三个候选方案：A=Listener 重写、B=Listener+GestureDetector 共存、C=推迟 onDragStart 到 onDragUpdate 第一次。

**Decision**: Plan A — 完整把 GestureDetector 换成 Listener，自管 slop 状态机和 VelocityTracker。

**Consequences**:
- 优点：完全控制起点时机；与 Legado MD3 语义 1:1 对齐；后续 Task 5（tap 完整仿真）和 Task 4（duration 可调）依赖手势层时不再被 GestureDetector 黑箱限制
- 缺点：~150 行 Dart（比预估 80 行多），需写 VelocityTracker + multi-pointer 处理；tap 路径要回归测试
- 风险：HitTestBehavior 与外层 ReaderPage GestureDetector 的事件穿透；测试需覆盖

## Technical Notes

### Flutter API 参考

- `Listener` widget — `onPointerDown/Move/Up/Cancel` 接收 `PointerEvent`
- `kTouchSlop` — 默认 18 logical pixels (Flutter 全平台一致)
- `VelocityTracker.withKind(PointerDeviceKind)` — kind 用 e.kind 传
- `PointerMoveEvent.delta` — 相对上一帧位移（无需自己累加）

### 命令前缀

- `flutter --no-version-check analyze`
- `xvfb-run -a flutter --no-version-check test`
- 工作目录 flutter_app/

## Research References

无（GestureDetector 内部行为是 Flutter 官方文档已知；Legado 原版做法在前序研究里已分析）。
