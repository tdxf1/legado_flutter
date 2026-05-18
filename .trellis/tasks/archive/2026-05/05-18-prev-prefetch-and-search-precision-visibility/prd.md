# Task X2 + X3 — prev 跨章预拉对称化 + 精确搜索可见性

**用户实测报告 5 个 bug，本批修剩下 2 个**：
- Bug C: 从一章切换到下一章有动画了，但回到前一章会卡一下且没动画
- Bug A: 精确搜索没有实现（用户感觉没生效）

Task X1 已修 Bug B/D/E（仿真 currentTouch 实时驱动）。

## Goal

### X2 (Bug C)

让 prev 方向的章末预拉与 next 对称：进章后**立即并行**拉 prev/next 字符串，
让用户从首页往前翻时邻章已就绪，走完整跨章动画。

### X3 (Bug A)

让用户**看见**精确搜索 toggle 状态变化 + **已展示的结果立即重过滤**：
- AppBar 用 FilterChip 替代 IconButton（更明显）
- toggle 切换后弹 SnackBar 反馈
- 切换后如果 _results 已有内容，**立即对它重过滤**（即使 _searchCtrl 是空，也覆盖上次模糊搜索的结果）

## Background

### X2 — prev 预拉为何不对称

`reader_page.dart:1151 _preloadAdjacentContent`：

```dart
final prevIndex = currentIndex - 1;
if (prevIndex >= 0) {
  final prevContent = chapters[prevIndex]['content'] as String?;
  if (prevContent == null || prevContent.isEmpty) {
    _loadChapterContent(prevIndex, chapters).then((content) {
      // ...写回 chapters[prevIndex]['content'] + _measureAdjacentChapters
    });
  }
}
final nextIndex = currentIndex + 1;
// 同上 next 路径
```

**乍看对称**——但 `_loadChapterContent` 内部会查数据库 / 走 Rust API 拉。
若 prev 章节字符串还在数据库里没缓存（是 null/empty），就要走 Rust 拉。
这是异步且有 **rate limit / 排队** —— 而 `_openChapter` 在调
`_preloadAdjacentContent` 之前还调过 `_preCacheNextChapter`（**只 next**），
**抢先把 next 拉到了** 数据库 + 字符串。所以当 `_preloadAdjacentContent`
跑到时 next 已就绪 → 立即灌 controller；prev 仍要排队拉。

**Bug C 真正路径**：
1. 用户进章 N
2. `_preCacheNextChapter(N, chapters)` → 异步拉 N+1 写库
3. `_preloadAdjacentContent(N, chapters)` → prev N-1 + next N+1 并行拉
   - next 已经被 step 2 启动 → 实际 `_loadChapterContent(N+1)` 命中缓存或更早完成
   - prev N-1 是新启动，**晚到**
4. `_measureAdjacentChapters(N)` → controller 拿到 prev=null（content 还没回来）
5. 用户从首页往前翻 → controller.boundaryPrevPage == null → fallback 走
   `_onPageChapterBoundary` → `_loadPageModeChapter(N-1)` → 同步 setState
   → **无动画 + 卡顿**

**修法 X2**：

把 `_openChapter` 完成后的 prefetch 升级为**对称并行**：
- 加 `_preCachePrevChapter(N-1)` 或者在 `_preCacheNextChapter` 一起拉
- 让 prev 与 next 同时进入 fetch 队列

或者更轻量：**让 _onCrossChapterCommit 也立即触发 prev 预拉**，且
首次 `_openChapter` 完成时**用 Future.wait 同时拉 prev 和 next**（不阻塞）。

### X3 — 精确搜索为何看不见

`search_page.dart:498-512` 当前实现：
```dart
appBar: AppBar(
  title: const Text('搜索'),
  actions: [
    IconButton(
      icon: Icon(_precisionMode ? Icons.youtube_searched_for : Icons.search),
      tooltip: _precisionMode ? '精确搜索（已开启）' : '模糊搜索',
      onPressed: _togglePrecisionMode,
    ),
  ],
),
```

问题：
1. 默认是 `Icons.search`（搜索图标），与 TextField prefixIcon `Icons.search`
   视觉重复，用户**根本注意不到** AppBar 这里有个独立 toggle
2. tooltip 只在长按时显示，移动用户基本看不到
3. `_togglePrecisionMode` (line 79-86) 切换后只在 `_searchCtrl.text` 非空
   时重跑 _doSearch；但 `_searchCtrl.text` 是 TextField 的当前内容，可能
   已被用户清空，**已显示的结果不会被重过滤**

**修法 X3**：
1. AppBar 改用 `FilterChip(label: '精确')` 加 `selected` 状态
   - 比 IconButton 视觉更显眼
   - 选中态有明显 Material 高亮
2. toggle 切换后弹 SnackBar："已切换到精确/模糊搜索"
3. toggle 切换后**先尝试对已显示的 _results 重过滤**：
   - 加字段 `_lastSearchKeyword`：每次 `_doSearch` 把 keyword 写入这个字段
   - toggle 时若 `_lastSearchKeyword` 非空，对 `_results.value` 重过滤而不
     是重跑搜索（节省网络）
   - 若 `_lastSearchKeyword` 为空（用户从未搜过）则只切换状态

