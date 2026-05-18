import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'theme.dart';
import 'refresh_rate_controller.dart';
import 'transport.dart';
import '../src/rust/api.dart' as rust_api;

import 'api/api_client.dart';
import 'api/reader_api.dart';
import 'api/bookshelf_api.dart';
import 'api/search_api.dart';
import 'api/source_api.dart';

// HTTP mode is retained only for future/debug clients. Android app data
// providers below intentionally use FRB so reads and writes share one store.
enum BackendMode { frb, http }

final backendModeProvider = StateProvider<BackendMode>((ref) => BackendMode.frb);

final apiBaseUrlProvider = StateProvider<String>((ref) => 'http://localhost:3000');

final apiTokenProvider = StateProvider<String?>((ref) => null);

final apiClientProvider = Provider<ApiClient>((ref) {
  final baseUrl = ref.watch(apiBaseUrlProvider);
  final token = ref.watch(apiTokenProvider);
  return ApiClient(baseUrl: baseUrl, token: token);
});

final readerApiProvider = Provider<ReaderApi>((ref) {
  final client = ref.watch(apiClientProvider);
  return ReaderApi(client);
});

final bookshelfApiProvider = Provider<BookshelfApi>((ref) {
  final client = ref.watch(apiClientProvider);
  return BookshelfApi(client);
});

final sourceApiProvider = Provider<SourceApi>((ref) {
  final client = ref.watch(apiClientProvider);
  return SourceApi(client);
});

final searchApiProvider = Provider<SearchApi>((ref) {
  final client = ref.watch(apiClientProvider);
  return SearchApi(client);
});

/// 统一传输层。在 [BackendMode.frb] 下返回 LocalTransport 占位；
/// 在 [BackendMode.http] 下返回 HttpTransport（含 SSE 能力）。
final transportProvider = Provider<Transport>((ref) {
  final mode = ref.watch(backendModeProvider);
  switch (mode) {
    case BackendMode.frb:
      return const LocalTransport();
    case BackendMode.http:
      final baseUrl = ref.watch(apiBaseUrlProvider);
      final token = ref.watch(apiTokenProvider);
      final t = HttpTransport(baseUrl: baseUrl, token: token);
      ref.onDispose(t.close);
      return t;
  }
});

final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);

final lightThemeProvider = Provider<ThemeData>((ref) => AppTheme.light);

final darkThemeProvider = Provider<ThemeData>((ref) => AppTheme.dark);

final fontSizeProvider = StateProvider<double>((ref) => 18.0);

final refreshRateModeProvider =
    StateProvider<RefreshRateMode>((ref) => RefreshRateMode.auto);

final dbDirProvider = FutureProvider<String>((ref) async {
  if (kIsWeb) return '.';
  try {
    final dir = Platform.isAndroid
        ? (await getApplicationDocumentsDirectory()).path
        : (await getApplicationSupportDirectory()).path;
    return dir;
  } catch (e) {
    return '.';
  }
});

final dbPathProvider = FutureProvider<String>((ref) async {
  final dbDir = await ref.watch(dbDirProvider.future);
  return '$dbDir/legado.db';
});

final dbInitializedProvider = FutureProvider<bool>((ref) async {
  final dbPath = await ref.watch(dbPathProvider.future);
  try {
    final result = await rust_api.initLegado(dbPath: dbPath);
    debugPrint('[FRB] initLegado: $result');
    final version = await rust_api.getDbVersion(dbPath: dbPath);
    debugPrint('[FRB] DB version: $version');
    return true;
  } catch (e) {
    debugPrint('[FRB] initLegado failed: $e');
    rethrow;
  }
});

// one-shot search test (runs during app init)
// Removed in code review: hardcoded sourceId, print() logs, fired by `watch`
// would also issue a stray search request. If you need to re-add a smoke,
// gate it behind kDebugMode and use debugPrint.

final allBooksProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  await ref.watch(dbInitializedProvider.future);
  final dbPath = await ref.watch(dbPathProvider.future);
  final json = await rust_api.getAllBooks(dbPath: dbPath);
  final List<dynamic> list = jsonDecode(json);
  return list.cast<Map<String, dynamic>>();
});

final allSourcesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  await ref.watch(dbInitializedProvider.future);
  final dbPath = await ref.watch(dbPathProvider.future);
  final json = await rust_api.getAllSources(dbPath: dbPath);
  final List<dynamic> list = jsonDecode(json);
  return list.cast<Map<String, dynamic>>();
});

final allReplaceRulesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  await ref.watch(dbInitializedProvider.future);
  final dbPath = await ref.watch(dbPathProvider.future);
  final json = await rust_api.getReplaceRules(dbPath: dbPath);
  final List<dynamic> list = jsonDecode(json);
  return list.cast<Map<String, dynamic>>();
});

/// 替换规则缓存代际。
///
/// 每次 ReplaceRule CRUD 后调用 `bumpReplaceRuleGeneration(ref)` 让 Rust
/// 侧的 enabled-rule 缓存失效；阅读器在切章节时把当前 generation 透传给
/// `apply_replace_rules`，缓存命中即不再走 DAO。
///
/// R43 — 多 isolate 场景的隐患：本 provider 是 Dart 进程内 StateProvider，
/// 每个 isolate 各自从 0 计数。Rust 侧 `apply_replace_rules` 的缓存是
/// `OnceLock` 全局且 key 包含 db_path（commit 8 的 R48 加固后），所以
/// 单 db_path + 多 isolate 各自 bump 时仍可能撞车（两个 isolate 都从 0
/// 开始，各自 bump 到 1 但规则集不同，Rust 缓存命中错误的版本）。
///
/// 当前没有跨 isolate 写规则的路径——`replace_rule_page.dart` 只在 UI
/// isolate 用——所以风险隐藏。如果以后引入 download isolate 写规则，
/// 这个 provider 需要改成 `StateProvider<(String, int)>` 把进程级随机
/// salt 也带进去，避免不同 isolate 的 generation 撞值。
final replaceRuleGenerationProvider = StateProvider<int>((ref) => 0);

void bumpReplaceRuleGeneration(WidgetRef ref) {
  ref.read(replaceRuleGenerationProvider.notifier).state++;
  ref.invalidate(allReplaceRulesProvider);
}

final downloadDirProvider = FutureProvider<String>((ref) async {
  final dbDir = await ref.watch(dbDirProvider.future);
  return '$dbDir/downloads';
});

final downloadTasksProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  await ref.watch(dbInitializedProvider.future);
  final dbPath = await ref.watch(dbPathProvider.future);
  final json = await rust_api.getDownloadTasks(dbPath: dbPath);
  final List<dynamic> list = jsonDecode(json);
  return list.cast<Map<String, dynamic>>();
});

final downloadChaptersProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((ref, taskId) async {
  await ref.watch(dbInitializedProvider.future);
  final dbPath = await ref.watch(dbPathProvider.future);
  final json = await rust_api.getDownloadChapters(dbPath: dbPath, taskId: taskId);
  final List<dynamic> list = jsonDecode(json);
  return list.cast<Map<String, dynamic>>();
});

final searchResultsProvider = FutureProvider.family<List<Map<String, dynamic>>, String>((ref, keyword) async {
  await ref.watch(dbInitializedProvider.future);
  final dbPath = await ref.watch(dbPathProvider.future);
  final json = await rust_api.searchBooksOffline(dbPath: dbPath, keyword: keyword);
  final List<dynamic> list = jsonDecode(json);
  return list.cast<Map<String, dynamic>>();
});

final bookByIdProvider =
    FutureProvider.family<Map<String, dynamic>?, String>((ref, bookId) async {
  final books = await ref.watch(allBooksProvider.future);
  for (final book in books) {
    if (book['id'] == bookId) return book;
  }
  return null;
});

final bookChaptersProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>(
        (ref, bookId) async {
  await ref.watch(dbInitializedProvider.future);
  final dbPath = await ref.watch(dbPathProvider.future);
  final json = await rust_api.getBookChapters(dbPath: dbPath, bookId: bookId);
  final List<dynamic> list = jsonDecode(json);
  return list.cast<Map<String, dynamic>>();
});

Future<ThemeMode> loadThemeModeFromDisk({String? directory}) async {
  try {
    final dir = directory ?? (Platform.isAndroid
        ? (await getApplicationDocumentsDirectory()).path
        : (await getApplicationSupportDirectory()).path);
    final file = File('$dir/settings.json');
    if (!await file.exists()) return ThemeMode.system;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return ThemeMode.values[json['themeMode'] as int? ?? 0];
  } catch (e) {
    return ThemeMode.system;
  }
}

