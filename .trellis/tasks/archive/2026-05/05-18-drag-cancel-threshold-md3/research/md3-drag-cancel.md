# 调研：MD3 drag 拖拽回滚阈值 / "isCancel last-frame 微动方向"语义

来源仓库：`/root/data/workspaces/doro_FriendMessage_641981595/legado-with-MD3`（Kotlin）。

## 1. 总体策略：last-frame 微动方向（horizontal/cover/simulation 共用）

不存在"过 30%/50% 屏宽阈值"或 fling velocity 阈值——`isCancel` 是**每个 MOVE 事件**重新计算的：当前帧的 sumX 与上一帧 lastX 的差值方向。

### `HorizontalPageDelegate.onScroll` (L62-L110 关键段)

```kotlin
override fun onScroll(event: MotionEvent) {
    val sumX = ...
    if (!isMoved) {
        ... distance > slopSquare → isMoved = true
    }
    if (isMoved) {
        // ⚠️ 关键：每帧比较 sumX vs lastX
        isCancel = if (mDirection == PageDirection.NEXT) sumX > lastX else sumX < lastX
        isRunning = true
        readView.setTouchPoint(sumX, sumY)
    }
}
```

**语义**：
- `direction == NEXT`（手指向左拉）：`sumX > lastX` 表示这一帧手指向**右**回拉 → 朝翻页**反方向** → 标 `isCancel = true`
- `direction == PREV`（手指向右拉）：`sumX < lastX` 表示这一帧手指向**左**回拉 → 朝翻页**反方向** → 标 `isCancel = true`

每个 MOVE 都覆盖 isCancel；最后一次 MOVE 是松手前那一帧。

### `HorizontalPageDelegate.onTouch` ACTION_UP

```kotlin
MotionEvent.ACTION_CANCEL, MotionEvent.ACTION_UP -> {
    onAnimStart(readView.defaultAnimationSpeed)  // 用最后一次 onScroll 算出的 isCancel
}
```

松手即 onAnimStart，不重新算 velocity / 不算位置阈值；直接用最后一帧的 isCancel 值。

## 2. isCancel 影响 onAnimStart 的 dx/dy 终值

### `SimulationPageDelegate.onAnimStart` (L208-L239)

```kotlin
override fun onAnimStart(animationSpeed: Int) {
    var dx: Float
    val dy: Float
    if (isCancel) {
        // 回滚分支：把触摸点拉回起点（startX/startY 附近）
        dx = if (mCornerX > 0 && mDirection == PageDirection.NEXT) {
            (viewWidth - touchX)         // NEXT 回滚：dx 朝右拉，回到原位
        } else {
            -touchX                       // PREV 回滚（mCornerX==0 路径）：dx 朝左拉
        }
        if (mDirection != PageDirection.NEXT) {
            dx = -(viewWidth + touchX)   // PREV 回滚（覆盖前面）：dx 朝屏外左侧
        }
        dy = if (mCornerY > 0) {
            (viewHeight - touchY)
        } else {
            -touchY
        }
    } else {
        // 正常翻页分支
        dx = if (mCornerX > 0 && mDirection == PageDirection.NEXT) {
            -(viewWidth + touchX)        // NEXT 翻：dx 朝屏外左侧
        } else {
            viewWidth - touchX            // PREV 翻：dx 朝右
        }
        dy = if (mCornerY > 0) {
            (viewHeight - touchY)
        } else {
            (1 - touchY)
        }
    }
    startScroll(touchX.toInt(), touchY.toInt(), dx.toInt(), dy.toInt(), animationSpeed)
}
```

### `CoverPageDelegate.onAnimStart` (L93-L115)

```kotlin
when (mDirection) {
    PageDirection.NEXT -> distanceX =
        if (isCancel) {
            // 回滚：把当前页拉回原位
            var dis = viewWidth - startX + touchX
            if (dis > viewWidth) dis = viewWidth.toFloat()
            viewWidth - dis
        } else {
            -(touchX + (viewWidth - startX))  // 正常翻：当前页滑出屏外
        }
    else -> distanceX =
        if (isCancel) {
            -(touchX - startX)        // PREV 回滚
        } else {
            viewWidth - (touchX - startX)  // PREV 翻
        }
}
startScroll(touchX.toInt(), 0, distanceX.toInt(), 0, animationSpeed)
```

## 3. 时长公式 = 距离比例缩放（不是固定 300ms）

### `PageDelegate.startScroll` (L72-L82)

```kotlin
protected fun startScroll(startX: Int, startY: Int, dx: Int, dy: Int, animationSpeed: Int) {
    val duration = if (dx != 0) {
        (animationSpeed * abs(dx)) / viewWidth
    } else {
        (animationSpeed * abs(dy)) / viewHeight
    }
    scroller.startScroll(startX, startY, dx, dy, duration)
    isRunning = true
    isStarted = true
    readView.invalidate()
}
```

**duration = 300ms × |dx|/viewWidth**：
- 正常翻页 dx ≈ -viewWidth → duration ≈ 300ms（满档）
- 回滚 / 即将完成的小余量 → duration 自动缩短

## 4. 当前 Flutter Dart 实现对比

### `flutter_app/lib/features/reader/page/delegate/page_delegate.dart` `onDragEnd`

