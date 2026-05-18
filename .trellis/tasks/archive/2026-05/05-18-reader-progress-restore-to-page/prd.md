# 阅读进度恢复到具体页 (T1)

## Goal

打开书时把上次阅读位置精确恢复到**章节 + 章内具体页**，章内每翻一页都立即把位置写入 DB；让用户回书架重开 app 后回到上次离开的那一页。

对齐 Legado MD3 行为：进度的最小存储单位是 `(durChapterIndex, durChapterPos)`——`durChapterPos` 是当前页**首字符的章内字节 offset**（不是页码），重开时用 `getPageIndexByCharOffset(durChapterPos)` 反算成具体页索引。

## What I already know

- `Book.kt` (L99-L103) `durChapterIndex` + `durChapterPos`（"首行字符的索引位置"）
- `TextChapter.getPageIndexByCharIndex` (L226-L243) 用 page 表二分搜索反算页码
- `ReadBook.moveToNextPage`/`moveToPrevPage` 章内每翻一页同步调 `saveRead(true)`（异步线程，无 debounce）
- `ReadBook.resetData`(L118-L146) 启动恢复链路：从 `book.durChapterPos` 拷字段到 `ReadBook.durChapterPos`，typeset 完通过 `durPageIndex` getter 显示对应页

Flutter 当前现状：
- `TextPage` (lib/features/reader/page/text_page.dart) **已有 `startCharOffset` / `endCharOffset`** —— 复用，不改 schema
- `PageViewController.jumpToPage(int pageIndex)` 已存在（L302-L308）
- `ReaderProgressService.save / load` 服务**已经实现完整**（services/reader_progress_service.dart）；`SavedReadingProgress.offset` 字段对齐 `durChapterPos`
- `ReaderPage.initState` **没有任何 progress.load 调用**——直接 `_currentIndex = widget.chapterIndex`（路由的 query param，从书架进入永远是 0）
- `_onPageChanged` listener 只 `setState(() {})` —— **章内翻页完全不存进度**
- 现有保存调用点：`_onCrossChapterCommit`（跨章 commit 后）、`_loadPageModeChapter`（fallback 路径）、`_openChapter`（打开章节时）—— 都只存 chapterIndex，offset/paragraphIndex 一律传 0

## Assumptions (temporary)

- `TextPage.startCharOffset` 在 page_measure.dart 里已经被正确填充——需要快速核验（看到 L141-L149 的累加逻辑，看起来对，但要单测验证）
- 同章不同字号 / 行距下 startCharOffset 仍稳定指向同一个字符——用户改字号后 char offset 仍能反算正确页（page 边界变了但是字符 offset 不变）
- `progressService.load` 失败 / 无记录 → fallback 到 `widget.chapterIndex`（保留现有行为）

## Requirements

1. **启动恢复**：`ReaderPage.initState`（或更靠前的 build first frame）await `progressService.load(bookId)`：
   - 命中 → `_currentIndex = saved.chapterIndex`，typeset 完后 jumpToPage 到 `getPageIndexByCharOffset(saved.offset)`
   - 未命中（首次打开 / load 失败） → 保留 `_currentIndex = widget.chapterIndex`（旧行为）
2. **新增 controller API**：`PageViewController.getPageIndexByCharOffset(int charOffset)` —— 二分搜索 `pages[i].startCharOffset`，返回最接近的 page idx；空 pages → 0
3. **章内翻页保存**：`_onPageChanged` 在每次翻页都立即 `progressService.save(currentChapterIndex, currentPage.startCharOffset)`（不引入 debounce，对齐 MD3 行为；fire-and-forget 不阻塞 UI）
4. **跨章保存对齐**：`_onCrossChapterCommit` 的保存调用从 `paragraphIndex: 0, offset: 0` 改为 `offset: currentPage?.startCharOffset ?? 0`（commit 完位置就是新章第 0 页，offset = 0，行为不变但用相同代码路径）
5. **router 兼容**：`/reader?bookId=xxx` 不带 chapterIndex 时，仍然 fallback 到 0；DB 进度恢复在 ReaderPage 内部做（router 不改）