Future<void> saveThemeModeToDisk(ThemeMode mode, {String? directory}) async {
  try {
    final dir = directory ?? (Platform.isAndroid
        ? (await getApplicationDocumentsDirectory()).path
        : (await getApplicationSupportDirectory()).path);
    final file = File('$dir/settings.json');
    final Map<String, dynamic> data = file.existsSync()
        ? jsonDecode(await file.readAsString()) as Map<String, dynamic>
        : {};
    data['themeMode'] = mode.index;
    await file.writeAsString(jsonEncode(data));
  } catch (e) {
    debugPrint('Failed to save theme mode: $e');
  }
}

Future<void> savePendingRoute(String route, {String? directory}) async {
  try {
    final dir = directory ?? (Platform.isAndroid
        ? (await getApplicationDocumentsDirectory()).path
        : (await getApplicationSupportDirectory()).path);
    final file = File('$dir/settings.json');
    final Map<String, dynamic> data = file.existsSync()
        ? jsonDecode(await file.readAsString()) as Map<String, dynamic>
        : {};
    data['pendingRoute'] = route;
    await file.writeAsString(jsonEncode(data));
  } catch (e) {
  }
}

Future<String?> loadPendingRoute({String? directory}) async {
  try {
    final dir = directory ?? (Platform.isAndroid
        ? (await getApplicationDocumentsDirectory()).path
        : (await getApplicationSupportDirectory()).path);
    final file = File('$dir/settings.json');
    if (!await file.exists()) {
      return null;
    }
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final route = json['pendingRoute'] as String?;
    return route;
  } catch (e) {
    return null;
  }
}

Future<void> clearPendingRoute({String? directory}) async {
  try {
    final dir = directory ?? (Platform.isAndroid
        ? (await getApplicationDocumentsDirectory()).path
        : (await getApplicationSupportDirectory()).path);
    final file = File('$dir/settings.json');
    if (await file.exists()) {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      json.remove('pendingRoute');
      await file.writeAsString(jsonEncode(json));
    } else {
    }
  } catch (e) {
  }
}

Future<double> loadFontSizeFromDisk() async {
  try {
    final dir = Platform.isAndroid
        ? (await getApplicationDocumentsDirectory()).path
        : (await getApplicationSupportDirectory()).path;
    final file = File('$dir/settings.json');
    if (!await file.exists()) return 18.0;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final v = json['fontSize'];
    if (v is num) return v.toDouble().clamp(14.0, 28.0);
    return 18.0;
  } catch (e) {
    return 18.0;
  }
}

Future<void> saveFontSizeToDisk(double fontSize) async {
  try {
    final dir = Platform.isAndroid
        ? (await getApplicationDocumentsDirectory()).path
        : (await getApplicationSupportDirectory()).path;
    final file = File('$dir/settings.json');
    final Map<String, dynamic> data = file.existsSync()
        ? jsonDecode(await file.readAsString()) as Map<String, dynamic>
        : {};
    data['fontSize'] = fontSize;
    await file.writeAsString(jsonEncode(data));
  } catch (e) {
    debugPrint('Failed to save font size: $e');
  }
}

Future<List<String>> loadSearchHistoryFromDisk() async {
  try {
    final dir = Platform.isAndroid
        ? (await getApplicationDocumentsDirectory()).path
        : (await getApplicationSupportDirectory()).path;
    final file = File('$dir/settings.json');
    if (!await file.exists()) return [];
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final list = json['searchHistory'];
    if (list is List) return list.map((e) => e.toString()).toList();
    return [];
  } catch (e) {
    return [];
  }
}

Future<void> saveSearchHistoryToDisk(List<String> history) async {
  try {
    final dir = Platform.isAndroid
        ? (await getApplicationDocumentsDirectory()).path
        : (await getApplicationSupportDirectory()).path;
    final file = File('$dir/settings.json');
    final Map<String, dynamic> data = file.existsSync()
        ? jsonDecode(await file.readAsString()) as Map<String, dynamic>
        : {};
    data['searchHistory'] = history;
    await file.writeAsString(jsonEncode(data));
  } catch (e) {
    debugPrint('Failed to save search history: $e');
  }
}

