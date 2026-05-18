# Subtask A — PageViewController 三章节窗口重构

**父任务**: `05-18-cross-chapter-animation`

## Goal

把 `flutter_app/lib/features/reader/page/page_view_controller.dart` 从单章节模型重构为三章节窗口（prev / cur / next），暴露 `boundaryNextPage` / `boundaryPrevPage` 跨章 getter + `setNeighborChapter` / `commitToNextChapter` / `commitToPrevChapter` 操作。**不动外层 ReaderPage 调用**——loadChapter API 兼容，旧路径 fallback 安全。

只做 controller 内部的状态机重构 + 单元测试，跨章动画那块由 Subtask C 接力。

## Requirements

- **A.1**：内部加 `_ChapterModel` 不可变值对象（title / paragraphs / pages / currentPageIndex），3 个字段：`_currentChapter` / `_prevChapter` / `_nextChapter`
- **A.2**：保留所有现有 public API 行为（loadChapter / clearChapter / jumpToPage / goToNextPage / goToPrevPage / hasNext / hasPrev / nextPage / prevPage / currentPage / currentChapterIndex / currentPageIndex / totalPagesInChapter / settings / updateSettings / updatePageSize）
- **A.3**：新增 public API：
  - `setNeighborChapter({_ChapterModel? prev, _ChapterModel? next})` — 由外层灌邻章
  - `boundaryNextPage` getter — 当本章末页时返回 `_nextChapter?.firstPage`，否则 null（用于 delegate 渲染）
  - `boundaryPrevPage` getter — 当本章首页时返回 `_prevChapter?.lastPage`，否则 null
  - `commitToNextChapter()` — 把 `_nextChapter` 提升为 `_currentChapter`，currentPageIndex=0，旧 cur 降为 prev，旧 prev 释放（变 null），返回 true 成功
  - `commitToPrevChapter()` — 把 `_prevChapter` 提升为 `_currentChapter`，currentPageIndex=last，旧 cur 降为 next
- **A.4**：updateSettings 影响布局时清空 cur 的 pages（仍允许重测）；prev / next 也清 pages 让外层重新灌
- **A.5**：updatePageSize 同样清三章 pages
- **A.6**：clearChapter 清三章
- **A.7**：单元测试覆盖：
  - 默认空 controller boundaryNextPage / boundaryPrevPage 为 null
  - loadChapter 后 setNeighborChapter(next:...) → 翻到末页 boundaryNextPage 不为 null
  - commitToNextChapter 后 currentChapter 切换、prev 升级、next 清空
  - 不可越界 commit (next/prev 为 null 时 commit 返回 false)
  - 同一时刻 prev / next / cur 三章 chapterIndex 必须递增
- **A.8**：保持 `_chapterTitle` / `_paragraphs` / `_pages` / `_currentPageIndex` 字段（测试可能直接访问）但内部用 currentChapter 模型——可以保留 getter shim 兼容

## Acceptance Criteria

- [ ] PageViewController 重构后所有现有调用方仍编译通过
- [ ] 新增 4 个 public API（setNeighborChapter / boundaryNextPage / boundaryPrevPage / commitToNextChapter / commitToPrevChapter）
- [ ] flutter --no-version-check analyze 0 issue
- [ ] xvfb-run flutter test 全套 141+ 用例无 regression
- [ ] 新增单元测试 `flutter_app/test/page_view_controller_window_test.dart` ≥ 8 用例

## Definition of Done

- 单一 commit "第二十五批 — Task 2A controller 三章节窗口"
- libbridge.so / Rust / FRB 零改动
- ReaderPage / PageDelegate / PageViewWidget 零改动

## Technical Approach

### _ChapterModel