```dart
void onDragEnd(PageDirection detectedDir) {
    if (isRunning) return;
    if (_direction == PageDirection.none) {
      _direction = detectedDir;
    }
    if (_direction == PageDirection.next) {
      goToNext();
    } else if (_direction == PageDirection.prev) {
      goToPrev();
    } else {
      resetState();
    }
}
```

**问题**：完全不看用户当前是否真的拖了"足够远"，也不看最后一帧方向。只要 `_direction` 不是 none（即 onDragUpdate 期间累加 dragOffset 越过 ±5 像素），松手立刻翻页。

### `onDragUpdate` 现状

```dart
void onDragUpdate(double delta) {
    if (isRunning) return;
    _dragOffset += delta;
    final totalWidth = pageSize.width > 0 ? pageSize.width : 300.0;
    if (_dragOffset > 5 && _direction == PageDirection.none) {
      _direction = PageDirection.prev;
    } else if (_dragOffset < -5 && _direction == PageDirection.none) {
      _direction = PageDirection.next;
    }
    final progress = (_dragOffset.abs() / totalWidth).clamp(0.0, 1.0);
    ... // 边界守门
    animController.value = progress;
}
```

`_dragOffset` 是累计带符号位移、`progress` 是绝对值占屏宽比例。**没有 isCancel / lastDelta 比较**。

## 5. 修复方案对照

| 维度 | MD3 Kotlin | Flutter 当前 | 修复后 Flutter |
|---|---|---|---|
| 阈值类型 | last-frame 微动方向 | 无（任何 _direction 非 none 直接翻） | last-frame 微动方向（对齐 MD3） |
| `isCancel` 字段 | 实例字段，每帧覆盖 | 无 | **新增** `bool _dragCancel = false` |
| `onScroll` / `onDragUpdate` 内每帧设值 | `isCancel = (sumX vs lastX 看方向)` | 无 | 加：`if direction==next` `isCancel = delta > 0`（delta 是当前帧 dx，正值=向右回拉）；prev 反 |
| `onAnimStart` / `onDragEnd` 用 isCancel 决定回滚 / 翻页 | 是 | `goToNext/Prev` 无条件翻 | 加：`if (_dragCancel) reverse animController; else forward` |
| 时长 duration | `300 × \|dx\|/viewWidth` | `pageAnimDurationMs` 固定 | 沿用固定（已经是 user 可设；按距离缩放是 nice-to-have，先不改） |
| velocity 是否参与 | **不参与**（horizontal/cover/simulation） | `_detectDirection` 只看 velocity > 50 决定方向 fallback，不影响 cancel | 不动 |

## 6. 实施关键点

### A. 哪一帧的 delta 决定 isCancel

MD3 用的是 `sumX vs lastX`：sumX 是"从 down 到当前的累计 X 位置"，lastX 是"上一次 sumX"。
等价于 **当前 MOVE 事件的 dx 增量**。

Flutter 的 `onDragUpdate(double delta)` 接收的就是当前 MOVE 增量。所以：
```dart
isCancel = (_direction == next && delta > 0) ||
           (_direction == prev && delta < 0);
```

### B. 回滚动画

`_runAnimation(forward)` 当前路径调 `animController.forward(...)` + onComplete callback。回滚要：
```dart
animController.reverse(from: animController.value); // 拉回 0
```

不调 controller.goToNextPage（因为不翻页）；reverse 完成后 `_resetState()`。

### C. drag 进度推进的正反方向语义

当前 `onDragUpdate` 让 `animController.value = progress`，progress = `_dragOffset.abs()/totalWidth`，永远是正值；视觉上 0 → 1 推进表示"正在翻"。回滚 reverse 1 → 0 → 视觉上"拉回"。

### D. 跨章 boundaryNext/PrevPage 路径

`onDragUpdate` 现有逻辑：跨章方向但邻章未灌入时 `animController.value = 0`。继续保持。

### E. 微抖动避免

每个 MOVE 都覆盖 `_dragCancel`，可能因为微抖动反复翻转。MD3 没做平滑——交给 last-frame 决定，认为用户最后一帧的意图就是松手意图。Flutter 同步即可。

## 7. 测试计划

- 单测：`onDragUpdate` 模拟序列 [负, 负, 负, 正]（next 方向最后一帧反拉）→ 松手后 `_dragCancel == true` → animController 应 reverse
- 单测：`onDragUpdate` 模拟序列 [负, 负, 负, 负]（next 方向一直拉）→ `_dragCancel == false` → forward + commit
- 单测：prev 方向对偶
- 单测：drag 越过 boundary 后再回拉的 _dragCancel 行为
- 实机：拖到 80% 反向回拉一点点松手 → 应该回滚
- 实机：拖到 20% 一直朝翻页方向松手 → 应该翻完

## 8. 风险

1. 用户既有"快速拖一下不想翻"的肌肉记忆——但其实回拉那一瞬间松手就行，跟 MD3 体验一致
2. `_dragCancel` 翻转一帧错误：MD3 用 `sumX vs lastX` 同样有这个问题，没修；交给用户最后一帧
3. 跨章 boundary fallback 路径：用户拖到章末再回拉 → `_dragCancel=true` → reverse 到 0；不应触发 onChapterBoundary
4. drag → up 极快（< 1 个 MOVE 事件）：onDragUpdate 没机会跑 → `_dragCancel` 保持初始值（false）→ 默认翻页（与现状一致）
