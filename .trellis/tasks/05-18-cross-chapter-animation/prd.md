# Task 2 — 跨章翻页动画 + 邻章预加载（父任务）

## Goal

让 cover/slide/simulation/fade 4 种水平翻页动画在跨章节边界（本章末页 → 下章首页 / 本章首页 → 上章末页）也走完整动画，而不是当前的"翻到底 → 静止 → 内容跳变"。同时把当前 `_preloadAdjacentContent` 的字符串预拉升级为完整 textPages 渲染，让 `_renderPage` 能拿到邻章首/末页的 ui.Picture 在动画期间绘制。

属于 MD3 体感复刻 7 任务序列的第 7 个（Phase D 大手术）。

## Background — 当前问题根因

用户原话："所有翻页动画遇到章节切换时有明显的卡顿不连贯且没有动画"。

现状路径（reader_page.dart:1693 `_onPageChapterBoundary`）：

```
用户拖到章末再翻一页
  → SimulationPageDelegate.goToNext (page_delegate.dart:154)
  → !controller.hasNext → _resetState() + onChapterBoundary?.call(next)
  → ReaderPage._onPageChapterBoundary
  → _loadPageModeChapter(currentIndex + 1)
  → setState(_isLoadingContent=true) 
  → await _loadChapterContent(...)  [可能耗时 500ms+]
  → setState(_isLoadingContent=false)
  → _pageViewController.loadChapter(...)  ← 这里才有新内容
  → setState 触发重建 → 用户看到新章首页突兀出现
```

问题：
1. 章末翻页**没有动画**，因为 _resetState() 直接清状态
2. 动画期间显示的旧 picture 在 _resetState 时已 dispose
3. 新内容在异步加载完成后才出现，期间是 _isLoadingContent 占位/空白

## Constraints (用户已确认)

- **范围**：±1 章窗口（3 章节）
- **窗口外**：严格释放 textPages + paragraphs，仅保留 chapters[i]['content'] 字符串缓存
- **预加载时机**：进章后立刻 fetch ±1 章
- **未就绪 fallback**：邻章未 ready 时翻页仍走现有 boundary（无动画），加载完才 setState 切章
- **不重写**：保留 ReaderPage 现有 `_loadPageModeChapter` 异步加载链路；改 controller + delegate 的章节边界语义

## High-Level Architecture

### 关键改动总览

```
┌─────────────────────────────────────────────────────┐
│  ReaderPage (高层)                                   │
│  - _cachedChapters (existing)                        │
│  - _preloadAdjacentContent (existing, 字符串拉取)     │
│  + _measureAdjacentChapters (NEW, 字符串 → TextPage)  │
│    在 currentIndex / pageSize / settings 变时触发     │
│    填 PageViewController.{prevChapter, nextChapter}   │
└─────────────────────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────┐
│  PageViewController (重构核心)                        │
│  当前: 单章节 (_pages, _paragraphs)                   │
│  目标: 三章节窗口                                     │
│    - currentChapter (cur, _pages, _currentPageIndex)  │
│    - prevChapter (prev, _pages or null)               │
│    - nextChapter (next, _pages or null)               │
│  跨章边界 getter:                                     │
│    + boundaryNextPage: nextChapter?._pages.first      │
│    + boundaryPrevPage: prevChapter?._pages.last       │
│  + setNeighborChapter(prev:, next:) 由外层灌          │
│  + commitToNextChapter() / commitToPrevChapter()      │
│    用于动画完成时把 nextChapter 提升为 currentChapter │
└─────────────────────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────┐
│  PageDelegate (跨章边界处理)                          │
│  当前: goToNext 章末 → _resetState + boundary callback │
│  目标:                                                │
│    if !hasNext (同章):                                │
│      if controller.boundaryNextPage != null:          │
│        // 走完整动画，picture 已包含邻章首页          │
│        _direction = next                              │
│        _runAnimation(() {                             │
│          controller.commitToNextChapter()             │
│          onCrossChapter?.call(next)  // 通知 reader  │
│        })                                             │
│      else:                                            │
│        // fallback 旧 boundary 路径（未就绪）         │
│        _resetState + onChapterBoundary?.call          │
│  + onDragStart 时如果章末 → nextPicture 用            │
│    boundaryNextPage 渲染（不是 controller.nextPage）  │
└─────────────────────────────────────────────────────┘
```

