# 调研：MD3 仿真翻页 prev 几何（活页书"翻过去盖回来"）

来源仓库：`/root/data/workspaces/doro_FriendMessage_641981595/legado-with-MD3`（Kotlin）。

## 目标体感

把手机当作一本翻开的书的右半边：
- **next（向下翻）**：右下角的纸从右向左**卷起翻过去**到屏幕左侧
- **prev（向上翻）**：刚翻过去那张纸**盖回到右侧**——视觉上是 next 的**反向运动**，cornerXY 仍锚在右下角

## 1. setDirection 镜像（核心）

### `SimulationPageDelegate.kt` (L188-L206)

```kotlin
override fun setDirection(direction: PageDirection) {
    super.setDirection(direction)
    when (direction) {
        PageDirection.PREV ->
            //上一页滑动不出现对角
            if (startX > viewWidth / 2) {
                calcCornerXY(startX, viewHeight.toFloat())
            } else {
                calcCornerXY(viewWidth - startX, viewHeight.toFloat())
            }

        PageDirection.NEXT ->
            if (viewWidth / 2 > startX) {
                calcCornerXY(viewWidth - startX, startY)
            }

        else -> Unit
    }
}
```

**关键观察**：PREV 路径**不论用户在屏幕哪边**最终都把 cornerXY 锚到**右下角**（startX > w/2 直接用，startX <= w/2 镜像 `viewWidth - startX` 仍 > w/2）。配合 calcCornerXY：

### `calcCornerXY` (L513-L518)

```kotlin
private fun calcCornerXY(x: Float, y: Float) {
    mCornerX = if (x <= viewWidth / 2) 0 else viewWidth
    mCornerY = if (y <= viewHeight / 2) 0 else viewHeight
    mIsRtOrLb = (mCornerX == 0 && mCornerY == viewHeight)
            || (mCornerY == 0 && mCornerX == viewWidth)
}
```

PREV 强制传 `viewHeight` 作 y → cornerY = viewHeight（底部）。PREV 路径 setDirection 后 x 永远 > w/2 → cornerX = viewWidth（右侧）。所以 **PREV 时 cornerXY 永远是 (viewWidth, viewHeight) 右下角，mIsRtOrLb = false**。

## 2. PREV tap 完整轨迹

### `HorizontalPageDelegate.prevPageByAnim` (L140-L146)

```kotlin
override fun prevPageByAnim(animationSpeed: Int) {
    abortAnim()
    if (!hasPrev()) return
    setDirection(PageDirection.PREV)              // ← 1. 先 setDirection 镜像 cornerXY
    readView.setStartPoint(0f, viewHeight.toFloat(), false)  // ← 2. 重置起点到左下 (0, h)
    onAnimStart(animationSpeed)                    // ← 3. 跑动画
}
```

注意调用顺序：
- L143 `setDirection(PREV)` 时 startX/startY 还是 tap 落点（用户实际点击位置）
- 执行 `setDirection` 内部 `calcCornerXY(viewWidth - startX, viewHeight)` → cornerXY 锁定在右下
- L144 `setStartPoint(0, viewHeight)` 把 startX/Y、touchX/Y 全部重置成左下角 (0, h)
- L145 `onAnimStart` 用最新的 (touchX, touchY) = (0, h) 开始跑

### `onAnimStart` 算 dx/dy (L208-L239)

```kotlin
override fun onAnimStart(animationSpeed: Int) {
    var dx: Float
    val dy: Float
    if (isCancel) {
        // 回滚分支（拖了又松手不翻页）
        dx = if (mCornerX > 0 && mDirection == PageDirection.NEXT) {
            (viewWidth - touchX)
        } else {
            -touchX
        }
        if (mDirection != PageDirection.NEXT) {
            dx = -(viewWidth + touchX)   // PREV 回滚：往左拉一整屏
        }
        dy = if (mCornerY > 0) {
            (viewHeight - touchY)
        } else {
            -touchY
        }
    } else {
        // 正常翻页分支
        dx = if (mCornerX > 0 && mDirection == PageDirection.NEXT) {
            -(viewWidth + touchX)        // NEXT 翻：触摸点拖到屏外左侧
        } else {
            viewWidth - touchX            // ⚠️ PREV 翻：触摸点 (0, h) 拖到 (w, h)
        }
        dy = if (mCornerY > 0) {
            (viewHeight - touchY)         // PREV: viewHeight - viewHeight = 0
        } else {
            (1 - touchY)
        }
    }
    startScroll(touchX.toInt(), touchY.toInt(), dx.toInt(), dy.toInt(), animationSpeed)
}
```

**PREV tap 完成翻页时的最终参数**：
- 起点：`(touchX, touchY) = (0, viewHeight)` ←  setStartPoint 设的左下角
- dx：`viewWidth - 0 = viewWidth`（往右一整屏）
- dy：`viewHeight - viewHeight = 0`（不动）
- → `startScroll(0, h, w, 0, duration)` —— **触摸点从屏幕左下角沿底边水平拖到右下角**

cornerXY 锚在 (w, h) 右下，触摸点从 (0, h) 滑到 (w, h)——视觉上整张纸**从左下方向右下卷过去**，刚好是 next 的反向。这就是"活页书翻过去盖回来"的几何来源。

## 3. PREV drag 路径

drag 用户实际触摸点的 startX 决定 corner 镜像。`HorizontalPageDelegate.onScroll` (L62-L110) 不重置 startPoint，每帧 `setTouchPoint(sumX, sumY)` 推进 touchX/Y；`setDirection(PREV)` 同样把 cornerXY 镜像到右半边。

