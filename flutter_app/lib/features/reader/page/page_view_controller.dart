import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../../../core/providers.dart';
import 'text_page.dart';
import 'page_measure.dart';

enum PageDirection { none, next, prev }

/// 由外层（ReaderPage）灌入邻章原始内容的 DTO。Controller 内部按当前
/// settings/pageSize 切段并 measure 成 [TextPage]。
///
/// 仅用于 [PageViewController.setNeighborChapter] 的入参，避免外层手工构造
/// controller 内部的 `_ChapterModel`（私有）。
@immutable
class ChapterWindow {
  final int chapterIndex;
  final String title;
  final String content;

  const ChapterWindow({
    required this.chapterIndex,
    required this.title,
    required this.content,
  });
}

/// 内部不可变章节模型（paragraphs / pages / currentPageIndex / title）。
///
/// `firstPage` / `lastPage` / `nextPage` / `prevPage` / `currentPage` 为
/// 边界 / 当前页的便捷访问器，[copyWith] 用于 controller 在状态机里推进
/// 页索引或更新 measure 结果。
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
          ? pages[currentPageIndex]
          : null;

  TextPage? get firstPage => pages.isNotEmpty ? pages.first : null;
  TextPage? get lastPage => pages.isNotEmpty ? pages.last : null;

  TextPage? get nextPage => (currentPageIndex + 1 < pages.length)
      ? pages[currentPageIndex + 1]
      : null;
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

/// 阅读器分页控制器 — 三章节窗口（prev / cur / next）模型。
///
/// **R-XX：三章节窗口仅服务于跨章动画 picture 渲染**——为 simulation /
/// cover / slide / fade 4 种水平翻页在章末→下章首页 / 章首→上章末页边界
/// 处提供 [boundaryNextPage] / [boundaryPrevPage]，让 PageDelegate 在
/// `onDragStart` 时能拿到下一章首页 / 上一章末页的 [TextPage]，渲染出
/// 完整动画的 `nextPicture` / `prevPicture`，而不是"翻到底→静止→内容
/// 跳变"。
///
/// **不是**让用户随意翻找章节的多章节缓存——窗口外严格释放，仅保留 ±1
/// 章。邻章 measure 由外层 [ReaderPage] 在 `_measureAdjacentChapters`
/// 完成后通过 [setNeighborChapter] 灌入；controller 不主动 measure 邻章
/// （除了在 [setNeighborChapter] 里做一次同步 measure 把 paragraphs 切成
/// pages）。动画完成时外层调 [commitToNextChapter] / [commitToPrevChapter]
/// 把 next/prev 提升为 currentChapter，旧 currentChapter 降级为 prev/next，
/// 旧 prev/next 释放。
///
/// 历史背景：早期版本曾尝试在控制器内部维护多章节窗口（neighbors 预测量、
/// 跨章节 nextPage 等），但当时为"让用户连续翻 ≥5 章"，与外层 ReaderPage
/// 的章节分页加载（_loadChapterContent + _preCacheNextChapter）撞车，并形
/// 成死代码。本次重构是不同设计——±1 章 + 仅服务跨章动画 picture 渲染——
/// 触发面小、内存可控（≤3 章 textPages）、且与外层 prefetch 协同（外层
/// 负责 fetch + measure，controller 负责 hold + boundary getter）。
class PageViewController extends ChangeNotifier {
  _ChapterModel? _currentChapter;
  _ChapterModel? _prevChapter;
  _ChapterModel? _nextChapter;

  // 在 loadChapter 之前的 fallback：兼容旧调用方在 loadChapter 前读取
  // currentChapterIndex / currentPageIndex 的语义（构造时 initialChapterIndex
  // 用于 ReaderPage 的初始章节定位）。
  final int _pendingChapterIndex;
  final int _pendingPageIndex;

  ReaderSettings _settings;
  Size _pageSize = Size.zero;
  bool _disposed = false;

  /// 由 [PageViewWidget] 注入：点击屏幕右 1/3 时调用，让 PageDelegate
  /// 跑动画后再 goToNextPage。如果 widget 未注入则为 null，调用方应回
  /// 退到直接 goToNextPage。
  VoidCallback? onTapNext;

  /// 由 [PageViewWidget] 注入：点击屏幕左 1/3 时调用。
  VoidCallback? onTapPrev;

  PageViewController({
    required ReaderSettings settings,
    int initialChapterIndex = 0,
    int initialPageIndex = 0,
  })  : _settings = settings,
        _pendingChapterIndex = initialChapterIndex,
        _pendingPageIndex = initialPageIndex;

