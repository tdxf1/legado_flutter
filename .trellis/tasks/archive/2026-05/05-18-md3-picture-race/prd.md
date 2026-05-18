# Task 6 — 翻页 isRunning reentrance guard

## Goal

为 `PageViewWidget._onHorizontalDragStart` 增加 `isRunning` 重入守卫，避免动画进行中再次拖拽触发 `_clearPictures()` 与新一轮 `onDragStart` 把正在被 painter 引用的 `ui.Picture` 提前 dispose。补一个快速连续翻页的 widget 测试做回归。

属于"MD3 翻页体感复刻"7 任务序列里的第一个，定位为低风险预热项 — 主要价值是在动手做后续 Task 3/5/2 之前，把翻页 delegate 的状态机最显眼的 race 风险消除掉。

## What I already know

- Flutter 端翻页架构：`PageViewWidget` (`page_view.dart`) + `PageViewController` + 5 个 `PageDelegate` 子类（cover/slide/simulation/fade/noAnim）
- 动画机制：单一 `AnimationController(duration: 300ms)`，由 delegate 的 `_runAnimation` 驱动 forward + then 切页 + `_resetState` 清状态
- Picture 生命周期：`onDragStart` 渲染 cur/next/prev 三张 `ui.Picture` → 每帧由 painter `canvas.drawPicture(...)` 引用 → 动画结束 `_resetState` 调 `_clearPictures` dispose
- 重入风险点：动画期间 `isRunning = true` 但 `_onHorizontalDragStart`（`page_view.dart:163-168`）**没有 isRunning guard**，外部触发的新拖拽会直接调 `_delegate.recordTouchStart` + `_delegate.onDragStart` → `_clearPictures()` 把正在被绘制的 Picture dispose
- 现有 `abortAnim()`（`page_delegate.dart:205`）只 stop animController + 置 isRunning = false，**不调** `_resetState/_clearPictures`，所以是"安全停止"。但 reentrance 路径完全绕过它

## MD3 根因映射 (审计已完成)

| 根因 | Flutter 状态 | 决策 |
|---|---|---|
| R1 亚像素 touchY floor | `_dragOffset += delta`（page_delegate.dart:112）全 double，grep 翻页路径上**无 toInt/floor/round** | 已经达成 MD3 状态，不需要改动 |
| R2 主线程图片清理 | reader 路径上**无** `imageCache.clear()`，只有 search 用 CoverCache | Flutter 端不存在该问题 |
| R3 preDownload 触发 upToc | reader_page.dart 无"翻页 → toc 刷新"副作用链 | Flutter 端不存在该问题 |
| R4 Picture race | `_clearPictures` 在动画结束时执行；但 `_onHorizontalDragStart` 缺 isRunning guard 是潜在重入风险 | **Task 6 唯一 deliverable** |
| Fade 0.1 阈值 | Flutter 当前用 `_dragOffset > 5 / < -5` 即触发方向，比 MD3 0.1 progress (~50px) 更灵敏 | MD3 反而更迟钝，不照搬 |

## Requirements

R6.1 — `PageViewWidget._onHorizontalDragStart` 在 `_delegate.isRunning == true` 时直接 return，不触发新一轮 `recordTouchStart` / `onDragStart`
R6.2 — 同理审计 `_onHorizontalDragUpdate` / `_onHorizontalDragEnd` — Update 当 isRunning 时不应再写 `_dragOffset`，End 当 isRunning 时不应再调 `goToNext/goToPrev`
R6.3 — 增加 widget test：模拟"动画进行中再开始新拖拽"场景，断言不抛异常 + 现有动画完成 + 新拖拽被忽略
R6.4 — 不动现有的"用户主动 abortAnim 中断动画"路径（点击翻页期间手动取消等）

## Acceptance Criteria

