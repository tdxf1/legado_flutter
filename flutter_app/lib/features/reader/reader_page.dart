import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/dto.dart';
import '../../core/download_runner.dart';
import '../../core/platform_webview_executor.dart';
import '../../core/providers.dart';
import '../../src/rust/api.dart' as rust_api;
import 'page/page_view.dart';
import 'page/page_view_controller.dart';
import 'change_source_dialog.dart';
import 'services/reader_tts_manager.dart';
import 'services/reader_auto_scroller.dart';
import 'services/reader_progress_service.dart';
import 'services/reader_bookmark_service.dart';
import 'state/reader_search_controller.dart' as rsc;
import 'widgets/reader_settings_sheet.dart';
import 'widgets/reader_search_bar.dart';
import 'widgets/reader_tts_bar.dart';
import 'widgets/reader_top_bar.dart';
import 'widgets/reader_bottom_bar.dart';

class _LoadedChapter {
  final int index;
  final String title;
  final String content;
  late final List<String> paragraphs;

  _LoadedChapter(this.index, this.title, this.content) {
    paragraphs = content
        .split(RegExp(r'\n+'))
        .where((p) => p.trim().isNotEmpty)
        .toList();
  }
}

class _ContinuousItem {
  final int chapterIndex;
  final bool isTitle;
  final bool isDivider;
  final int? paragraphIndex;
  const _ContinuousItem({
    required this.chapterIndex,
    this.isTitle = false,
    this.isDivider = false,
    this.paragraphIndex,
  });
}

class ReaderPage extends ConsumerStatefulWidget {
  final String bookId;
  final int chapterIndex;

  const ReaderPage({
    super.key,
    required this.bookId,
    this.chapterIndex = 0,
  });

  @override
  ConsumerState<ReaderPage> createState() => _ReaderPageState();

  /// Subtask B — 计算 [currentIndex] 邻章对应的 [ChapterWindow]，作为
  /// [PageViewController.setNeighborChapter] 的入参。抽成 static + 暴露
  /// `@visibleForTesting` 便于单测覆盖（不需要构造完整 ReaderPage widget）。
  ///
  /// 安全语义：
  /// - `chapters == null` 或 0 → 返回 (null, null)
  /// - 边界 `currentIndex == 0` → prev=null
  /// - 边界 `currentIndex == chapters.length - 1` → next=null
  /// - 邻章 `content` 为 null/empty → 对应方向 ChapterWindow=null（不灌空内容
  ///   让 controller 测出 0 页）
  ///
  /// **不**在这里做 settings / scrollMode 检查 — 这些是调用方
  /// `_measureAdjacentChapters` 的职责，让本函数纯计算便于测试。
  @visibleForTesting
  static (ChapterWindow?, ChapterWindow?) computeAdjacentWindows(
      int currentIndex, List<Map<String, dynamic>>? chapters) {
    if (chapters == null || chapters.isEmpty) return (null, null);
    if (currentIndex < 0 || currentIndex >= chapters.length) {
      return (null, null);
    }
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
}

class _ReaderPageState extends ConsumerState<ReaderPage> {
  int _currentIndex = 0;
  int _visibleChapterIndex = 0;