## Acceptance Criteria

- [ ] 单测：`PageViewController.getPageIndexByCharOffset` 在 0 / 中间 / 末尾 / 越界四种 charOffset 都返回正确 page idx
- [ ] 单测：`page_measure_test` 验证 `TextPage.startCharOffset` 单调递增、累加正确
- [ ] 单测：ReaderPage 加载流程 mock progressService 返回 (chapterIndex=5, offset=2000) → 预期 _currentIndex=5、jumpToPage 被调用并落到正确页
- [ ] 集成行为：章内翻 3 页 → kill app → 重开 → 仍在该章第 3 页（实机验证）
- [ ] 集成行为：跨章后再翻几页 → kill app → 重开 → 章节 + 页都对（实机验证）
- [ ] 测试套件 215+ 测试全绿

## Definition of Done

- flutter analyze 0 issue
- xvfb-run flutter test 全绿
- debug APK 实机验证通过（重开 app 不丢进度）
- commit 一次

## Technical Approach

### A. 复用现有 schema

- `TextPage.startCharOffset` 已存在 → 不改 model
- `SavedReadingProgress.offset` 已存在 → DB 字段语义直接对齐 `durChapterPos`
- `ReaderProgressService.load/save` 已实现 → 不改 service
- 不新增 `chapterPosition` 字段——`startCharOffset` 完全等价

### B. 新增 1 个 controller 方法

```dart
/// 用章内字符偏移反算页索引。pages 为空返回 0；offset < 0 返回 0；
/// offset 超过最后一页返回 lastIndex。
int getPageIndexByCharOffset(int charOffset) {
  final cur = _currentChapter;
  if (cur == null || cur.pages.isEmpty) return 0;
  if (charOffset <= 0) return 0;
  // 线性扫描足够（章内页数通常 < 50），未来可改二分
  for (int i = 0; i < cur.pages.length; i++) {
    final p = cur.pages[i];
    if (charOffset >= p.startCharOffset && charOffset <= p.endCharOffset) {
      return i;
    }
  }
  return cur.pages.length - 1; // offset 越界 → 末页
}
```

### C. ReaderPage 改造

```dart
@override
void initState() {
  super.initState();
  _currentIndex = widget.chapterIndex;
  ...
  _pageViewController = PageViewController(...);
  _pageViewController!.addListener(_onPageChanged);
  ...
  // 新增：异步恢复进度（不阻塞 initState）
  _restoreProgress();
}

Future<void> _restoreProgress() async {
  try {
    final dbPath = await ref.read(dbPathProvider.future);
    if (!mounted) return;
    final saved = await _progressService.load(
      dbPath: dbPath,
      bookId: widget.bookId,
    );
    if (saved == null || !mounted) return;
    // 改 _currentIndex 让 _openChapter 加载 saved chapter
    setState(() {
      _currentIndex = saved.chapterIndex;
      _restoreCharOffset = saved.offset;  // 暂存，loadChapter 完后用
    });
  } catch (e) {
    debugPrint('[Reader] restoreProgress failed: $e');
  }
}

// 在 _openChapter 完成 loadChapter 之后（或 _measureCurrentChapter 完成）
// postFrameCallback 调 jumpToPage(getPageIndexByCharOffset(savedOffset))
```

```dart
void _onPageChanged() {
  if (mounted) setState(() {});
  // 新增：章内翻页保存
  _saveCurrentPagePosition();
}

void _saveCurrentPagePosition() {
  final ctrl = _pageViewController;
  if (ctrl == null) return;
  final page = ctrl.currentPage;
  if (page == null) return;
  // fire-and-forget；不 await
  ref.read(dbPathProvider.future).then((dbPath) {
    if (!mounted) return;
    _progressService.save(
      dbPath: dbPath,
      bookId: widget.bookId,
      chapterIndex: ctrl.currentChapterIndex,
      offset: page.startCharOffset,
    );
  });
}
```

### D. 关键时序