  // ── 当前章节 getter（保 API 兼容） ───────────────────────────
  int get currentChapterIndex =>
      _currentChapter?.chapterIndex ?? _pendingChapterIndex;
  int get currentPageIndex =>
      _currentChapter?.currentPageIndex ?? _pendingPageIndex;
  ReaderSettings get settings => _settings;

  TextPage? get currentPage => _currentChapter?.currentPage;

  /// 章节内的下一页；越过章末返回 null（跨章页面通过 [boundaryNextPage]
  /// 取，由 [PageDelegate] 在章末时使用）。
  TextPage? get nextPage => _currentChapter?.nextPage;

  /// 章节内的上一页；越过章首返回 null（跨章页面见 [boundaryPrevPage]）。
  TextPage? get prevPage => _currentChapter?.prevPage;

  /// 章节内是否还有下一页（不考虑跨章；跨章见 [boundaryNextPage]）。
  bool get hasNext => _currentChapter?.hasNext ?? false;

  /// 章节内是否还有上一页（不考虑跨章；跨章见 [boundaryPrevPage]）。
  bool get hasPrev => _currentChapter?.hasPrev ?? false;

  int get totalPagesInChapter => _currentChapter?.totalPages ?? 0;

  // ── 跨章 getter（A.3） ───────────────────────────────────────
  /// 本章末页 + 已灌入下一章 → 返回下一章首页；否则 null。
  ///
  /// 让 [PageDelegate.onDragStart] 在章末拖动时把 nextPicture 渲染成下一
  /// 章首页（视觉上滑过去就是下章），动画完成后外层调 [commitToNextChapter]
  /// 把 next 提升为 cur。
  TextPage? get boundaryNextPage {
    final cur = _currentChapter;
    if (cur == null || cur.pages.isEmpty) return null;
    final isLast = cur.currentPageIndex == cur.pages.length - 1;
    if (!isLast) return null;
    return _nextChapter?.firstPage;
  }

  /// 本章首页 + 已灌入上一章 → 返回上一章末页；否则 null。
  TextPage? get boundaryPrevPage {
    final cur = _currentChapter;
    if (cur == null || cur.pages.isEmpty) return null;
    if (cur.currentPageIndex != 0) return null;
    return _prevChapter?.lastPage;
  }

  // ── 邻章注入 / 提升 / 清理（A.3） ───────────────────────────
  /// 由外层 [ReaderPage._measureAdjacentChapters] 完成后调用，灌入邻章。
  /// 任一参数为 null 表示清空对应邻章。Controller 内部把 [ChapterWindow]
  /// 的 raw content 切段并立即 measure（如果 [_pageSize] 已就绪）。
  void setNeighborChapter({ChapterWindow? prev, ChapterWindow? next}) {
    _prevChapter = prev == null ? null : _buildAndMeasure(prev);
    _nextChapter = next == null ? null : _buildAndMeasure(next);
    notifyListeners();
  }

  /// 把 [_nextChapter] 提升为 [_currentChapter]：旧 cur 降级为 prev，旧
  /// prev 释放，next 清空。返回 true 成功；false 表示 _nextChapter 为
  /// null（外层应回退到现有 fallback 路径——立即异步加载下一章）。
  ///
  /// 提升后 currentPageIndex 重置为 0（新章第一页）。
  bool commitToNextChapter() {
    final next = _nextChapter;
    if (next == null) return false;
    _prevChapter = _currentChapter;
    _currentChapter = next.copyWith(currentPageIndex: 0);
    _nextChapter = null;
    notifyListeners();
    return true;
  }

  /// 把 [_prevChapter] 提升为 [_currentChapter]：旧 cur 降级为 next，旧
  /// next 释放，prev 清空。返回 true 成功；false 表示 _prevChapter 为
  /// null。
  ///
  /// 提升后 currentPageIndex 定位到上一章末页（用户从下章首页向后翻进
  /// 上一章应落在末页）。
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