/// 搜索精确模式：是否仅保留 `name == kw / author == kw / contains kw` 的结果。
///
/// 复用 [loadSearchHistoryFromDisk] 同款 `settings.json` 持久化通道
/// （PRD 文本写的是 SharedPreferences，但工程里没有 shared_preferences 依赖
/// 只有 path_provider，且 search_history 已经走 settings.json，按
/// code-reuse-thinking-guide 复用现有方案，避免引入新依赖与平台 mock）。
Future<bool> loadSearchPrecisionFromDisk() async {
  try {
    final dir = Platform.isAndroid
        ? (await getApplicationDocumentsDirectory()).path
        : (await getApplicationSupportDirectory()).path;
    final file = File('$dir/settings.json');
    if (!await file.exists()) return false;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final v = json['searchPrecision'];
    if (v is bool) return v;
    return false;
  } catch (e) {
    return false;
  }
}

Future<void> saveSearchPrecisionToDisk(bool enabled) async {
  try {
    final dir = Platform.isAndroid
        ? (await getApplicationDocumentsDirectory()).path
        : (await getApplicationSupportDirectory()).path;
    final file = File('$dir/settings.json');
    final Map<String, dynamic> data = file.existsSync()
        ? jsonDecode(await file.readAsString()) as Map<String, dynamic>
        : {};
    data['searchPrecision'] = enabled;
    await file.writeAsString(jsonEncode(data));
  } catch (e) {
    debugPrint('Failed to save search precision: $e');
  }
}
/// 阅读器渲染模式。
///
/// 之前散落使用 `_settings.pageAnim == ReaderPageAnim.scroll` 或
/// `_settings.isScrollMode` 来切换 ListView 渲染路径。抽出 enum 后调用方
/// 可用 switch 表达全部分支，遗漏一个会有静态警告（虽然 Dart 不会强制
/// exhaustive，但 IDE 提示更明显）。
enum ReaderRenderMode {
  /// 翻页模式：使用 [PageViewWidget] + 各种 delegate（cover/slide/simulation/...）。
  paged,

  /// 连续滚动模式：把整本按章节连续排版到一个 ListView 里（原
  /// `ReaderPageMode.continuousScroll`，现在并入 [ReaderPageAnim.scroll]）。
  continuous,
}

/// 翻页动画类型。v4 起把"连续滚动"作为一种翻页动画并入此枚举（命名为
/// `scroll`），UI 不再有独立的"翻页方式"分组，统一称作"翻页动画"。
///
/// 取值列表（v4，当前）：
///   0 = cover      覆盖
///   1 = slide      平移
///   2 = simulation 仿真（书本翻页）
///   3 = fade       淡入淡出
///   4 = noAnim     无动画
///   5 = scroll     滚动（即原 `ReaderPageMode.continuousScroll`，整本按章节连续排版）
///
/// 历史版本兼容：
/// - settingsVersion ≤ 1：pageAnim 旧语义 (0=无, 2=cover, 3=slide) +
///   PageMode 旧枚举 (0=continuousScroll, 1=tapChapter, 2=page) → 见 [migrateFromV1]
/// - settingsVersion == 2：pageAnim 旧语义 (0=cover...5=noAnim) +
///   PageMode 旧枚举（同 v1） → 见 [migrateFromV2]
/// - settingsVersion == 3：pageAnim (0=cover...4=noAnim, 无 scroll) +
///   PageMode (0=continuousScroll, 1=page)，两者并存 → 见 [migrateFromV3]
/// - settingsVersion == 4：pageAnim 含 scroll，PageMode 已废弃。
/// - settingsVersion == 5：当前。新增 pageAnimDurationMs（int，默认 300）。
class ReaderPageAnim {
  static const int cover = 0;
  static const int slide = 1;
  static const int simulation = 2;
  static const int fade = 3;
  static const int noAnim = 4;

  /// 滚动翻页 = 整本按章节连续排版（原 ReaderPageMode.continuousScroll）。
  /// 选这个时不走 PageView 渲染，走 ListView 长滚动。
  static const int scroll = 5;

  static const int min = 0;
  static const int max = 5;

  static const Map<int, String> labels = {
    cover: '覆盖',
    slide: '平移',
    simulation: '仿真',
    fade: '淡入淡出',
    noAnim: '无动画',
    scroll: '滚动',
  };

  /// settingsVersion ≤ 1（Legado 旧版）→ v4 当前值。
  /// PageMode 旧值（0=continuousScroll, 1=tapChapter, 2=page）需配合
  /// [migratePageModeV1ToAnimV4] 一起决定。
  ///
  /// 旧 PageAnim:
  ///   0 (无动画) → 新 4 (noAnim)
  ///   2 (覆盖)   → 新 0 (cover)
  ///   3 (平移)   → 新 1 (slide)
  ///   其它       → 新 4 (noAnim)
  static int migrateFromV1(int oldValue) {
    switch (oldValue) {
      case 0:
        return noAnim;
      case 2:
        return cover;
      case 3:
        return slide;
      default:
        return noAnim;
    }
  }