### 数据流（跨章成功路径）

```
T0  ReaderPage 进入第 N 章
    └─ _measureAdjacentChapters(N)
        ├─ measure chapters[N-1] → TextPage list (heavy)
        └─ measure chapters[N+1] → TextPage list
        └─ pageViewController.setNeighborChapter(prev:, next:)

T1  用户拖到第 N 章末页

T2  用户再来一指拖动 (next 方向)
    └─ delegate.onDragStart 渲染 picture
        ├─ curPicture: controller.currentPage (本章末页)
        ├─ nextPicture: controller.boundaryNextPage (第 N+1 章首页)
        │             ← 关键：从 nextChapter._pages.first 渲染
        └─ prevPicture: controller.prevPage (本章倒数第二页)

T3  drag 进度 → 完整贝塞尔动画

T4  drag 松手 → goToNext()
    ├─ !controller.hasNext (本章无下页)
    ├─ controller.boundaryNextPage != null (邻章已就绪)
    └─ _runAnimation(() {
          controller.commitToNextChapter()
          // 现在 currentChapter = 原 nextChapter
          // currentPageIndex = 0 (新章首页)
          onCrossChapter?.call(next)
       })

T5  动画完成回调
    └─ ReaderPage._onCrossChapterCommit(next)
        ├─ setState(_currentIndex = N+1)
        ├─ saveReadingProgress
        └─ _measureAdjacentChapters(N+1)
            ├─ measure chapters[N] → 新的 prevChapter
            └─ measure chapters[N+2] → 新的 nextChapter
            └─ pageViewController.setNeighborChapter(prev:, next:)
```

### 数据流（fallback 邻章未就绪）

```
T0  用户进章很快就拖到末页
    （邻章 measure 还没完成）

T1  user drag end → goToNext
    ├─ !controller.hasNext
    └─ controller.boundaryNextPage == null
    └─ _resetState + onChapterBoundary?.call(next)
        // 走旧 _onPageChapterBoundary 路径
        // 用户看到无动画切章（与现状一致，可接受）
```

## Subtasks

整个改动拆 4 个子任务，串行执行：

### Subtask A — `controller-3ch` (controller 三章窗口)
- 路径：`.trellis/tasks/05-18-controller-3ch`
- 改 `page_view_controller.dart`：从单章节模型重构为三章节窗口
- 加 `_ChapterModel` 内部类容纳 (paragraphs, pages, currentPageIndex, title)
- 加 `prevChapter`, `nextChapter` 字段 + setNeighborChapter / commitToNextChapter / commitToPrevChapter
- 加 `boundaryNextPage` / `boundaryPrevPage` getter
- 改 nextPage / prevPage 跨章 fallback：本章 last → boundaryNextPage；本章 first → boundaryPrevPage
- 旧 loadChapter API 兼容（外层 ReaderPage 不变）
- 测试：纯 unit test，~10 用例覆盖 setNeighbor / commit / boundary 边界

### Subtask B — `prefetch-feed` (reader 预加载灌入 controller)
- 路径：`.trellis/tasks/05-18-prefetch-feed`
- 改 `reader_page.dart`：加 `_measureAdjacentChapters(int index)`
- 在 `_loadPageModeChapter` 完成后 + 进章 dispatch 后调
- 把 `chapters[i]['content']` 字符串通过 PageMeasure 测量成 TextPage list
- 调 `pageViewController.setNeighborChapter(prev:, next:)`
- 改 `_preloadAdjacentContent` 在 fetch 字符串成功后触发再次 measure
- 测试：mock chapters + measure，验证 controller 收到正确 pages

### Subtask C — `delegate-xchapter` (delegate 跨章动画路径)
- 路径：`.trellis/tasks/05-18-delegate-xchapter`
- 改 `page_delegate.dart`：goToNext / goToPrev 加 boundary chapter 检查
  - if !hasNext && boundaryNextPage != null → 走完整动画
  - 走完动画回调 commitToNextChapter