```
打开书 (从书架 push /reader?bookId=xxx)
  ↓
initState: _currentIndex = 0; addListener; pageViewController init
  ↓ (并行 microtask)
  _restoreProgress() → load DB → saved.chapterIndex=5, offset=2000
  ↓ setState(_currentIndex = 5; _restoreCharOffset = 2000)
  ↓
build 触发 _openChapter(5)
  ↓
_loadChapterContent(5) → controller.loadChapter(5, content)
  ↓ measure pages
  ↓ postFrameCallback：
     idx = controller.getPageIndexByCharOffset(2000)
     controller.jumpToPage(idx)
  ↓
用户看到第 5 章第 N 页
```

## Decision (ADR-lite)

**Context**: 用户重开 app 不能从上次位置继续读，体验断裂。

**Decision**:
1. 复用 `TextPage.startCharOffset` 不改 model；用 char offset 而非 pageIndex 存 DB（page 边界会因字号变化而变，offset 稳定）。
2. 章内每翻一页立即异步保存（对齐 MD3，每翻一页 fire-and-forget save 任务给 Rust SQLite，无 debounce）——SQLite 在 Rust 端用 spawn_blocking 跑，不会阻塞 UI。
3. **首屏阻塞 loading（Option B）**：build 在 progress.load 完成前显示 loading 占位（复用现有 `_isLoadingContent`），避免"先闪现章 0 再跳章 5"的视觉跳变；DB 读入很快（< 100ms），用户从书架进入本就有"在加载"心理预期。
4. `_restoreProgress` 在 initState 末尾异步触发；首章 `_openChapter` **延后到 progress.load 完成**才发起，避免重复加载；jumpToPage 通过 postFrameCallback 在 loadChapter 完成后触发。

**Consequences**:
- 用户改字号 / 字体 / 行距后重开不丢进度（offset 稳定）
- 同步频率高：章内连翻 10 页 = 10 次写库，但 SQLite 单条 UPDATE 在 Rust 端 < 1ms 异步无感
- 与现有 `_onCrossChapterCommit` 的保存路径要保持代码一致（统一改成传 startCharOffset，避免两路语义不一致）
- 首屏多一次"等 progress.load"延时（约 50-150ms 内），但整体体验比"闪现错章节"好

## Out of Scope (explicit)

- 段落级 / 字符级精确恢复（saved.paragraphIndex 字段现存但本期不用，保留 0）
- 滚动模式（scroll mode）的进度恢复——本期只覆盖 page mode；scroll 模式后续单独 task
- T2/T3/T4 的内容（仿真镜像、回滚阈值、跨章预拉）

## Technical Notes

### 关键文件

- `lib/features/reader/page/text_page.dart` — 不改（已有 startCharOffset）
- `lib/features/reader/page/page_measure.dart` — 不改（已填充 startCharOffset）
- `lib/features/reader/page/page_view_controller.dart` — **加 `getPageIndexByCharOffset` 方法**
- `lib/features/reader/services/reader_progress_service.dart` — 不改
- `lib/features/reader/reader_page.dart` — **加 `_restoreProgress` + `_saveCurrentPagePosition` + `_onPageChanged` 调用**

### 测试文件

- `test/page_view_controller_test.dart`（如有，扩 `getPageIndexByCharOffset` 测试）
- `test/page_measure_test.dart`（如有，加 startCharOffset 单调性测试）

### 风险点

1. **time-of-check vs time-of-use**：用户重开 app 的同时换字号 → load 旧 offset 后 typeset 用新字号 → page 边界变 → jumpToPage 落在的"那一页"内容不完全是上次最后看到的字符。但用户**仍然不会丢上下文**（offset 在该页范围内）。可接受。
2. **首次打开书**：DB 无记录 → load 返回 null → fallback 到 widget.chapterIndex（=0），与现状一致。
3. **跨章保存代码路径**：`_onCrossChapterCommit` 现在也调 `_saveProgressAsync(newIndex)`——本期改成统一调 `_saveCurrentPagePosition()`（commit 后 currentPage 是新章首页，offset = 0，等价于 paragraphIndex=0/offset=0）。

## Research References

- [`research/md3-progress-storage.md`](research/md3-progress-storage.md) — MD3 进度存储/恢复链路逐字代码摘录
