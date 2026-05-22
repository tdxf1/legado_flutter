# T4 Followup — drag 拖拽回滚阈值未验收 (backlog)

## 状态

⏸ **待用户实机验收** — T4（commit `5ac62d0`，archive 在
`.trellis/tasks/archive/2026-05/05-18-drag-cancel-threshold-md3/`）已实现
last-frame 微动方向 isCancel 语义 + reverse 回滚动画 + 10 个单测全绿。
但用户当时说"接下来时间我没法测试先不修 记录下来去做其他的"——T4 与
T2 followup 一并暂存，等用户回来一起验收再激活修订。

## 已实现的能力

- `PageDelegate._dragCancel` 字段 + `debugDragCancel` @visibleForTesting
- `onDragUpdate` 每帧根据 delta 符号 + `_direction` 覆盖 `_dragCancel`
  - next 方向 + delta > 0（向右回拉）→ cancel
  - prev 方向 + delta < 0（向左回拉）→ cancel
  - delta == 0 保留上一帧值
- `onDragEnd` 看 `_dragCancel`：true → `_runReverseAnimation`、false → 走原 `goToNext` / `goToPrev`
- `_runReverseAnimation`：`animController.reverse(from: value)` → resetState；不调 controller / 不切章
- `resetState` / `cancelDrag` 清 `_dragCancel`

## 跨 delegate 共享

simulation/cover/slide/fade/no_anim 自动受益（继承 PageDelegate）。tap 路径不受影响（不走 onDragUpdate）。

## 未做但保留可选

- duration 按 `|dx|/viewWidth` 比例缩放（MD3 PageDelegate.startScroll L72-L82）——本期保守不动
- velocity 阈值——MD3 horizontal 不参考；保持
- Fade 自有 `flipThreshold = 0.1f`——独立分支，不动

## APK

`dist/legado-arm64-debug-T4-drag-cancel.apk`，含 T1+T2+T3+T4 全部修复。

## 用户验收清单

1. 仿真/覆盖任一翻页动画下：
   - 拖 50% → 反向回拉 5-10px → 松手 → **应回滚到原位**（不翻页）
   - 拖 20% → 一直朝翻页方向松手 → 翻完
2. 跨章场景：拖到章末再回拉松手 → 不切章
3. tap 翻页不受影响

## 重启时操作清单

1. 让用户描述实机现象（如"反拉了但仍翻页"或"反拉灵敏度太高，轻微抖动就回滚"）
2. 抓 logcat（`onDragUpdate` 加临时 `debugPrint('[Drag] delta=$delta dir=$_direction cancel=$_dragCancel')` 即可）
3. 对照 MD3 `HorizontalPageDelegate.onScroll` L62-L110 的 `isCancel` 计算复核
4. 极端微抖动问题→ 加平滑窗口（取最近 3-5 帧 delta 之和符号）

## 候选优化方向

- 微抖动平滑：用最近 N 帧 delta 累计判定方向而非单帧
- duration 距离缩放：`startScroll` 时长按 `|dx|/viewWidth` 比例缩放
- 反向运动死区：delta 必须超过某阈值（如 1px）才 flip cancel，避免传感器噪声