## Requirements

### X2 — prev 对称预拉

- **X2.1** 加 `_preCachePrevChapter(int currentIndex, List chapters)`：
  类似 `_preCacheNextChapter` 行为，但拉 prev 方向。`currentIndex - 1 >= 0`
  且 `chapters[prevIndex]['content']` 为 null/empty 时拉。fetch 完写库
  + 写 chapters[prevIndex]['content']
- **X2.2** `_openChapter` 完成后调用点（line 524 附近）现在调
  `_preCacheNextChapter`，加 `_preCachePrevChapter` 同位置
- **X2.3** `_loadPageModeChapter` 完成后（line 1769 附近）同样调
- **X2.4** `_onCrossChapterCommit` (line 1820 附近) 也加 prev 预拉
- **X2.5** 测试覆盖：mock chapters, 模拟 _openChapter → 验证 prev 字符串被
  fetch 写入 chapters[prev]['content']

### X3 — 精确搜索可见性

- **X3.1** `search_page.dart` 加字段 `String _lastSearchKeyword = ''`
- **X3.2** `_doSearch` 入口把 `keyword` 写入 `_lastSearchKeyword`
  (赋值时机：在 trim 之后、刚验证非空之时)
- **X3.3** `_togglePrecisionMode` 改逻辑：
  ```
  setState(() => _precisionMode = !_precisionMode)
  unawaited(saveSearchPrecisionToDisk(...))
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(_precisionMode ? '已切换到精确搜索' : '已切换到模糊搜索'),
    duration: const Duration(seconds: 1)))
  if (_lastSearchKeyword.isNotEmpty) _doSearch();  // 用记忆 keyword 重跑
  ```
  注意：`_doSearch` 内部仍读 `_searchCtrl.text.trim()`；如果用户清空了
  TextField，重跑会拿到空——不行。改成：`_doSearch` 接受可选
  `String? overrideKeyword`，toggle 用 `_doSearch(overrideKeyword: _lastSearchKeyword)`。
  或者：toggle 时先把 `_lastSearchKeyword` 写回 `_searchCtrl.text`，再
  `_doSearch()`。后者简单。
- **X3.4** AppBar UI 改：用 Padding + FilterChip 替代 IconButton：
  ```dart
  Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
    child: FilterChip(
      label: const Text('精确'),
      selected: _precisionMode,
      onSelected: (_) => _togglePrecisionMode(),
      avatar: Icon(_precisionMode
          ? Icons.youtube_searched_for
          : Icons.search_off, size: 18),
    ),
  ),
  ```
- **X3.5** 测试覆盖：
  - toggle 后 `_lastSearchKeyword` 已记忆且 SnackBar fire
  - FilterChip selected 状态跟 _precisionMode 同步

## Acceptance Criteria

- [ ] _preCachePrevChapter 实现 + 三个调用点植入
- [ ] _doSearch 记忆 _lastSearchKeyword
- [ ] _togglePrecisionMode 用记忆 keyword 重跑 + SnackBar
- [ ] AppBar 改用 FilterChip
- [ ] flutter analyze 0 issue
- [ ] xvfb-run flutter test 全绿（208 baseline + 新增）
- [ ] reader 既有测试无 regression
- [ ] search 既有测试无 regression（注意 search_page_test.dart 数 Icons.search
      的逻辑可能需调）

## Definition of Done

- 单一 commit "第三十批 — prev 对称预拉 + 精确搜索 FilterChip"
- libbridge.so / Rust / FRB 零改动

## Technical Approach

### X2: _preCachePrevChapter

参考已有 `_preCacheNextChapter`（line ~1051-1149）：

```dart
Future<void> _preCachePrevChapter(
    int currentIndex, List<Map<String, dynamic>> chapters) async {
  final prevIndex = currentIndex - 1;
  if (prevIndex < 0) return;
  if (_settings.isScrollMode) return;  // 滚动模式有自己机制
  final prevContent = chapters[prevIndex]['content'] as String?;
  if (prevContent != null && prevContent.isNotEmpty) return;  // 已就绪
  try {
    final dbPath = await ref.read(dbPathProvider.future);
    if (!mounted) return;
    final cached = await rust_api.getChapterContent(
      dbPath: dbPath,
      chapterId: chapters[prevIndex]['id'] as String? ?? '',
    );
    if (cached.isNotEmpty) {
      chapters[prevIndex]['content'] = cached;
      if (mounted) _measureAdjacentChapters(_currentIndex);
      return;
    }
    // 缓存空 → 拉网络（同 _preCacheNextChapter 的逻辑）
    final url = chapters[prevIndex]['url'] as String? ?? '';
    final book = await ref.read(bookByIdProvider(widget.bookId).future);
    if (!mounted || book == null || url.isEmpty) return;
    final content = await rust_api.fetchChapterContent(
      dbPath: dbPath,
      sourceJson: ...,  // 视具体 API 而定
      chapterUrl: url,
    );
    if (content.isNotEmpty) {
      chapters[prevIndex]['content'] = content;
      await rust_api.updateChapterContent(
        dbPath: dbPath,
        chapterId: chapters[prevIndex]['id'] as String? ?? '',
        content: content,
      );
      if (mounted) _measureAdjacentChapters(_currentIndex);
    }
  } catch (e) {
    debugPrint('[Reader] preCachePrevChapter failed: $e');
  }
}
```

