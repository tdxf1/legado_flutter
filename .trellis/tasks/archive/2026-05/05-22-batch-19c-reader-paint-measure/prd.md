# BATCH-19c: Reader 渲染优化（Listenable 拆层 + measure 同步化）

**Stage**: P1
**Slug**: `reader-paint-measure`
**Effort**: M (≤300 行)
**Depends on**: BATCH-19b ✅
**Splits from**: BATCH-19（路线图原 L 拆 3 子批，本批是 3/3）

## 1. 范围

修 reader 渲染层 2 个 C-性能 finding。
- F-W2A-012 子项 1：`Listenable.merge` 拆「内层 controller-only」+「外层 anim-only」
- F-W2A-013：`_measureChapter` 末尾 `notifyListeners` 改用 phase 感知策略（idle 时同步、build 时 postFrame）

留给独立 follow-up（不在本批）：
- F-W2A-012 子项 2：仿真 `_calcPoints` 早退缓存（行为重写复杂，需要充分 fps 测试）
- F-W2A-012 子项 3：仿真 `LinearGradient` shader 缓存（已有注释承认"开销可控"，单独评估）

## 2. 包含的 findings

| Finding | 当前行号 | 实施 |
|---------|---------|------|
| F-W2A-012 子项 1 | `page_view.dart:330-348` (AnimatedBuilder + Listenable.merge) | 拆双层：外 `AnimatedBuilder(animation: _animController!)` 重建 painter；内 `AnimatedBuilder(animation: widget.controller)` 仅在 currentTouch / direction / isRunning 等 controller 字段变化时刷新 painter 输入。**核心**：让纯 controller `notifyListeners`（loadChapter 后的 postFrame）不再触发动画 painter 重绘，反之亦然 |
| F-W2A-013 | `page_view_controller.dart:438-449` (`_measureChapter` 末 postFrame) | 改 phase-aware：`SchedulerBinding.instance.schedulerPhase` 在 `idle` / `postFrameCallbacks` → 同步 `notifyListeners`；其他 phase（`build` / `layout` / `paint`） → 保留 postFrame |

## 3. 影响文件

### `flutter_app/lib/features/reader/page/page_view.dart`

**F-W2A-012 子项 1 拆 Listenable**：
- 当前 line 330-348：
  ```dart
  AnimatedBuilder(
    animation: Listenable.merge([widget.controller, _animController!]),
    builder: (context, child) {
      return CustomPaint(painter: _PageViewPainter(
        ... currentPage / currentTouch / animProgress / isRunning ...
      ));
    },
  )
  ```
- 改写为嵌套：
  ```dart
  AnimatedBuilder(
    animation: _animController!, // 仅 anim 帧驱动
    builder: (context, child) {
      // anim 推进时重新读 controller 字段（值类型，安全）
      // 但本层仅 anim 变化触发 rebuild
      return AnimatedBuilder(
        animation: widget.controller, // controller-only 通知
        builder: (context, child) {
          return CustomPaint(painter: _PageViewPainter(
            currentPage: widget.controller.currentPage,
            ...
            animProgress: _animController!.value,
            currentTouch: _delegate.currentTouch,
          ));
        },
      );
    },
  )
  ```
- **风险**：内层每次 anim 帧都会被重建（外层 builder 调用内层 builder），效果上不一定省 paint 次数。**实际优化点**：当 anim **未跑** 时（`!_animController!.isAnimating`），controller `notifyListeners` 不应触发 painter 重绘。
- **更精确方案**：用 `ValueListenableBuilder` 或拆开两个 `AnimatedBuilder`：
  - 外层只 watch `_animController`，rebuild 时把 `_animController!.value` 注入
  - 内层 watch `widget.controller`，rebuild 时构造 painter
  - 两层都能独立 rebuild，但 painter 一帧最多构造 1 次
- **风险评估后实施保守方案**：sub-agent 先评估当前 `notifyListeners` 调用频率（grep 看 controller 在 loadChapter / measure / direction 等多少处 notify），如果非动画期 notify 频率低（每章节切换 1-2 次）→ **不拆**，仅给现状加注释说明决策
- **若拆**：用嵌套 `AnimatedBuilder` 方案，并 doc 说明语义

### `flutter_app/lib/features/reader/page/page_view_controller.dart`

**F-W2A-013 phase-aware notify**：
- 当前 line 445-449：
  ```dart
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!_disposed && _currentChapter?.chapterIndex == chapterIndex) {
      notifyListeners();
    }
  });
  ```
