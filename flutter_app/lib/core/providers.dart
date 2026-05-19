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

// HTTP mode is retained only for future/debug clients. Android app data
// providers below intentionally use FRB so reads and writes share one store.
//
// BATCH-18a (05-20): 死代码清理。删除 `core/api/` 整目录（5 个 Dio 客户端
// 薄壳类 + dto.dart 中 5 个仅 Dio 路径用的 DTO）+ 7 个零消费者 provider
// （apiClientProvider / readerApiProvider / bookshelfApiProvider /
// sourceApiProvider / searchApiProvider / apiBaseUrlProvider /
// apiTokenProvider）。仅 [PlatformRequest] DTO 仍被 reader_page 真用，
// 已迁到 `core/dto.dart`。`BackendMode` enum + [transportProvider] +
// [HttpTransport] 保留——SSE 路径在 search_page 仍引用，是否真死留
// BATCH-18b 专项确认。
enum BackendMode { frb, http }

final backendModeProvider = StateProvider<BackendMode>((ref) => BackendMode.frb);

/// 统一传输层。在 [BackendMode.frb] 下返回 LocalTransport 占位；
/// 在 [BackendMode.http] 下返回 HttpTransport（含 SSE 能力）。
///
/// HTTP 模式当前仅保留给未来/调试客户端使用；base URL 与 token 暂硬编码
/// 默认值（原 apiBaseUrlProvider / apiTokenProvider 在 BATCH-18a 中作为
/// 零消费者一并清理）。如果 BATCH-18b 决定保留 HTTP 路径，再把这两项
/// 重新提成可配置 provider。
final transportProvider = Provider<Transport>((ref) {
  final mode = ref.watch(backendModeProvider);
  switch (mode) {
    case BackendMode.frb:
      return const LocalTransport();
    case BackendMode.http:
      final t = HttpTransport(
        baseUrl: 'http://localhost:3000',
        token: null,
      );
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
  // 批次 8 (05-19): 透传 bookshelfSort 给 Rust 端，让 ORDER BY 生效。
  // allBooksProvider 不分 family —— 整书架排序就这一个全局设置。
  final sortOrder = ref.watch(bookshelfSortProvider);
  final json = await rust_api.getAllBooks(dbPath: dbPath, sortOrder: sortOrder);
  final List<dynamic> list = jsonDecode(json);
  return list.cast<Map<String, dynamic>>();
});

/// 批次 8 (05-19): 书架排序方式（int），从 [readerSettingsProvider] 派生。
///
/// 用 `Provider`（非 StateProvider）保证：写永远走
/// `readerSettingsProvider.notifier.state = newSettings.copyWith(...)`
/// 单一路径，避免两个互相不同步的状态源；同时让所有依赖它的 provider
/// （allBooksProvider / booksByGroupProvider）能在 settings 变更时自动
/// 重新触发。
final bookshelfSortProvider = Provider<int>((ref) {
  return ref.watch(readerSettingsProvider).bookshelfSort;
});

/// 批次 7：拉取所有用户自建分组（按 sort_order 升序），
/// 给书架顶栏 TabBar 用。每次分组 CRUD 后调用 `ref.invalidate` 刷新。
final bookGroupsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  await ref.watch(dbInitializedProvider.future);
  final dbPath = await ref.watch(dbPathProvider.future);
  final json = await rust_api.listBookGroups(dbPath: dbPath);
  final List<dynamic> list = jsonDecode(json);
  return list.cast<Map<String, dynamic>>();
});