drag 松手时 `onAnimStart` 用当前 touchX/Y 算 dx/dy，与 tap 共用同一公式。

## 4. 与 Flutter 当前实现的差异（**bug**）

Flutter `simulation_page_delegate.dart` 当前 `prevPageByAnim`：

```dart
@override
void prevPageByAnim(int animationSpeed) {
    if (isRunning) return;
    final size = pageSize.isEmpty ? const Size(400, 600) : pageSize;
    // 左下角附近虚拟起点：与 next 的 (0.9w, 0.9h) 镜像，留出 0.1*w 偏移
    final virtualStart = Offset(size.width * 0.1, size.height * 0.9);
    recordTouchStart(virtualStart, size);
    _maxLength = math.sqrt(...);
    _calcCornerXY(virtualStart.dx, virtualStart.dy);    // ⚠️ x=0.1w → cornerX=0 左下
    _setupTapAnim(virtualStart, PageDirection.prev);     // ⚠️ 终点 (w, h) 但起点 (0.1w, 0.9h)
    super.prevPageByAnim(animationSpeed);
}
```

`_calcCornerXY` 同 MD3 公式（x ≤ w/2 → cornerX=0），但起点 (0.1w, 0.9h) 直接落在左半边 → cornerX = 0 左下、isRtOrLb=true → 视觉上是**从左下角卷出一张新纸**，不是"右下角的纸盖回来"。

**根因**：缺 `setDirection` 镜像那段——PREV 时不该让 cornerXY 落在左下，要么直接传 `(viewWidth - startX, h)` 镜像（startX=0.1w → 0.9w → cornerX=w），要么 setStartPoint 时直接给 (0, h) 但 cornerXY 提前算好右下。

## 5. 修复方案对照

| 步骤 | MD3 Kotlin | Flutter 当前（错） | Flutter 修复后 |
|---|---|---|---|
| 1. tap 落点 | startX (实际) | 虚拟 (0.1w, 0.9h) | **保留 tap 落点（左 1/3 区域）**或虚拟 (0.1w, 0.9h) |
| 2. setDirection 镜像 cornerXY | startX > w/2 ? (startX, h) : (w-startX, h) | 无 | **新增**：传 (w-startX, h) 算出右下 corner |
| 3. setStartPoint 重置触摸点 | (0, h) | 仍是虚拟起点 (0.1w, 0.9h) | **改为 (0, h)** |
| 4. onAnimStart / setupTapAnim 终点 | dx=w → 终点 (w, h) | 当前已是 (w, h) | 保持 |
| 5. 视觉效果 | 触摸点 (0, h) → (w, h)，corner 锚右下 | 触摸点 (0.1w, 0.9h) → (w, h)，corner 锚左下 | **触摸点 (0, h) → (w, h)，corner 锚右下**（与 next 反向镜像） |

## 6. drag 路径要不要改

MD3 drag PREV：用户从左半屏拖时也走 setDirection PREV → 镜像 cornerXY 到右下。视觉上"用户从左侧撕但 cornerXY 锁右"。

Flutter 当前 drag：`onDragStart` 用 startTouch 直接算 cornerXY（与 _calcCornerXY 同公式）。如果用户从左半屏 drag → cornerX=0 左下（错）。修：drag 起始时也走 setDirection 镜像逻辑。

## 7. 验收

视觉上：
- prev tap：从屏幕**左下方"撕"出一张纸沿底边水平拖到右下角**，纸张右下角是支点（折角在右下）
- prev drag：用户手指无论从哪儿往右拉，纸张折角都锚在右下，与 next 反向
- next 行为不变（左下方虚拟起点 / 右下角 corner）

## 8. 单测策略

- `simulation_page_delegate_test.dart` 已有 `debugCornerX/Y/IsRtOrLb` 暴露
- 加测试：`prevPageByAnim` 触发后 cornerX == pageSize.width / cornerY == pageSize.height / isRtOrLb == false（与 MD3 一致）
- next 不变验证 cornerX == w / cornerY == h / isRtOrLb == false（也是右下，next/prev 现在共用 corner）

## 9. 注意点

cornerXY 都是右下时，next 与 prev 几何上**相同**——区别在 `_animTargetTouch`（lerp 终点）方向：
- next：触摸点从 (0.9w, 0.9h) 虚拟起点 → (-w, h)（屏外左侧）
- prev：触摸点从 (0, h) → (w, h) 等等? 不对，应该从屏外左侧 (-w?) 还是 (0, h) 到 (w, h)？

MD3 prev tap 触摸点是从 (0, h) 拖到 (w, h)——这意味着**画面里能看到的是触摸点向右移动**，但视觉上的"纸张盖回"是 corner 在右下、touchPoint 拉离 corner 越远纸卷得越大。

让我重新想几何：
- next：corner 在右下 (w, h)，touchPoint 从 (0.9w, 0.9h) 拉到 (-w, h)；touchPoint 离 corner 距离从近到远 → 纸从平贴到全卷起 → "翻过去"
- prev：corner 在右下 (w, h)，touchPoint 从 (0, h)（远离 corner）拉到 (w, h)（贴着 corner）；touchPoint 离 corner 距离从远到近 → 纸从全卷起逐渐贴回 → "盖回来"

逻辑一致：**PREV 是 NEXT 几何的时间反向**，touchPoint 起点是 NEXT 的终点附近、终点是 NEXT 的起点附近。