```dart
@immutable
class _ChapterModel {
  final int chapterIndex;
  final String title;
  final List<String> paragraphs;
  final List<TextPage> pages;
  final int currentPageIndex;

  const _ChapterModel({
    required this.chapterIndex,
    required this.title,
    required this.paragraphs,
    this.pages = const [],
    this.currentPageIndex = 0,
  });

  TextPage? get currentPage => 
    (currentPageIndex >= 0 && currentPageIndex < pages.length)
      ? pages[currentPageIndex] : null;

  TextPage? get firstPage => pages.isNotEmpty ? pages.first : null;
  TextPage? get lastPage => pages.isNotEmpty ? pages.last : null;

  TextPage? get nextPage => 
    (currentPageIndex + 1 < pages.length) ? pages[currentPageIndex + 1] : null;
  TextPage? get prevPage =>
    (currentPageIndex > 0) ? pages[currentPageIndex - 1] : null;

  bool get hasNext => currentPageIndex + 1 < pages.length;
  bool get hasPrev => currentPageIndex > 0;
  int get totalPages => pages.length;

  _ChapterModel copyWith({
    int? chapterIndex,
    String? title,
    List<String>? paragraphs,
    List<TextPage>? pages,
    int? currentPageIndex,
  }) =>
    _ChapterModel(
      chapterIndex: chapterIndex ?? this.chapterIndex,
      title: title ?? this.title,
      paragraphs: paragraphs ?? this.paragraphs,
      pages: pages ?? this.pages,
      currentPageIndex: currentPageIndex ?? this.currentPageIndex,
    );
}
```

### Controller 重构（保 API 兼容）

