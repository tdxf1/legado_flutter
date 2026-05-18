# Subtask B — ReaderPage 邻章预加载灌入 controller

**父任务**: `05-18-cross-chapter-animation`
**前置**: Subtask A 完成 (commit d62f11e)，PageViewController 已支持 ChapterWindow + setNeighborChapter

## Goal

在 ReaderPage 加 `_measureAdjacentChapters(int currentIndex)` 方法，把 `_cachedChapters[i]['content']` 字符串 prefetch 转化为 PageMeasure 测量好的 textPages，再通过 `pageViewController.setNeighborChapter(...)` 灌入 controller。让 Subtask C 后续接力 delegate 跨章动画时，邻章 firstPage / lastPage 已就绪。

只动 ReaderPage 一个文件 + 加 widget 测试。**不动 PageViewController（已 Subtask A 完成）也不动 PageDelegate（Subtask C 范围）**。

## Background

### Subtask A 给 ReaderPage 的契约

```dart
// PageViewController API (Subtask A)
class ChapterWindow {
  final int chapterIndex;
  final String title;
  final String content;
  const ChapterWindow({...});
}

class PageViewController extends ChangeNotifier {
  void setNeighborChapter({ChapterWindow? prev, ChapterWindow? next});
  // ... boundaryNextPage / boundaryPrevPage / commitToNextChapter etc
}
```

### ReaderPage 现有数据流

```dart
// _openChapter (line 444 ish):
_cachedChapters = chapters;
setState(() => _currentIndex = index);
final content = await _loadChapterContent(index, chapters);
setState(() {
  _chapterContent = content;
  _pageViewController?.loadChapter(index, title, content);
});
_preCacheNextChapter(index, chapters);    // ← 已有：fetch 下章字符串
_preloadAdjacentContent(index, chapters); // ← 已有：fetch 上下章字符串

// _loadPageModeChapter (line 1652):
// 从 _onPageChapterBoundary 触发的章末翻页路径，与 _openChapter 类似
```

`_preloadAdjacentContent` 已经把 `chapters[i-1]['content']` 和 `chapters[i+1]['content']` 字符串拉到 _cachedChapters 数组里。本子任务在拉完后**进一步把字符串灌进 controller**。

## Requirements

- **B.1**：加 `void _measureAdjacentChapters(int currentIndex)`：
  - 从 `_cachedChapters[currentIndex - 1]` / `[currentIndex + 1]` 拿 content / title / chapterIndex
  - 如果 content 已 fetch（非 null 非空）→ 包装成 `ChapterWindow(chapterIndex, title, content)` 灌进 `pageViewController.setNeighborChapter(prev:, next:)`
  - 如果 content 还没 fetch → 灌 null（或保留旧 prev/next 不变 — 决策见下）
  - 边界：currentIndex == 0 → prev=null；currentIndex == chapters.length-1 → next=null
- **B.2**：在 `_openChapter` 完成后调 `_measureAdjacentChapters(_currentIndex)`（与现有 `_preCacheNextChapter` / `_preloadAdjacentContent` 同位置）
- **B.3**：在 `_loadPageModeChapter` 完成后调 `_measureAdjacentChapters(targetIndex)`
- **B.4**：把现有 `_preloadAdjacentContent` 改造：当 fetch 字符串成功后，再次调 `_measureAdjacentChapters(_currentIndex)` 让 controller 收到刚 fetch 的内容
- **B.5**：处理 race：用户快速切多个章节时，老的 _measureAdjacentChapters 不能覆盖新的。用 _chapterRequestId 或 mounted check 防御
- **B.6**：在 settings 排版字段变化时（_setReaderSettings 路径）调 _measureAdjacentChapters 重灌（PageViewController 在 updateSettings 已自动清三章 pages，外层只需重灌邻章）
- **B.7**：测试覆盖（widget test）：
  - mock _cachedChapters，验证 _measureAdjacentChapters 调 controller.setNeighborChapter 时 ChapterWindow 字段正确
  - 边界：第一章只灌 next；最后一章只灌 prev
  - content 缺失：不该灌（avoid 灌空 content 让 controller 测出空 pages）
  - settings 变化触发重灌
- **B.8**：分析 / 测试不退化

## Acceptance Criteria