/// 批次 7：按分组 ID 拉书。groupId 语义：
/// - `-1` → 全部（"全部" Tab）
/// - `0`  → 未分组（"未分组" Tab）
/// - `>= 1` → 具体分组
///
/// 批次 8 (05-19): family 入参从 `int groupId` 升级为 record `(groupId, sort)`，
/// 让每个 Tab 都按当前用户偏好的排序方式拉书。所有调用方（书架页 6 个 Tab +
/// 长按菜单调用）必须显式传入 sort（默认从 [bookshelfSortProvider] 读）。
///
/// 用 `family.autoDispose` —— 不同 Tab + 不同 sort 的 cache 互相独立，
/// 离开书架页时整体释放。
final booksByGroupProvider = FutureProvider.family
    .autoDispose<List<Map<String, dynamic>>, (int, int)>((ref, key) async {
  final (groupId, sortOrder) = key;
  await ref.watch(dbInitializedProvider.future);
  final dbPath = await ref.watch(dbPathProvider.future);
  final json = await rust_api.listBooksByGroup(
      dbPath: dbPath, groupId: groupId, sortOrder: sortOrder);
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
  final stopwatch = Stopwatch()..start();
  debugPrint('[providers.timing] bookChaptersProvider START bookId=$bookId');
  await ref.watch(dbInitializedProvider.future);
  debugPrint(
      '[providers.timing] bookChaptersProvider db ready t=${stopwatch.elapsedMilliseconds}ms');
  final dbPath = await ref.watch(dbPathProvider.future);
  debugPrint(
      '[providers.timing] bookChaptersProvider dbPath ready t=${stopwatch.elapsedMilliseconds}ms');
  final json = await rust_api.getBookChapters(dbPath: dbPath, bookId: bookId);
  debugPrint(
      '[providers.timing] bookChaptersProvider Rust returned len=${json.length} t=${stopwatch.elapsedMilliseconds}ms');
  final List<dynamic> list = jsonDecode(json);
  final result = list.cast<Map<String, dynamic>>();
  // 统计有 content 的章节数
  final withContent =
      result.where((m) => (m['content'] as String?)?.isNotEmpty ?? false).length;
  debugPrint(
      '[providers.timing] bookChaptersProvider DONE chapters=${result.length} withContent=$withContent TOTAL=${stopwatch.elapsedMilliseconds}ms');
  return result;
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
/// - 5：新增 `pageAnimDurationMs`（int，默认 300）—— 翻页动画时长可配
/// - 6：新增 `screenBrightness`（double，-1.0 = 跟随系统）+ `keepScreenOn`
///   （bool，默认 true）—— 屏幕亮度调节 + 屏幕常亮。
/// - 7：新增 `bookshelfSort`（int，默认 0=Default）—— 书架排序方式，对齐
///   原 Legado `AppConfig.bookshelfSort`。语义见 Rust `BookSort` enum。
///   旧 JSON 缺字段时 fromJson 走 `?? 0`，不影响存档兼容（当前版本）。
const int kReaderSettingsCurrentVersion = 7;

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

  /// 批次 1 (05-18): 屏幕亮度 0.0..1.0；-1.0 表示"跟随系统"（不主动调节）。
  ///
  /// 进 reader 时由 [_ReaderPageState._applyHardwareSettings] 同步给
  /// [ScreenBrightness.setApplicationScreenBrightness]；退出 reader（dispose）
  /// 时调用 [ScreenBrightness.resetApplicationScreenBrightness] 复位，避免
  /// reader 设置的亮度污染书架等其它页面（应用级亮度，不影响系统亮度本身）。
  ///
  /// 用 `-1.0` 哨兵值代替 nullable，简化 JSON 序列化路径。
  final double screenBrightness;

  /// 批次 1 (05-18): 进 reader 时是否启用 [WakelockPlus] 防止系统超时锁屏。
  ///
  /// 默认 true，对齐原 Legado `BaseReadBookActivity.keepScreenOn` 默认行为
  /// （阅读时主流期望）。dispose 时一定调 [WakelockPlus.disable]。

  final bool keepScreenOn;

  /// 批次 2 (05-18): 启用音量键翻页（VOLUME_UP / VOLUME_DOWN）。默认 true，
  /// 对齐原 Legado MD3 `AppConfig.volumeKeyPage` 默认值。
  ///
  /// PageUp / PageDown / Space / 方向键不受此开关影响——它们没有系统冲突
  /// 行为，始终翻页。该开关只挡住"音量键被吃成翻页"这一条路径。
  final bool enableVolumeKeyPage;

  /// 批次 2 (05-18): 朗读中音量键是否仍翻页。默认 false（朗读时让系统调
  /// 音量），对齐原 Legado MD3 `AppConfig.volumeKeyPageOnPlay` 默认行为。
  ///
  /// 仅在 [enableVolumeKeyPage] 为 true 时才会被检查；如果设为 true，则
  /// 朗读中音量键依旧翻页，调音量需要靠系统音量条手动调节。
  final bool volumeKeyPageOnTts;

  /// 批次 3 (05-18): 阅读器 3×3 点击区域配置。9 个槽位，索引顺序：
  /// `[0=左上, 1=上, 2=右上, 3=左, 4=中, 5=右, 6=左下, 7=下, 8=右下]`。
  /// 每个值：0=prevPage / 1=nextPage / 2=showMenu / 3=nothing。
  ///
  /// 默认 [tapZonesDefault] = `[2,2,2,2,2,2,0,1,1]`：上半屏 + 中排全菜单、
  /// 左下 prev、下中 + 右下 next（移动端单手习惯：下排操作翻页、上排出菜单）。
  ///
  /// 仍保 schema=v6（与 batch01/02 同模式：fromJson 缺字段 fallback 默认列表，
  /// 不强升 settingsVersion）。
  final List<int> tapZones;

  /// 批次 3 默认预设：左下 prev、下中 next、右下 next、其余 menu（单手翻页）。
  static const List<int> tapZonesDefault = [2, 2, 2, 2, 2, 2, 0, 1, 1];

  /// 批次 3 经典预设：上半屏左 prev / 上半屏右 next / 中间 menu / 下半屏左 next /
  /// 下半屏右 next。`[0,0,0,0,2,1,1,1,1]` — 经典 GPS 类阅读器布局。
  static const List<int> tapZonesClassic = [0, 0, 0, 0, 2, 1, 1, 1, 1];

  /// 批次 3 全屏菜单预设：9 格全 showMenu，靠音量键 / 物理键翻页。
  static const List<int> tapZonesFullMenu = [2, 2, 2, 2, 2, 2, 2, 2, 2];

  /// 批次 4 (05-18): 自动滚动速度档位（仅滚动模式）。1..10 整数 → 直接作
  /// 为每 50ms 推进的像素数（pixelsPerStep）。默认 1（≈ 20 px/s，与原硬
  /// 编码值一致）。10 档约等于 200 px/s，肉眼明显但仍可读。
  ///
  /// 与 [autoPageIntervalSeconds] 互不影响：滚动模式只看本字段，分页模式
  /// 只看 [autoPageIntervalSeconds]。仍保 schema=v6（fromJson 缺字段 fallback）。
  final int autoScrollSpeed;

  /// 批次 4 (05-18): 分页模式下两次自动翻页之间的间隔（秒）。1..30 整数。
  /// 默认 10s（中等阅读速度，约 200 字/页 / 10s = 20 字/s）。
  ///
  /// 实际间隔 = autoPageIntervalSeconds × 1000ms 传给 ReaderAutoScroller.pageIntervalMs。
  final int autoPageIntervalSeconds;

  /// 批次 5 (05-18): 启用长按文字菜单。默认 true。长按 reader 弹底部 sheet
  /// 提供复制 / 分享 / 朗读三个动作（整页粒度，MVP 阶段不做字符级选区）。
  /// 用户可关闭以避免长按误触。
  final bool enableLongPressMenu;

  /// 批次 8 (05-19): 书架排序方式。0=Default(rowid ASC) / 1=Name / 2=Author /
  /// 3=TimeAdd / 4=DurTime / 5=ChapterCount。语义对齐 Rust `BookSort` enum。
  ///
  /// 默认 0（与历史行为一致：按插入顺序）。schema=v7（与 batch01..batch05
  /// 同模式：fromJson 缺字段 fallback `?? 0`，老 JSON 自动升级无感）。
  /// 透传给 bridge `getAllBooks` / `listBooksByGroup` 的 `sortOrder` 入参；
  /// 越界值由 Rust 端 [`BookSort::from_i32`] clamp 回 Default。
  final int bookshelfSort;

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
    this.screenBrightness = -1.0,
    this.keepScreenOn = true,
    this.enableVolumeKeyPage = true,
    this.volumeKeyPageOnTts = false,
    this.tapZones = tapZonesDefault,
    this.autoScrollSpeed = 1,
    this.autoPageIntervalSeconds = 10,
    this.enableLongPressMenu = true,
    this.bookshelfSort = 0,
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
    double? screenBrightness,
    bool? keepScreenOn,
    bool? enableVolumeKeyPage,
    bool? volumeKeyPageOnTts,
    List<int>? tapZones,
    int? autoScrollSpeed,
    int? autoPageIntervalSeconds,
    bool? enableLongPressMenu,
    int? bookshelfSort,
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
      screenBrightness: screenBrightness ?? this.screenBrightness,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      enableVolumeKeyPage: enableVolumeKeyPage ?? this.enableVolumeKeyPage,
      volumeKeyPageOnTts: volumeKeyPageOnTts ?? this.volumeKeyPageOnTts,
      tapZones: tapZones ?? this.tapZones,
      autoScrollSpeed: autoScrollSpeed ?? this.autoScrollSpeed,
      autoPageIntervalSeconds:
          autoPageIntervalSeconds ?? this.autoPageIntervalSeconds,
      enableLongPressMenu: enableLongPressMenu ?? this.enableLongPressMenu,
      bookshelfSort: bookshelfSort ?? this.bookshelfSort,
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
        'screenBrightness': screenBrightness,
        'keepScreenOn': keepScreenOn,
        'enableVolumeKeyPage': enableVolumeKeyPage,
        'volumeKeyPageOnTts': volumeKeyPageOnTts,
        'tapZones': tapZones,
        'autoScrollSpeed': autoScrollSpeed,
        'autoPageIntervalSeconds': autoPageIntervalSeconds,
        'enableLongPressMenu': enableLongPressMenu,
        'bookshelfSort': bookshelfSort,
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
      // v6 新字段；v ≤ 5 旧 JSON 缺省时 fallback 到默认值（-1.0 = 跟随系统 / true）。
      screenBrightness:
          (json['screenBrightness'] as num?)?.toDouble() ?? -1.0,
      keepScreenOn: json['keepScreenOn'] as bool? ?? true,
      // 批次 2 (05-18): 音量键翻页开关。仍保 schema=v6（与 batch01 同模式：
      // 走"缺字段 fallback 默认值"路径，不强升 settingsVersion）。
      enableVolumeKeyPage: json['enableVolumeKeyPage'] as bool? ?? true,
      volumeKeyPageOnTts: json['volumeKeyPageOnTts'] as bool? ?? false,
      // 批次 3 (05-18): 3×3 点击区域。缺字段 fallback 默认列表；长度异常
      // 也回退默认（避免老/损坏 JSON 把 9 槽位破成 5/3 长度引发越界）。
      tapZones: _parseTapZones(json['tapZones']),
      // 批次 4 (05-18): 自动翻页速度 / 间隔。缺字段 fallback 默认；clamp 到
      // 合法区间避免恶意 JSON 给 0 / 负值 / 超大值。
      autoScrollSpeed:
          ((json['autoScrollSpeed'] as num?)?.toInt() ?? 1).clamp(1, 10),
      autoPageIntervalSeconds:
          ((json['autoPageIntervalSeconds'] as num?)?.toInt() ?? 10)
              .clamp(1, 30),
      // 批次 5 (05-18): 长按文字菜单开关。缺字段 fallback true（默认开启）。
      enableLongPressMenu: json['enableLongPressMenu'] as bool? ?? true,
      // 批次 8 (05-19): 书架排序方式。v ≤ 6 旧 JSON 缺字段时 fallback 0。
      // 越界值不在这里 clamp；Rust [`BookSort::from_i32`] 会兜底回 Default。
      bookshelfSort: (json['bookshelfSort'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 批次 3 (05-18): 解析 JSON 里的 tapZones 字段。
/// - null / 类型不对 → 回退默认 [ReaderSettings.tapZonesDefault]
/// - 长度 != 9       → 回退默认（数据损坏防御）
/// - 元素类型不是 int → 用 0..3 范围 clamp，非 int 直接当 2 (showMenu)
/// 返回的 List 是新的可修改副本（避免引用 const 默认列表后被外部 mutate）。
List<int> _parseTapZones(dynamic raw) {
  if (raw is! List) return List<int>.from(ReaderSettings.tapZonesDefault);
  if (raw.length != 9) return List<int>.from(ReaderSettings.tapZonesDefault);
  return List<int>.generate(9, (i) {
    final v = raw[i];
    if (v is int) return v.clamp(0, 3);
    if (v is num) return v.toInt().clamp(0, 3);
    return 2; // showMenu 兜底
  });
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
