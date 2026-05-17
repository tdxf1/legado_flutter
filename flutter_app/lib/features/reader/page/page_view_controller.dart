import 'package:flutter/material.dart';
import '../../../core/providers.dart';
import 'text_page.dart';
import 'page_measure.dart';

enum PageDirection { none, next, prev }

/// 阅读器分页控制器（单章节模型）。
///
/// **架构约定**：本控制器只持有"当前章节"一份内容，跨章节切换由外层
/// [ReaderPage] 调用 [loadChapter] 重新喂入新章节负责。
///
/// 历史背景：早期版本曾尝试在控制器内部维护多章节窗口（neighbors 预测量、
/// 跨章节 nextPage 等），但与 [ReaderPage] 自己的章节分页加载（_loadChapterContent
/// + _preCacheNextChapter + 异步章节切换）撞车并形成死代码。当前实现明确
/// 单章节语义，跨章节由外层动作回调驱动 [loadChapter]。如果以后真要让仿真
/// 翻页"看到下一章首页"，再讨论是否改回多章节窗口。
class PageViewController extends ChangeNotifier {
  String? _chapterTitle;
  List<String> _paragraphs = const [];
  List<TextPage> _pages = const [];

  int _currentChapterIndex = 0;
  int _currentPageIndex = 0;
  ReaderSettings _settings;
  Size _pageSize = Size.zero;

  bool _disposed = false;

  /// 由 [PageViewWidget] 注入：点击屏幕右 1/3 时调用，让 PageDelegate
  /// 跑动画后再 goToNextPage。如果 widget 未注入则为 null，调用方应回退到
  /// 直接 goToNextPage。
  VoidCallback? onTapNext;

  /// 由 [PageViewWidget] 注入：点击屏幕左 1/3 时调用。
  VoidCallback? onTapPrev;

  PageViewController({
    required ReaderSettings settings,
    int initialChapterIndex = 0,
    int initialPageIndex = 0,
  })  : _settings = settings,
        _currentChapterIndex = initialChapterIndex,
        _currentPageIndex = initialPageIndex;

  int get currentChapterIndex => _currentChapterIndex;
  int get currentPageIndex => _currentPageIndex;
  ReaderSettings get settings => _settings;

  TextPage? get currentPage {
    if (_currentPageIndex < 0 || _currentPageIndex >= _pages.length) {
      return null;
    }
    return _pages[_currentPageIndex];
  }

  /// 章节内的下一页；越过章末返回 null（由 [ReaderPage] 在 onChapterBoundary
  /// 回调里负责加载下一章）。
  TextPage? get nextPage {
    final nextIdx = _currentPageIndex + 1;
    if (nextIdx < _pages.length) return _pages[nextIdx];
    return null;
  }

  /// 章节内的上一页；越过章首返回 null。
  TextPage? get prevPage {
    final prevIdx = _currentPageIndex - 1;
    if (prevIdx >= 0) return _pages[prevIdx];
    return null;
  }

  /// 章节内是否还有下一页。跨章节由外层判断。
  bool get hasNext => _currentPageIndex + 1 < _pages.length;

  /// 章节内是否还有上一页。跨章节由外层判断。
  bool get hasPrev => _currentPageIndex > 0;

  int get totalPagesInChapter => _pages.length;

  void updatePageSize(Size size) {
    _pageSize = size;
    _measureCurrentChapterIfNeeded();
  }

  void updateSettings(ReaderSettings settings) {
    // Whitelist of fields that change the *typesetting result*; if any of
    // these differ from the previous settings we have to discard the cached
    // measure and re-paginate. Color-only changes don't affect line breaks
    // and are handled by repaint alone (see _PageViewPainter.shouldRepaint).
    //
    // R16: fontFamily was missing from the comparison, which made font
    // changes silently keep the old page splits while rendering with the
    // new font — top half OK, bottom half misaligned.
    if (_settings.fontSize == settings.fontSize &&
        _settings.fontWeightIndex == settings.fontWeightIndex &&
        _settings.fontFamily == settings.fontFamily &&
        _settings.letterSpacing == settings.letterSpacing &&
        _settings.lineHeight == settings.lineHeight &&
        _settings.paragraphSpacing == settings.paragraphSpacing &&
        _settings.horizontalPadding == settings.horizontalPadding &&
        _settings.verticalPadding == settings.verticalPadding &&
        _settings.paragraphIndent == settings.paragraphIndent) {
      _settings = settings;
      return;
    }
    _settings = settings;
    _pages = const [];
    _measureCurrentChapterIfNeeded();
  }