注意需要看 `_preCacheNextChapter` 实际签名再镜像写。如果太复杂，**简化**：
不重复 _preCacheNextChapter 的所有 fetch 逻辑，直接复用 `_loadChapterContent`：

```dart
Future<void> _preCachePrevChapter(
    int currentIndex, List<Map<String, dynamic>> chapters) async {
  final prevIndex = currentIndex - 1;
  if (prevIndex < 0) return;
  final prevContent = chapters[prevIndex]['content'] as String?;
  if (prevContent != null && prevContent.isNotEmpty) return;
  try {
    final content = await _loadChapterContent(prevIndex, chapters);
    if (!mounted) return;
    if (content.isNotEmpty) {
      chapters[prevIndex]['content'] = content;
      _measureAdjacentChapters(_currentIndex);
    }
  } catch (e) {
    debugPrint('[Reader] preCachePrevChapter failed: $e');
  }
}
```

`_loadChapterContent` 已经处理了缓存命中、Rust API 调用等。但要确认它**写库**
（与 `_preCacheNextChapter` 行为对齐）。如果 `_loadChapterContent` 不写库，
prev 章下次进入还要重拉。看 implement agent 实施时再决定。

### 调用点

- `_openChapter` line ~524：`_preloadAdjacentContent(index, chapters)` 后加
  `_preCachePrevChapter(index, chapters)`
- `_loadPageModeChapter` line ~1769：同样
- `_onCrossChapterCommit` line ~1820：调 `_preCachePrevChapter` + 已有
  `_preloadAdjacentContent` 也已经在调 → 但 `_preloadAdjacentContent` 内部
  的 prev fetch 也会启动；与 `_preCachePrevChapter` 重复但幂等

实际上 `_preloadAdjacentContent` 已经异步拉 prev 字符串了。**Bug C 的真正
根因可能是 `_preloadAdjacentContent` 触发太晚 / 被串行 await 阻塞**，而不是
没拉。需要再核查：`_openChapter` line 524 调 `_preloadAdjacentContent` 是
不 await 的（fire and forget）；OK。

但 `_preloadAdjacentContent` 内 `_loadChapterContent(prevIndex)` 可能很慢
（缓存 miss + 网络）。如果 next 章节早被 `_preCacheNextChapter` 拉过，next
fetch 立即命中缓存返回，prev 仍 cold start。

**X2 真正需要的**：进章后**第一时间**对 prev 也启动一次"网络预拉 + 写库"，
让下次进章命中缓存。`_preCacheNextChapter` 已是这种语义。**X2 = 给 prev
加同样的 _preCachePrevChapter**。

### X3 实施

核心三处：
- `_lastSearchKeyword` 字段记忆
- `_togglePrecisionMode` 重跑用记忆 keyword + SnackBar
- AppBar UI 改 FilterChip

详见 Requirements。

### 测试调整

`search_page_test.dart` 现在数 `Icons.search` 出现次数（前批 Task 1 加了
toggle UI 改成 +1）。本批换成 FilterChip + Icons.search_off / youtube_searched_for，
icon 数量会变。需要调整测试用 `find.byType(FilterChip)` 而不是数 icon。

## Out of Scope

- Task X1 的 onAnimTick / lerp 逻辑（已完成）
- 仿真 prev 几何不对称
- Curve 改 linear
- Rust / FRB / libbridge.so

## Technical Notes

### 关键 file:line

- `flutter_app/lib/features/reader/reader_page.dart:1051-1149` — _preCacheNextChapter
- `flutter_app/lib/features/reader/reader_page.dart:1151-1184` — _preloadAdjacentContent
- `flutter_app/lib/features/reader/reader_page.dart:520-528` — _openChapter prefetch 调用点
- `flutter_app/lib/features/reader/reader_page.dart:1769-1770` — _loadPageModeChapter prefetch 调用点
- `flutter_app/lib/features/reader/reader_page.dart:1820-1823` — _onCrossChapterCommit prefetch 调用点
- `flutter_app/lib/features/search/search_page.dart:498-512` — AppBar
- `flutter_app/lib/features/search/search_page.dart:79-86` — _togglePrecisionMode
- `flutter_app/lib/features/search/search_page.dart:223-` — _doSearch（要记忆 keyword）

### 命令前缀

- `flutter --no-version-check analyze`
- `xvfb-run -a flutter --no-version-check test`
- 工作目录 flutter_app/