- [ ] ReaderPage._measureAdjacentChapters 实现
- [ ] _openChapter / _loadPageModeChapter / _preloadAdjacentContent / _setReaderSettings 调用点添加
- [ ] race / mounted 检查覆盖
- [ ] 新增测试 `flutter_app/test/reader_measure_adjacent_test.dart` ≥ 5 用例
- [ ] flutter --no-version-check analyze 0 issue
- [ ] xvfb-run flutter test 全绿（162 baseline + 新增）
- [ ] 既有 reader_page_test / reader_page_anim_test 不退化

## Definition of Done

- 单一 commit "第二十六批 — Task 2B reader 邻章预加载灌入 controller"
- libbridge.so / Rust / FRB 零改动
- PageDelegate / PageViewWidget / PageViewController 零改动（除调用方法）

## Technical Approach

### _measureAdjacentChapters 实现

```dart
/// Subtask B: 把已预加载的邻章字符串内容灌进 PageViewController，
/// 让 delegate 跨章动画期间能渲染邻章首/末页 picture。
///
/// 调用时机：
///   - _openChapter 完成后（进章触发）
///   - _loadPageModeChapter 完成后（章末翻页触发）
///   - _preloadAdjacentContent 完成 fetch 字符串后（异步触发）
///   - _setReaderSettings 排版字段变化后（重测触发）
///
/// 安全语义：
///   - 邻章 content 缺失 (null/empty) → 灌 null，由 fallback boundary 回退
///   - currentIndex 边界 (首章/末章) → 对应方向灌 null
///   - controller 不在 page mode 时（continuousScroll）skip — 滚动模式
///     自己在 _ensureCurrentChapterInContinuous 处理
void _measureAdjacentChapters(int currentIndex) {
  final ctrl = _pageViewController;
  if (ctrl == null) return;
  if (_settings.isScrollMode) return;  // 滚动模式不需要
  final chapters = _cachedChapters;
  if (chapters == null) return;

  ChapterWindow? prev;
  if (currentIndex > 0) {
    final prevMap = chapters[currentIndex - 1];
    final prevContent = prevMap['content'] as String?;
    if (prevContent != null && prevContent.isNotEmpty) {
      prev = ChapterWindow(
        chapterIndex: currentIndex - 1,
        title: prevMap['title'] as String? ?? '',
        content: prevContent,
      );
    }
  }

  ChapterWindow? next;
  if (currentIndex < chapters.length - 1) {
    final nextMap = chapters[currentIndex + 1];
    final nextContent = nextMap['content'] as String?;
    if (nextContent != null && nextContent.isNotEmpty) {
      next = ChapterWindow(
        chapterIndex: currentIndex + 1,
        title: nextMap['title'] as String? ?? '',
        content: nextContent,
      );
    }
  }

  ctrl.setNeighborChapter(prev: prev, next: next);
}
```

### 调用点植入

#### _openChapter (line 476-477 附近)
```dart
_preCacheNextChapter(index, chapters);
_preloadAdjacentContent(index, chapters);
_measureAdjacentChapters(index);  // ← 新增
_fetchSourceInfo();
```

#### _loadPageModeChapter (line 1683 附近)
```dart
_pageViewController?.updateSettings(_settings);
_pageViewController?.loadChapter(targetIndex, title, content,
    jumpToLast: isPrev);
_preloadAdjacentContent(targetIndex, chapters);
_measureAdjacentChapters(targetIndex);  // ← 新增
```

#### _preloadAdjacentContent (line 1101-1107 附近)
```dart
_loadChapterContent(prevIndex, chapters).then((content) {
  if (content.isNotEmpty) {
    chapters[prevIndex]['content'] = content;
    if (mounted) _measureAdjacentChapters(_currentIndex);  // ← 新增
  }
}).catchError((Object e) {
  debugPrint('[Reader] preload prev chapter failed: $e');
});

// 同样改 next 路径
```

#### _setReaderSettings 排版字段变化
```dart
// 已有 _settings 更新，pageViewController.updateSettings 在内部调
// 这里加：
if (_pageViewController != null && !_settings.isScrollMode) {
  _measureAdjacentChapters(_currentIndex);
}
```

需要看 _setReaderSettings 当前实现来精准插入。审计已有 `_pageViewController?.updateSettings(_settings)` 调用点附近加。

### Race & mounted

- `_measureAdjacentChapters` 内部已通过 `_pageViewController == null` 早 return
- 调用方在 callback 里加 `if (mounted)` 守卫（_preloadAdjacentContent 的 then 回调已是异步路径）
- _chapterRequestId：现有机制保护 _openChapter 主路径已足够；_measureAdjacentChapters 只读 _cachedChapters[i]，幂等，不需要额外 race guard

### 测试