  // ── 现有 API（路由到 _currentChapter） ──────────────────────
  void updatePageSize(Size size) {
    if (_pageSize == size) return;
    _pageSize = size;
    // pageSize 变化（e.g. 旋转屏 / 首次 layout）会让所有缓存的 pages
    // 失效。cur 保留 paragraphs 重新 measure；prev/next 也保留 paragraphs
    // 重新 measure（而非清空——清空会导致 boundaryNextPage/boundaryPrevPage
    // 在 setNeighborChapter 重新灌入之前返回 null，用户翻章时走无动画 fallback 路径）。
    if (_currentChapter != null) {
      _currentChapter = _currentChapter!.copyWith(pages: const []);
    }
    _prevChapter = _remeasureChapter(_prevChapter);
    _nextChapter = _remeasureChapter(_nextChapter);
    _measureCurrentChapterIfNeeded();
  }

  _ChapterModel? _remeasureChapter(_ChapterModel? chapter) {
    if (chapter == null) return null;
    if (chapter.paragraphs.isEmpty) return chapter.copyWith(pages: const []);
    if (_pageSize.width <= 0 || _pageSize.height <= 0) {
      return chapter.copyWith(pages: const []);
    }
    final measure = PageMeasure(
      settings: _settings,
      pageSize: _pageSize,
      chapterTitle: chapter.title,
    );
    final result =
        measure.measureChapter(chapter.chapterIndex, chapter.paragraphs);
    return chapter.copyWith(pages: result.pages);
  }

  void updateSettings(ReaderSettings settings) {
    // Whitelist of fields that change the *typesetting result*; if any of
    // these differ from the previous settings we have to discard the
    // cached measure and re-paginate. Color-only changes don't affect
    // line breaks and are handled by repaint alone.
    //
    // R16: fontFamily was missing from the comparison, which made font
    // changes silently keep the old page splits while rendering with the
    // new font — top half OK, bottom half misaligned.
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
    if (!layoutChanged) return;
    // 三章都需要重测：cur 保留 paragraphs 等下次 _measure；prev/next 整
    // 个清掉等外层重灌（外层 ReaderPage 会监听到设置变更后重新 _measure
    // AdjacentChapters → setNeighborChapter）。A.4。
    if (_currentChapter != null) {
      _currentChapter = _currentChapter!.copyWith(pages: const []);
    }
    _prevChapter = null;
    _nextChapter = null;
    _measureCurrentChapterIfNeeded();
  }

  /// 加载新章节内容。会清空旧的测量缓存并异步触发 measure。
  /// [jumpToLast] = true 时（场景：从下一章往回翻），定位到最后一页。
  ///
  /// 不连续 chapterIndex 时（用户跳章 / 不只是相邻翻页）清空 prev/next，
  /// 避免邻章错位（外层 _measureAdjacentChapters 会重新灌）。
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

  /// 用章内字符偏移反算页索引 — MD3 `TextChapter.getPageIndexByCharIndex`
  /// 的 Flutter 等价实现。
  ///
  /// 复用 [TextPage.startCharOffset]（由 [PageMeasure._finalizePage] 累加
  /// paragraph 长度填充），不引入新字段。
  ///
  /// 边界语义（与 MD3 fastBinarySearchBy(chapterPosition) 等价）：
  /// - 当前章未 measure 或 pages 为空 → 返回 0
  /// - charOffset <= 0 → 返回 0（首页）
  /// - 否则返回 `startCharOffset <= charOffset` 的**最后一个**页索引
  ///   （即下一页 startCharOffset 已超过 charOffset 的那一页）
  /// - charOffset 越过末页 startCharOffset → 返回末页 idx
  ///
  /// **不能**用 `[startCharOffset, endCharOffset]` 双闭区间判断 — page i
  /// 的 endCharOffset 与 page i+1 的 startCharOffset 在段尾对齐时相等，
  /// 双闭会让边界 offset 落到上一页。
  ///
  /// 章内页数通常 < 50，线性扫描足够；未来如果章节极长可改二分。该方法
  /// 不修改任何状态，调用前后 currentPageIndex 不变。调用方需要再调
  /// [jumpToPage] 才会真正跳页 + notifyListeners。
  int getPageIndexByCharOffset(int charOffset) {
    final cur = _currentChapter;
    if (cur == null || cur.pages.isEmpty) return 0;
    if (charOffset <= 0) return 0;
    int result = 0;
    for (int i = 0; i < cur.pages.length; i++) {
      if (cur.pages[i].startCharOffset <= charOffset) {
        result = i;
      } else {
        break;
      }
    }
    return result;
  }