- [ ] `PageViewWidget._onHorizontalDragStart/Update/End` 三处加 isRunning guard
- [ ] 新增测试 `page_view_reentrance_test.dart`：覆盖动画进行中 drag 重入
- [ ] `flutter --no-version-check analyze` 0 issue
- [ ] `xvfb-run flutter --no-version-check test test/features/reader/` 全绿（含新增测试）
- [ ] 既有 reader_page widget 测试不出现 regression
- [ ] grep `goToNext\|goToPrev\|_clearPictures` 在 `page_delegate.dart` 的调用次序未发生意外变化

## Definition of Done

- 测试新增 + 既有测试不退化
- analyze 全绿
- 单一 commit message，遵循"第二十一批"格式
- libbridge.so / Rust 端零改动

## Technical Approach

最小手术式 patch：

```dart
// page_view.dart:163-178
void _onHorizontalDragStart(DragStartDetails details) {
  if (_delegate.isRunning) return;     // ← 新增
  if (_pageSize.isEmpty) return;
  ...
}

void _onHorizontalDragUpdate(DragUpdateDetails details) {
  if (_delegate.isRunning) return;     // ← 新增
  _delegate.recordTouchUpdate(details.localPosition);
  _delegate.onDragUpdate(details.primaryDelta ?? 0);
}

void _onHorizontalDragEnd(DragEndDetails details) {
  if (_delegate.isRunning) return;     // ← 新增
  ...
}
```

为什么不直接 abortAnim：MD3 原版让动画自然走完即可，强制 abort 反而会出现"动画进行中突然停在中间帧"。Flutter 端 GestureDetector 的 onHorizontalDrag* 会把同手势的 events 全部 dispatch；动画进行时直接吞掉重入手势，等动画结束自然恢复响应。

## Decision (ADR-lite)

**Context**: Task 6 原计划要复刻 4 项 MD3 体感修复 (R1-R4)。审计后发现 R1/R2/R3 在 Flutter 端不存在，R4 仅剩"reentrance race"一个微型隐患。

**Decision**: Task 6 缩小为单一 deliverable — 三处 GestureDetector 回调加 isRunning guard + 一个 widget reentrance 测试。

**Consequences**:
- 实施周期由半天压到 1-2 小时
- 后续 Task 3/5/2 不依赖 Task 6 输出，可独立推进
- 如果实测暴露真正的 Picture race，再单建 Task 重做

## Out of Scope

- 不动 Fade 阈值（Flutter 现状比 MD3 更灵敏，照搬反而劣化）
- 不引入 abortAnim 在 reentrance 路径（MD3 也不 abort）
- 不改 AnimationController duration / curve（保持 300ms / Curves.linear）
- 不审计 `nextPageByAnim` / `prevPageByAnim` 的 reentrance — 那条路径走 `goToNext` 内部已有 `_runAnimation` 的 isRunning 短路，无新增风险
- 不改 Rust / libbridge.so / FRB 桥接

## Technical Notes

### 关键 file:line

- `flutter_app/lib/features/reader/page/page_view.dart:163-178` — 三个 drag callback 落点
- `flutter_app/lib/features/reader/page/delegate/page_delegate.dart:174-181` — `_runAnimation` 设 isRunning
- `flutter_app/lib/features/reader/page/delegate/page_delegate.dart:75-82` — `_clearPictures` 实现
- `flutter_app/lib/features/reader/page/delegate/page_delegate.dart:205-210` — abortAnim 现状（Task 6 不动它）

### 测试入口

- `flutter_app/test/features/reader/` 已存在的测试目录 (检查是否有 page_view_test.dart)
- 新增 `flutter_app/test/features/reader/page_view_reentrance_test.dart`
- 测试构造 PageViewWidget + 真实 PageViewController，模拟 `WidgetTester.startGesture` 触发 onDragStart → 等动画跑一半 → 再 startGesture → pumpAndSettle → 断言无异常 + currentPage 行为正确

### 命令前缀

- `flutter --no-version-check analyze`
- `xvfb-run flutter --no-version-check test test/features/reader/`

## Research References

无（审计是 inline 完成的，无 sub-agent 研究产物）。
