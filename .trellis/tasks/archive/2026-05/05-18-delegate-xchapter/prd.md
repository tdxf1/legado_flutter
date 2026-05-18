# Subtask C — PageDelegate 跨章动画路径

**父任务**: `05-18-cross-chapter-animation`
**前置**: A (commit d62f11e), B (commit af4564b)

## Goal

让 PageDelegate.goToNext / goToPrev 在章末 / 章首时，如果 controller 的 boundaryNextPage / boundaryPrevPage 已就绪，**走完整动画**而不是直接 _resetState + boundary callback。动画完成后调 `controller.commitToNextChapter()` 切章 + 通过新的 `onCrossChapter` callback 通知 ReaderPage 做 setState + saveProgress + 重新预加载。

未就绪 fallback 仍走旧 `onChapterBoundary` 路径（与现状一致，无动画切章）。

## Requirements

- **C.1**：PageDelegate 加 `ChapterBoundaryCallback? onCrossChapter` (区别于现有 onChapterBoundary)
- **C.2**：`goToNext` 改逻辑：
  ```
  if hasNext (同章): _runAnimation(() => controller.goToNextPage())  // 不变
  else if controller.boundaryNextPage != null:
    _direction = next
    _runAnimation(() {
      controller.commitToNextChapter()
      onCrossChapter?.call(next)  // 通知 ReaderPage
    })
  else:
    _resetState
    onChapterBoundary?.call(next)  // fallback 旧路径
  ```
- **C.3**：`goToPrev` 同样三分支逻辑
- **C.4**：`onDragStart` 章末 / 章首时，nextPicture / prevPicture 用 boundaryNextPage / boundaryPrevPage 渲染（而不是 controller.nextPage / prevPage 的 null）
- **C.5**：`nextPageByAnim` / `prevPageByAnim` 同样支持跨章
- **C.6**：ReaderPage 加 `_onCrossChapterCommit(PageDirection dir)`：
  - 用 controller.currentChapterIndex 同步 _currentIndex
  - 调 saveReadingProgress
  - 调 _measureAdjacentChapters(_currentIndex) 重新预加载新邻章
  - 不调 _loadPageModeChapter（controller 已 commit，内容已就绪）
- **C.7**：PageViewWidget 把 onCrossChapter 透传到 delegate
- **C.8**：测试覆盖：
  - 单测 PageDelegate.goToNext 三分支
  - widget 测试：构造 controller + 灌邻章 + 触发 nextPageByAnim → 断言 onCrossChapter 被调 + currentChapterIndex 增加
  - 测试：boundaryNextPage 为 null 时仍走 onChapterBoundary fallback

## Acceptance Criteria

- [ ] PageDelegate.goToNext / goToPrev 三分支 (同章 / 跨章动画 / fallback)
- [ ] PageDelegate.onDragStart 章末时用 boundaryNextPage 渲染 nextPicture
- [ ] PageDelegate.nextPageByAnim / prevPageByAnim 跨章支持
- [ ] PageViewWidget 透传 onCrossChapter
- [ ] ReaderPage._onCrossChapterCommit 实现 + 与 _onPageChapterBoundary 共存
- [ ] flutter analyze 0 issue
- [ ] xvfb-run flutter test 全绿（176 baseline + 新增）

## Definition of Done

- 单一 commit "第二十七批 — Task 2C delegate 跨章动画路径"
- libbridge.so / Rust / FRB 零改动

## Technical Approach

### PageDelegate 改动

```dart
abstract class PageDelegate {
  // ... 现有字段 ...
  ChapterBoundaryCallback? onChapterBoundary;     // 现有
  ChapterBoundaryCallback? onCrossChapter;        // ← 新增

  void goToNext() {
    if (controller.hasNext) {
      _direction = PageDirection.next;
      _runAnimation(() => controller.goToNextPage());
      return;
    }
    // 章末：检查邻章是否就绪
    if (controller.boundaryNextPage != null) {
      _direction = PageDirection.next;
      _runAnimation(() {
        controller.commitToNextChapter();
        onCrossChapter?.call(PageDirection.next);
      });
      return;
    }
    // fallback: 邻章未就绪
    _resetState();
    onChapterBoundary?.call(PageDirection.next);
  }

  void goToPrev() {
    if (controller.hasPrev) {
      _direction = PageDirection.prev;
      _runAnimation(() => controller.goToPrevPage());
      return;
    }
    if (controller.boundaryPrevPage != null) {
      _direction = PageDirection.prev;
      _runAnimation(() {
        controller.commitToPrevChapter();
        onCrossChapter?.call(PageDirection.prev);
      });
      return;
    }
    _resetState();
    onChapterBoundary?.call(PageDirection.prev);
  }

  void onDragStart(Size pageSize, TextPage? cur, TextPage? next, TextPage? prev) {
    _clearPictures();
    curPicture = _renderPage(pageSize, cur);
    // C.4: 章末用 boundaryNextPage（如果 next 是 null 但 boundaryNextPage 存在）
    final effectiveNext = next ?? controller.boundaryNextPage;
    nextPicture = _renderPage(pageSize, effectiveNext);
    final effectivePrev = prev ?? controller.boundaryPrevPage;
    prevPicture = _renderPage(pageSize, effectivePrev);
  }

  void nextPageByAnim(int animationSpeed) {
    if (isRunning) return;
    // 同章 / 跨章 / fallback 三分支统一在 goToNext 里
    if (!controller.hasNext && controller.boundaryNextPage == null) {
      // fallback 路径 - 没有邻章数据
      onChapterBoundary?.call(PageDirection.next);
      return;
    }
    final size = pageSize.isEmpty ? const Size(400, 600) : pageSize;
    _clearPictures();
    curPicture = _renderPage(size, controller.currentPage);
    final effectiveNext = controller.nextPage ?? controller.boundaryNextPage;
    nextPicture = _renderPage(size, effectiveNext);
    final effectivePrev = controller.prevPage ?? controller.boundaryPrevPage;
    prevPicture = _renderPage(size, effectivePrev);
    goToNext();
  }

  // prevPageByAnim 同样
}
```