  /// settingsVersion == 2（含 scroll 的旧 PageAnim 语义）→ v4 当前值。
  /// 这一版 scroll 是被删除过的，所以反过来要把"被删除的 scroll"理解成
  /// 想要"滚动模式"的用户，但当时已经映射到 noAnim 了，无从分辨。这里只
  /// 处理静态的 anim 数值；PageMode 仍由 [migratePageModeV2ToAnimV4] 承担。
  ///
  /// 旧 PageAnim (v2):
  ///   0=cover/1=slide/2=simulation → 新值不变
  ///   3=scroll → 这一版的 scroll 是分页内的"上下滚动"动画，与 v4 的整本
  ///             连续滚动语义不同；保守 fallback 到 noAnim
  ///   4=fade → 新 3 (fade)
  ///   5=noAnim → 新 4 (noAnim)
  static int migrateFromV2(int oldValue) {
    switch (oldValue) {
      case 0:
      case 1:
      case 2:
        return oldValue;
      case 3:
        return noAnim;
      case 4:
        return fade;
      case 5:
        return noAnim;
      default:
        return noAnim;
    }
  }

  /// settingsVersion == 3 → v4。
  /// v3 的 pageAnim 0..4 与 v4 完全对齐（cover/slide/simulation/fade/noAnim）。
  /// PageMode 由 [migratePageModeV3ToAnimV4] 处理：v3 continuousScroll 在 v4 里
  /// 等价于 pageAnim=scroll。
  static int migrateFromV3(int oldValue) {
    return oldValue.clamp(min, noAnim); // v3 max 是 noAnim=4
  }
}

/// 旧 PageMode（v1/v2 含 tapChapter）→ v4 PageAnim 的合成迁移。
/// 当 [migrateFromV1] / [migrateFromV2] 处理了 pageAnim 的纯数值后，PageMode
/// 决定要不要进一步覆盖成 scroll：
///
/// - 旧 0 (continuousScroll) → 强制改 pageAnim = scroll
/// - 旧 1 (tapChapter)       → 不动 pageAnim（tapChapter 没有"连续滚动"语义）
/// - 旧 2 (page)             → 不动 pageAnim
///
/// 即使 v1/v2 里同时存在 PageAnim 和 PageMode，PageMode 优先级更高（用户当时
/// 选择"连续滚动"模式时 PageAnim 是无效占位）。
int overlayPageModeOnAnim({
  required int oldPageMode,
  required int currentAnim,
}) {
  if (oldPageMode == 0) {
    return ReaderPageAnim.scroll;
  }
  return currentAnim;
}

/// `settings.json` 中 `readerSettings` 的 schema 版本。
///
/// - 1（或缺省）：pageAnim 旧语义 (0=无, 2=cover, 3=slide) + PageMode 含 tapChapter
/// - 2：pageAnim Legado MD3 (0=cover...5=noAnim) + PageMode 仍含 tapChapter
/// - 3：删除 PageAnim.scroll，删除 PageMode.tapChapter（PageMode 仍存在）
/// - 4：合并 PageMode 进 PageAnim（scroll = 原 continuousScroll）
/// - 5：新增 `pageAnimDurationMs`（int，默认 300）—— 翻页动画时长可配（当前版本）
const int kReaderSettingsCurrentVersion = 5;

class ReaderSettings {
  final double fontSize;
  final int fontWeightIndex;
  final String? fontFamily;
  final int textColor;
  final int backgroundColor;
  final String? backgroundImagePath;
  final double letterSpacing;
  final double lineHeight;
  final double paragraphSpacing;
  final double horizontalPadding;
  final double verticalPadding;
  final String paragraphIndent;
  final int pageAnim;
  final bool nightMode;
  final int nightBackgroundColor;
  final int nightTextColor;
  final bool showReadingInfo;
  final bool showChapterTitle;
  final bool showClock;
  final bool showProgress;
  final double ttsSpeed;

  /// 翻页动画时长（毫秒）。tap / drag fling 共用同一个 [AnimationController]
  /// 的 duration；调大此值可放慢仿真翻页折角弹起的过程。
  ///
  /// 默认 300ms（对齐 Legado MD3 原版体感），UI Slider 提供 200..1000ms 范围。
  final int pageAnimDurationMs;

