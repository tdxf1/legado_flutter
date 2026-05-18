# drag 拖拽回滚阈值（last-frame 微动方向） (T4)

## Goal

让 drag 翻页支持"拖了一半反悔"——当用户拖到 80% 但松手前最后一帧手指**朝翻页反方向**回拉一点点，松手后**不翻页**而是回滚到原位。对齐 MD3 horizontal/cover/simulation delegate 的 `isCancel` 语义（每帧 sumX vs lastX 比较，松手时按最后一帧方向决定翻 / 滚）。

## What I already know

- MD3 `HorizontalPageDelegate.onScroll` (L62-L110) 每帧 `isCancel = (NEXT && sumX>lastX) || (PREV && sumX<lastX)`——朝翻页**反向**移动 → 标 cancel
- MD3 `onAnimStart` 用 isCancel 决定 dx/dy 终值（回滚或翻页）
- MD3 不看 velocity / 不看绝对位置百分比阈值（horizontal 三种 delegate 共用）；Fade 例外用 `flipThreshold=0.1f`
- duration 按 `|dx|/viewWidth` 比例缩放，回滚耗时短
- Flutter 现状：`onDragEnd` 只看 `_direction`，没 isCancel 字段，松手即翻

详见 `research/md3-drag-cancel.md` 完整代码摘录 + Dart vs Kotlin 差异表。

## Requirements

1. **加 `_dragCancel` 字段**：在 `PageDelegate`，每帧 `onDragUpdate` 根据 delta 符号 + `_direction` 重新计算
2. **`onDragEnd` 看 _dragCancel**：true → reverse animController 回滚；false → forward 翻页（同现行）
3. **跨章 boundaryNext/PrevPage 也支持回滚**：拖到章末再回拉松手不切章
4. **跨 delegate 共享**：simulation/cover/slide/fade 都受益（fade 自有 `flipThreshold` 不冲突，但走同一 isCancel）
5. **不影响 tap 路径**：tap nextPageByAnim / prevPageByAnim 不走 onDragUpdate，无 isCancel 概念，永远翻页

## Acceptance Criteria

- [ ] 单测：`onDragUpdate` 模拟 [-30, -30, -30, +5]（next 方向最后一帧反拉 5px）→ `_dragCancel == true`
- [ ] 单测：`onDragUpdate` 模拟 [-30, -30, -30, -5]（一直 next 方向）→ `_dragCancel == false`
- [ ] 单测：prev 方向对偶（[+30, +30, +30, -5] → cancel；[+30, +30, +30, +5] → 不 cancel）
- [ ] 单测：`onDragEnd` 看 _dragCancel：true → animController.value 0；false → animController.value 1（forward 完成）
- [ ] 单测：跨章 boundaryNextPage 路径下 cancel 不切章（commitToNextChapter 不被调）
- [ ] 实机：拖 50% 后反拉 1cm 松手 → 回滚（不翻页）
- [ ] 实机：拖 20% 一直朝翻页方向松手 → 翻完
- [ ] 测试套件 225+ 全绿

## Definition of Done

- flutter analyze 0 issue
- xvfb-run flutter test 全绿
- debug APK 实机验证
- commit 一次 + archive

## Technical Approach

### A. PageDelegate 字段 + onDragUpdate 钩子

```dart
/// T4 (05-18): 对应 MD3 HorizontalPageDelegate.onScroll 的 isCancel。
/// 每帧 [onDragUpdate] 比较当前 delta 与翻页方向：
/// - next 方向（用户向左拉）+ delta > 0（这一帧向右）→ 朝反向 → cancel
/// - prev 方向（用户向右拉）+ delta < 0（这一帧向左）→ 朝反向 → cancel
/// 松手时 [onDragEnd] 看 _dragCancel 决定回滚 vs 翻页。
bool _dragCancel = false;

@protected
bool get dragCancel => _dragCancel;

void onDragUpdate(double delta) {
  if (isRunning) return;
  _dragOffset += delta;
  final totalWidth = pageSize.width > 0 ? pageSize.width : 300.0;

  if (_dragOffset > 5 && _direction == PageDirection.none) {
    _direction = PageDirection.prev;
  } else if (_dragOffset < -5 && _direction == PageDirection.none) {
    _direction = PageDirection.next;
  }

  // T4 新增：每帧覆盖 _dragCancel（与 MD3 一致 — 松手时取最后一帧值）
  if (_direction == PageDirection.next) {
    _dragCancel = delta > 0;  // 这一帧向右回拉
  } else if (_direction == PageDirection.prev) {
    _dragCancel = delta < 0;  // 这一帧向左回拉
  }

  // 边界守门 ... 同现行
  final progress = (_dragOffset.abs() / totalWidth).clamp(0.0, 1.0);
  ...
  animController.value = progress;
}
```