- 加 `onCrossChapter` callback (区别于现有 onChapterBoundary)
- 改 `onDragStart`：章末时 nextPicture 用 boundaryNextPage 渲染
- 改 `nextPageByAnim` / `prevPageByAnim` 同样支持
- ReaderPage 加 `_onCrossChapterCommit` 处理 setState + saveProgress + 重新预加载
- 测试：模拟章末拖到下章，断言完整动画 + 切章成功

### Subtask D — `xchapter-tests` (集成测试 + APK 实机验证)
- 路径：`.trellis/tasks/05-18-xchapter-tests`
- 加端到端测试覆盖
- 性能 / 内存 leak guard
- 编译 release APK 给用户实机验证

## Risk & Mitigation

- **PageViewController 注释明确说"早期版本曾尝试在控制器内部维护多章节窗口...形成死代码"**：当时是想做完整多章节窗口（≥5 章）。本次只做 ±1 章是不同设计，且**仅服务于跨章动画 picture 渲染**，不是为了用户随意翻找章节。注释要更新
- **Settings 变更触发整窗口重新 measure**：updateSettings 时不仅清 currentChapter._pages，还要清 prev/next 的 _pages（外层 ReaderPage 监听到设置变更后重新 _measureAdjacentChapters）
- **用户连续翻三章**：从 N → N+1 → N+2，第一次跨章时 nextChapter 是已 measure 好的 N+1，commit 后变成 currentChapter，prev 退位，nextChapter 变 null（直到 _measureAdjacentChapters(N+1) 完成）。第二次跨章用户能否再走动画？依赖 measure 速度。100ms 内 measure 完成的话用户感觉不到延迟
- **内存**：N+1 章 measure 完后 ~500KB textPages（取决于章长度）。3 章节 ~1.5MB。可接受。LRU 不必要（用户选择"严格窗口释放"）
- **外层 fallback 路径仍要保留**：现有 _onPageChapterBoundary 不删，作为 fallback。新加 _onCrossChapterCommit 处理"动画完成后真切章"

## Acceptance Criteria (父任务整体)

- [ ] Subtask A 完成：controller 单元测试全绿
- [ ] Subtask B 完成：reader 预加载灌入 controller
- [ ] Subtask C 完成：4 种水平动画跨章走完整动画
- [ ] Subtask D 完成：集成测试 + 实机验证
- [ ] flutter analyze 0 issue
- [ ] flutter test 全绿（141 baseline + 子任务新增）
- [ ] 用户实机验证舒适度

## Definition of Done

- 4 子任务各自独立 commit
- 父任务 archive 时所有子任务也 archive
- libbridge.so / Rust / FRB 零改动

## Out of Scope

- LRU 多章节缓存（严格窗口释放足够）
- ±2 章窗口（先 ±1 验证体感）
- 章节切换的"加载中"占位 UI（fallback 仍用现有占位）
- ReaderPage 滚动模式（continuousScroll 不受此次改动影响）
- Rust / FRB / libbridge.so

## Technical Notes

### 命令前缀

- `flutter --no-version-check analyze`
- `xvfb-run -a flutter --no-version-check test`
- 工作目录 flutter_app/

### 关键 file:line

- `flutter_app/lib/features/reader/page/page_view_controller.dart:13-17` — 历史"死代码"注释（要更新）
- `flutter_app/lib/features/reader/page/page_view_controller.dart:111-124` — loadChapter 当前签名
- `flutter_app/lib/features/reader/page/delegate/page_delegate.dart:154-162` — goToNext 章末 boundary
- `flutter_app/lib/features/reader/page/delegate/page_delegate.dart:174-181` — _runAnimation
- `flutter_app/lib/features/reader/reader_page.dart:1652-1701` — _loadPageModeChapter / _onPageChapterBoundary
- `flutter_app/lib/features/reader/reader_page.dart:1095-1123` — _preloadAdjacentContent

## Research References

无（架构设计基于已完成的 Legado MD3 调研，前序 Task 6/3/5/4 都有记录）。