  const ReaderSettings({
    this.fontSize = 18.0,
    this.fontWeightIndex = 1,
    this.fontFamily,
    this.textColor = 0xFF3E3D3B,
    this.backgroundColor = 0xFFEEEEEE,
    this.backgroundImagePath,
    this.letterSpacing = 0.1,
    this.lineHeight = 1.8,
    this.paragraphSpacing = 8.0,
    this.horizontalPadding = 16.0,
    this.verticalPadding = 16.0,
    this.paragraphIndent = '\u3000\u3000',
    this.pageAnim = ReaderPageAnim.scroll,
    this.nightMode = false,
    this.nightBackgroundColor = 0xFF1A1A1A,
    this.nightTextColor = 0xFFADADAD,
    this.showReadingInfo = true,
    this.showChapterTitle = true,
    this.showClock = true,
    this.showProgress = true,
    this.ttsSpeed = 0.5,
    this.pageAnimDurationMs = 300,
  });

  static const List<int> fontWeightValues = [400, 700, 900];
  static const List<Color> presetColors = [
    Color(0xFFF5ECD7),
    Color(0xFFFFF8E7),
    Color(0xFFC8E6C9),
    Color(0xFF212121),
    Color(0xFF000000),
  ];

  int get effectiveBackgroundColor => nightMode ? nightBackgroundColor : backgroundColor;
  int get effectiveTextColor => nightMode ? nightTextColor : textColor;

  /// 阅读器当前的渲染模式。
  ///
  /// 由 [pageAnim] 派生：`pageAnim == scroll` 走 `continuous`（整本按章节
  /// 连续排版的 ListView），其它值走 `paged`（PageView + delegate 翻页）。
  /// 把这层判断从散落的 `_settings.isScrollMode` 调用集中到 enum，便于阅读
  /// 与后续扩展（比如未来增加章节内分页的"半连续"模式）。
  ReaderRenderMode get renderMode => pageAnim == ReaderPageAnim.scroll
      ? ReaderRenderMode.continuous
      : ReaderRenderMode.paged;

  /// 当前是否为"滚动模式"（即原 `ReaderPageMode.continuousScroll`）。
  /// 等价于 `renderMode == ReaderRenderMode.continuous`，保留为快捷别名。
  ///
  /// R37: this alias is the recommended call-site form for the binary
  /// "scroll vs paged" branch (it reads naturally and has the same
  /// compile-time safety as the enum because both routes through the
  /// same `renderMode` getter). When/if a third mode is added, switch
  /// the call-sites that need ternary handling to `switch (renderMode)`
  /// and tighten this alias's doc-comment to call out the boolean
  /// projection's loss of fidelity. For now keeping ~16 boolean checks
  /// is preferable to expanding them into `renderMode ==
  /// ReaderRenderMode.continuous` everywhere.
  bool get isScrollMode => renderMode == ReaderRenderMode.continuous;

  ReaderSettings copyWith({
    double? fontSize,
    int? fontWeightIndex,
    String? fontFamily,
    int? textColor,
    int? backgroundColor,
    String? backgroundImagePath,
    double? letterSpacing,
    double? lineHeight,
    double? paragraphSpacing,
    double? horizontalPadding,
    double? verticalPadding,
    String? paragraphIndent,
    int? pageAnim,
    bool? nightMode,
    int? nightBackgroundColor,
    int? nightTextColor,
    bool? showReadingInfo,
    bool? showChapterTitle,
    bool? showClock,
    bool? showProgress,
    double? ttsSpeed,
    int? pageAnimDurationMs,
  }) {
    return ReaderSettings(
      fontSize: fontSize ?? this.fontSize,
      fontWeightIndex: fontWeightIndex ?? this.fontWeightIndex,
      fontFamily: fontFamily ?? this.fontFamily,
      textColor: textColor ?? this.textColor,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      backgroundImagePath: backgroundImagePath ?? this.backgroundImagePath,
      letterSpacing: letterSpacing ?? this.letterSpacing,
      lineHeight: lineHeight ?? this.lineHeight,
      paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
      horizontalPadding: horizontalPadding ?? this.horizontalPadding,
      verticalPadding: verticalPadding ?? this.verticalPadding,
      paragraphIndent: paragraphIndent ?? this.paragraphIndent,
      pageAnim: pageAnim ?? this.pageAnim,
      nightMode: nightMode ?? this.nightMode,
      nightBackgroundColor: nightBackgroundColor ?? this.nightBackgroundColor,
      nightTextColor: nightTextColor ?? this.nightTextColor,
      showReadingInfo: showReadingInfo ?? this.showReadingInfo,
      showChapterTitle: showChapterTitle ?? this.showChapterTitle,
      showClock: showClock ?? this.showClock,
      showProgress: showProgress ?? this.showProgress,
      ttsSpeed: ttsSpeed ?? this.ttsSpeed,
      pageAnimDurationMs: pageAnimDurationMs ?? this.pageAnimDurationMs,
    );
  }