- 改为：
  ```dart
  // F-W2A-013 (BATCH-19c): phase-aware notify。
  // - idle / postFrameCallbacks：可以同步 notifyListeners 不触发
  //   "setState during build" assert，且消除"加载圆圈 → 短暂空白
  //   章节 → 真正内容"的首屏闪烁。
  // - build / layout / paint：保留 postFrame 兜底，避免 Riverpod
  //   selector 在 build 期间触发 loadChapter 导致的重入。
  final phase = SchedulerBinding.instance.schedulerPhase;
  if (phase == SchedulerPhase.idle || phase == SchedulerPhase.postFrameCallbacks) {
    if (!_disposed && _currentChapter?.chapterIndex == chapterIndex) {
      notifyListeners();
    }
  } else {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed && _currentChapter?.chapterIndex == chapterIndex) {
        notifyListeners();
      }
    });
  }
  ```
- 加 import `package:flutter/scheduler.dart`（如尚未 import）
- **风险**：idle 同步 notifyListeners 在 sub-agent 评估后如果发现现有调用链仍有"build 期触发 loadChapter"路径，必须保 postFrame 不动。decision tree 在 sub-agent 实施时跑一次 cargo+flutter test 验证。

## 4. 测试策略

- 现有 reader 测试套件回归（baseline 523）必须 PASS
- `flutter analyze` 0 issue
- `cargo build / cargo test` PASS
- **不强求新增 widget test**：painter rebuild 计数与 schedulerPhase 测试需要复杂的 widget 框架 stub，ROI 不划算；用 baseline 测试覆盖回归

## 5. 验收

- [ ] master finding F-W2A-012 子项 1 / F-W2A-013 标 Resolved by BATCH-19c（F-W2A-012 子项 2/3 标 partial / split-out）
- [ ] flutter analyze 0 issue / flutter test 523/523 PASS / cargo build / cargo test PASS
- [ ] decision 写入 spec：phase-aware notify 模式 + Listenable 拆层评估结论

## 6. 不在范围

- F-W2A-012 子项 2：仿真 `_calcPoints` 早退缓存（行为重写 + 浮点 epsilon 处理 + fps 测试，独立 follow-up）
- F-W2A-012 子项 3：仿真 `LinearGradient` shader 缓存（同 file 注释已承认"开销可控"，独立 evaluate）
- ReaderController class 抽取（路线图原 L 计划，BATCH-19a/b/c 完成后再评估必要性）

## 7. 风险点

- **Listenable 拆层**：嵌套 `AnimatedBuilder` 效果不确定（每帧外层 builder 调内层 builder，内层可能仍跑），**最大风险是没收益**。实施前 sub-agent 必须 grep 当前 controller `notifyListeners` 调用点列表 + 调用频率评估，如果非动画期 notify 频率低（每章节切换 1-2 次）→ 不拆改为加 doc 说明现状是 acceptable trade-off + master finding 标 partial Resolved + spec 注解。
- **phase-aware notify**：`SchedulerBinding.instance.schedulerPhase` API 稳定（Flutter 3.x+）；但 idle 同步 notify 在罕见的"build 期触发 loadChapter → 同步 notify → 上游 widget 还在 build → setState during build"场景仍可能出 assert。decision tree 在 sub-agent 实施时跑测试验证。

## 8. Post-archive update (2026-05-22)

本 PRD 第 1 / 5 / 6 / 7 节多处把 F-W2A-012 子项 2（`_calcPoints` 早退缓存）+ 子项 3（`LinearGradient` shader 缓存）描述为「留独立 follow-up / split-out / 标 partial Resolved」。归档后复评，决策修订为 **Resolved-by-Design (RBD) 不实施**。理由：

- 仿真翻页 painter 热路径只有 drag / tap-anim 两种；这两条路径上 `currentTouch` 每帧都不同（手指位置 / `_animStartTouch` → `_animTargetTouch` lerp 进度），早退 guard 与 shader 缓存键永远 miss。
- idle 期 painter `shouldRepaint` 已把 `currentTouch / direction / animProgress` 加入比较，外层 `AnimatedBuilder` 触发时返 false → `paint` 根本不被调用，guard / cache 也无处发挥。
- LinearGradient cache key 必须含 `(_isRtOrLb, _bs/_bc/_be 系列动态坐标, head/tailColor)`，与 currentTouch miss 同源问题。

修订同步入：
- master `findings.md` F-W2A-012 行 → `Resolved`（不再 `Partial Resolved`）
- `findings-flutter-core.md` F-W2A-012 Resolution → 子项 2/3 标 RBD + 三条复评触发条件
- spec `quality-and-anti-patterns.md`「Reader 渲染边界 (BATCH-19c)」段尾追加「`_calcPoints` 早退缓存与 LinearGradient shader 缓存评估结论 (不动)」小节

复评触发条件（任一满足回头加缓存）：(1) fps 基线测试 + profile 实证热点确实落在 `_calcPoints` atan2/sqrt 或 shader 创建；(2) 仿真翻页改离散帧 anim 模型，guard 命中率上升；(3) `_calcPoints` 几何被多个 painter 共享，缓存收益放大。

第 1 / 5 / 6 / 7 节正文保留原计划描述以反映当时的归档状态，本节为权威修订口径。