### PageViewWidget 透传

```dart
// page_view.dart
class PageViewWidget extends StatefulWidget {
  final ChapterBoundaryCallback? onChapterBoundary;
  final ChapterBoundaryCallback? onCrossChapter;  // ← 新增
  // ...
}

// _createDelegate 内每个 delegate 构造都加：
onChapterBoundary: widget.onChapterBoundary,
onCrossChapter: widget.onCrossChapter,  // ← 新增
```

### ReaderPage 改动

```dart
// reader_page.dart _buildPageBody (line ~1644)
return PageViewWidget(
  controller: _pageViewController!,
  settings: settings,
  pageAnim: settings.pageAnim,
  onChapterBoundary: _onPageChapterBoundary,
  onCrossChapter: _onCrossChapterCommit,  // ← 新增
);

// 加新方法
void _onCrossChapterCommit(PageDirection dir) {
  if (!mounted) return;
  final ctrl = _pageViewController;
  if (ctrl == null) return;
  // controller 已经 commit 了，从 controller 同步 _currentIndex
  final newIndex = ctrl.currentChapterIndex;
  if (newIndex == _currentIndex) return;  // 防御：commit 失败 fallback
  setState(() {
    _currentIndex = newIndex;
    if (_cachedChapters != null && newIndex < _cachedChapters!.length) {
      _chapterContent = _cachedChapters![newIndex]['content'] as String? ?? '';
      _chapterUrl = _cachedChapters![newIndex]['url'] as String? ?? '';
    }
  });
  // saveReadingProgress async
  _saveProgressAsync(newIndex);
  // 重新灌邻章
  _measureAdjacentChapters(newIndex);
  // 字符串预拉新邻章（fetch 还没就绪的）
  if (_cachedChapters != null) {
    _preloadAdjacentContent(newIndex, _cachedChapters!);
  }
}

Future<void> _saveProgressAsync(int chapterIndex) async {
  try {
    final dbPath = await ref.read(dbPathProvider.future);
    if (!mounted) return;
    await rust_api.saveReadingProgress(
      dbPath: dbPath,
      bookId: widget.bookId,
      chapterIndex: chapterIndex,
      paragraphIndex: 0,
      offset: 0,
    );
  } catch (e) {
    debugPrint('[Reader] saveProgressAsync failed: $e');
  }
}
```

### 测试

新增 `flutter_app/test/delegate_cross_chapter_test.dart` ≥ 5 用例：

1. goToNext 同章：调 controller.goToNextPage，无 cross
2. goToNext 章末 + boundaryNextPage 就绪：调 commitToNextChapter + onCrossChapter
3. goToNext 章末 + boundaryNextPage null：调 onChapterBoundary fallback
4. goToPrev 三分支同样
5. nextPageByAnim 跨章成功：currentChapterIndex 增加 1

## Out of Scope

- 不动 PageMeasure / TextPage / ReaderSettings
- 不动 Rust / FRB / libbridge.so
- 不改滚动模式
- 不改简单 cover/slide/fade/noAnim 几何（只动 PageDelegate 基类的状态机；子类不需要改 draw 因为它们已经支持基于 picture 的渲染）

## Technical Notes

- delegate base class 的改动会被所有 5 个子类继承（cover/slide/simulation/fade/noAnim）
- simulation 子类有自己的 onDragStart override (line 91-103)，需要确认 super.onDragStart 调用后 effectiveNext / effectivePrev 逻辑正确
- nextPageByAnim 已经在 simulation 子类里 override（合成虚拟起点 + 调 super），super 改了 effectiveNext 后会自然受益

### 关键 file:line

- `flutter_app/lib/features/reader/page/delegate/page_delegate.dart:154-181` — goToNext / goToPrev / _runAnimation
- `flutter_app/lib/features/reader/page/delegate/page_delegate.dart:62-68` — onDragStart
- `flutter_app/lib/features/reader/page/delegate/page_delegate.dart:218-244` — nextPageByAnim / prevPageByAnim
- `flutter_app/lib/features/reader/page/delegate/simulation_page_delegate.dart:91-103` — simulation 子类 onDragStart override
- `flutter_app/lib/features/reader/page/page_view.dart:17,90-149` — PageViewWidget ctor + _createDelegate
- `flutter_app/lib/features/reader/reader_page.dart:1644-1701` — _buildPageBody + _onPageChapterBoundary