新增 `flutter_app/test/reader_measure_adjacent_test.dart`，重点不需要构造完整 ReaderPage（重）— 直接测 _measureAdjacentChapters 逻辑。但 _measureAdjacentChapters 是 ReaderPage private 实例方法...

**两种测试策略**：

**A. 抽出工具函数**（推荐）：把核心 logic 抽成 `static List<ChapterWindow?> computeAdjacentWindows(int currentIndex, List<Map> chapters)` 静态函数（不依赖 ReaderPage 实例），单测它；然后 ReaderPage._measureAdjacentChapters 调它 + 调 setNeighborChapter

```dart
// 在 reader_page.dart 加 static
@visibleForTesting
static (ChapterWindow?, ChapterWindow?) computeAdjacentWindows(
    int currentIndex, List<Map<String, dynamic>>? chapters) {
  if (chapters == null) return (null, null);
  ChapterWindow? prev;
  if (currentIndex > 0) {
    final m = chapters[currentIndex - 1];
    final c = m['content'] as String?;
    if (c != null && c.isNotEmpty) {
      prev = ChapterWindow(
        chapterIndex: currentIndex - 1,
        title: m['title'] as String? ?? '',
        content: c,
      );
    }
  }
  ChapterWindow? next;
  if (currentIndex < chapters.length - 1) {
    final m = chapters[currentIndex + 1];
    final c = m['content'] as String?;
    if (c != null && c.isNotEmpty) {
      next = ChapterWindow(
        chapterIndex: currentIndex + 1,
        title: m['title'] as String? ?? '',
        content: c,
      );
    }
  }
  return (prev, next);
}
```

**B. Widget integration test**（重）：构造 ReaderPage + mock dbPath + 灌 _cachedChapters via init args... 复杂度高。

**采用 A**：抽工具函数；测试调静态函数 + 直接构造 PageViewController + 调用 setNeighborChapter 验证 ChapterWindow 字段。

测试用例：
1. currentIndex=0 → prev=null, next 有效 (next content 已就绪)
2. currentIndex=last → prev 有效, next=null
3. currentIndex 中间 → prev/next 都有效
4. 邻章 content 为 null → 对应方向 ChapterWindow=null
5. 邻章 content 为空字符串 → 对应方向 ChapterWindow=null
6. chapters=null → (null, null)
7. ChapterWindow 字段值正确（title/chapterIndex/content）

## Risk & Mitigation

- **isScrollMode skip**：滚动模式有自己的多章节加载机制（_loadedChapters / _cachedContinuousItems），_measureAdjacentChapters 跳过即可。Settings 切换 page↔scroll 模式时由 _setReaderSettings 重新触发
- **_preloadAdjacentContent 的 then 回调晚到**：用户进章 N 后立即跳到章 M，_preloadAdjacentContent 异步 then 回调可能更晚到达。回调里检查 `_currentIndex == targetIndex` 等。但 `chapters[i]['content']` 写到 cachedChapters 是幂等的（同一章节同一内容），无害
- **memory**：每次 setNeighborChapter 触发 measure 邻章 ~500KB textPages × 2 = ~1MB。窗口外章节由 controller 自动释放（Subtask A 已实现）
- **第二次进章 cur=N+1，prev/next 重新 measure**：测量耗时取决于章节长度。100ms 内可接受，用户感觉不到
- **测试 hooks 污染 production API**：用 `@visibleForTesting` static fn 不暴露给运行时

## Out of Scope

- 不改 PageDelegate（Subtask C 范围）
- 不改 PageViewController（Subtask A 已完成）
- 不改滚动模式 _ensureCurrentChapterInContinuous
- 不引入 LRU / 多章节窗口
- 不动 Rust / FRB / libbridge.so

## Technical Notes

### 关键 file:line

- `flutter_app/lib/features/reader/reader_page.dart:444-486` — _openChapter
- `flutter_app/lib/features/reader/reader_page.dart:1652-1687` — _loadPageModeChapter
- `flutter_app/lib/features/reader/reader_page.dart:1095-1123` — _preloadAdjacentContent
- `flutter_app/lib/features/reader/reader_page.dart:488-540` — _setReaderSettings (Setting 入口)
- `flutter_app/lib/features/reader/page/page_view_controller.dart` — Subtask A 已加 ChapterWindow / setNeighborChapter

### 命令前缀

- `flutter --no-version-check analyze`
- `xvfb-run -a flutter --no-version-check test`
- 工作目录 flutter_app/

## Research References

无（基于父任务和 Subtask A 已有架构）。