### B. onDragEnd 看 _dragCancel

```dart
void onDragEnd(PageDirection detectedDir) {
  if (isRunning) return;
  if (_direction == PageDirection.none) {
    _direction = detectedDir;
  }
  if (_direction == PageDirection.none) {
    resetState();
    return;
  }
  // T4 新增：cancel 路径走回滚
  if (_dragCancel) {
    _runReverseAnimation();
    return;
  }
  // 正常翻页（保留现行）
  if (_direction == PageDirection.next) {
    goToNext();
  } else {
    goToPrev();
  }
}

void _runReverseAnimation() {
  if (isRunning) return;
  isRunning = true;
  void tick() => onAnimTick(animController.value);
  animController.addListener(tick);
  animController.reverse(from: animController.value).then((_) {
    animController.removeListener(tick);
    resetState();
    onAnimEnd();
  });
}
```

`_runReverseAnimation` 不 callback `controller.goToNextPage`——什么也不做就是回滚。

### C. resetState 清 _dragCancel

```dart
void resetState() {
  _direction = PageDirection.none;
  _dragOffset = 0;
  _dragCancel = false;  // T4 新增
  isRunning = false;
  animController.value = 0;
  _clearPictures();
}
```

`cancelDrag()` 同样要清。

## Decision (ADR-lite)

**Context**: 用户报告"手动翻页可以更灵敏一点"+"拖了一半反悔了不应该翻"。MD3 horizontal 三种 delegate 通过 last-frame 微动方向实现这个体感，没有百分比阈值。

**Decision**:
1. 对齐 MD3 last-frame 微动方向逻辑——加 `_dragCancel` 字段每帧覆盖、`onDragEnd` 看 cancel 决定 reverse / forward
2. **不引入百分比阈值**（不做 Fade 那种 `flipThreshold = 0.1f`）—— horizontal 三种 delegate 都跟 MD3 一致
3. **不引入 velocity 阈值** —— MD3 horizontal 不参考 velocity
4. duration 缩放（按 |dx|/viewWidth）暂不做——本期保守，先把回滚行为加上

**Consequences**:
- 用户体感对齐 MD3 / 上游 Legado；从该项目过渡不需重新学手势
- 极端微抖动可能让 _dragCancel 一帧错误翻转——MD3 也有同样问题，交给最后一帧
- 跨 delegate 共用一份逻辑（无需 simulation/cover/slide 各自实现）；fade 自己的 `flipThreshold` 走自己分支，不冲突

## Out of Scope

- duration 按 |dx|/viewWidth 缩放（nice-to-have，不阻塞）
- Fade `flipThreshold` 调整（fade 走自有分支）
- T2 followup（仿真 prev 镜像剩余问题）
- velocity 参与翻页判定

## Technical Notes

### 关键文件

- `flutter_app/lib/features/reader/page/delegate/page_delegate.dart` — 加字段 + 改 `onDragUpdate` / `onDragEnd` / `resetState`
- 不动子类（simulation/cover/slide/fade/no_anim）

### 测试文件

`test/page_view_controller_window_test.dart` 或新建 `test/drag_cancel_test.dart` — drag delta 序列单测

### 风险点

1. 现有跨章测试 `delegate_cross_chapter_test.dart` 看 onDragEnd 行为——_dragCancel 默认 false 不影响现行 forward 路径，应不会破坏
2. _runReverseAnimation 不调 onChapterBoundary——cancel 路径既然不翻页就不应该触发邻章预拉的副作用
3. Listener 层 `cancelDrag()` 是用户 PointerCancel 触发，与 _dragCancel 语义无关——cancelDrag 直接复位、_dragCancel 是松手前最后一帧方向，两路独立

## Research References

- [`research/md3-drag-cancel.md`](research/md3-drag-cancel.md) — MD3 horizontal/cover/simulation delegate 的 isCancel 完整代码摘录