```dart
class PageViewController extends ChangeNotifier {
  _ChapterModel? _currentChapter;
  _ChapterModel? _prevChapter;
  _ChapterModel? _nextChapter;

  ReaderSettings _settings;
  Size _pageSize = Size.zero;
  bool _disposed = false;
  VoidCallback? onTapNext;
  VoidCallback? onTapPrev;

  // ── Public API getters (保兼容) ────────────────────────────────
  int get currentChapterIndex => _currentChapter?.chapterIndex ?? 0;
  int get currentPageIndex => _currentChapter?.currentPageIndex ?? 0;
  ReaderSettings get settings => _settings;

  TextPage? get currentPage => _currentChapter?.currentPage;
  TextPage? get nextPage => _currentChapter?.nextPage;
  TextPage? get prevPage => _currentChapter?.prevPage;

  bool get hasNext => _currentChapter?.hasNext ?? false;
  bool get hasPrev => _currentChapter?.hasPrev ?? false;

  int get totalPagesInChapter => _currentChapter?.totalPages ?? 0;

  // ── 跨章 getter ────────────────────────────────────────────────
  /// 本章末页时返回下一章首页 textPage（用于 delegate.onDragStart 渲染 nextPicture）
  TextPage? get boundaryNextPage {
    final cur = _currentChapter;
    if (cur == null) return null;
    final isLast = cur.currentPageIndex == cur.pages.length - 1;
    if (!isLast) return null;
    return _nextChapter?.firstPage;
  }

  /// 本章首页时返回上一章末页 textPage
  TextPage? get boundaryPrevPage {
    final cur = _currentChapter;
    if (cur == null) return null;
    final isFirst = cur.currentPageIndex == 0;
    if (!isFirst) return null;
    return _prevChapter?.lastPage;
  }

  // ── 邻章注入 / 提升 / 清理 ──────────────────────────────────────

  /// 由外层 ReaderPage 在 _measureAdjacentChapters 完成后调用，灌入邻章。
  /// 任一参数为 null 表示清空对应邻章。
  void setNeighborChapter({_ChapterModel? prev, _ChapterModel? next}) {
    _prevChapter = prev;
    _nextChapter = next;
    notifyListeners();
  }

  /// 把 nextChapter 提升为 currentChapter（动画完成时调）。
  /// 旧 currentChapter 降级为 prevChapter，旧 prevChapter 释放。
  /// 返回 true=成功；false=没有 nextChapter（外层应走 fallback）
  bool commitToNextChapter() {
    final next = _nextChapter;
    if (next == null) return false;
    _prevChapter = _currentChapter;
    _currentChapter = next.copyWith(currentPageIndex: 0);
    _nextChapter = null;
    notifyListeners();
    return true;
  }

  /// 把 prevChapter 提升为 currentChapter，旧 cur 降级为 next，旧 next 释放
  bool commitToPrevChapter() {
    final prev = _prevChapter;
    if (prev == null) return false;
    _nextChapter = _currentChapter;
    final lastIdx = prev.pages.isEmpty ? 0 : prev.pages.length - 1;
    _currentChapter = prev.copyWith(currentPageIndex: lastIdx);
    _prevChapter = null;
    notifyListeners();
    return true;
  }

  // ── 现有 API 兼容实现（路由到 _currentChapter）─────────────────

  void loadChapter(int index, String title, String content,
      {bool jumpToLast = false}) {
    final paragraphs = content
        .split(RegExp(r'\n+'))
        .where((p) => p.trim().isNotEmpty)
        .toList();
    _currentChapter = _ChapterModel(
      chapterIndex: index,
      title: title,
      paragraphs: paragraphs,
      pages: const [],
      currentPageIndex: 0,
    );
    // 注意：loadChapter 不动 prev/next，让外层 setNeighborChapter 自己管
    // 但如果 index 与现有 prev/next chapterIndex 不连续（用户跳章），清空它们
    if (_prevChapter != null && _prevChapter!.chapterIndex != index - 1) {
      _prevChapter = null;
    }
    if (_nextChapter != null && _nextChapter!.chapterIndex != index + 1) {
      _nextChapter = null;
    }
    _measureCurrentChapterIfNeeded(jumpToLast: jumpToLast);
  }

  void clearChapter() {
    _currentChapter = null;
    _prevChapter = null;
    _nextChapter = null;
  }

  void jumpToPage(int pageIndex) {
    final cur = _currentChapter;
    if (cur == null || cur.pages.isEmpty) return;
    final clamped = pageIndex.clamp(0, cur.pages.length - 1);
    _currentChapter = cur.copyWith(currentPageIndex: clamped);
    notifyListeners();
  }

  bool goToNextPage() {
    final cur = _currentChapter;
    if (cur == null) return false;
    if (cur.currentPageIndex + 1 < cur.pages.length) {
      _currentChapter = cur.copyWith(currentPageIndex: cur.currentPageIndex + 1);
      notifyListeners();
      return true;
    }
    return false;
  }

  bool goToPrevPage() {
    final cur = _currentChapter;
    if (cur == null) return false;
    if (cur.currentPageIndex > 0) {
      _currentChapter = cur.copyWith(currentPageIndex: cur.currentPageIndex - 1);
      notifyListeners();
      return true;
    }
    return false;
  }

  void updatePageSize(Size size) {
    _pageSize = size;
    // 只对 currentChapter 触发测量（邻章由外层 _measureAdjacentChapters 管）
    _measureCurrentChapterIfNeeded();
  }

  void updateSettings(ReaderSettings settings) {
    final layoutChanged = _settings.fontSize != settings.fontSize ||
        _settings.fontWeightIndex != settings.fontWeightIndex ||
        _settings.fontFamily != settings.fontFamily ||
        _settings.letterSpacing != settings.letterSpacing ||
        _settings.lineHeight != settings.lineHeight ||
        _settings.paragraphSpacing != settings.paragraphSpacing ||
        _settings.horizontalPadding != settings.horizontalPadding ||
        _settings.verticalPadding != settings.verticalPadding ||
        _settings.paragraphIndent != settings.paragraphIndent;
    _settings = settings;
    if (layoutChanged) {
      // 三章都需要重测（外层会调 setNeighborChapter 重灌）
      if (_currentChapter != null) {
        _currentChapter = _currentChapter!.copyWith(pages: const []);
      }
      _prevChapter = null;
      _nextChapter = null;
      _measureCurrentChapterIfNeeded();
    }
  }

  void _measureCurrentChapterIfNeeded({bool jumpToLast = false}) {
    final cur = _currentChapter;
    if (cur == null) return;
    if (cur.paragraphs.isEmpty) return;
    if (cur.pages.isNotEmpty) return;
    if (_pageSize.width <= 0 || _pageSize.height <= 0) return;
    _measureChapter(jumpToLast: jumpToLast);
  }

  void _measureChapter({bool jumpToLast = false}) {
    final cur = _currentChapter;
    if (cur == null) return;
    final chapterIndex = cur.chapterIndex;

    final measure = PageMeasure(
      settings: _settings,
      pageSize: _pageSize,
      chapterTitle: cur.title,
    );
    final result = measure.measureChapter(chapterIndex, cur.paragraphs);

    var newPageIndex = cur.currentPageIndex;
    if (jumpToLast && result.pages.isNotEmpty) {
      newPageIndex = result.pages.length - 1;
    }
    _currentChapter = cur.copyWith(
      pages: result.pages,
      currentPageIndex: newPageIndex,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed && _currentChapter?.chapterIndex == chapterIndex) {
        notifyListeners();
      }
    });
  }
}
```