  /// 加载新章节内容。会清空旧的测量缓存，并异步触发当前章节的测量。
  /// [jumpToLast] = true 时（场景：从下一章往回翻），定位到最后一页。
  void loadChapter(int index, String title, String content,
      {bool jumpToLast = false}) {
    _chapterTitle = title;
    _paragraphs = content
        .split(RegExp(r'\n+'))
        .where((p) => p.trim().isNotEmpty)
        .toList();
    _currentChapterIndex = index;
    _currentPageIndex = 0;
    _pages = const [];
    _measureCurrentChapterIfNeeded(jumpToLast: jumpToLast);
  }

  void clearChapter() {
    _chapterTitle = null;
    _paragraphs = const [];
    _pages = const [];
    _currentChapterIndex = 0;
    _currentPageIndex = 0;
  }

  void jumpToPage(int pageIndex) {
    if (_pages.isEmpty) return;
    _currentPageIndex = pageIndex.clamp(0, _pages.length - 1);
    notifyListeners();
  }

  /// 章节内翻到下一页。返回 true 表示成功；返回 false 表示已在章末，
  /// 调用方需要自行加载下一章节（参考 ReaderPage._goToNextChapter）。
  bool goToNextPage() {
    if (_currentPageIndex + 1 < _pages.length) {
      _currentPageIndex++;
      notifyListeners();
      return true;
    }
    return false;
  }

  /// 章节内翻到上一页。返回 true 表示成功；返回 false 表示已在章首。
  bool goToPrevPage() {
    if (_currentPageIndex > 0) {
      _currentPageIndex--;
      notifyListeners();
      return true;
    }
    return false;
  }

  void _measureCurrentChapterIfNeeded({bool jumpToLast = false}) {
    if (_paragraphs.isEmpty) return;
    if (_pages.isNotEmpty) return;
    if (_pageSize.width <= 0 || _pageSize.height <= 0) return;
    _measureChapter(jumpToLast: jumpToLast);
  }

  void _measureChapter({bool jumpToLast = false}) {
    // R38: removed the previous `_isMeasuring` re-entrancy guard. Layout
    // is fully synchronous on this code path (PageMeasure.measureChapter
    // does its work in-thread), so there's no observable window in which
    // a second caller could see the flag set. The flag was introduced
    // assuming an async measure that never landed; it only added the
    // illusion of safety.
    //
    // Snapshot only chapterIndex — that's the one referenced from the
    // post-frame callback below to detect "user already moved on to a
    // different chapter while we were measuring". Settings/pageSize were
    // historically captured here too but never read again because the
    // measure call below reads them via fields directly; keeping the
    // dead snapshots only invited drift bugs.
    final chapterIndex = _currentChapterIndex;

    final measure = PageMeasure(
      settings: _settings,
      pageSize: _pageSize,
      chapterTitle: _chapterTitle ?? '',
    );
    final result = measure.measureChapter(chapterIndex, _paragraphs);
    _pages = result.pages;

    if (jumpToLast && _pages.isNotEmpty) {
      _currentPageIndex = _pages.length - 1;
    }

    // R39: always defer the listener notification to the next frame.
    // The previous code path notified synchronously when `jumpToLast`
    // was true, which meant calling `notifyListeners()` mid-build if a
    // widget triggered loadChapter() during its own build phase
    // (e.g. via a Riverpod selector firing on first read). Deferring is
    // free for the common path and removes the "setState during build"
    // assertion as a possible failure mode.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed && chapterIndex == _currentChapterIndex) {
        notifyListeners();
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