  int get fontWeight =>
      fontWeightIndex >= 0 && fontWeightIndex < fontWeightValues.length
          ? fontWeightValues[fontWeightIndex]
          : 400;

  Map<String, dynamic> toJson() => {
        'settingsVersion': kReaderSettingsCurrentVersion,
        'fontSize': fontSize,
        'fontWeightIndex': fontWeightIndex,
        'fontFamily': fontFamily,
        'textColor': textColor,
        'backgroundColor': backgroundColor,
        'backgroundImagePath': backgroundImagePath,
        'letterSpacing': letterSpacing,
        'lineHeight': lineHeight,
        'paragraphSpacing': paragraphSpacing,
        'horizontalPadding': horizontalPadding,
        'verticalPadding': verticalPadding,
        'paragraphIndent': paragraphIndent,
        'pageAnim': pageAnim,
        'nightMode': nightMode,
        'nightBackgroundColor': nightBackgroundColor,
        'nightTextColor': nightTextColor,
        'showReadingInfo': showReadingInfo,
        'showChapterTitle': showChapterTitle,
        'showClock': showClock,
        'showProgress': showProgress,
        'ttsSpeed': ttsSpeed,
        'pageAnimDurationMs': pageAnimDurationMs,
      };

  factory ReaderSettings.fromJson(Map<String, dynamic> json) {
    final version = json['settingsVersion'] as int? ?? 1;

    // ── PageAnim migration chain: v1/v2/v3 → v4 ─────────────────────────
    final rawPageAnim = json['pageAnim'] as int? ?? 0;
    int pageAnim;
    if (version <= 1) {
      pageAnim = ReaderPageAnim.migrateFromV1(rawPageAnim);
    } else if (version == 2) {
      pageAnim = ReaderPageAnim.migrateFromV2(rawPageAnim);
    } else if (version == 3) {
      pageAnim = ReaderPageAnim.migrateFromV3(rawPageAnim);
    } else {
      pageAnim = rawPageAnim.clamp(ReaderPageAnim.min, ReaderPageAnim.max);
    }

    // ── PageMode overlay (v ≤ 3) → 把"continuousScroll"折叠成 pageAnim=scroll
    if (version < 4 && json.containsKey('pageMode')) {
      final rawPageMode = json['pageMode'] as int? ?? 0;
      // v1/v2 旧 enum: 0=continuousScroll, 1=tapChapter, 2=page
      // v3 enum:      0=continuousScroll, 1=page
      // 不论哪一版，pageMode == 0 总是 continuousScroll，需要折叠为 scroll。
      pageAnim = overlayPageModeOnAnim(
        oldPageMode: rawPageMode,
        currentAnim: pageAnim,
      );
    }

    return ReaderSettings(
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 18.0,
      fontWeightIndex: json['fontWeightIndex'] as int? ?? 1,
      fontFamily: json['fontFamily'] as String?,
      textColor: json['textColor'] as int? ?? 0xFF3E3D3B,
      backgroundColor: json['backgroundColor'] as int? ?? 0xFFEEEEEE,
      backgroundImagePath: json['backgroundImagePath'] as String?,
      letterSpacing: (json['letterSpacing'] as num?)?.toDouble() ?? 0.1,
      lineHeight: (json['lineHeight'] as num?)?.toDouble() ?? 1.8,
      paragraphSpacing: (json['paragraphSpacing'] as num?)?.toDouble() ?? 8.0,
      horizontalPadding: (json['horizontalPadding'] as num?)?.toDouble() ?? 16.0,
      verticalPadding: (json['verticalPadding'] as num?)?.toDouble() ?? 16.0,
      paragraphIndent: json['paragraphIndent'] as String? ?? '\u3000\u3000',
      pageAnim: pageAnim,
      nightMode: json['nightMode'] as bool? ?? false,
      nightBackgroundColor: json['nightBackgroundColor'] as int? ?? 0xFF1A1A1A,
      nightTextColor: json['nightTextColor'] as int? ?? 0xFFADADAD,
      showReadingInfo: json['showReadingInfo'] as bool? ?? true,
      showChapterTitle: json['showChapterTitle'] as bool? ?? true,
      showClock: json['showClock'] as bool? ?? true,
      showProgress: json['showProgress'] as bool? ?? true,
      ttsSpeed: (json['ttsSpeed'] as num?)?.toDouble() ?? 0.5,
      // v5 新字段；v ≤ 4 旧 JSON 缺省 fallback 到 300ms（与默认值一致）。
      pageAnimDurationMs: (json['pageAnimDurationMs'] as int?) ?? 300,
    );
  }
}