### 关键观察

- `_ChapterModel` 是 private（下划线开头），无须暴露给外部
- `setNeighborChapter` 接受 `_ChapterModel?` 也是 private 类型——意味着外层 ReaderPage 不能直接构造它。需要再加一个 public 构造方法 `PageViewController.makeChapter({index, title, content})` 让外层灌
- 或者把 `_ChapterModel` 改为 public `ChapterWindow`（更长远）

**决策**：本子任务先定 `ChapterWindow` 为 public class（同文件 export）。下面 setNeighborChapter 接受 `ChapterWindow?` 类型。

### 更新方案：ChapterWindow public

```dart
@immutable
class ChapterWindow {
  final int chapterIndex;
  final String title;
  final String content;  // ← raw content，由 controller 内部 split
  // ... 内部 paragraphs / pages 仍 private

  const ChapterWindow({
    required this.chapterIndex,
    required this.title,
    required this.content,
  });
}
```

外层 ReaderPage 调用：
```dart
pageViewController.setNeighborChapter(
  prev: prev != null ? ChapterWindow(
    chapterIndex: prevIdx,
    title: prevTitle,
    content: prevContent,
  ) : null,
  next: ...,
);
```

Controller 内部把 ChapterWindow 转 _ChapterModel + 测量。这样 public API 简洁，private 类型完全藏起来。

### 测试

新增 `flutter_app/test/page_view_controller_window_test.dart` 8+ 用例：

1. 默认 controller / 单章节 loadChapter / boundaryNextPage == null
2. setNeighborChapter(next:) 后未到末页 boundaryNextPage == null
3. setNeighborChapter(next:) 后跳到末页 boundaryNextPage 不为 null
4. setNeighborChapter(next:) 后调用 commitToNextChapter 切换 currentChapter
5. commitToNextChapter 在 _nextChapter == null 时返回 false
6. commitToPrevChapter 同样路径
7. commitToNextChapter 后 prev 升级为旧 cur，next 变 null
8. loadChapter(index) 与 prev/next 不连续时清空 prev/next
9. updateSettings 排版字段变化时清空三章 pages
10. ChapterWindow 公共构造器接受 raw content + 内部 split

## Risk & Mitigation

- **API 兼容**：保留全部现有方法签名 + 行为；测试需覆盖外层 ReaderPage 现有所有调用路径不退化
- **measure 时机**：只在 `_currentChapter` 上做 measure；prev/next 的 measure 由外层 ReaderPage 在 `_measureAdjacentChapters`（Subtask B）里手动驱动 `PageMeasure.measureChapter` 后通过 setNeighborChapter 灌入。Controller 不主动 measure 邻章
- **Settings 变更**：sub-agent 容易忘了清 prev/next 的 pages；测试要覆盖
- **测试访问私有字段**：用 @visibleForTesting getter 暴露 `_prevChapter` / `_nextChapter`（仅测试可见）

## Out of Scope

- 不动 ReaderPage（Subtask B 范围）
- 不动 PageDelegate（Subtask C 范围）
- 不写跨章动画测试（Subtask D 范围）
- 不动 measure 算法（PageMeasure 不变）
- 不动 Rust / FRB

## Technical Notes

### 关键 file:line

- `flutter_app/lib/features/reader/page/page_view_controller.dart:1-215` — 全文重构
- 旧的"死代码"注释 (line 13-17) — 更新成"R-XX: 三章节窗口为跨章动画 picture 渲染服务"
- `flutter_app/lib/features/reader/page/text_page.dart` — TextPage 类型不动
- `flutter_app/lib/features/reader/page/page_measure.dart` — PageMeasure 不动

### 命令前缀

- `flutter --no-version-check analyze`
- `xvfb-run -a flutter --no-version-check test`

## Research References

无（架构基于父任务 PRD）。