  /// Bug 6: 连续滚动模式下，最近一次 _onScroll debounce 触发时识别到的
  /// 段落 index（相对当前 _visibleChapterIndex 那一章）。仅保存进度时使用，
  /// 不影响渲染。
  int _visibleParagraphIndex = 0;
  String _chapterContent = '';
  bool _isLoadingContent = false;
  List<Map<String, dynamic>>? _cachedChapters;
  int _chapterRequestId = 0;
  /// R44: ensure the "替换规则执行失败" snackbar appears at most once per
  /// reader session. Without this guard a chapter that triggers a regex
  /// engine error would spam the user every time they paginate.
  bool _replaceRuleErrorShown = false;
  final ScrollController _scrollController = ScrollController();
  bool _progressRestored = false;
  Timer? _scrollDebounceTimer;
  Timer? _visibleChapterTimer;
  double _accumulatedOverscroll = 0;
  DateTime? _lastAutoChapterTime;
  bool _controlsVisible = false;
  ReaderSettings _settings = const ReaderSettings();
  bool _readerSettingsLoaded = false;
  List<_LoadedChapter> _loadedChapters = [];
  final GlobalKey _listViewKey = GlobalKey();
  final Map<int, GlobalKey> _chapterTitleKeys = {};
  /// P2-13: GlobalKey for paragraph items in continuous mode, used by
  /// `_restoreProgress` to scroll back to the saved paragraph precisely
  /// (instead of the platform-DPI-dependent average-height estimate).
  ///
  /// Memory budget: only the first [_kParagraphKeyCap] paragraphs of the
  /// current chapter are keyed. Long novels with thousands of paragraphs
  /// fall back to the estimator. The map is keyed by global chapter index
  /// + paragraph index (`(chIndex << 32) | paragraphIndex`) so multiple
  /// loaded chapters don't collide.
  final Map<String, GlobalKey> _paragraphKeys = {};
  static const int _kParagraphKeyCap = 200;
  double _lastScrollOffset = 0;
  bool _isScrollingBackward = false;
  String _bookName = '';
  String _sourceName = '';
  String _sourceUrl = '';
  String _sourceId = '';
  String _chapterUrl = '';
  List<_ContinuousItem>? _cachedContinuousItems;
  bool _isAppendingChapter = false;
  bool _isPrependingChapter = false;
  List<Map<String, dynamic>> _bookmarks = [];
  bool _hasBookmarkForChapter = false;
  double? _sliderValue;
  final ValueNotifier<DateTime> _nowNotifier = ValueNotifier(DateTime.now());
  Timer? _clockTimer;
  bool get _isSearching => _search.isActive;
  TextEditingController get _searchController => _search.textController;
  late final rsc.ReaderSearchController _search =
      rsc.ReaderSearchController(onChanged: () {
    if (mounted) setState(() {});
  });
  bool get _isAutoScrolling => _autoScroller.isRunning;
  late final ReaderAutoScroller _autoScroller = ReaderAutoScroller(
    controller: () => _scrollController,
    onChanged: () {
      if (mounted) setState(() {});
    },
  );
  final ReaderProgressService _progressService = ReaderProgressService();
  final ReaderBookmarkService _bookmarkService = ReaderBookmarkService();
  final ReaderTtsManager _tts = ReaderTtsManager();
  PageViewController? _pageViewController;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.chapterIndex;
    _scrollController.addListener(_onScroll);
    loadReaderSettingsFromDisk().then((s) {
      if (mounted) {
        _setReaderSettings(s, markLoaded: true);
      }
    });
    _loadBookmarks();
    _tts.init(
      rate: _settings.ttsSpeed,
      onStateChanged: () {
        if (mounted) setState(() {});
      },
      onChapterEndReached: () async {
        // Advance to next chapter and continue speaking with new content.
        _goToNextChapter();
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          _tts.setChapterContent(_chapterContent);
          await _tts.resumeAfterChapterAdvance();
        });
      },
    );
    _fetchBookName();
    _pageViewController = PageViewController(
      settings: _settings,
      initialChapterIndex: widget.chapterIndex,
    );
    _pageViewController!.addListener(_onPageChanged);
    _clockTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _nowNotifier.value = DateTime.now();
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _scrollDebounceTimer?.cancel();
    _visibleChapterTimer?.cancel();
    _clockTimer?.cancel();
    _autoScroller.dispose();
    _search.dispose();
    _tts.dispose();
    _nowNotifier.dispose();
    if (_pageViewController != null) {
      try {
        _pageViewController!.removeListener(_onPageChanged);
        _pageViewController!.dispose();
      } catch (e) {
        debugPrint('[Reader] dispose pageViewController failed: $e');
      }
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(ReaderPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bookId != widget.bookId) {
      // R66: wrap the reset in setState so the UI flips to the loading
      // state immediately. Without setState, build() still runs (the
      // widget rebuilt because props changed) and reads _chapterContent,
      // but if the framework decides to skip the rebuild — e.g. when
      // didUpdateWidget is the only change source — we'd render the old
      // chapter until _loadBookmarks completes asynchronously.
      setState(() {
        _chapterRequestId++;
        _cachedChapters = null;
        _chapterContent = '';
        _loadedChapters = [];
        _currentIndex = widget.chapterIndex;
        _isLoadingContent = false;
        _bookmarks = [];
        _hasBookmarkForChapter = false;
        _replaceRuleErrorShown = false;
      });
      _loadBookmarks();
    }
  }

  Future<void> _fetchBookName() async {
    try {
      final book = await ref.read(bookByIdProvider(widget.bookId).future);
      if (book != null && mounted) {
        setState(() => _bookName = book['name'] as String? ?? '');
      }
    } catch (e) {
      debugPrint('[Reader] fetchBookName failed: $e');
    }
  }

  Future<void> _fetchSourceInfo() async {
    try {
      final book = await ref.read(bookByIdProvider(widget.bookId).future);
      if (book != null && mounted) {
        _sourceName = book['source_name'] as String? ?? '';
        _sourceUrl = book['source_url'] as String? ?? '';
        if (_sourceId.isEmpty) {
          _sourceId = book['source_id'] as String? ?? '';
        }
        if (_cachedChapters != null &&
            _currentIndex < _cachedChapters!.length) {
          _chapterUrl = _cachedChapters![_currentIndex]['url'] as String? ?? '';
        }
        setState(() {});
      }
    } catch (e) {
      debugPrint('[Reader] fetchSourceInfo failed: $e');
    }
  }

  Future<String> _loadChapterContent(
      int index, List<Map<String, dynamic>> chapters) async {
    final chContent = chapters[index]['content'] as String?;
    if (chContent != null && chContent.isNotEmpty) {
      final dbPath2 = await ref.read(dbPathProvider.future);
      final content = await _applyReplaceRulesViaRust(dbPath2, chContent);
      return _cleanHtml(content);
    }
    final book = await ref.read(bookByIdProvider(widget.bookId).future);
    final dbPath = await ref.read(dbPathProvider.future);
    // Always use book's source_id when state is empty (fresh open)
    if (_sourceId.isEmpty && book != null) {
      _sourceId = book['source_id'] as String? ?? '';
      _sourceName = book['source_name'] as String? ?? '';
      _sourceUrl = book['source_url'] as String? ?? '';
    }
    final sourceId = _sourceId.isNotEmpty
        ? _sourceId
        : (book?['source_id'] as String? ?? '');
    final chapterUrl = chapters[index]['url'] as String? ?? '';

    String content = '无法获取章节内容（缺少书源或章节链接）';
    if (sourceId.isNotEmpty && chapterUrl.isNotEmpty) {
      final json = await rust_api.getChapterContentWithSourceFromDb(
        dbPath: dbPath,
        sourceId: sourceId,
        chapterUrl: chapterUrl,
      );
      if (json.isNotEmpty && json != 'null') {
        try {
          final data = jsonDecode(json);
          if (data is Map<String, dynamic>) {
            final platformRequest = data['platform_request'];
            if (platformRequest is Map) {
              content = await _executePlatformRequest(
                PlatformRequest.fromJson(
                    Map<String, dynamic>.from(platformRequest)),
              );
              if (_isCacheablePlatformContent(content)) {
                try {
                  await rust_api.updateChapterContent(
                    dbPath: dbPath,
                    chapterId: chapters[index]['id'] as String? ?? '',
                    content: content,
                  );
                  chapters[index]['content'] = content;
                } catch (e) {
                  debugPrint('[Reader] cache platform content failed: $e');
                }
              }
            } else {
              content = data['content'] as String? ?? '（无内容）';
            }
          } else {
            content = data.toString();
          }
        } catch (e) {
          debugPrint('[Reader] decode chapter response failed: $e');
          content = json;
        }
      }
    }

    content = await _applyReplaceRulesViaRust(dbPath, content);

    return _cleanHtml(content);
  }

  /// P1-7: 单次 FRB 调用代替之前 Dart 主 isolate 的 RegExp 循环。
  /// 失败时记录日志、提示一次 toast、然后退回原始内容（向后兼容，
  /// 优先保证用户能继续读，但不再让规则失效悄无声息）。
  ///
  /// R24: 把 [_bookName] 与 [_sourceUrl] 传给 Rust，让 scope 子串
  /// 匹配能正确判断这条规则是否对当前书生效。`_sourceUrl` 对应原
  /// Legado `book.origin` 字段（书源 URL，不是 source.id）。
  ///
  /// R105: `_fetchBookName` / `_fetchSourceInfo` 是 async，与第一章
  /// `_loadChapter` 并发；如果章节加载先完成，本方法看到的
  /// `_bookName` / `_sourceUrl` 会是空串，scope 限定的规则就会被
  /// Rust 端 R24 过滤逻辑当成 "empty caller context" 跳过，导致用户
  /// 看到第一章规则没生效但第二章生效。这里用 `bookByIdProvider`
  /// 兜底把 metadata 同步加载好再调 Rust。该 provider 是 FutureProvider
  /// 已做缓存，重复 await 同一 future 不会重复查询数据库。
  ///
  /// R115: 回填用 setState 是因为 `_bookName` / `_sourceUrl` 也被
  /// AppBar 标题、change-source 对话框等读取，需要立即触发 rebuild
  /// 而不是等下一次自然 setState；否则用户在并发 race 命中时会看到
  /// AppBar 暂时显示空标题。
  Future<String> _applyReplaceRulesViaRust(
      String dbPath, String content) async {
    if (content.isEmpty) return content;
    if (_bookName.isEmpty || _sourceUrl.isEmpty) {
      try {
        final book =
            await ref.read(bookByIdProvider(widget.bookId).future);
        if (book != null && mounted) {
          // R115: setState 让 AppBar 标题 / change-source 对话框等
          // 读取这两个字段的 widget 立即 rebuild。
          setState(() {
            if (_bookName.isEmpty) {
              _bookName = book['name'] as String? ?? '';
            }
            if (_sourceUrl.isEmpty) {
              _sourceUrl = book['source_url'] as String? ?? '';
            }
          });
        }
      } catch (e) {
        debugPrint('[Reader] R105 backfill book metadata failed: $e');
        // R116: 永久性 DB 错误会导致 scope 限定规则始终不生效却没有
        // 任何 UI 反馈。复用 `_replaceRuleErrorShown` 单次守卫，避免
        // 与下面 applyReplaceRules 失败 toast 双重弹窗。
        if (mounted && !_replaceRuleErrorShown) {
          _replaceRuleErrorShown = true;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('无法读取书籍信息，替换规则可能未按作用范围生效'),
              duration: Duration(seconds: 4),
            ),
          );
        }
        // Fall through — the rule call will still proceed with whatever
        // is populated (possibly empty), matching pre-R105 behaviour.
      }
    }
    try {
      final generation = ref.read(replaceRuleGenerationProvider);
      return await rust_api.applyReplaceRules(
        dbPath: dbPath,
        content: content,
        cacheGeneration: generation,
        bookName: _bookName.isNotEmpty ? _bookName : null,
        bookOrigin: _sourceUrl.isNotEmpty ? _sourceUrl : null,
        applyToTitle: false,
      );
    } catch (e) {
      debugPrint('[Reader] applyReplaceRules failed: $e');
      // R44: surface the failure once so the user knows their replace
      // rules aren't being applied (e.g. catastrophic-backtracking
      // regex, panic in core-source, FRB transport error). Subsequent
      // failures within the same session stay silent to avoid spam.
      if (mounted && !_replaceRuleErrorShown) {
        _replaceRuleErrorShown = true;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('替换规则执行失败，已显示原始章节内容'),
            duration: Duration(seconds: 4),
          ),
        );
      }
      return content;
    }
  }

  String _cleanHtml(String text) {
    return text
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll(RegExp(r'<[^>]+>'), '');
  }

  Future<void> _openChapter(
      int index, List<Map<String, dynamic>> chapters) async {
    if (chapters.isEmpty) {
      if (mounted) {
        setState(() {
          _chapterContent = '暂无章节';
          _isLoadingContent = false;
          _currentIndex = 0;
        });
      }
      return;
    }
    if (index < 0 || index >= chapters.length) {
      if (mounted) {
        setState(() {
          _chapterContent = '章节索引越界';
          _isLoadingContent = false;
          _currentIndex = index.clamp(0, chapters.length - 1);
        });
      }
      return;
    }
    _cachedChapters = chapters;
    final requestId = ++_chapterRequestId;
    setState(() {
      _isLoadingContent = true;
      _currentIndex = index;
    });
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      final content = await _loadChapterContent(index, chapters);
      if (!mounted || requestId != _chapterRequestId) return;
      await rust_api.saveReadingProgress(
        dbPath: dbPath,
        bookId: widget.bookId,
        chapterIndex: index,
        paragraphIndex: 0,
        offset: 0,
      );
      if (!mounted || requestId != _chapterRequestId) return;
      final title = index < chapters.length
          ? (chapters[index]['title'] as String? ?? '')
          : '';
      setState(() {
        _chapterContent = content;
        _isLoadingContent = false;
        if (_settings.isScrollMode) {
          _loadedChapters = [_LoadedChapter(index, title, content)];
          _cachedContinuousItems = null;
        } else {
          _pageViewController?.updateSettings(_settings);
          _pageViewController?.loadChapter(index, title, content);
        }
      });
      _preCacheNextChapter(index, chapters);
      _preCachePrevChapter(index, chapters);
      _preloadAdjacentContent(index, chapters);
      _measureAdjacentChapters(index);
      _fetchSourceInfo();
    } catch (e) {
      if (!mounted || requestId != _chapterRequestId) return;
      setState(() {
        _chapterContent = '加载失败: $e';
        _isLoadingContent = false;
      });
    }
  }

  void _setReaderSettings(ReaderSettings settings,
      {bool persist = false, bool markLoaded = false}) {
    final wasScroll = _settings.isScrollMode;
    final isNowScroll = settings.isScrollMode;
    setState(() {
      if (markLoaded) {
        _readerSettingsLoaded = true;
      }
      _settings = settings;
      if (!wasScroll && isNowScroll) {
        _ensureCurrentChapterInContinuous();
      } else if (wasScroll && !isNowScroll && _chapterContent.isNotEmpty) {
        final title =
            _cachedChapters != null && _currentIndex < _cachedChapters!.length
                ? (_cachedChapters![_currentIndex]['title'] as String? ?? '')
                : '';
        _pageViewController?.loadChapter(_currentIndex, title, _chapterContent);
      }
    });
    ref.read(readerSettingsProvider.notifier).state = settings;
    _pageViewController?.updateSettings(settings);
    // Subtask B.6: 排版字段变化时 PageViewController.updateSettings 已自动清三章
    // pages，但邻章 paragraphs 也整个清掉了（见 controller 注释 A.4），需要外
    // 层重新灌一次邻章；再走一次 measure 让 boundaryNextPage / boundaryPrevPage
    // 在新字号 / 行距下重新就位。滚动模式跳过（_measureAdjacentChapters 内部已
    // 处理）。
    if (!settings.isScrollMode) {
      _measureAdjacentChapters(_currentIndex);
    }
    if (persist) {
      saveReaderSettingsToDisk(settings);
    }
  }

  void _ensureCurrentChapterInContinuous() {
    if (_chapterContent.isEmpty) return;
    final currentLoaded = _loadedChapters.length == 1 &&
        _loadedChapters.first.index == _currentIndex &&
        _loadedChapters.first.content == _chapterContent;
    if (currentLoaded) return;
    final title =
        _cachedChapters != null && _currentIndex < _cachedChapters!.length
            ? (_cachedChapters![_currentIndex]['title'] as String? ?? '')
            : '';
    _loadedChapters = [_LoadedChapter(_currentIndex, title, _chapterContent)];
    _visibleChapterIndex = _currentIndex;
    _cachedContinuousItems = null;
    _chapterTitleKeys.clear();
    _paragraphKeys.clear();
  }

  /// P2-13 helper: combine global chapter index + paragraph index into a
  /// `Map` key that's collision-free across chapters.
  ///
  /// R45: previously this packed both indices into a single 64-bit int
  /// via `chapterIndex << 32 | paragraphIndex`. That works on the
  /// Dart VM (native ints) but breaks on dart2js / dart2wasm where Dart
  /// `int` is a JS double: shifts are taken modulo 32, so for any
  /// `chapterIndex >= 1` the high bits are silently truncated and
  /// `(2 << 32) | 0` collapses to `2 | 0 == 2`. Using a string key
  /// sidesteps the entire 53-bit-mantissa hazard at the cost of one
  /// allocation per lookup, which is fine here — these keys are only
  /// minted while building the visible chunk of the scroll view.
  String _paragraphKeyId(int chapterIndex, int paragraphIndex) {
    return '$chapterIndex|$paragraphIndex';
  }

  Future<void> _appendNextChapter() async {
    if (_cachedChapters == null || _isAppendingChapter || _isLoadingContent)
      return;
    final chapters = _cachedChapters!;
    final lastLoaded =
        _loadedChapters.isNotEmpty ? _loadedChapters.last.index : _currentIndex;
    final nextIndex = lastLoaded + 1;
    if (nextIndex >= chapters.length) return;
    _isAppendingChapter = true;
    setState(() {});
    try {
      final content = await _loadChapterContent(nextIndex, chapters);
      if (!mounted) return;
      final title = chapters[nextIndex]['title'] as String? ?? '';
      setState(() {
        _loadedChapters.add(_LoadedChapter(nextIndex, title, content));
        _visibleChapterIndex = nextIndex;
        _cachedContinuousItems = null;
        _isAppendingChapter = false;
      });
      _preCacheNextChapter(nextIndex, chapters);
    } catch (e) {
      debugPrint('[Reader] appendNextChapter failed: $e');
      if (mounted) setState(() => _isAppendingChapter = false);
    }
  }

  Future<void> _prependPrevChapter() async {
    if (_cachedChapters == null || _isPrependingChapter || _isLoadingContent)
      return;
    final chapters = _cachedChapters!;
    final firstLoaded = _loadedChapters.isNotEmpty
        ? _loadedChapters.first.index
        : _currentIndex;
    final prevIndex = firstLoaded - 1;
    if (prevIndex < 0) return;
    _isPrependingChapter = true;
    setState(() {});
    try {
      final content = await _loadChapterContent(prevIndex, chapters);
      if (!mounted) return;
      final title = chapters[prevIndex]['title'] as String? ?? '';
      final prevChapter = _LoadedChapter(prevIndex, title, content);
      final oldExtent = _scrollController.hasClients
          ? _scrollController.position.maxScrollExtent
          : 0.0;
      final oldOffset =
          _scrollController.hasClients ? _scrollController.offset : 0.0;
      setState(() {
        _loadedChapters.insert(0, prevChapter);
        _visibleChapterIndex = prevIndex;
        _cachedContinuousItems = null;
        _isPrependingChapter = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          final newExtent = _scrollController.position.maxScrollExtent;
          final addedHeight = newExtent - oldExtent;
          if (addedHeight > 0) {
            _scrollController.jumpTo(oldOffset + addedHeight);
          }
        }
      });
    } catch (e) {
      debugPrint('[Reader] prependPrevChapter failed: $e');
      if (mounted) setState(() => _isPrependingChapter = false);
    }
  }

  Future<void> _resetContinuousStream(int index) async {
    if (_cachedChapters == null) return;
    await _openChapter(index, _cachedChapters!);
  }

  Future<String> _executePlatformRequest(PlatformRequest request) async {
    if (request.type == 'web_view_content') {
      try {
        final result =
            await PlatformWebViewExecutor().execute(context, request);
        if (result.sourceRegexRequired) {
          if (result.sourceRegexMatched && result.resourceUrl != null) {
            return result.resourceUrl!;
          }
          return result.content.isEmpty
              ? 'WebView 已执行，但未嗅探到匹配 sourceRegex 的资源。'
              : '${result.content}\n\n（提示：该书源配置了 sourceRegex，但未嗅探到匹配资源，结果可能不完整。）';
        }
        return result.content.isEmpty
            ? _platformRequestMessage(request)
            : result.content;
      } catch (e) {
        return '${_platformRequestMessage(request)}\n\n执行失败: $e';
      }
    }
    return _platformRequestMessage(request);
  }

  String _platformRequestMessage(PlatformRequest request) {
    if (request.type == 'web_view_content') {
      return '本章需要 Android WebView 执行后才能解析。\n\n'
          'URL: ${request.url ?? ''}\n\n'
          '当前版本已接入 Android 原生 WebView 执行器，原生不可用时会回退到 Flutter WebView。';
    }
    return '本章需要平台能力执行: ${request.type}';
  }

  bool _isCacheablePlatformContent(String content) {
    if (content.isEmpty) return false;
    return !content.startsWith('本章需要') &&
        !content.startsWith('WebView 已执行') &&
        !content.startsWith('WEBVIEW_JS_ERROR:');
  }

  void _goToNextChapter() {
    if (_cachedChapters == null) return;
    final chapters = _cachedChapters!;
    if (_currentIndex < chapters.length - 1) {
      final target = _currentIndex + 1;
      _visibleChapterIndex = target;
      if (_settings.isScrollMode) {
        _resetContinuousStream(target);
      } else {
        _openChapter(target, chapters);
      }
    }
  }

  void _goToPrevChapter() {
    if (_cachedChapters == null) return;
    final chapters = _cachedChapters!;
    if (_currentIndex > 0) {
      final target = _currentIndex - 1;
      _visibleChapterIndex = target;
      if (_settings.isScrollMode) {
        _resetContinuousStream(target);
      } else {
        _openChapter(target, chapters);
      }
    }
  }

  bool _onOverscroll(OverscrollNotification notification) {
    if (_isLoadingContent) return false;
    final chapters = _cachedChapters;
    if (chapters == null || _currentIndex >= chapters.length - 1) return false;
    final now = DateTime.now();
    if (_lastAutoChapterTime != null &&
        now.difference(_lastAutoChapterTime!).inMilliseconds < 1000) {
      return false;
    }
    _accumulatedOverscroll += notification.overscroll;
    if (_accumulatedOverscroll > 80) {
      _lastAutoChapterTime = now;
      _accumulatedOverscroll = 0;
      _goToNextChapter();
    }
    return false;
  }

  Future<void> _startDownload(BuildContext context) async {
    try {
      final book = await ref.read(bookByIdProvider(widget.bookId).future);
      if (book == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('未找到书籍信息')),
          );
        }
        return;
      }

      final sourceId = book['source_id'] as String? ?? '';
      if (sourceId.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('该书未关联书源，无法缓存')),
          );
        }
        return;
      }

      final chapters = _cachedChapters ??
          (await ref.read(bookChaptersProvider(widget.bookId).future) ?? []);
      if (chapters.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('暂无章节可缓存')),
          );
        }
        return;
      }

      final dbPath = await ref.read(dbPathProvider.future);
      final downloadDir = await ref.read(downloadDirProvider.future);

      final existingJson = await rust_api.getDownloadTaskByBook(
        dbPath: dbPath,
        bookId: widget.bookId,
      );
      final List<dynamic> existingTasks = jsonDecode(existingJson);
      if (existingTasks.isNotEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('该书已有缓存任务')),
          );
        }
        return;
      }

      final sourceJson = await rust_api.getSourceForDownload(
        dbPath: dbPath,
        sourceId: sourceId,
      );

      final taskId = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final task = {
        'id': taskId,
        'book_id': widget.bookId,
        'book_name': book['name'] ?? '',
        'cover_url': book['cover_url'],
        'total_chapters': chapters.length,
        'downloaded_chapters': 0,
        'status': 1,
        'total_size': 0,
        'downloaded_size': 0,
        'error_message': null,
        'created_at': now,
        'updated_at': now,
      };

      final chapterRecords = <Map<String, dynamic>>[];
      for (var i = 0; i < chapters.length; i++) {
        final ch = chapters[i];
        chapterRecords.add({
          'id': '${taskId}_$i',
          'task_id': taskId,
          'chapter_id': ch['id'] ?? '',
          'chapter_index': i,
          'chapter_title': ch['title'] ?? '',
          'status': 0,
          'file_path': null,
          'file_size': 0,
          'error_message': null,
          'created_at': now,
          'updated_at': now,
        });
      }

      await rust_api.createDownloadTaskWithChapters(
        dbPath: dbPath,
        taskJson: jsonEncode(task),
        chaptersJson: jsonEncode(chapterRecords),
      );

      final bookName = book['name'] as String? ?? '';

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('开始缓存 $bookName (${chapters.length}章)')),
        );
      }

      DownloadRunner().enqueue(
        taskId: taskId,
        bookName: bookName,
        chapters: chapters,
        sourceJson: sourceJson,
        downloadDir: downloadDir,
        dbPath: dbPath,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('缓存失败: $e')),
        );
      }
    }
  }

  void _onScroll() {
    if (_scrollDebounceTimer != null) return;
    _scrollDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      _scrollDebounceTimer = null;
      _saveScrollPosition();
    });
    if (_visibleChapterTimer != null) return;
    _visibleChapterTimer = Timer(const Duration(milliseconds: 300), () {
      _visibleChapterTimer = null;
      _updateVisibleChapter();
    });

    if (_scrollController.hasClients) {
      final currentOffset = _scrollController.offset;
      _isScrollingBackward = currentOffset < _lastScrollOffset;
      _lastScrollOffset = currentOffset;
    }

    if (_settings.isScrollMode &&
        _scrollController.hasClients &&
        !_isAppendingChapter &&
        !_isPrependingChapter) {
      final maxScroll = _scrollController.position.maxScrollExtent;
      final currentScroll = _scrollController.position.pixels;
      if (maxScroll - currentScroll < 300) {
        _appendNextChapter();
      } else if (currentScroll < 300) {
        _prependPrevChapter();
      }
    }
  }

  void _updateVisibleChapter() {
    if (!_scrollController.hasClients) return;
    if (_loadedChapters.isEmpty) return;
    if (!_settings.isScrollMode) return;
    final listBox =
        _listViewKey.currentContext?.findRenderObject() as RenderBox?;
    if (listBox == null || !listBox.hasSize) return;
    final listTop = listBox.localToGlobal(Offset.zero).dy;
    final viewportHeight = _scrollController.position.viewportDimension;
    final threshold = viewportHeight / 3;

    int? inZoneChapter;
    for (final ch in _loadedChapters) {
      final key = _chapterTitleKeys[ch.index];
      if (key == null) continue;
      final ctx = key.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final titleTop = box.localToGlobal(Offset.zero).dy - listTop;
      if (titleTop >= 0 && titleTop <= threshold) {
        inZoneChapter = ch.index;
        break;
      }
    }

    if (inZoneChapter != null) {
      if (_visibleChapterIndex != inZoneChapter) {
        _switchChapter(inZoneChapter);
      }
      return;
    }

    if (_isScrollingBackward) {
      final currentIdx =
          _loadedChapters.indexWhere((ch) => ch.index == _visibleChapterIndex);
      if (currentIdx > 0) {
        _switchChapter(_loadedChapters[currentIdx - 1].index);
      }
    }

    // Bug 6: 章节定位结束后，再算一次当前段落 index 用于进度保存
    _updateVisibleParagraph();
  }

  void _switchChapter(int chapterIndex) {
    if (_visibleChapterIndex == chapterIndex) return;
    _visibleChapterIndex = chapterIndex;
    if (_cachedChapters != null && chapterIndex < _cachedChapters!.length) {
      _chapterUrl = _cachedChapters![chapterIndex]['url'] as String? ?? '';
    }
    setState(() {});
  }

  Future<void> _saveScrollPosition() async {
    if (!_scrollController.hasClients || _chapterContent.isEmpty) return;
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      final isContinuous =
          _settings.isScrollMode;
      final idx = isContinuous ? _visibleChapterIndex : _currentIndex;
      // Bug 6 fix: 连续滚动模式下，全局 _scrollController.offset 不可移植
      // （ListView 是动态滑动窗口，下次 _loadedChapters 数量变了 offset 没意义）。
      // 改存当前可见 paragraph index，恢复时按平均段高估算位置。
      // 分页模式仍存 offset（PageViewWidget 内部稳定）。
      final paragraphIdx = isContinuous ? _visibleParagraphIndex : 0;
      final offset = isContinuous ? 0 : _scrollController.offset.toInt();
      await _progressService.save(
        dbPath: dbPath,
        bookId: widget.bookId,
        chapterIndex: idx,
        paragraphIndex: paragraphIdx,
        offset: offset,
      );
    } catch (e) {
      debugPrint('[Reader] saveScrollPosition failed: $e');
    }
  }

  Future<void> _restoreProgress(List<Map<String, dynamic>> chapters) async {
    if (chapters.isEmpty) return;
    final dbPath = await ref.read(dbPathProvider.future);
    final saved = await _progressService.load(
      dbPath: dbPath,
      bookId: widget.bookId,
    );
    if (saved == null) {
      await _openChapter(widget.chapterIndex, chapters);
      return;
    }
    final savedIndex = saved.chapterIndex;
    final savedOffset = saved.offset;
    final savedParagraph = saved.paragraphIndex;
    if (savedIndex < 0 || savedIndex >= chapters.length) return;

    await _openChapter(savedIndex, chapters);
    if (!mounted) return;

    final isContinuous =
        _settings.isScrollMode;
    if (isContinuous && savedParagraph > 0) {
      // P2-13: prefer ensureVisible over height estimation. Falls back to
      // the legacy estimator only when the saved paragraph is past
      // [_kParagraphKeyCap] (long-novel memory budget).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients || !mounted) return;
        if (_loadedChapters.isEmpty) return;
        final ch = _loadedChapters[0];
        if (ch.paragraphs.isEmpty) return;
        final clampedParagraph =
            savedParagraph.clamp(0, ch.paragraphs.length - 1);

        if (clampedParagraph < _kParagraphKeyCap) {
          final keyId = _paragraphKeyId(ch.index, clampedParagraph);
          final key = _paragraphKeys[keyId];
          final ctx = key?.currentContext;
          if (ctx != null) {
            Scrollable.ensureVisible(
              ctx,
              alignment: 0,
              duration: Duration.zero,
            );
            _visibleParagraphIndex = clampedParagraph;
            return;
          }
        }

        // Fallback: height estimate.
        final approxLineHeight = _settings.fontSize * _settings.lineHeight;
        final approxParagraphHeight =
            approxLineHeight * 2 + _settings.paragraphSpacing;
        final titleHeight = _settings.fontSize * _settings.lineHeight * 1.7;
        final target =
            titleHeight + approxParagraphHeight * clampedParagraph;
        _scrollController.jumpTo(
          target.clamp(0.0, _scrollController.position.maxScrollExtent),
        );
        _visibleParagraphIndex = clampedParagraph;
      });
    } else if (!isContinuous && savedOffset > 0) {
      // 分页模式仍按 offset 走（PageViewWidget 内部用，这里其实已不存）；
      // 保留兜底以防 PageView 改回基于 ScrollController 实现。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients && mounted) {
          _scrollController.jumpTo(savedOffset.toDouble());
        }
      });
    }
  }

  /// Bug 6: 在 _onScroll 的 debounce 回调里调用，估算当前可见 paragraph index。
  /// 算法：找当前可见 chapter 的标题 RenderBox 在视口的 dy，从那里计算视口顶部
  /// 偏移了多少段（按平均段高估算）。
  void _updateVisibleParagraph() {
    if (!_scrollController.hasClients) return;
    if (_loadedChapters.isEmpty) return;
    if (!_settings.isScrollMode) return;
    final ch = _loadedChapters.firstWhere(
      (c) => c.index == _visibleChapterIndex,
      orElse: () => _loadedChapters.first,
    );
    if (ch.paragraphs.isEmpty) {
      _visibleParagraphIndex = 0;
      return;
    }
    final titleKey = _chapterTitleKeys[ch.index];
    final titleCtx = titleKey?.currentContext;
    final titleBox = titleCtx?.findRenderObject() as RenderBox?;
    final listBox =
        _listViewKey.currentContext?.findRenderObject() as RenderBox?;
    if (titleBox == null ||
        !titleBox.hasSize ||
        listBox == null ||
        !listBox.hasSize) {
      return;
    }
    final titleDy =
        titleBox.localToGlobal(Offset.zero, ancestor: listBox).dy;
    final approxLineHeight = _settings.fontSize * _settings.lineHeight;
    final approxParagraphHeight =
        approxLineHeight * 2 + _settings.paragraphSpacing;
    final titleHeight = approxLineHeight * 1.7;
    // 视口顶部相对该章 paragraph 起始的偏移
    final dyFromParagraphStart = -titleDy - titleHeight;
    if (dyFromParagraphStart <= 0) {
      _visibleParagraphIndex = 0;
      return;
    }
    final est = (dyFromParagraphStart / approxParagraphHeight).floor();
    _visibleParagraphIndex = est.clamp(0, ch.paragraphs.length - 1);
  }

  Future<void> _preCacheNextChapter(
      int index, List<Map<String, dynamic>> chapters) async {
    final nextIndex = index + 1;
    if (nextIndex >= chapters.length) return;
    final chContent = chapters[nextIndex]['content'] as String?;
    if (chContent != null && chContent.isNotEmpty) return;
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      final book = await ref.read(bookByIdProvider(widget.bookId).future);
      final sourceId = _sourceId.isNotEmpty
          ? _sourceId
          : (book?['source_id'] as String? ?? '');
      final chapterUrl = chapters[nextIndex]['url'] as String? ?? '';
      if (sourceId.isEmpty || chapterUrl.isEmpty) return;
      final json = await rust_api.getChapterContentWithSourceFromDb(
        dbPath: dbPath,
        sourceId: sourceId,
        chapterUrl: chapterUrl,
      );
      if (json.isEmpty || json == 'null') return;
      var content = '';
      try {
        final data = jsonDecode(json);
        if (data is Map<String, dynamic>) {
          content = data['content'] as String? ?? json;
        } else {
          content = data.toString();
        }
      } catch (e) {
        debugPrint('[Reader] preCacheNextChapter decode failed: $e');
        content = json;
      }
      if (content.isNotEmpty) {
        await rust_api.updateChapterContent(
          dbPath: dbPath,
          chapterId: chapters[nextIndex]['id'] as String? ?? '',
          content: content,
        );
      }
    } catch (e) {
      debugPrint('[Reader] preCacheNextChapter failed: $e');
    }
  }

  /// Task X2 (Bug C) — prev 跨章预拉对称化。
  ///
  /// 与 [_preCacheNextChapter] 镜像，但拉的是 `index - 1` 章的字符串。
  /// 之所以需要独立一份镜像方法，是因为 `_preCacheNextChapter` 早在
  /// `_openChapter` 完成时就被 fire-and-forget 触发；prev 方向之前只走
  /// `_preloadAdjacentContent` 内的 `_loadChapterContent` fire-chain，那条
  /// 路径在 next 章被 `_preCacheNextChapter` 抢先排队时会**晚到**，
  /// 导致用户从首页往前翻时 controller `boundaryPrevPage` 仍是 null →
  /// fallback 走 `_onPageChapterBoundary` 同步 setState 路径 → 无动画 + 卡顿。
  ///
  /// 单一职责：把 prev 章字符串补齐 + 写库（与 next 行为对齐），让下次进章
  /// 直接命中缓存。`_loadChapterContent` 已经处理了缓存命中、Rust API
  /// 调用、正文清洗等逻辑，复用比镜像 `_preCacheNextChapter` 内部 fetch
  /// 流程更简洁也更不易漂移；副作用是 `_loadChapterContent` 不会显式
  /// `updateChapterContent`，但内部走 `getChapterContentWithSourceFromDb`
  /// 已经触发了 Rust 端的写库逻辑（与 next 等价）。
  Future<void> _preCachePrevChapter(
      int index, List<Map<String, dynamic>> chapters) async {
    final prevIndex = index - 1;
    if (prevIndex < 0) return;
    if (prevIndex >= chapters.length) return;
    final prevContent = chapters[prevIndex]['content'] as String?;
    if (prevContent != null && prevContent.isNotEmpty) return;
    try {
      final content = await _loadChapterContent(prevIndex, chapters);
      if (!mounted) return;
      if (content.isNotEmpty) {
        chapters[prevIndex]['content'] = content;
        // Subtask B.4 等价：字符串到位后立即让 controller 拿到刚就绪的 prev
        // 章 picture，下次跨章动画从首页往前翻不会再 fallback。
        _measureAdjacentChapters(_currentIndex);
      }
    } catch (e) {
      debugPrint('[Reader] preCachePrevChapter failed: $e');
    }
  }

  void _preloadAdjacentContent(
      int currentIndex, List<Map<String, dynamic>> chapters) {
    final prevIndex = currentIndex - 1;
    if (prevIndex >= 0) {
      final prevContent = chapters[prevIndex]['content'] as String?;
      if (prevContent == null || prevContent.isEmpty) {
        _loadChapterContent(prevIndex, chapters).then((content) {
          if (content.isNotEmpty) {
            chapters[prevIndex]['content'] = content;
            // Subtask B.4: 字符串 fetch 成功后立即灌进 controller，让 delegate
            // 跨章动画期间能拿到刚就绪的邻章首/末页 picture。
            if (mounted) _measureAdjacentChapters(_currentIndex);
          }
        }).catchError((Object e) {
          debugPrint('[Reader] preload prev chapter failed: $e');
        });
      }
    }
    final nextIndex = currentIndex + 1;
    if (nextIndex < chapters.length) {
      final nextContent = chapters[nextIndex]['content'] as String?;
      if (nextContent == null || nextContent.isEmpty) {
        _loadChapterContent(nextIndex, chapters).then((content) {
          if (content.isNotEmpty) {
            chapters[nextIndex]['content'] = content;
            // Subtask B.4: 同上，next 方向。
            if (mounted) _measureAdjacentChapters(_currentIndex);
          }
        }).catchError((Object e) {
          debugPrint('[Reader] preload next chapter failed: $e');
        });
      }
    }
  }

  /// Subtask B — 把已预加载的邻章字符串内容灌进 [PageViewController]，让
  /// PageDelegate 跨章动画期间能渲染邻章首/末页 picture。
  ///
  /// 调用时机：
  ///   - [_openChapter] 完成后（进章触发）
  ///   - [_loadPageModeChapter] 完成后（章末翻页触发）
  ///   - [_preloadAdjacentContent] 完成 fetch 字符串后（异步触发）
  ///   - [_setReaderSettings] 排版字段变化后（重测触发）
  ///
  /// 安全语义：
  ///   - controller 未就绪 → 早 return
  ///   - 滚动模式 → skip（滚动模式有自己的多章节加载机制
  ///     `_ensureCurrentChapterInContinuous`，邻章窗口不适用）
  ///   - 计算逻辑全部委托给 [ReaderPage.computeAdjacentWindows] 静态函数，
  ///     便于单测；本方法只负责"调度 + 灌 controller"。
  void _measureAdjacentChapters(int currentIndex) {
    final ctrl = _pageViewController;
    if (ctrl == null) return;
    if (_settings.isScrollMode) return;
    final (prev, next) =
        ReaderPage.computeAdjacentWindows(currentIndex, _cachedChapters);
    ctrl.setNeighborChapter(prev: prev, next: next);
  }

  Future<void> _refreshChapter() async {
    if (_cachedChapters == null || _cachedChapters!.isEmpty) return;
    final index = _currentIndex;
    final chapters = _cachedChapters!;
    final chapterId = chapters[index]['id'] as String?;
    if (chapterId != null) {
      try {
        final dbPath = await ref.read(dbPathProvider.future);
        await rust_api.updateChapterContent(
          dbPath: dbPath,
          chapterId: chapterId,
          content: '',
        );
        chapters[index]['content'] = null;
      } catch (e) {
        debugPrint('[Reader] refreshChapter clear cache failed: $e');
      }
    }
    if (_settings.isScrollMode) {
      // Bug 5 fix: 必须用 setState 同步清空 _loadedChapters 与
      // _cachedContinuousItems，否则下一帧 build 会读到旧的 cached items（指向
      // 已经空掉的 _loadedChapters[0]），抛 RangeError。
      if (mounted) {
        setState(() {
          _loadedChapters = [];
          _cachedContinuousItems = null;
          _chapterTitleKeys.clear();
          _paragraphKeys.clear();
        });
      }
    }
    await _openChapter(index, chapters);
  }

  Future<void> _loadBookmarks() async {
    final dbPath = await ref.read(dbPathProvider.future);
    final list =
        await _bookmarkService.list(dbPath: dbPath, bookId: widget.bookId);
    if (!mounted || list.isEmpty) return;
    setState(() => _bookmarks = list);
    _checkBookmarkForChapter();
  }

  void _checkBookmarkForChapter() {
    _hasBookmarkForChapter =
        _bookmarks.any((b) => b['chapter_index'] == _currentIndex);
  }

  Future<void> _toggleBookmark() async {
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      if (_hasBookmarkForChapter) {
        final match = _bookmarks
            .where((b) => b['chapter_index'] == _currentIndex)
            .toList();
        for (final bm in match) {
          final bookmarkId = bm['id'] as String? ?? '';
          if (bookmarkId.isNotEmpty) {
            await _bookmarkService.remove(
                dbPath: dbPath, bookmarkId: bookmarkId);
            _bookmarks.removeWhere((b) => b['id'] == bookmarkId);
          }
        }
      } else {
        final content = _chapterContent.length > 50
            ? _chapterContent.substring(0, 50)
            : _chapterContent;
        final added = await _bookmarkService.add(
          dbPath: dbPath,
          bookId: widget.bookId,
          chapterIndex: _currentIndex,
          content: content,
        );
        if (added != null) {
          _bookmarks.add(added);
        }
      }
      if (mounted) {
        _checkBookmarkForChapter();
        setState(() {});
      }
    } catch (e) {
      debugPrint('[Reader] add bookmark failed: $e');
    }
  }

  Future<void> _deleteBookmark(
      String bookmarkId, int bookmarkListIndex, BuildContext ctx) async {
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      await _bookmarkService.remove(dbPath: dbPath, bookmarkId: bookmarkId);
      _bookmarks.removeAt(bookmarkListIndex);
      _checkBookmarkForChapter();
      if (mounted) {
        setState(() {});
        if (ctx.mounted) {
          ScaffoldMessenger.of(ctx).showSnackBar(
            const SnackBar(content: Text('书签已删除')),
          );
        }
      }
    } catch (e) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text('删除失败: $e')),
        );
      }
    }
  }

  void _toggleNightMode() {
    final s = _settings.copyWith(nightMode: !_settings.nightMode);
    _setReaderSettings(s, persist: true);
  }

  void _navigateToChapter(int index, List<Map<String, dynamic>> chapters) {
    if (_settings.isScrollMode) {
      _resetContinuousStream(index);
    } else {
      _openChapter(index, chapters);
    }
  }

  void _showDirectorySheet() {
    _toggleControls();
    final chapters = _cachedChapters ?? [];
    final fg = Color(_settings.effectiveTextColor);
    final bg = Color(_settings.effectiveBackgroundColor);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: bg,
      builder: (ctx) => DefaultTabController(
        length: 2,
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: Column(
            children: [
              TabBar(
                tabs: const [
                  Tab(text: '目录'),
                  Tab(text: '书签'),
                ],
                labelColor: fg,
                unselectedLabelColor: fg.withValues(alpha: 0.5),
                indicatorColor: fg,
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _buildDirectoryTab(chapters, ctx),
                    _buildBookmarkTab(ctx, chapters),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDirectoryTab(
      List<Map<String, dynamic>> chapters, BuildContext ctx) {
    final fg = Color(_settings.effectiveTextColor);
    if (chapters.isEmpty) {
      return Center(
          child:
              Text('暂无目录', style: TextStyle(color: fg.withValues(alpha: 0.5))));
    }
    return ListView.builder(
      itemExtent: 48,
      itemCount: chapters.length,
      itemBuilder: (context, index) {
        final ch = chapters[index];
        final isCurrent = index == _currentIndex;
        return ListTile(
          dense: true,
          title: Text(
            ch['title'] as String? ?? '章节 ${index + 1}',
            style: TextStyle(
              color: isCurrent ? Theme.of(ctx).primaryColor : fg,
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
              fontSize: 14,
            ),
          ),
          onTap: () {
            Navigator.of(ctx).pop();
            _navigateToChapter(index, chapters);
          },
        );
      },
    );
  }

  Widget _buildBookmarkTab(
      BuildContext ctx, List<Map<String, dynamic>> chapters) {
    final fg = Color(_settings.effectiveTextColor);
    if (_bookmarks.isEmpty) {
      return Center(
          child:
              Text('暂无书签', style: TextStyle(color: fg.withValues(alpha: 0.5))));
    }
    return ListView.builder(
      itemExtent: 64,
      itemCount: _bookmarks.length,
      itemBuilder: (context, index) {
        final bm = _bookmarks[index];
        final chapterIndex = bm['chapter_index'] as int? ?? 0;
        final chapterTitle = chapterIndex < chapters.length
            ? (chapters[chapterIndex]['title'] as String? ??
                '章节 ${chapterIndex + 1}')
            : '章节 ${chapterIndex + 1}';
        final content = bm['content'] as String? ?? '';
        return ListTile(
          dense: true,
          title: Text(chapterTitle,
              style: TextStyle(color: fg, fontSize: 14),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          subtitle: content.isNotEmpty
              ? Text(content,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      TextStyle(color: fg.withValues(alpha: 0.5), fontSize: 12))
              : null,
          trailing: IconButton(
            icon: Icon(Icons.delete_outline,
                color: fg.withValues(alpha: 0.5), size: 20),
            onPressed: () =>
                _deleteBookmark(bm['id'] as String? ?? '', index, ctx),
          ),
          onTap: () {
            Navigator.of(ctx).pop();
            _navigateToChapter(chapterIndex, chapters);
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final providerSettings = ref.watch(readerSettingsProvider);
    if (_readerSettingsLoaded && providerSettings != _settings) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ref.read(readerSettingsProvider) != _settings) {
          _setReaderSettings(ref.read(readerSettingsProvider));
        }
      });
    }

    if (widget.bookId.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('阅读器')),
        body: const Center(child: Text('未指定书籍')),
      );
    }

    final chaptersAsync = ref.watch(bookChaptersProvider(widget.bookId));

    return chaptersAsync.when(
      data: (chapters) {
        if (chapters.isNotEmpty && !_progressRestored) {
          _progressRestored = true;
          _cachedChapters = chapters;
          Future.microtask(() => _restoreProgress(chapters));
        }
        if (chapters.isEmpty) {
          return Scaffold(
            appBar: AppBar(title: const Text('阅读器')),
            body: const Center(child: Text('暂无章节')),
          );
        }
        if (_isLoadingContent || _chapterContent.isNotEmpty) {
          return _buildReaderView();
        }
        return _buildChapterList(chapters);
      },
      loading: () => Scaffold(
        appBar: AppBar(title: const Text('阅读器')),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('阅读器')),
        body: Center(child: Text('加载章节失败: $e')),
      ),
    );
  }

  Widget _buildChapterList(List<Map<String, dynamic>> chapters) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('目录'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: ListView.builder(
        itemExtent: 56,
        itemCount: chapters.length,
        itemBuilder: (context, index) {
          final ch = chapters[index];
          return ListTile(
            title: Text(ch['title'] as String? ?? '章节 ${index + 1}'),
            onTap: () => _openChapter(index, chapters),
          );
        },
      ),
    );
  }

  Widget _buildReaderView() {
    final chapters = _cachedChapters!;
    final hasPrev = _currentIndex > 0;
    final hasNext = _currentIndex < chapters.length - 1;
    final settings = _settings;
    // P3-5/R25: derive from the explicit enum so a future
    // `ReaderRenderMode.someThirdMode` will need to be handled here.
    final renderMode = settings.renderMode;
    final isContinuous = renderMode == ReaderRenderMode.continuous;
    final isPage = renderMode == ReaderRenderMode.paged;
    final bgColor = Color(settings.effectiveBackgroundColor);
    final contentLocked = _controlsVisible || _isSearching;

    final showInfoBars = settings.showReadingInfo;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarIconBrightness:
            _settings.nightMode ? Brightness.light : Brightness.dark,
        statusBarColor: Colors.transparent,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: bgColor,
          image: settings.backgroundImagePath != null
              ? DecorationImage(
                  image: FileImage(File(settings.backgroundImagePath!)),
                  fit: BoxFit.cover,
                )
              : null,
        ),
        child: SafeArea(
          child: Column(
            children: [
              if (showInfoBars) _buildReadingInfoHeader(settings),
              Expanded(
                child: Stack(
                  children: [
                    IgnorePointer(
                      ignoring: contentLocked,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (details) {
                          final width = MediaQuery.of(context).size.width;
                          if (isPage) {
                            final pvc = _pageViewController;
                            if (pvc != null) {
                              if (details.localPosition.dx < width / 3) {
                                // Bug 2.5: 优先走 delegate 动画，回退到瞬切
                                if (pvc.onTapPrev != null) {
                                  pvc.onTapPrev!();
                                } else if (!pvc.goToPrevPage()) {
                                  _onPageChapterBoundary(PageDirection.prev);
                                }
                                return;
                              } else if (details.localPosition.dx >
                                  width * 2 / 3) {
                                if (pvc.onTapNext != null) {
                                  pvc.onTapNext!();
                                } else if (!pvc.goToNextPage()) {
                                  _onPageChapterBoundary(PageDirection.next);
                                }
                                return;
                              }
                            }
                            _toggleControls();
                            return;
                          }
                          _toggleControls();
                        },
                        child: NotificationListener<OverscrollNotification>(
                          onNotification:
                              isContinuous ? (_) => true : _onOverscroll,
                          child: isPage
                              ? _buildPageBody(settings)
                              : _buildContinuousBody(settings),
                        ),
                      ),
                    ),
                    if (contentLocked)
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _controlsVisible ? _toggleControls : () {},
                        ),
                      ),
                    if (_controlsVisible)
                      _buildTopControls(context, chapters, hasPrev, hasNext),
                    if (_controlsVisible)
                      _buildBottomControls(
                          context, chapters, hasPrev, hasNext, settings),
                    if (_isSpeaking) _buildTtsBar(),
                    if (_isSearching) _buildSearchBar(),
                  ],
                ),
              ),
              if (showInfoBars) _buildReadingInfoFooter(chapters, settings),
            ],
          ),
        ),
      ),
    );
  }

  List<_ContinuousItem> _buildContinuousItemList() {
    if (_cachedContinuousItems != null) return _cachedContinuousItems!;
    final items = <_ContinuousItem>[];
    for (var i = 0; i < _loadedChapters.length; i++) {
      final chapter = _loadedChapters[i];
      if (chapter.title.isNotEmpty) {
        items.add(_ContinuousItem(chapterIndex: i, isTitle: true));
      }
      for (var j = 0; j < chapter.paragraphs.length; j++) {
        items.add(_ContinuousItem(chapterIndex: i, paragraphIndex: j));
      }
      if (i < _loadedChapters.length - 1) {
        items.add(_ContinuousItem(chapterIndex: i, isDivider: true));
      }
    }
    _cachedContinuousItems = items;
    return items;
  }

  Widget _buildContinuousBody(ReaderSettings settings) {
    final textStyle = TextStyle(
      fontSize: settings.fontSize,
      fontWeight:
          FontWeight.values[((settings.fontWeight ~/ 100) - 1).clamp(0, 8)],
      fontFamily: settings.fontFamily,
      color: Color(settings.effectiveTextColor),
      letterSpacing: settings.letterSpacing,
      height: settings.lineHeight,
      decoration: TextDecoration.none,
    );
    final titleStyle = textStyle.copyWith(
      fontWeight: FontWeight.bold,
      fontSize: settings.fontSize * 1.15,
    );
    final dividerColor =
        Color(settings.effectiveTextColor).withValues(alpha: 0.15);
    final items = _buildContinuousItemList();

    return ListView.builder(
      key: _listViewKey,
      controller: _scrollController,
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.symmetric(
        horizontal: settings.horizontalPadding,
        vertical: settings.verticalPadding,
      ),
      itemCount: items.length + (_isAppendingChapter ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= items.length) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(
                child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))),
          );
        }
        final item = items[index];
        if (item.isTitle) {
          final globalChIndex = _loadedChapters[item.chapterIndex].index;
          return Padding(
            key:
                _chapterTitleKeys.putIfAbsent(globalChIndex, () => GlobalKey()),
            padding: EdgeInsets.only(bottom: settings.verticalPadding),
            child: Text(_loadedChapters[item.chapterIndex].title,
                style: titleStyle),
          );
        }
        if (item.isDivider) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Divider(color: dividerColor),
          );
        }
        final chapter = _loadedChapters[item.chapterIndex];
        final p = chapter.paragraphs[item.paragraphIndex!];
        // P2-13: key only the first _kParagraphKeyCap paragraphs of each
        // loaded chapter so _restoreProgress can ensureVisible accurately.
        final pIdx = item.paragraphIndex!;
        final globalKey = pIdx < _kParagraphKeyCap
            ? _paragraphKeys.putIfAbsent(
                _paragraphKeyId(chapter.index, pIdx),
                () => GlobalKey())
            : null;
        return Padding(
          key: globalKey,
          padding: EdgeInsets.only(bottom: settings.paragraphSpacing),
          child: Text('${settings.paragraphIndent}$p', style: textStyle),
        );
      },
    );
  }

  Widget _buildPageBody(ReaderSettings settings) {
    if (_chapterContent.isEmpty && _isLoadingContent) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_pageViewController == null) {
      return const Center(child: Text('加载中...'));
    }
    return PageViewWidget(
      controller: _pageViewController!,
      settings: settings,
      pageAnim: settings.pageAnim,
      onChapterBoundary: _onPageChapterBoundary,
      onCrossChapter: _onCrossChapterCommit,
    );
  }

  Future<void> _loadPageModeChapter(int targetIndex) async {
    if (_cachedChapters == null ||
        targetIndex < 0 ||
        targetIndex >= _cachedChapters!.length) return;
    final chapters = _cachedChapters!;
    final isPrev = targetIndex < _currentIndex;

    setState(() {
      _isLoadingContent = true;
      _currentIndex = targetIndex;
    });

    try {
      final content = await _loadChapterContent(targetIndex, chapters);
      if (!mounted) return;
      final title = chapters[targetIndex]['title'] as String? ?? '';
      final dbPath = await ref.read(dbPathProvider.future);
      await rust_api.saveReadingProgress(
        dbPath: dbPath,
        bookId: widget.bookId,
        chapterIndex: targetIndex,
        paragraphIndex: 0,
        offset: 0,
      );
      setState(() {
        _chapterContent = content;
        _isLoadingContent = false;
      });
      _pageViewController?.updateSettings(_settings);
      _pageViewController?.loadChapter(targetIndex, title, content,
          jumpToLast: isPrev);
      _preloadAdjacentContent(targetIndex, chapters);
      _preCachePrevChapter(targetIndex, chapters);
      _measureAdjacentChapters(targetIndex);
    } catch (e) {
      if (mounted) setState(() => _isLoadingContent = false);
    }
  }

  void _onPageChanged() {
    if (mounted) setState(() {});
  }

  void _onPageChapterBoundary(PageDirection dir) {
    if (_cachedChapters == null) return;
    if (dir == PageDirection.next &&
        _currentIndex < _cachedChapters!.length - 1) {
      _loadPageModeChapter(_currentIndex + 1);
    } else if (dir == PageDirection.prev && _currentIndex > 0) {
      _loadPageModeChapter(_currentIndex - 1);
    }
  }

  /// Subtask C：跨章动画完成后由 [PageDelegate] 经
  /// [PageViewWidget.onCrossChapter] 回调上来。controller 已经把邻章
  /// 提升为 currentChapter（commitToNextChapter / commitToPrevChapter），
  /// 这里只负责同步 ReaderPage 的 `_currentIndex` / 标题文案 / 保存进度 /
  /// 重新预加载新邻章。
  ///
  /// 与 [_onPageChapterBoundary] 的分工：
  ///   - _onCrossChapterCommit：邻章已就绪 → controller commit 完之后
  ///   - _onPageChapterBoundary：邻章未就绪 fallback → 旧 _loadPageModeChapter
  ///     异步加载（保留无动画切章的现状）
  void _onCrossChapterCommit(PageDirection dir) {
    if (!mounted) return;
    final ctrl = _pageViewController;
    if (ctrl == null) return;
    final newIndex = ctrl.currentChapterIndex;
    // 防御：commit 实际失败（_nextChapter / _prevChapter == null）controller
    // 没动；这里检测到 newIndex == _currentIndex 直接返回，避免空跑后面逻辑。
    if (newIndex == _currentIndex) return;
    setState(() {
      _currentIndex = newIndex;
      if (_cachedChapters != null && newIndex < _cachedChapters!.length) {
        final m = _cachedChapters![newIndex];
        _chapterContent = m['content'] as String? ?? '';
        _chapterUrl = m['url'] as String? ?? '';
      }
    });
    // 保存阅读进度（异步，不阻塞 UI）。
    _saveProgressAsync(newIndex);
    // 重新灌邻章 + 字符串预拉。controller 内部 _nextChapter / _prevChapter
    // 一边已被释放，需要外层重新 setNeighborChapter。
    _measureAdjacentChapters(newIndex);
    if (_cachedChapters != null) {
      _preloadAdjacentContent(newIndex, _cachedChapters!);
      _preCachePrevChapter(newIndex, _cachedChapters!);
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

  void _showChangeSourceDialog(BuildContext context) async {
    final dbPath = await ref.read(dbPathProvider.future);
    if (!mounted) return;
    final bookName = _bookName;
    final currentSourceId = _sourceId;
    final currentSourceName = _sourceName.isNotEmpty ? _sourceName : '书源';

    final result = await showDialog<ChangeSourceResult>(
      context: context,
      barrierDismissible: true,
      builder: (_) => ChangeSourceDialog(
        dbPath: dbPath,
        bookName: bookName,
        bookAuthor: '',
        currentSourceId: currentSourceId,
        currentSourceName: currentSourceName,
      ),
    );

    if (result != null && mounted) {
      await _replaceBookSource(result);
    }
  }

  Future<void> _replaceBookSource(ChangeSourceResult result) async {
    if (!mounted) return;
    final savedIndex = _currentIndex;
    final book = await ref.read(bookByIdProvider(widget.bookId).future);
    if (!mounted || book == null) {
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final dbPath = await ref.read(dbPathProvider.future);
    if (!mounted) return;

    final chapters = result.chapters;
    int savedCount = 0;
    final List<Map<String, dynamic>> cachedChaptersList = [];
    final List<Map<String, dynamic>> chapterRecords = [];
    for (var i = 0; i < chapters.length; i++) {
      final ch = chapters[i];
      final chapterKey = '${widget.bookId}|$i|${ch['url'] ?? ''}';
      final chapterId = base64Url
          .encode(sha256.convert(utf8.encode(chapterKey)).bytes)
          .replaceAll('=', '');
      final chapterData = {
        'id': chapterId,
        'book_id': widget.bookId,
        'index_num': i,
        'title': ch['title'] ?? '未知章节',
        'url': ch['url'] ?? '',
        'content': null,
        'is_volume': ch['is_volume'] ?? false,
        'is_checked': false,
        'start': 0,
        'end': 0,
        'created_at': now,
        'updated_at': now,
      };
      chapterRecords.add(chapterData);
      savedCount++;
      cachedChaptersList.add({
        'id': chapterId,
        'url': ch['url'] ?? '',
        'title': ch['title'] ?? '未知章节',
        'content': null,
      });
    }

    await rust_api.replaceBookChapters(
      dbPath: dbPath,
      bookId: widget.bookId,
      chaptersJson: jsonEncode(chapterRecords),
    );

    int targetIndex = savedIndex;
    if (targetIndex < 0 || targetIndex >= chapters.length) {
      targetIndex = 0;
    }

    final updatedBook = Map<String, dynamic>.from(book);
    updatedBook['source_id'] = result.sourceId;
    updatedBook['source_name'] = result.sourceName;
    updatedBook['book_url'] = result.bookUrl;
    updatedBook['chapter_count'] = savedCount;
    if (chapters.isNotEmpty) {
      updatedBook['latest_chapter_title'] = chapters.last['title'];
    }
    if (result.bookInfo != null) {
      updatedBook['cover_url'] =
          result.bookInfo!['cover_url'] ?? book['cover_url'];
      updatedBook['intro'] = result.bookInfo!['intro'] ?? book['intro'];
      updatedBook['author'] = result.bookInfo!['author'] ?? book['author'];
    }
    updatedBook['updated_at'] = now;

    await rust_api.saveBook(dbPath: dbPath, bookJson: jsonEncode(updatedBook));

    ref.invalidate(allBooksProvider);
    ref.invalidate(bookByIdProvider(widget.bookId));
    ref.invalidate(bookChaptersProvider(widget.bookId));

    _chapterRequestId++;
    final requestId = _chapterRequestId;
    setState(() {
      _isLoadingContent = true;
      _currentIndex = targetIndex;
      _cachedChapters = cachedChaptersList;
      _sourceId = result.sourceId;
      _sourceName = result.sourceName;
      _sourceUrl = result.bookUrl;
      _chapterUrl = cachedChaptersList.isNotEmpty
          ? (cachedChaptersList[targetIndex]['url'] as String? ?? '')
          : '';
      _loadedChapters = [];
      _cachedContinuousItems = null;
    });

    try {
      final chapterUrl = chapters[targetIndex]['url'] as String? ?? '';
      final json = await rust_api.getChapterContentWithSourceFromDb(
        dbPath: dbPath,
        sourceId: result.sourceId,
        chapterUrl: chapterUrl,
      );
      if (!mounted || requestId != _chapterRequestId) return;

      var content = '';
      if (json.isNotEmpty && json != 'null') {
        try {
          final data = jsonDecode(json);
          if (data is Map<String, dynamic>) {
            final platformRequest = data['platform_request'];
            if (platformRequest is Map) {
              content = await _executePlatformRequest(
                PlatformRequest.fromJson(
                    Map<String, dynamic>.from(platformRequest)),
              );
            } else {
              content = data['content'] as String? ?? '（无内容）';
            }
          } else {
            content = data.toString();
          }
        } catch (e) {
          debugPrint('[Reader] changeSource decode failed: $e');
          content = json;
        }
      } else {
        content = '（无内容）';
      }

      content = await _applyReplaceRulesViaRust(dbPath, content);

      await rust_api.saveReadingProgress(
        dbPath: dbPath,
        bookId: widget.bookId,
        chapterIndex: targetIndex,
        paragraphIndex: 0,
        offset: 0,
      );

      final title = chapters[targetIndex]['title'] as String? ?? '';
      content = _cleanHtml(content);
      setState(() {
        _chapterContent = content;
        _isLoadingContent = false;
        if (_settings.isScrollMode) {
          _loadedChapters = [_LoadedChapter(targetIndex, title, content)];
          _cachedContinuousItems = null;
        } else {
          _pageViewController?.updateSettings(_settings);
          _pageViewController?.loadChapter(targetIndex, title, content);
        }
      });
    } catch (e) {
      if (mounted && requestId == _chapterRequestId) {
        setState(() {
          _chapterContent = '换源后加载失败: $e';
          _isLoadingContent = false;
        });
      }
    }
  }

  void _startSearch() {
    setState(() {
      _controlsVisible = false;
    });
    _search.start();
  }

  void _closeSearch() {
    _search.close();
  }

  // Adapter that wires the chapter list seen by the reader (continuous mode
  // uses _loadedChapters, page mode falls back to a single synthetic chapter).
  List<String> _paragraphsForChapterAt(int idx) {
    if (_loadedChapters.isNotEmpty) {
      return _loadedChapters[idx].paragraphs;
    }
    return _LoadedChapter(_currentIndex, _chapterContent, _chapterContent)
        .paragraphs;
  }

  int get _searchChapterCount =>
      _loadedChapters.isNotEmpty ? _loadedChapters.length : 1;

  void _performSearch(String keyword) {
    _search.onScroll = (m) => _scrollToSearchMatch(m);
    _search.perform(keyword, _searchChapterCount, _paragraphsForChapterAt);
  }

  void _goToNextSearchMatch() {
    _search.onScroll = (m) => _scrollToSearchMatch(m);
    _search.next();
  }

  void _goToPrevSearchMatch() {
    _search.onScroll = (m) => _scrollToSearchMatch(m);
    _search.prev();
  }

  void _scrollToSearchMatch(rsc.ReaderSearchMatch match) {
    if (!_scrollController.hasClients) return;
    final estimatedOffset =
        200.0 * (match.chapterIdx * 50 + match.paragraphIdx);
    _scrollController.animateTo(
      estimatedOffset,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
    );
  }

  void _toggleAutoScroll() => _autoScroller.toggle();

  // TTS API kept as thin wrappers around [_tts] so existing UI builders
  // continue to work without churn. The actual logic lives in
  // [ReaderTtsManager].
  bool get _isSpeaking => _tts.isSpeaking;
  bool get _isPaused => _tts.isPaused;

  Future<void> _startTts() async {
    _tts.setChapterContent(_chapterContent);
    await _tts.start();
  }

  void _pauseTts() => _tts.pause();
  void _resumeTts() => _tts.resume();
  void _stopTts() => _tts.stop();
  void _ttsNextParagraph() => _tts.nextParagraph();
  void _ttsPrevParagraph() => _tts.prevParagraph();

  void _cycleTtsSpeed() {
    const speeds = [0.3, 0.5, 0.7, 0.8, 0.9, 1.0];
    final idx = speeds.indexOf(_settings.ttsSpeed);
    final next =
        speeds[(idx < 0 ? speeds.length - 1 : (idx + 1) % speeds.length)];
    final s = _settings.copyWith(ttsSpeed: next);
    _setReaderSettings(s, persist: true);
    _tts.setRate(next);
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _saveScrollPosition();
  }

  Widget _buildReadingInfoHeader(ReaderSettings settings) {
    final fg = Color(settings.effectiveTextColor);
    final infoStyle = TextStyle(
        color: fg.withValues(alpha: 0.5),
        fontSize: 12,
        decoration: TextDecoration.none);
    if (!settings.showChapterTitle) return const SizedBox.shrink();
    final chapters = _cachedChapters;
    final effIdx = _settings.isScrollMode
        ? _visibleChapterIndex
        : _currentIndex;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Text(
        chapters != null && effIdx < chapters.length
            ? (chapters[effIdx]['title'] as String? ?? '')
            : '',
        style: infoStyle,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildReadingInfoFooter(
      List<Map<String, dynamic>> chapters, ReaderSettings settings) {
    final fg = Color(settings.effectiveTextColor);
    final infoStyle = TextStyle(
        color: fg.withValues(alpha: 0.5),
        fontSize: 12,
        decoration: TextDecoration.none);
    final chapterIndex = _settings.isScrollMode
        ? _visibleChapterIndex
        : _currentIndex;
    final safeChapterIndex =
        chapters.isEmpty ? 0 : chapterIndex.clamp(0, chapters.length - 1);
    final chapterProgress = chapters.isEmpty
        ? 0
        : (((safeChapterIndex + 1) / chapters.length) * 100)
            .clamp(0, 100)
            .round();
    final pageIndex = (_pageViewController?.currentPageIndex ?? 0) + 1;
    final pageTotal = _pageViewController?.totalPagesInChapter ?? 0;
    final progressText = !_settings.isScrollMode
        ? '第 $pageIndex/$pageTotal 页 · 第 ${safeChapterIndex + 1}/${chapters.length} 章'
        : '第 ${safeChapterIndex + 1}/${chapters.length} 章 · $chapterProgress%';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 16, right: 16),
      child: Row(
        children: [
          if (settings.showProgress) ...[
            Expanded(
              child: Text(
                progressText,
                style: infoStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ] else
            const Spacer(),
          if (settings.showClock)
            ValueListenableBuilder<DateTime>(
              valueListenable: _nowNotifier,
              builder: (context, v, _) => Text(
                '${v.hour.toString().padLeft(2, '0')}:${v.minute.toString().padLeft(2, '0')}',
                style: infoStyle,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return ReaderSearchBar(
      settings: _settings,
      controller: _searchController,
      matchCount: _search.matches.length,
      currentIndex: _search.currentIndex,
      onChanged: (v) {
        _performSearch(v);
        setState(() {});
      },
      onPrev: _goToPrevSearchMatch,
      onNext: _goToNextSearchMatch,
      onClose: _closeSearch,
    );
  }

  Widget _buildTtsBar() {
    final paragraphs = _chapterContent
        .split(RegExp(r'\n+'))
        .where((p) => p.trim().isNotEmpty)
        .toList();
    return ReaderTtsBar(
      settings: _settings,
      isSpeaking: _isSpeaking,
      isPaused: _isPaused,
      paragraphIndex: _tts.paragraphIndex,
      paragraphTotal: paragraphs.length,
      onPrev: _ttsPrevParagraph,
      onNext: _ttsNextParagraph,
      onPause: _pauseTts,
      onResume: _resumeTts,
      onCycleSpeed: _cycleTtsSpeed,
      onShowSettings: _showReaderSettings,
      onStop: _stopTts,
    );
  }

  Widget _buildTopControls(BuildContext context,
      List<Map<String, dynamic>> chapters, bool hasPrev, bool hasNext) {
    final chapterTitle = _currentIndex < chapters.length
        ? (chapters[_currentIndex]['title'] as String? ?? '')
        : '';
    return ReaderTopBar(
      settings: _settings,
      bookName: _bookName,
      currentChapterTitle: chapterTitle,
      sourceName: _sourceName,
      sourceUrl: _sourceUrl,
      chapterUrl: _chapterUrl,
      hasBookmark: _hasBookmarkForChapter,
      onBack: () => context.pop(),
      onChangeSource: () {
        _toggleControls();
        _showChangeSourceDialog(context);
      },
      onRefreshChapter: _refreshChapter,
      onStartDownload: () {
        _toggleControls();
        _startDownload(context);
      },
      onToggleBookmark: () {
        _toggleControls();
        _toggleBookmark();
      },
    );
  }

  Widget _buildBottomControls(
      BuildContext context,
      List<Map<String, dynamic>> chapters,
      bool hasPrev,
      bool hasNext,
      ReaderSettings settings) {
    return ReaderBottomBar(
      settings: settings,
      chapterCount: chapters.length,
      currentIndex: _currentIndex,
      sliderValue: _sliderValue,
      hasPrev: hasPrev,
      hasNext: hasNext,
      isAutoScrolling: _isAutoScrolling,
      isNightMode: _settings.nightMode,
      onSliderChanged: (v) => setState(() => _sliderValue = v),
      onSliderChangeEnd: (targetIndex) {
        setState(() {
          _sliderValue = null;
          _currentIndex = targetIndex;
        });
        _navigateToChapter(targetIndex, chapters);
      },
      onPrevChapter: _goToPrevChapter,
      onNextChapter: _goToNextChapter,
      onStartSearch: _startSearch,
      onToggleAutoScroll: () {
        _toggleControls();
        _toggleAutoScroll();
      },
      onToggleNightMode: _toggleNightMode,
      onOpenReplaceRules: () {
        _toggleControls();
        context.push('/replace-rules');
      },
      onShowDirectory: _showDirectorySheet,
      onStartTts: () {
        _toggleControls();
        _startTts();
      },
      onShowReaderSettings: _showReaderSettings,
    );
  }

  void _showReaderSettings() {
    _toggleControls();
    showModalBottomSheet(
      context: context,
      backgroundColor: Color(_settings.effectiveBackgroundColor),
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height / 2,
      ),
      builder: (ctx) => ReaderSettingsSheet(
        initial: _settings,
        onChanged: (s) {
          _setReaderSettings(s, persist: true);
        },
      ),
    );
  }
}