final readerSettingsProvider = StateProvider<ReaderSettings>((ref) => const ReaderSettings());

Future<ReaderSettings> loadReaderSettingsFromDisk() async {
  try {
    final dir = Platform.isAndroid
        ? (await getApplicationDocumentsDirectory()).path
        : (await getApplicationSupportDirectory()).path;
    final file = File('$dir/settings.json');
    if (!await file.exists()) return const ReaderSettings();
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final settingsJson = json['readerSettings'];
    if (settingsJson is Map<String, dynamic>) {
      return ReaderSettings.fromJson(settingsJson);
    }
    return const ReaderSettings();
  } catch (e) {
    return const ReaderSettings();
  }
}

Future<void> saveReaderSettingsToDisk(ReaderSettings settings) async {
  try {
    final dir = Platform.isAndroid
        ? (await getApplicationDocumentsDirectory()).path
        : (await getApplicationSupportDirectory()).path;
    final file = File('$dir/settings.json');
    final Map<String, dynamic> data = file.existsSync()
        ? jsonDecode(await file.readAsString()) as Map<String, dynamic>
        : {};
    data['readerSettings'] = settings.toJson();
    await file.writeAsString(jsonEncode(data));
  } catch (e) {
    debugPrint('Failed to save reader settings: $e');
  }
}

Future<bool> loadBookshelfGridViewFromDisk() async {
  try {
    final dir = Platform.isAndroid
        ? (await getApplicationDocumentsDirectory()).path
        : (await getApplicationSupportDirectory()).path;
    final file = File('$dir/settings.json');
    if (!await file.exists()) return false;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final v = json['bookshelfGridView'];
    if (v is bool) return v;
    return false;
  } catch (e) {
    return false;
  }
}

Future<void> saveBookshelfGridViewToDisk(bool isGridView) async {
  try {
    final dir = Platform.isAndroid
        ? (await getApplicationDocumentsDirectory()).path
        : (await getApplicationSupportDirectory()).path;
    final file = File('$dir/settings.json');
    final Map<String, dynamic> data = file.existsSync()
        ? jsonDecode(await file.readAsString()) as Map<String, dynamic>
        : {};
    data['bookshelfGridView'] = isGridView;
    await file.writeAsString(jsonEncode(data));
  } catch (e) {
    debugPrint('Failed to save bookshelf grid view: $e');
  }
}

Future<RefreshRateMode> loadRefreshRateModeFromDisk() async {
  try {
    final dir = Platform.isAndroid
        ? (await getApplicationDocumentsDirectory()).path
        : (await getApplicationSupportDirectory()).path;
    final file = File('$dir/settings.json');
    if (!await file.exists()) return RefreshRateMode.auto;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final v = json['refreshRateMode'];
    if (v is int) return RefreshRateModeLabel.fromIndex(v);
    return RefreshRateMode.auto;
  } catch (e) {
    return RefreshRateMode.auto;
  }
}

Future<void> saveRefreshRateModeToDisk(RefreshRateMode mode) async {
  try {
    final dir = Platform.isAndroid
        ? (await getApplicationDocumentsDirectory()).path
        : (await getApplicationSupportDirectory()).path;
    final file = File('$dir/settings.json');
    final Map<String, dynamic> data = file.existsSync()
        ? jsonDecode(await file.readAsString()) as Map<String, dynamic>
        : {};
    data['refreshRateMode'] = mode.persistIndex;
    await file.writeAsString(jsonEncode(data));
  } catch (e) {
    debugPrint('Failed to save refresh rate mode: $e');
  }
}