  /// 章节内翻到下一页。返回 true 表示成功；返回 false 表示已在章末，
  /// 调用方需要自行加载下一章节（参考 ReaderPage._goToNextChapter，或
  /// 走新增的 [commitToNextChapter] 路径）。
  bool goToNextPage() {
    final cur = _currentChapter;
    if (cur == null) return false;
    if (cur.currentPageIndex + 1 < cur.pages.length) {
      _currentChapter =
          cur.copyWith(currentPageIndex: cur.currentPageIndex + 1);
      notifyListeners();
      return true;
    }
    return false;
  }

  /// 章节内翻到上一页。返回 true 表示成功；返回 false 表示已在章首。
  bool goToPrevPage() {
    final cur = _currentChapter;
    if (cur == null) return false;
    if (cur.currentPageIndex > 0) {
      _currentChapter =
          cur.copyWith(currentPageIndex: cur.currentPageIndex - 1);
      notifyListeners();
      return true;
    }
    return false;
  }

  // ── 内部 ────────────────────────────────────────────────────
  /// 把 [ChapterWindow] 转成 [_ChapterModel]：split content 切段 +（如
  /// pageSize 已就绪）同步 measure 出 pages。
  _ChapterModel _buildAndMeasure(ChapterWindow win) {
    final paragraphs = win.content
        .split(RegExp(r'\n+'))
        .where((p) => p.trim().isNotEmpty)
        .toList();
    var model = _ChapterModel(
      chapterIndex: win.chapterIndex,
      title: win.title,
      paragraphs: paragraphs,
      pages: const [],
      currentPageIndex: 0,
    );
    if (paragraphs.isNotEmpty &&
        _pageSize.width > 0 &&
        _pageSize.height > 0) {
      final measure = PageMeasure(
        settings: _settings,
        pageSize: _pageSize,
        chapterTitle: win.title,
      );
      final result = measure.measureChapter(win.chapterIndex, paragraphs);
      model = model.copyWith(pages: result.pages);
    }
    return model;
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
    // R38: removed the previous `_isMeasuring` re-entrancy guard. Layout
    // is fully synchronous on this code path (PageMeasure.measureChapter
    // does its work in-thread), so there's no observable window in which
    // a second caller could see the flag set. The flag was introduced
    // assuming an async measure that never landed; it only added the
    // illusion of safety.
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

    // F-W2A-013 (BATCH-19c): phase-aware notify。
    //
    // 原 R39 强制 postFrame 是为了避免"setState during build"——某个
    // widget 在 build 阶段触发 loadChapter（典型：Riverpod selector
    // 在 build 内 read provider 间接触发）→ 同步 notifyListeners 把
    // 还在 build 的祖先 widget 重入 → assert 触发。但 postFrame 同时
    // 牺牲了首屏体感：用户看到"加载圆圈 → 短暂空白章节 → 真正内容"
    // 三段闪，因为 build 帧拿到的还是 `pages = const []`，要等下一帧
    // 才看到真实内容。
    //
    // 折中方案：按 `SchedulerBinding.instance.schedulerPhase` 分流。
    // - idle / postFrameCallbacks：当前不在 widget 树 build/layout/paint
    //   过程中，可以同步 notify 不会重入。loadChapter 多由用户操作
    //   或 Future.then 等异步路径触发，落在 idle 是常态，省一帧空白。
    // - 其他 phase（build / layout / paint / persistentCallbacks）：
    //   保留 postFrame 兜底，避免 setState during build assert。
    //
    // 详见 .trellis/spec/flutter-app/quality-and-anti-patterns.md
    // 「Reader 渲染边界 (BATCH-19c)」。
    final phase = SchedulerBinding.instance.schedulerPhase;
    final canNotifySync = phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks;
    if (canNotifySync) {
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
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  // ── @visibleForTesting：观测三章节窗口内部状态 ───────────────
  @visibleForTesting
  int? get debugPrevChapterIndex => _prevChapter?.chapterIndex;

  @visibleForTesting
  int? get debugNextChapterIndex => _nextChapter?.chapterIndex;

  @visibleForTesting
  int get debugPrevChapterPageCount => _prevChapter?.pages.length ?? 0;

  @visibleForTesting
  int get debugNextChapterPageCount => _nextChapter?.pages.length ?? 0;

  @visibleForTesting
  int get debugCurrentChapterPageCount => _currentChapter?.pages.length ?? 0;

  @visibleForTesting
  String? get debugCurrentChapterTitle => _currentChapter?.title;

  @visibleForTesting
  String? get debugPrevChapterTitle => _prevChapter?.title;

  @visibleForTesting
  String? get debugNextChapterTitle => _nextChapter?.title;
}
