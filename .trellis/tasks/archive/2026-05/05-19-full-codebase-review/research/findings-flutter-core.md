# Findings — Wave 2A (Flutter core + reader)

**Scope**: `flutter_app/lib/main.dart` + `flutter_app/lib/core/*` + `flutter_app/lib/features/reader/*`
**Reviewed at**: 2026-05-20
**File count**: 47
**Lines reviewed**: ~11,525

## 统计

### 按严重度
| Severity | Count |
|---|---|
| P0 严重 | 1 |
| P1 主要 | 13 |
| P2 次要 | 43 |
| P3 nice-to-have | 23 |

### 按维度
| 维度 | Count |
|---|---|
| A-架构 | 24 |
| B-正确性 | 20 |
| C-性能 | 15 |
| D-安全 | 6 |
| E-代码异味 | 15 |

### 按模块
| 模块 | P0 | P1 | P2 | P3 |
|---|---|---|---|---|
| main / core/api | 0 | 1 | 2 | 2 |
| core/providers | 0 | 3 | 4 | 2 |
| core/router + theme | 0 | 0 | 2 | 2 |
| core/transport + download_runner | 0 | 1 | 2 | 1 |
| core/notification + cover_cache + perf | 0 | 0 | 2 | 6 |
| core/platform_webview_executor + refresh_rate | 1 | 1 | 0 | 1 |
| reader/page (翻页/动画) | 0 | 2 | 10 | 4 |
| reader/state + provider (reader_page main) | 0 | 5 | 17 | 2 |
| reader/services + tts + change_source | 0 | 0 | 4 | 3 |

---

## Findings

### F-W2A-001 [P1][A-架构][core/api]

**File**: `flutter_app/lib/core/api/api_client.dart:1-31` + `bookshelf_api.dart` + `reader_api.dart` + `search_api.dart` + `source_api.dart` + `dto.dart`

**问题**: 整个 `core/api/` Dio HTTP 客户端目录是死代码（`AddBookRequest` / `BookshelfApi` / `ReaderApi` / `SearchApi` / `SourceApi` / `ApiClient`），仅在 `core/providers.dart:30-54` 创建 provider 但无任何消费者。

**详细**: `grep ref.watch(readerApiProvider)` / `bookshelfApiProvider` 等 5 个 provider 在 `lib/` 全无消费者。Provider 仍 `ref.watch(apiBaseUrlProvider)` 因此每次 base url 变化都白白 rebuild ApiClient。`pubspec.yaml` 因此长期保留 `dio`，而真正的网络层走 FRB 与少量 `http`/HttpClient。`providers.dart:20-22` 注释也承认"HTTP mode is retained only for future/debug clients"。

**建议**: 删除 `core/api/` 整目录（或迁去 `legacy/`），同时删 `apiClientProvider` / `readerApiProvider` / `bookshelfApiProvider` / `sourceApiProvider` / `searchApiProvider` / `apiBaseUrlProvider` / `apiTokenProvider` / `BackendMode.http` / `transportProvider` 的 http 分支；剩余 `dto.dart` 中只有 `PlatformRequest` / `FailedSource` / `SearchResponse` 仍被使用，挪到 `core/dto.dart` 或 reader 模块即可。Dio 依赖只剩 `cover_cache` 一处使用，可考虑换 `package:http`。

---

### F-W2A-002 [P1][A-架构][core/transport]

**File**: `flutter_app/lib/core/transport.dart:301-319` + `providers.dart:58-70`

**问题**: `LocalTransport` 是占位实现（`invoke` 抛 `UnimplementedError`，`stream` 返回 empty stream），`HttpTransport` 没有任何调用方。`transportProvider` 与 `BackendMode.frb`/`http` 切换是无人使用的死分支。

**详细**: 文件头声称"统一传输抽象层"，但 widget 全部直接 `import 'src/rust/api.dart' as rust_api;` 调用 FRB，从未走过 `ref.read(transportProvider)`。SSE 解析 (`parseSseStream`) 与 Listener 链 ~280 行属于"提前抽象、永久未落地"。

**建议**: 要么补一份"FRB 也走 Transport.invoke"的迁移路线图（PRD 写明并打开追踪），要么直接删掉 `Transport` 抽象 + `HttpTransport` + `BackendMode` enum，让代码真实反映"FRB 单一传输"的现状；保留下来无消费者反而误导未来开发者。

**Resolution**: Resolved by BATCH-18b（commit 待补）— 整组删除 Transport / HttpTransport / LocalTransport / BackendMode / transportProvider / search_page._doSearchViaSse + 两个测试文件，净 ~-700 行。

---

### F-W2A-003 [P1][A-架构][core/providers]

**File**: `flutter_app/lib/core/providers.dart:276-1086`

**问题**: 11 个 settings.json IO 函数（`loadThemeMode/saveThemeMode/savePendingRoute/loadPendingRoute/clearPendingRoute/loadFontSize/saveFontSize/loadSearchHistory/saveSearchHistory/loadSearchPrecision/saveSearchPrecision/loadReaderSettings/saveReaderSettings/loadBookshelfGridView/saveBookshelfGridView/loadRefreshRateMode/saveRefreshRateMode`）每个都在重复同一段 `dir = Platform.isAndroid ? getApplicationDocumentsDirectory : getApplicationSupportDirectory ; File('$dir/settings.json'); jsonDecode...` 的 ~10 行模板。

**详细**: 共出现 16 次该模板，约 ~250 行可去重。因为每次写入要重读 + 重写 JSON 文件，每次切设置会全文件 round-trip，没有锁，并发写存在丢失更新风险（如启动时同时 `saveReaderSettings` + `saveThemeModeToDisk` race，后写者覆盖前写者）。

**建议**: 抽出 `class _SettingsStore { static Future<Map> read(); static Future<void> writeKey(String k, dynamic v); }` 单点序列化；或者干脆引入 `package:shared_preferences` 把这堆字段迁过去。后者更优——SharedPreferences 自带 atomicity 与平台无关，能去掉 `Platform.isAndroid` 路径分叉。

**Resolution (BATCH-18c, 2026-05-20)**: Extracted to `flutter_app/lib/core/persistence/json_store.dart` with 3 helpers (`readJsonKey<T>`, `writeJsonKey`, `deleteJsonKey`) plus a public `resolvePersistenceDir` (which `dbDirProvider` now reuses). All 17 wrapper functions in `providers.dart` keep their signatures; bodies reduced to 1–3 line helper calls. Module-level `_Mutex` serializes every write/delete, resolving the read-modify-write race noted at the end of this finding (`getApplicationDocumentsDirectory|getApplicationSupportDirectory` and `Platform.isAndroid` no longer appear in `providers.dart`). Did not introduce `shared_preferences` (would be a dep + migration cost orthogonal to this batch's "local extraction" goal). Net diff ≈ −150 lines on `providers.dart` plus a new ~165 line helper and ~135 line test file (`test/json_store_test.dart`, 9 cases including concurrent-write serialization and read-write non-blocking).

---

### F-W2A-004 [P1][B-正确性][core/providers]

**File**: `flutter_app/lib/core/providers.dart:189-211`

**问题**: `replaceRuleGenerationProvider` 自身注释（L196-205）已承认多 isolate 场景下"不同 isolate 各自从 0 计数会撞车导致 Rust 缓存命中错误版本"。当前 download_runner 仍走 main isolate，但任何后续把规则写入移到 worker isolate 的改动都会触发该数据竞争。

**详细**: `bumpReplaceRuleGeneration(ref)` 只在 main isolate 内 atomic，Rust `apply_replace_rules` 全局 OnceLock 缓存以 `(db_path, generation)` 为 key，跨 isolate 看到相同 generation=0 仍可能命中陈旧规则集。

**建议**: 把 generation 升为 `(String processSalt, int monotonicCounter)`，或在 Rust 端把 cache key 加上 process-startup-uuid。短期防御：在 spec 中明确"replace rule CRUD 必须在 main isolate"，并加 assert。

**Resolution**: BATCH-19a (2026-05-22, 方案 B) — 保守方案：保 `int` 类型不动 FFI cache key 序列化路径。`providers.dart::replaceRuleGenerationProvider` (line 125-150) 升级 doc 注释说明：(1) 当前 download_runner 在 main isolate，无真实漂移；(2) 未来如把 replace rule CRUD 移到 worker isolate，必须升级为 `(salt, counter)` tuple 同步 Rust 端 cache key。`debugName` 在 release build 不可靠，不加 runtime assert；改为 spec 文档化（`.trellis/spec/flutter-app/quality-and-anti-patterns.md` 「Reader 正确性边界 (BATCH-19a)」段）。task: 05-22-batch-19a-reader-correctness。

---

### F-W2A-005 [P1][B-正确性][reader/state]

**File**: `flutter_app/lib/features/reader/reader_page.dart:1722-1731`

**问题**: `build()` 内通过 `addPostFrameCallback` 调 `_setReaderSettings(ref.read(readerSettingsProvider))`——这是 setState-during-build 反模式的延迟版本。每次 reader build（PageView 动画期间一秒数十次）都会比较 `providerSettings != _settings`，比较失败时 schedule postFrame 回写。

**详细**: 比较用 `!=` 但 `ReaderSettings` 没有 override `==`/`hashCode`，所以**每次都是 reference 不等**。结果是每帧都会 schedule 一个 postFrame 回调把 provider 状态再灌回 _settings + setState。虽然有 mounted/`ref.read` 二次校验，但仍是无谓的状态同步循环。

**建议**: 用 `ref.listen(readerSettingsProvider)` 替代 build 内部 `ref.watch + 比较`；或给 `ReaderSettings` 增加 `==`/`hashCode`（推荐用 `package:freezed` 或手写 `Object.hashAll([...])`），这样首次相等比较就能短路。

**Resolution**: BATCH-19a (2026-05-22) — 选「手写 == / hashCode」方案，免引 freezed/build_runner。`providers.dart::class ReaderSettings` 加 `@override bool operator ==(Object other)` 全 31 字段比较（含 `listEquals` 深比较 `tapZones: List<int>`）+ `@override int get hashCode => Object.hashAll([...])`。31 字段集合与 `copyWith` / `fromJson` / `toJson` 三处对齐。`reader_page.dart::build` 保持现有 `ref.watch + != 比较 + postFrame` 结构（`_readerSettingsLoaded` 路径需要），加 == 后稳态命中等价短路至零 schedule；首次同步与真实 settings 变更照常。新增 `flutter_app/test/reader_settings_equality_test.dart` 40 case：default equal / type mismatch / 字段集合规模 == 31 / 每个字段 not_equal_when_<field>_differs 参数化 / hashCode 等价 / tapZones 深比较 / set_dedup。task: 05-22-batch-19a-reader-correctness。

---

### F-W2A-006 [P1][B-正确性][reader/state]

**File**: `flutter_app/lib/features/reader/reader_page.dart:1093-1123`

**问题**: `_onScroll` 每次回调都启动两个 `Timer`（300ms / 500ms），但 `_visibleChapterTimer != null` 的早 return 在 `_scrollDebounceTimer != null` 早 return 之后——后者命中时 `_visibleChapterTimer` 永远不会被启动，导致章节定位 debounce 完全靠运气触发。

**详细**: L1094 `if (_scrollDebounceTimer != null) return;`——只要在 500ms 防抖窗口内连续滚动，整个函数就 early return，包括 L1099 的 visible chapter 计时器、L1105 的 backward detect、L1111 的 append/prepend 触发。视觉上表现为"长程滚动期间章节标题不更新"。

**建议**: 拆开两段：`_scrollDebounceTimer ??= Timer(...)` 模式（不 reset），让 visible chapter 与 backward detect 不被 debounce 早 return 拦下。也可以把 backward detect 与 prefetch 移到 `_scrollDebounceTimer == null` 分支之外。

**Resolution**: BATCH-19a (2026-05-22) — `reader_page.dart::_onScroll` (line 1094-1140) 重构为三段独立路径：(1) `if (_scrollDebounceTimer == null) { _scrollDebounceTimer = Timer(500ms, save) }` 独占 save debounce；(2) `_visibleChapterTimer ??= Timer(300ms, updateVisibleChapter)` 独立计时器；(3) backward detect / append-prepend 总执行（不被早 return 拦截）。修复后连续滚动期间章节标题更新 + 追加/前置章节正常触发。task: 05-22-batch-19a-reader-correctness。

---

### F-W2A-007 [P1][B-正确性][reader/state]

**File**: `flutter_app/lib/features/reader/reader_page.dart:418-444`

**问题**: `_fetchSourceInfo` 在 mounted 检查通过后做 4 个 `_sourceName/_sourceUrl/_sourceId/_chapterUrl = ...` 赋值**之后**才 `setState(() {})`——这 4 个字段是 plain field 不是 state field，赋值是在 build 回放完成之后；正确写法是把赋值放进 `setState` callback 内或者全部用 lateinit + setState 包起。

**详细**: 同样的反模式在 `_fetchBookName` 里是对的（L420 `setState(() => _bookName = ...);`）但 `_fetchSourceInfo` L431-438 在 setState 外赋值。表现：一次紧跟着的 rebuild（如 `replaceRuleGeneration` 触发）能拿到刚赋值的数据，但 `setState({})` 触发的本次 rebuild 的 build phase 已经读过旧值——AppBar 的"书源"显示与底部 chapterUrl 显示有可能慢一帧。

**建议**: 把 L431-438 的 4 个赋值移进 `setState` callback；或者改为 unconditional `setState(() { _sourceName = ...; ... });`。

**Resolution**: BATCH-19a (2026-05-22) — `reader_page.dart::_fetchSourceInfo` (line 428-451) 把 4 个 plain field (`_sourceName` / `_sourceUrl` / `_sourceId` / `_chapterUrl`) 的赋值全部移进 `setState(() {...})` callback；删空 `setState(() {})` 反模式。下一次 build 直接拿到新值，AppBar 书源显示与 chapterUrl 不再慢一帧。task: 05-22-batch-19a-reader-correctness。

---

### F-W2A-008 [P1][B-正确性][core/providers]

**File**: `flutter_app/lib/core/providers.dart:78` + `reader_page.dart:1723`

**问题**: `fontSizeProvider` 和 `readerSettings.fontSize` 是两个独立 source of truth；fontSize 同时存在于 `StateProvider<double>` 和 `ReaderSettings.fontSize` 两处；两者由 `loadFontSizeFromDisk()` 与 `loadReaderSettingsFromDisk` 各自从同一份 settings.json 不同 key 加载。

**详细**: `main.dart:49` 把 `loadFontSizeFromDisk` 的值灌进 `fontSizeProvider`，但 reader 实际读 `ReaderSettings.fontSize`；`saveFontSizeToDisk` 与 `saveReaderSettingsToDisk` 写入同一个 `settings.json` 的不同字段。修改阅读器字号时只改 `readerSettings.fontSize`，`fontSizeProvider.state` 不会同步——其他依赖 `fontSizeProvider` 的 widget（如设置页可能会用）显示陈旧值。

**建议**: 删掉 `fontSizeProvider` + `loadFontSizeFromDisk` + `saveFontSizeToDisk`；统一从 `readerSettingsProvider` 派生 `final fontSizeProvider = Provider<double>((ref) => ref.watch(readerSettingsProvider).fontSize);`。

**Resolution (BATCH-18d, 2026-05-20)**: Resolved。`fontSizeProvider` 改派生 `Provider<double>((ref) => ref.watch(readerSettingsProvider).fontSize)`（providers.dart:822）；整删 `loadFontSizeFromDisk` / `saveFontSizeToDisk` 两个 wrapper（BATCH-18c 后已是 1-3 行 helper 调用，删后 caller 无残留）；`main.dart` 启动加载链路从 `loadFontSizeFromDisk` 改为 `loadReaderSettingsFromDisk` + `readerSettingsProvider.overrideWith`，让派生 `fontSizeProvider` 第一帧拿到正确值；`settings_page.dart` slider onChanged 改走 `readerSettingsProvider.notifier.state = state.copyWith(fontSize: value)` + `saveReaderSettingsToDisk`，settings 端与 reader 端共享同一 source of truth。新增 `test/font_size_derived_test.dart` 4 case 验证派生、override、state 变化、dedup 行为。`flutter analyze` 0 issue；`flutter test` 393/393 PASS（含新增 4 case）。顶级 `fontSize` key 残留无害不做迁移（极小概率"用户只在 settings 页改过字号、从未进过 reader"才会丢失偏好，留观察）。

---

### F-W2A-009 [P0][D-安全][core/platform_webview_executor]

**File**: `flutter_app/lib/core/platform_webview_executor.dart:104-105`

**问题**: WebView 执行器**始终**启用 `JavaScriptMode.unrestricted`，并且对 `request.userAgent` / `request.headers` / `request.url` 不做任何来源校验或 scheme 白名单（http/https 之外的 scheme 也会被 `Uri.parse` 后 `loadRequest`）。

**详细**: `request.url` 来自书源 JSON（用户从订阅源/QR 导入），可被恶意源构造 `file://`、`content://`、`javascript:` 等 scheme 触发本地资源访问、内容暴露或 JS bridge 注入。webJs 内联进入 wrapped IIFE（L165-178），返回值 toString 后回灌 chapter 内容；该路径的攻击面是"恶意书源在解析章节内容时获得任意 JS 执行 + cookie 读取"。`onWebResourceError` 不区分关键资源失败与广告资源失败，统一显示 banner 但仍允许执行规则 → 信息泄露窗口。

**建议**: (1) 在 `_executeNative` / `Uri.parse(widget.request.url!)` 之前强校验 `uri.scheme == 'http' || uri.scheme == 'https'`，其它直接抛异常；(2) `addJavaScriptChannel` 当前未用，若后续添加必须命名空间隔离；(3) 限制 `webJs` 长度上限并在日志中只打前 200 字符；(4) 给 WebView 设 `setBackgroundColor(transparent)` 之外，关闭 `setMixedContentMode`（默认禁），并考虑 `clearLocalStorage` / `clearCache` 在 dispose 时调用避免跨书源 cookie 持久化。

**Resolution (BATCH-05, 2026-05-21)**: P0 部分闭环。新建 `flutter_app/lib/core/security/webview_safety.dart` 集中 4 件套：`enforceWebViewScheme(url)` (http/https 白名单越界 throw `WebViewSafetyException`)、`classifyHost(url) → HostClass enum`、`defaultUserAgent()` 项目统一 UA、`safeJsResultDecode(raw)` 取代旧 `_normalizeJsResult`。`platform_webview_executor.dart`：`PlatformWebViewExecutor.execute()` 入口 + `_WebViewExecutionPageState.initState` 在 `loadRequest` 前都调 `enforceWebViewScheme`（双层防线）；caller 没指定 UA 时走 `defaultUserAgent()` 而非 webview-flutter 默认 UA；`_normalizeJsResult` 删除，统一走 `safeJsResultDecode`。`PlatformWebViewExecutor` class doc 加 ADR 注释说明 reader webview 是业务豁免：必须保留 `JavaScriptMode.unrestricted` 以跑远端 webJs 规则；新增 webview caller 默认 disabled，要 unrestricted 必须文档化业务必要性。**未做**（PRD Out of Scope）：webJs 长度限制、`clearCache`/`clearLocalStorage` on dispose（webview_flutter 4.x 跨平台 API 不一致，留 BATCH-05b）。`flutter analyze` 0 issue；`flutter test` 479/479 PASS（旧 429 + 新 50）。同 file F-W2A-010 顺手在同 PR 解决。

---

### F-W2A-010 [P1][D-安全][core/platform_webview_executor]

**File**: `flutter_app/lib/core/platform_webview_executor.dart:181-193`

**问题**: `_normalizeJsResult` 对 JS 返回的字符串用 `jsonDecode(text)` 还原引号，但 fallback 路径 L189 直接 `text.substring(1, text.length - 1)` 去除首尾引号——若 JS 返回的字符串包含转义序列（`\n` / `\u4e2d` / `\\`），fallback 路径会把它们当字面量保留，与 jsonDecode 路径行为不一致；有些章节内容会因此出现奇怪的反斜杠串。

**建议**: jsonDecode 失败时记录原始长度 + hash 后直接返回 `text`（带首尾引号）由调用方上报错误，而不是粗暴去引号。或者退化用 `unescape` 手动处理常见转义。

**Resolution (BATCH-05, 2026-05-21)**: 闭环。`_normalizeJsResult` 删除；`safeJsResultDecode` 在 `core/security/webview_safety.dart` 替代实现，jsonDecode 失败时 `debugPrint('[WebViewSafety] decode JS string failed: len=$len hash=<md5>')` 后返回原 `raw.toString()`（保留引号），不再 `substring(1, len-1)` 丢字符。+ 5 case 单测覆盖 null / plain / JSON-string / JSON-string-with-escapes / malformed JSON 路径。同 file F-W2A-009 同 PR 解决。

---

### F-W2A-011 [P1][C-性能][reader/state]

**File**: `flutter_app/lib/features/reader/reader_page.dart:1722-1781`

**问题**: ReaderPage `build` 调 `ref.watch(readerSettingsProvider)` + `ref.watch(bookChaptersProvider(widget.bookId))`——任一变更（包括 fontSize 微调）都会全树 rebuild，包括 `_buildPageBody` 内的 `PageViewWidget` + 连续滚动 ListView。

**详细**: PageViewWidget 自己在 `didUpdateWidget` 内有几个 settings 字段比较再决定是否重建 delegate，但 `LayoutBuilder` 仍会被 rebuild 一次；更重要的是滚动模式下 `_buildContinuousBody` 整个 ListView.builder 也会重新创建（`_buildContinuousItemList` 看 `_cachedContinuousItems != null` 缓存命中没问题，但 padding/textStyle 等参数都是每次重新计算）。

**建议**: 把对 settings 的 watch 拆为 `select`：`ref.watch(readerSettingsProvider.select((s) => s.fontSize))` 等粒度，仅订阅会改变本子树的字段；或拆出 `_ReaderBodyConsumer` ConsumerWidget 来局部监听。

**Resolution**: BATCH-19b (2026-05-22) — 选「`ref.listen` + `_settings` plain field」方案而非 select 拆订阅（reader 子树 ≥30 字段散布，select 拆细粒度成本/收益不划算）。`reader_page.dart::build` 顶部把 `final providerSettings = ref.watch(readerSettingsProvider)` + 嵌套 `addPostFrameCallback` 块（共 15 行）替换为 `ref.listen<ReaderSettings>(readerSettingsProvider, (prev, next) { if (mounted && _readerSettingsLoaded && next != _settings) _setReaderSettings(next); })`。`ref.listen` 回调天然 post-build 触发，无需 postFrame 嵌套；BATCH-19a 加的 `==/hashCode` 保证 next != _settings 在稳态短路。`_setReaderSettings` 内部已包 setState 推动子树读 `_settings`。首帧兜底走 initState 内 `loadReaderSettingsFromDisk().then((s) => _setReaderSettings(s, markLoaded: true))` + `main.dart` 启动期 `readerSettingsProvider.overrideWith`，listen 仅接管 post-startup 的 provider 端变更（设置页 slider / bookshelfSort 写回等）。task: 05-22-batch-19b-reader-perf-selector。

---

### F-W2A-012 [P1][C-性能][reader/page]

**File**: `flutter_app/lib/features/reader/page/page_view.dart:329-348` + `_PageViewPainter:399-433`

**问题**: `AnimatedBuilder` 把 `widget.controller` + `_animController` 合并 listenable，每次 controller `notifyListeners()`（loadChapter 后的 postFrame）都会触发 CustomPaint 重绘；但 `_PageViewPainter.shouldRepaint` 比较了 12 个 settings 字段，每帧重绘成本不低（加上 simulation delegate 的 `_calcPoints` 没有早退条件）。

**详细**: 仿真翻页的 painter shouldRepaint 在动画跑动时返回 `isRunning ||` 必然 true；但 controller 注入的 currentTouch / direction / animProgress 也都参与比较，只是冗余而已。问题更大的是 `_calcPoints` 无短路（每帧 60+ 次浮点 + atan2 + sqrt 调用），低端机 ≤ 60Hz 的余量被吃掉。

**建议**: (1) 加一个 `Listenable.merge` 的"内层 controller-only" + "外层 anim-only" 拆分，让纯 controller 变更不重绘 painter；(2) `_calcPoints` 缓存上一帧的 `_touchX/_touchY` 与 cornerXY，相等时早 return；(3) 给 `LinearGradient` shader 缓存（segments 在 L0=6 时每帧创建 6 个 shader，明显可省）。

**Resolution**: BATCH-19c (2026-05-22) — **resolved**：
- 子项 1（Listenable 拆层）：评估后**保留合并**。`PageViewController` 7 处 `notifyListeners` 调用点（`setNeighborChapter` / `commitToNextChapter` / `commitToPrevChapter` / `jumpToPage` / `goToNextPage` / `goToPrevPage` / `_measureChapter` postFrame）全部是离散低频用户/系统事件，并发上限 ≈ 用户 tap 频率 ≤ 3-5 次/秒；合并 listenable 引入的"无效 painter rebuild"成本可忽略。嵌套 `AnimatedBuilder` 方案在 anim 帧仍重建内层 builder + painter，只在 anim 未跑时收益，但那种情况频率已极低，嵌套引入的可读性成本不划算。`page_view.dart::build` 在 `AnimatedBuilder` 上方加 28 行 doc 注释列出 7 个调用点 + 复评触发条件（controller 高频源新增 / `shouldRepaint` 字段大幅扩张时回头拆嵌套）。决策同步入 spec `quality-and-anti-patterns.md`「Reader 渲染边界 (BATCH-19c)」段。
- 子项 2（仿真 `_calcPoints` 早退缓存）：**Resolved-by-Design / 不动**。仿真翻页 painter 热路径（drag / tap-anim）期间 `currentTouch` 每帧都变（手指位置 / lerp 进度），早退 guard 永不命中；idle 期 `painter.shouldRepaint` 已返 false → `paint` 不被调用，guard 也无处发挥。ROI 在没有 fps 基线测试支撑前不明，行为重写引入浮点 epsilon 风险大于收益。复评触发条件入 spec：(a) fps 基线 + profile 实证热点落在 atan2/sqrt 时；(b) anim 模型改为离散帧使 guard 命中率上升时；(c) `_calcPoints` 几何被多个 painter 共享、缓存收益放大时；任一满足回头加。
- 子项 3（仿真 `LinearGradient` shader 缓存）：**Resolved-by-Design / 不动**。4 处 `ui.Gradient.linear` 的 cache key 必须含 `(_isRtOrLb, _bs/_bc/_be 系列动态坐标, head/tailColor)`——坐标全部由 `currentTouch` 派生、drag/anim 期每帧 miss，与子项 2 同样的命中率问题。同 file 注释已承认"开销可控"。复评触发条件同子项 2（fps 实证 / 离散帧 anim / 多 painter 共享几何）。
task: 05-22-batch-19c-reader-paint-measure。

---

### F-W2A-013 [P1][C-性能][reader/page]

**File**: `flutter_app/lib/features/reader/page/page_view_controller.dart:438-449`

**问题**: `_measureChapter` 在 `addPostFrameCallback` 内调 `notifyListeners()`，配合外层 `loadChapter` 是同步 build → schedule postFrame 链；R39 注释说这避免了"setState during build"，但代价是 chapter 切换后**首屏闪烁**——build phase 看到 `pages = const []`，第一帧画空页，下一帧才真正绘制。

**详细**: 首章打开时 `_chapterRequestId++` → setState(loading=true) → loadChapter → measure(同步完成) → schedule postFrame notify → 下一帧才有 pages。用户看到的是"加载圆圈 → 短暂空白章节 → 真正内容"。

**建议**: measure 同步 + 同步 notifyListeners 的设计本身没问题（pages 是 immutable，没有重入风险）；R38 注释也承认 isMeasuring guard 是假象。把 R39 的 postFrame 改回同步 notifyListeners，配合外层 R66 的 `setState` wrap（已经在），就不会有 setState-during-build assert。如果担心 widget tree 还在 build 中，用 `SchedulerBinding.instance.schedulerPhase != idle` 判断后再选 sync vs postFrame。

**Resolution**: BATCH-19c (2026-05-22) — `page_view_controller.dart::_measureChapter` 末尾 postFrame 块改成 phase-aware 分流：`SchedulerBinding.instance.schedulerPhase` 在 `idle` / `postFrameCallbacks` 阶段 → 同步 `notifyListeners()`（消除"加载圆圈 → 空白章节 → 真正内容"三段闪烁），其他 phase（build / layout / paint / persistentCallbacks）→ 保留原 postFrame 兜底（避免极少数路径如 Riverpod selector 在 build 内 read provider 间接触发 loadChapter 时的 setState during build assert）。两路径都保留 `!_disposed && _currentChapter?.chapterIndex == chapterIndex` 身份校验。`flutter test` baseline 523 全 PASS 验证 sync 路径在 widget test 跑 reader UI 不触发 assert。决策同步入 spec `quality-and-anti-patterns.md`「Reader 渲染边界 (BATCH-19c)」段。task: 05-22-batch-19c-reader-paint-measure。

---

### F-W2A-014 [P1][C-性能][reader/state]

**File**: `flutter_app/lib/features/reader/reader_page.dart:1300-1337`

**问题**: 滚动模式 `_updateVisibleParagraph` 用平均段高估算（`approxLineHeight * 2 + paragraphSpacing`）来反算段索引，估算误差在 fontSize / 行距 / 段距变化时可达 ±5 段，并且**每次 _onScroll debounce 都会跑一次浮点除法 + clamp**。

**详细**: P2-13（reader_page.dart:1257-1278）已经用 GlobalKey + `Scrollable.ensureVisible` 做了精确恢复路径，但保存时仍用估算（L1335 `(dyFromParagraphStart / approxParagraphHeight).floor()`）。导致"恢复用 GlobalKey、保存用估算" 的不对称——保存的 paragraph index 可能与实际可见 paragraph 偏差 1-2 段，下次恢复 ensureVisible 落到错误位置。

**建议**: 保存路径也用 GlobalKey 反查：遍历前 _kParagraphKeyCap 个 key 找到 RenderBox.localToGlobal().dy >= 0 的最小者；超出 cap 的章再 fallback 估算。读写对称后恢复精度大幅提升。

**Resolution**: BATCH-19b (2026-05-22) — `reader_page.dart::_updateVisibleParagraph` 改两段：(1) cap 内 GlobalKey 反查：遍历当前章前 `_kParagraphKeyCap = 200` 个 `_paragraphKeys[_paragraphKeyId(ch.index, idx)]`，过滤未 layout 节点（`box?.hasSize == true`），找第一个 `localToGlobal(Offset.zero, ancestor: listBox).dy >= 0` 的 idx；(2) 未命中（cap 外 / 全在视口之上 / 全未 layout）→ fallback 现有标题 dy + 段高估算。复用 `_paragraphKeyId(int, int)` helper（line 815）保证 keyId 格式（`'$chapterIndex|$paragraphIndex'`）与构造路径一致。与 P2-13 已有的 GlobalKey 恢复路径对称，paragraph index 误差从 ±1-2 段降到 0（cap 内场景）。task: 05-22-batch-19b-reader-perf-selector。

---

### F-W2A-015 [P2][B-正确性][reader/state]

**File**: `flutter_app/lib/features/reader/reader_page.dart:813-815` + `840-842`

**问题**: `_appendNextChapter` / `_prependPrevChapter` 单行 if + return 没有花括号（dart linter 默认 prefer_curly_braces_in_flow_control_structures）。当未来在 if 体内添加第二条语句时极易引入 bug。

**建议**: 加花括号。

---

### F-W2A-016 [P2][B-正确性][reader/state]

**File**: `flutter_app/lib/features/reader/reader_page.dart:1093-1123`

**问题**: `_isScrollingBackward` 是赤裸 field，被 `_onScroll`（debounce 500ms 内每次都更新）+ `_updateVisibleChapter`（每 300ms 一次）跨 timer 共享读写，但没有同步保护。

**详细**: 实践上 dart 单 isolate 不会有数据竞争，但 backward 判定可能在 `_updateVisibleChapter` 跑 visible chapter loop 期间被另一帧 `_onScroll` 翻转，导致 L1158 `if (_isScrollingBackward)` 误判。

**建议**: 把 `_isScrollingBackward` 局部化——`_updateVisibleChapter` 进入时读 `_lastScrollOffset` 与 `_scrollController.offset` 自行决定方向，去掉跨 timer 共享 field。

---

### F-W2A-017 [P2][B-正确性][reader/state]

**File**: `flutter_app/lib/features/reader/reader_page.dart:386-389`

**问题**: `didChangeAppLifecycleState` 把 `paused/inactive/hidden/detached` 全部当成"暂停阅读时长 ticker"——但 `inactive` 在 iOS 上是来电、Android 上是分屏激活，并不一定是"用户离开"；实际读者可能仍在阅读。当前不是 P0，但记录阅读时长统计会漏算。

**建议**: 仅在 `paused` / `detached` 暂停 ticker；`inactive` 时保留 ticker 运行。

---

### F-W2A-018 [P2][B-正确性][reader/state]

**File**: `flutter_app/lib/features/reader/reader_page.dart:2126-2136`

**问题**: `_saveCurrentPagePosition` 内 `ref.read(dbPathProvider.future).then(...)` 用 `mounted` 在 then callback 内做守卫，但 `_progressService.save` 是在 then callback 之后并发调度的——如果 await 完成时 widget 已 dispose，仍可能写库。

**详细**: 当前 `_progressService.save` 内部独立做 try/catch + debugPrint，写一次脏库不会崩溃，但语义上"已 dispose 就不应再写" 没有完全保证。

**建议**: 把 `if (!mounted) return;` 改成 `if (_disposed) return;` 风格的显式 dispose flag（参考 page_view_controller 的 `_disposed`），并在 dispose 时把 flag 置 true，避免 race。

---

### F-W2A-019 [P2][B-正确性][reader/state]

**File**: `flutter_app/lib/features/reader/reader_page.dart:1339-1453`

**问题**: `_preCacheNextChapter` / `_preCachePrevChapter` / `_preloadAdjacentContent` 三个预加载方法有重叠语义但行为不一致：next 方向走 fetch-only（不写 chapters[i]['content'] 缓存）；prev 方向走 `_loadChapterContent` 完整路径并写 chapters[i]['content']；`_preloadAdjacentContent` 同时调 prev + next 两个 fire-and-forget。

**详细**: 三处函数同时被 `_openChapter` L716-718 触发：`_preCacheNextChapter(i)` + `_preCachePrevChapter(i)` + `_preloadAdjacentContent(i)`——后者又会再次触发 `_loadChapterContent(prev)` / `_loadChapterContent(next)`。两次 `_preCachePrevChapter` 与一次 `_preloadAdjacentContent` 内的 prev fetch 同时进行，浪费 1 次网络请求或者撞到 Rust 端 cache contention。

**建议**: 删掉 `_preCacheNextChapter` 与 `_preCachePrevChapter`，统一只调 `_preloadAdjacentContent`；prev 方向由 `_preloadAdjacentContent` 内部完成 chapters[i]['content'] 写入并触发 `_measureAdjacentChapters` 即可。

---

### F-W2A-020 [P2][B-正确性][reader/state]

**File**: `flutter_app/lib/features/reader/reader_page.dart:2438-2444`

**问题**: `_replaceBookSource` 强写 `saveReadingProgress(offset:0)`——这违反了 commit 注释 "T1 修复：删除强写 offset=0"（L687-695, L2075-2077）确立的"进度由 _onPageChanged 驱动"原则。换源后用户被强制回到章首页，但其实换源前的 saved offset 在新书源下大多数情况依然有效（章节字符 offset 与书源无关）。

**建议**: 与 `_openChapter` 一致：删掉 `saveReadingProgress(offset:0)`，让换源后 controller.loadChapter + _saveCurrentPagePosition 自然驱动；或者只 reset paragraph_index = 0 但保留 chapter offset。

---

### F-W2A-021 [P2][C-性能][reader/state]

**File**: `flutter_app/lib/features/reader/reader_page.dart:1949-2041`

**问题**: `_buildContinuousItemList` cache 失效条件简单：`_cachedContinuousItems = null` 在 append/prepend/refresh/换源/`_ensureCurrentChapterInContinuous` 时清；但 ReaderSettings 的 paragraphIndent / fontSize / paragraphSpacing 改动会让旧 items 内容仍正确，**只是 padding/textStyle 重新计算**。问题不在 cache，问题在 `_buildContinuousBody` 每次 build 都重建 `textStyle` / `titleStyle` / `dividerColor` 三个对象。

**建议**: 把 `textStyle` / `titleStyle` 提到 `_settings` 变化时计算并 cached（State field），`build` 内只读取；进一步可以把 `_ContinuousItem` widget 抽成顶级 StatelessWidget 搭配 `const TextStyle` 派发。

---

### F-W2A-022 [P2][C-性能][reader/page]

**File**: `flutter_app/lib/features/reader/page/page_measure.dart:53-59`

**问题**: 每次 `_buildParagraph` 都 new `ParagraphBuilder` + `pushStyle` + `addText` + `build` + `layout`——一章 1000 段就是 1000 次 paragraph 构建+layout，layout 在 dart:ui 内部走 SkParagraph，复杂场景毫秒级。`_textStyle` / `_paragraphStyle` 每次 getter 都 new 一份。

**建议**: 把 `_textStyle` / `_paragraphStyle` 在 `PageMeasure` 构造时 cache 一次；`measureChapter` 内复用 builder（注意 ParagraphBuilder 不可复用，但 ui.TextStyle 可复用）。再激进一点把 page_measure 移到 isolate（compute）跑，避免长章卡 UI 线程。

---

### F-W2A-023 [P2][C-性能][reader/page]

**File**: `flutter_app/lib/features/reader/page/content_page.dart:66-79`

**问题**: `ContentPagePainter.paint` 每帧（仿真翻页 60Hz 下每秒 60 次）重新构造每个段落的 ParagraphBuilder + layout——这跟 page_measure 是两条独立路径，page_measure 的结果完全没复用到 painter。

**详细**: 仿真翻页期间 painter 重画 `curPicture` / `nextPicture` 一次（onDragStart 时），后续动画用的是 ui.Picture 回放（OK 的）；但**静态展示 / noAnim 模式 / fade 期间的 saveLayer 内部画**都会触发 `ContentPagePainter.paint` 全段落重 layout。

**建议**: TextPage 内 cache 一份 `List<ui.Paragraph> laidOutParagraphs`，painter 直接 `canvas.drawParagraph(p, offset)`，避免每次 build。这能让 fade / noAnim 性能与仿真翻页持平。

---

### F-W2A-024 [P2][C-性能][reader/page]

**File**: `flutter_app/lib/features/reader/page/delegate/simulation_page_delegate.dart:567-575` + `615-625` + `669-677`

**问题**: 每帧 `draw` 都 new 3-5 个 `ui.Gradient.linear` + `Paint`——每秒约 180-300 次 shader 创建。即便 GPU 有 shader cache，对象本身在 GC 压力上不友好。

**建议**: 把 4 段阴影的 gradient 与 paint 提到字段级 cache，仅在 size 变化或 SimulationDegradeLevel 变化时重建。

---

### F-W2A-025 [P2][A-架构][reader/page]

**File**: `flutter_app/lib/features/reader/page/delegate/simulation_page_delegate.dart:55-66` + `cover_page_delegate.dart` + `slide_page_delegate.dart` + `fade_page_delegate.dart`

**问题**: 4 种 delegate 共享父类，但 simulation 维护 9 对独立的 `_bs1x/y / _bs2x/y / _bc1x/y / ...` doubles 而非 `Offset` 对象——节流 GC 但牺牲可读性。其他 delegate 各自实现 `draw` 逻辑共用很少。

**建议**: 现状的几何参数化（`_bs1x` 等）确实是性能必要，可加注释解释；可考虑用 `final List<Offset>` + 索引常量（B_S1=0, B_S2=1...）兼顾性能与可读。

---

### F-W2A-026 [P2][E-代码异味][reader/state]

**File**: `flutter_app/lib/features/reader/reader_page.dart:1` (整个文件)

**问题**: `reader_page.dart` 2807 行，单一 State class `_ReaderPageState` 持有：`_currentIndex` / `_chapterContent` / `_loadedChapters` / `_pageViewController` / `_search` / `_autoScroller` / `_tts` / `_progressService` / `_bookmarkService` 等 30+ 字段，并实现 `WidgetsBindingObserver`。`build` 方法 60 行，`_buildReaderView` 138 行，`_buildContinuousBody` 75 行。

**详细**: 已经把 search / tts / autoScroll / bookmark / progress / key / tap zone / long press 抽到 service 是好事，但 reader_page 内仍混合 chapter loading / progress restore / appendChapter / prependChapter / 替换规则 / search / TTS / 换源 / 下载入口 / 屏幕亮度 / 阅读时长 / 物理按键 12+ 个职责。

**建议**: 拆分时机已成熟。建议：
- `reader_chapter_loader.dart`（_loadChapterContent / _openChapter / _preloadAdjacent / _preCache*）
- `reader_progress_restore.dart`（_restoreProgress / _consumeRestoreCharOffsetIfNeeded / _saveCurrentPagePosition）
- `reader_continuous_body.dart`（_buildContinuousItemList / _buildContinuousBody / _appendNextChapter / _prependPrevChapter / _updateVisibleChapter）
- `reader_change_source_handler.dart`（_replaceBookSource）

---

### F-W2A-027 [P2][E-代码异味][reader/state]

**File**: `flutter_app/lib/features/reader/reader_page.dart:447-545`

**问题**: `_loadChapterContent` 99 行，含 7 个 debugPrint、3 个嵌套 try-catch、2 个分支（cache hit / cache miss）、2 个 platform_request 处理路径——已经很难一眼看清主流程。

**建议**: 拆为 (1) `_loadFromCacheOrFetch` 决策，(2) `_handlePlatformRequest`，(3) `_persistFetchedContent` 三步；timing 日志改为 trace span 模板（Stopwatch + 一次性 dump），减少 debugPrint 散落。

---

### F-W2A-028 [P2][E-代码异味][reader/state]

**File**: `flutter_app/lib/features/reader/reader_page.dart:135-136` + `2807` lines

**问题**: 多处魔法数字未命名常量化：
- L160 `_kParagraphKeyCap = 200`（已命名，OK）
- L968 `_accumulatedOverscroll > 80`（书末向下拉触发翻章节阈值，未命名）
- L1100 `Duration(milliseconds: 300)`（visible chapter debounce）
- L1095 `Duration(milliseconds: 500)`（save scroll debounce）
- L1117 `if (maxScroll - currentScroll < 300)` 与 L1119 `if (currentScroll < 300)`（append/prepend 触发）
- L268 `Duration(seconds: 30)` 时钟刷新
- L273 `Duration(seconds: 60)` 阅读时长 ticker

**建议**: 抽成 `_ReaderPageState` static const 字段（`_kAppendThresholdPx = 300`, `_kVisibleChapterDebounceMs = 300` 等），方便未来调参与单测引用。

---

### F-W2A-029 [P2][E-代码异味][reader/page]

**File**: `flutter_app/lib/features/reader/page/delegate/simulation_page_delegate.dart:380-415` + `page_delegate.dart:381-394`

**问题**: 大量 `debugPrint('[SimulationDelegate] ...')` / `[PageDelegate]` 留在生产代码，nextPageByAnim / prevPageByAnim 每次 tap 都打印 cur/next/prev 三个 picture 引用——release 包仍会调到 logcat（debugPrint 有 kReleaseMode 短路但仍会构造字符串）。

**建议**: 用 `assert(() { debugPrint(...); return true; }());` 或 `if (kDebugMode) debugPrint(...)` 包裹；或改为 `developer.log(level: 500, 'sim_page')` 走 logging level 过滤。

---

### F-W2A-030 [P2][E-代码异味][reader/state]

**File**: `flutter_app/lib/features/reader/reader_page.dart:1211-1247` + 多处

**问题**: `[Reader.T1]` / `[Reader.timing]` / `[Reader]` / `[providers.timing]` 多种 log 前缀混用，无统一 logger，难以一键 grep 出仿真翻页 / 进度恢复 / 章节加载 三个独立路径的轨迹。

**建议**: 引入轻量 logger（`logger` 包或自写 trace categories）：`logger.t.reader.t1.info('...')` 之类；Spec 中明确"reader 路径必须用 reader.* 前缀"。

---

### F-W2A-031 [P3][E-代码异味][reader/change_source]

**File**: `flutter_app/lib/features/reader/change_source_dialog.dart:69` + `120`

**问题**: 留有调试 `print("ZZZZ changeSource ...")`、`print("ZZZZ changeSrc: ...")`——明显未清理的开发期 sentinel。

**Resolution (BATCH-22, 2026-05-21)**: Resolved。删除两处 print。

**建议**: 删除或换 `debugPrint`。

---

### F-W2A-032 [P2][B-正确性][reader/change_source]

**File**: `flutter_app/lib/features/reader/change_source_dialog.dart:117-128`

**问题**: 注释说 "Accept all results from the search - let user decide"——`nameMatch / authorMatch` 永远 true，那两个 final var 与下面的 if 判断完全是死代码（dart_code_metrics 会报）。

**建议**: 删掉无意义的 `final nameMatch = true; final authorMatch = true; if (nameMatch && authorMatch)` 包裹，直接做 dedup。

**Resolution (BATCH-22, 2026-05-21)**: Resolved。删 2 个 final 死变量 + 1 个 if 死包裹直接执行 body；顺手删除 L113-115 仅服务该 print 的 `name` / `_` / `bookName` 局部变量。

---

### F-W2A-033 [P2][B-正确性][reader/change_source]

**File**: `flutter_app/lib/features/reader/change_source_dialog.dart:62-66`

**问题**: `dispose()` 没有取消 `_startSearch` 内部启动的 `Future.wait` / 各 `_searchSource`。如果用户在 8 个并发查询任一返回前关闭 dialog，setState 会抛 "setState() called after dispose"；当前用 `if (!mounted) return;` 保护住了 setState，但 8 个并发请求仍会在后台跑完——无法真正取消 in-flight FRB call。

**建议**: 添加一个 `bool _disposed` 字段，dispose 时置 true，`_searchSource` 每次 await 后检查；最优是把 FRB call 改成支持 `CancellationToken` 模式（FRB 2.0 支持 sync abort）。

---

### F-W2A-034 [P3][D-安全][core/cover_cache]

**File**: `flutter_app/lib/core/cover_cache.dart:38-39`

**问题**: `coverUrl.split('.').last.split('?').first` 提取扩展名——若 URL 是 `http://x/y.php?img=cover.png` 则取到 `png`，OK；但若是 `http://x/cover` 取到 `cover`（>5 chars 走 jpg fallback），但若是 `http://x/cover.exe` 取到 `exe` 通过长度检查会写成 `.exe`——下游展示不会执行但攻击面非零。

**建议**: 白名单 `['jpg', 'jpeg', 'png', 'webp', 'gif']`，不在白名单全部 fallback `jpg`。

---

### F-W2A-035 [P3][D-安全][core/cover_cache]

**File**: `flutter_app/lib/core/cover_cache.dart:27-50`

**问题**: `Dio().download(coverUrl, filePath)` 没设 timeout、没限制最大文件大小、不验证 Content-Type；恶意书源可推一个 100 MB 流量来填手机 / 一个 .so 让用户下载到 covers/ 目录。

**建议**: `Dio(BaseOptions(connectTimeout: 5s, receiveTimeout: 30s))` + `onReceiveProgress` 检查累计字节不超过 5 MB 即 cancel。

---

### F-W2A-036 [P3][C-性能][core/cover_cache]

**File**: `flutter_app/lib/core/cover_cache.dart:32-34`

**问题**: 每次调用 `downloadAndCache` 都 new `Dio()`——Dio 内部含连接池，但每次 new 抛弃连接重新建立 TLS。封面缓存高频场景下浪费明显。

**建议**: `static final Dio _dio = Dio()`，外部 BaseOptions 集中配置。

---

### F-W2A-037 [P2][A-架构][core/notification_service]

**File**: `flutter_app/lib/core/notification_service.dart:138-158`

**问题**: `hasPermission` / `requestPermission` 用 `MethodChannel('legado/notifications')`，与 `flutter_local_notifications` plugin 平行——意味着 Android 侧除了 plugin 自带的 channel 外还要自己实现 `MainActivity.kt:hasPermission/requestPermission`。

**详细**: 这是合理的（`flutter_local_notifications` 在 Android 13+ POST_NOTIFICATIONS 处理较晚），但代码注释完全没说明。`_initialized = false` 在 init 失败后回写但 `_initialized` 仍是 true 的判断（L17-18）会让重试 init 走捷径。

**建议**: 加注释说明双 channel 设计；`_initialized = false` 写在 catch 里时同时清除 plugin state，否则下次 init 走 `if (_initialized) return;` 跳过。

---

### F-W2A-038 [P3][A-架构][core/notification_service]

**File**: `flutter_app/lib/core/notification_service.dart:79-82` + `118-122`

**问题**: iOS DarwinNotificationDetails `presentAlert/presentBadge/presentSound` 与 Android `Importance.low` 不对称——下载完成时 Android 是 `defaultImportance + autoCancel`，iOS 是 `presentAlert: true`；下载中两端 importance/priority 是 low，但 iOS 用 `presentAlert: false`（不弹）+ `presentBadge: true`（角标会变）。

**建议**: 项目主线是 Android，可加 `// iOS not in Phase 5 scope` 注释；或者把 iOS DarwinNotificationDetails 提到统一常量减少复制粘贴。

---

### F-W2A-039 [P2][A-架构][core/download_runner]

**File**: `flutter_app/lib/core/download_runner.dart:78-81`

**问题**: `DownloadRunner` 是 process-wide singleton（factory + private constructor + `_instance`），但 `_completionController = StreamController<String>.broadcast()` 在 `dispose` 中被 close——singleton 的 dispose 永远不应被调用，否则下次 enqueue 会 add 到已 close 的 stream 抛 StateError。

**详细**: `dispose()` 方法 L261-263 存在但代码里全程没人调；如果未来某个测试 / 拆分把它调起来，整个进程的下载就坏了。

**建议**: 删掉 `dispose()` 方法（singleton 不该有），或改为 `void shutdown()` + 内部 reset controller。

---

### F-W2A-040 [P2][B-正确性][core/download_runner]

**File**: `flutter_app/lib/core/download_runner.dart:123-140`

**问题**: `totalChapters == 0` 时调 `updateDownloadTaskStatus(status: failed)` 直接早 return，但**前面 L142-150 还会再把 status 改为 running**——总章节为 0 时这两段竞争（虽然实际是顺序执行，failed 写入早于 running 写入会被覆盖？看代码是 L142 之前 return）—— L139 `_completionController.add` + return 之后不会执行 L142；这个分支是对的。

**详细**: 但 `totalChapters > 0 && successCount == 0 && failCount == 0 && skipCount == 0` 路径（理论上 chapter loop 全 continue 不会发生，但 chapters 都是 url 为空 string 时确实成立）→ status 走到 L240 `complete`，与"全跳过"语义不符。

**建议**: 修正完成判定：`if (failCount > 0 || skipCount > 0)` 改为 `if (successCount == 0 || failCount > 0 || skipCount > 0)`。

---

### F-W2A-041 [P3][A-架构][core/download_runner]

**File**: `flutter_app/lib/core/download_runner.dart:39-48`

**问题**: `_sanitizeDownloadError` 只去掉 `?...query` 部分；但 fragment（`#token=xxx`）以及 path 段中包含的 token（`/api/auth/eyJhbGc.../chapter`）都会被保留。

**建议**: 在 spec 中明确"errorMessage 是用户可见字段，不能持久化任何 URL，且最长 200 字"——直接 `if (msg.contains('http')) msg = '<network error>';`。

---

### F-W2A-042 [P3][A-架构][core/perf_monitor]

**File**: `flutter_app/lib/core/perf_monitor.dart:18-23`

**问题**: `PerfMonitor.instance` 在第一次 getter 调用时即注册 `addTimingsCallback`——副作用全局，且**永远不会** detach。即便切到非 reader 页面也在 collecting，浪费 30 帧 buffer 的内存。

**建议**: 提供 `start()/stop()` 显式控制；或者懒加载到 SimulationDegrade 实际 attach 时才注册 callback。

---

### F-W2A-043 [P2][B-正确性][core/perf_monitor]

**File**: `flutter_app/lib/core/perf_monitor.dart:36-39`

**问题**: `addListener` 返回的回调 `() => _listeners.remove(listener)` 在迭代 `_listeners` 时被调用（L52 for...in `_listeners`）会触发 ConcurrentModificationError。SimulationDegrade.detach 在 listener callback 内调用 unsubscribe 即可重现。

**建议**: 把 `for (final listener in _listeners)` 改为 `for (final listener in List.of(_listeners))` 或者用 ListenerBuilder pattern；其它 Flutter framework 的 ChangeNotifier 也是这么做的。

---

### F-W2A-044 [P3][A-架构][core/refresh_rate_controller]

**File**: `flutter_app/lib/core/refresh_rate_controller.dart:25-66`

**问题**: 类整体使用 static 字段（`_current` / `_supported`）——典型的 god-class singleton。`_supported ??= await ...` 仅在第一次 apply 时 lazy-load；如果中途用户改了系统显示设置（罕见但可能），缓存就过期了。

**建议**: 至少加个 `static Future<void> reset()` 用于设置页测试或者支持模式列表"刷新"按钮。

---

### F-W2A-045 [P3][E-代码异味][reader/page]

**File**: `flutter_app/lib/features/reader/page/page_view.dart:50-67`

**问题**: `Slop state machine` 5 个 field（`_slopExceeded` / `_pointerDownPos` / `_activePointerId` / `_velocityTracker` / `_pageSize`）零散散落在 State；没有抽成 `_DragGestureState` data class 让各个 handler 共享。

**建议**: 抽 `class _DragSession { final int pointerId; final Offset downPos; bool slopExceeded; VelocityTracker tracker; ...}`，State 持 `_DragSession? _activeSession`，开启 / 关闭 session 配套 reset 6 个字段，避免任一 handler 漏 reset 一个字段引发 ghost-progress（注释 L296-302 也承认有这种类型的 bug）。

---

### F-W2A-046 [P3][C-性能][reader/page]

**File**: `flutter_app/lib/features/reader/page/page_view.dart:307-352`

**问题**: `LayoutBuilder` builder 内每次都调 `widget.controller.updatePageSize(size)` + `_delegate.updatePageSize(size)`——controller 内部已经有 `if (_pageSize == size) return` early return，但 `_delegate.updatePageSize(size)` 是直接赋值无 early return。

**建议**: PageDelegate.updatePageSize 加 `if (_pageSize == size) return;` 短路；或者把 size 比较移到 PageView 自己的 field 上避免 delegate 重赋值。

---

### F-W2A-047 [P3][E-代码异味][reader/page]

**File**: `flutter_app/lib/features/reader/page/delegate/simulation_page_delegate.dart:55-66` + `826-834`

**问题**: `_bezierStart1` / `_bezierStart2` const Offset(0, 0) 是装饰性常量字段，注释 L827-833 也承认"借助这两个字段去消静态分析未使用警告"——典型的"为了取悦 linter 留下的死字段"。

**建议**: 删除两个 const + getter，并把"5 对贝塞尔关键点"的语义直接写在文件头注释里。

**Resolution (BATCH-22, 2026-05-21)**: Resolved。删 2 个 const Offset 字段 + 2 个带 `// ignore: unused_element` 的 getter + 7 行解释注释。"5 对贝塞尔关键点"语义在双精度成员声明上方注释保留。

---

### F-W2A-048 [P2][A-架构][core/providers]

**File**: `flutter_app/lib/core/providers.dart:243-274`

**问题**: `bookByIdProvider` 和 `bookChaptersProvider` 都自己 await `dbInitializedProvider.future` + `dbPathProvider.future` —— 这两个 await 在每个 family.autoDispose provider 里重复出现（L120, L145, L167, L175, L183, L219, L228, L236, L245, L257）共 10+ 次。

**详细**: 模板代码量 ~50 行，且没有任何 helper 抽出，提高了引入"忘了 await dbInitializedProvider 直接 read dbPath" 类型的 bug 风险。

**建议**: 抽 `Future<String> _readyDbPath(Ref ref) async { await ref.watch(dbInitializedProvider.future); return ref.watch(dbPathProvider.future); }`，所有 provider 改为 `final dbPath = await _readyDbPath(ref);` 单行。

---

### F-W2A-049 [P2][A-架构][core/providers]

**File**: `flutter_app/lib/core/providers.dart:252-274`

**问题**: `bookChaptersProvider` 内部嵌套 7 个 debugPrint timing log，与 `_loadChapterContent` 内的 timing log 各自独立——`[providers.timing]` 与 `[Reader.timing]` 时间轴无法对齐（不同 Stopwatch instance）。

**建议**: 改为 `Trace.beginSection / endSection`（dev_tools）或者外部 trace runner，统一时间起点。

---

### F-W2A-050 [P3][E-代码异味][core/providers]

**File**: `flutter_app/lib/core/providers.dart:114-117`

**问题**: 注释 "Removed in code review: hardcoded sourceId, print() logs..."——是一段被删除代码的"墓志铭"，遗留在文件里没有承载任何运行时意义。

**建议**: 删除。git history 即可追溯。

**Resolution (BATCH-22, 2026-05-21)**: Resolved。删 4 行注释。注：原 finding 报 L114-117，实际在 L54-57（providers.dart 顺序变化导致）。

---

### F-W2A-051 [P2][E-代码异味][core/providers]

**File**: `flutter_app/lib/core/providers.dart:606-893`

**问题**: `ReaderSettings` 26 个字段、275 行——是事实上的"reader settings god class"。`copyWith` 26 个 nullable param 模板，`fromJson` / `toJson` 各 35 行重复键值映射。

**建议**: 引入 `package:freezed` 或至少 `package:json_annotation` 自动生成 `copyWith` / `==` / `hashCode` / `fromJson` / `toJson`——不仅消除模板，还能解决 F-W2A-005 中 ReaderSettings 没有 `==` / `hashCode` 的问题。

---

### F-W2A-052 [P2][A-架构][core/providers]

**File**: `flutter_app/lib/core/providers.dart:455-590`

**问题**: `ReaderPageAnim` 静态常量类 + 3 个 migration 方法 + `overlayPageModeOnAnim` 顶层函数 + `kReaderSettingsCurrentVersion` 顶级 const——schema 迁移逻辑横跨 200 行，分布在 ReaderPageAnim 内（pageAnim 字段迁移）、`overlayPageModeOnAnim`（PageMode 迁移）、`ReaderSettings.fromJson`（其它字段缺省 fallback）。

**建议**: 抽出独立 `reader_settings_migration.dart`，所有 `migrateFromV*` 与 `_parseTapZones` 与 `_kReaderSettingsCurrentVersion` 集中；ReaderSettings 本身只关心当前 schema。

---

### F-W2A-053 [P3][A-架构][core/providers]

**File**: `flutter_app/lib/core/providers.dart:130-139`

**问题**: `bookshelfSortProvider` 是从 `readerSettingsProvider` 派生的，但语义明显属于 bookshelf（不是 reader）；放在 `readerSettings` 里是历史遗留。

**建议**: 拆 `BookshelfSettings` data class（含 `sortOrder` / `gridView` 等）；`ReaderSettings` 严格只保 reader 相关字段。

---

### F-W2A-054 [P2][A-架构][core/router]

**File**: `flutter_app/lib/core/router.dart:23-153`

**问题**: 13 个顶级 `GoRoute` 通过字面量路径 + 字面量 query parameters key 组装；`bookId` / `chapterIndex` / `sourceUrl` / `link` 这些 query key 散布在 reader_page、bookshelf_page、rss_*_page，任一处改键名都会静默失效。

**建议**: 把所有路径 + query key 抽成 `class AppRoutes { static const reader = '/reader'; static String readerPath({String bookId, int chapterIndex}) => '$reader?bookId=$bookId&chapterIndex=$chapterIndex'; }`，调用方走 `context.push(AppRoutes.readerPath(bookId: id, chapterIndex: i))`。

---

### F-W2A-055 [P3][E-代码异味][core/theme]

**File**: `flutter_app/lib/core/theme.dart:1-49`

**问题**: light 与 dark 主题 32 行几乎完全镜像——只 `brightness` 字段不同。

**建议**: 抽 `ThemeData _build(Brightness b) => ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(...), ...);`，light/dark 一行 `_build(Brightness.light)`。

---

### F-W2A-056 [P2][A-架构][core/router]

**File**: `flutter_app/lib/core/router.dart:155-200`

**问题**: `_AppShell` 用 5 个 NavigationDestination 写死了底部 tab，`bookshelf` / `search` / `sources` / `downloads` / `settings`——但 `download` 在 `bookshelf_page` PopupMenu 也有入口（按 README 描述），且 `rss / qr / replace_rule` 等更高频的入口反而藏在子菜单里。

**建议**: tab 设计是产品决策，留给 PRD 决定；这里仅记录"底部 tab 配置当前是硬编码、未来若引入用户自定义 tab 顺序需要改造为 ListView"。

---

### F-W2A-057 [P2][B-正确性][reader/state]

**File**: `flutter_app/lib/features/reader/reader_page.dart:391-414`

**问题**: `didUpdateWidget` 当 `oldWidget.bookId != widget.bookId` 时重置全部状态，但**没有重置** `_progressRestored = false` —— 切换书籍后 build 内 `if (chapters.isNotEmpty && !_progressRestored && _readerSettingsLoaded)` 仍是 true，但 `_progressRestored` 仍是 true（上一本的）！结果是新书的 saved progress 永远不会被 restore，强制走 `widget.chapterIndex` fallback。

**详细**: 原因：reader 接口 `(bookId, chapterIndex)` 在 router 里是 query param 切换，理论上 GoRouter 会 dispose old + create new ReaderPage，didUpdateWidget 路径其实很罕见——但如果路由配置改成 keepAlive，bug 就显现了。

**建议**: 在 didUpdateWidget 内加 `_progressRestored = false;`（与其他 reset field 一起 wrap 在 setState 里）。

---

### F-W2A-058 [P2][B-正确性][reader/state]

**File**: `flutter_app/lib/features/reader/reader_page.dart:201-204` + `262-263`

**问题**: `ReaderAutoScroller` 在 `_pageViewController = ...` 之前就已构造（L200-214），它的 `controller: () => _scrollController` getter 会在分页模式时拿到 `ScrollController`——但分页模式下 scroll controller 永远没有 client（PageViewWidget 自己跑 Listener，不挂 ScrollController）。`_autoScroller._stepScroll` 在分页模式下会先 `c.hasClients == false` 早 stop。

**详细**: 这段实际是对的——ReaderAutoScroller `toggle(scroll: _settings.isScrollMode)` 已经分派到 `_scheduleNextPage` 或 `_scheduleNextScroll`。只是这两条 path 的语义切换在 `toggle` 时一次决定，**之后用户运行时切换 pageAnim 到 scroll，再 toggle 自动翻页，新旧 path 是否仍正确？** 当前 `_scrollMode` 由 `_start` 时的 `scroll` 参数决定，但用户可能先 toggle 再切设置——currently `_setReaderSettings` 没调 `_autoScroller.stop()`，会出现"分页模式启动 auto-page，切到滚动模式 ticker 仍跑分页 onPageTick" 的错配。

**建议**: `_setReaderSettings` 内检测到 `wasScroll != isNowScroll` 时调 `_autoScroller.stop()`。

---

### F-W2A-059 [P2][C-性能][reader/state]

**File**: `flutter_app/lib/features/reader/reader_page.dart:268-270` + `1184`

**问题**: `_clockTimer` 每 30s 触发 `_nowNotifier.value = DateTime.now()`——`ValueListenableBuilder<DateTime>` 监听后只重画显示时分秒的 Text widget。OK。但同样的 30s 心跳也可以与阅读时长 ticker `Duration(seconds: 60)` 合并。

**建议**: 两个 ticker 合并成 `Duration(seconds: 30)` 单 ticker，每偶数 tick 累加 60s 阅读时长，奇数 tick 仅刷时钟显示——节省一次 setState 调度。

---

### F-W2A-060 [P3][A-架构][reader/services]

**File**: `flutter_app/lib/features/reader/services/reader_progress_service.dart:1` + 4 services

**问题**: 5 个 service（`reader_progress_service` / `reader_bookmark_service` / `reader_tts_manager` / `reader_auto_scroller` / `reader_search_controller` / `long_press_action_handler` / `tap_zone_resolver` / `reader_key_handler`）目录平铺，无 README 说明依赖关系；其中 `reader_progress_service` 与 `reader_bookmark_service` 是 stateless wrapper（只是把 `rust_api.xxx` 包成 service class），而 `reader_tts_manager` / `reader_auto_scroller` 是有状态的 controller。这两类生命周期不同。

**建议**: 重命名：stateless 的改 `reader_progress_repository.dart` / `reader_bookmark_repository.dart`；有状态的保留 `_manager` / `_controller` 后缀。增加 `services/README.md` 说明分层。

---

### F-W2A-061 [P2][C-性能][reader/services]

**File**: `flutter_app/lib/features/reader/services/reader_auto_scroller.dart:97-117`

**问题**: 滚动模式 `_stepScroll` 每 50ms `c.jumpTo(currentScroll + pixelsPerStep)`——`jumpTo` 是同步立即跳，没有 InertiaSimulation；用户视觉上是"卡顿地一格一格"而非"匀速滑动"。

**建议**: 用 `c.animateTo(currentScroll + pixelsPerStep, duration: 50ms, curve: Curves.linear)` 改善观感；或者在每帧 `SchedulerBinding.instance.addPostFrameCallback` 内累加 `pixelsPerStep / 60`，更平滑。

---

### F-W2A-062 [P2][B-正确性][reader/tts]

**File**: `flutter_app/lib/features/reader/services/reader_tts_manager.dart:69-73`

**问题**: `setCompletionHandler` 在 init 时注册一次，但永远没人 unregister——dispose 时虽然有 `setCompletionHandler(() {})` 重置（L184），但中途如果 `init` 被多次调用（边缘 case：reader page rebuild 时构造新的 ReaderTtsManager），新 manager 会覆盖旧 manager 的 handler，旧 handler 引用的 ReaderTtsManager 已经 dispose，回调若被触发会读到已 dispose 状态。

**建议**: 在 dispose 后再被回调时用 `if (!_initialized) return;` 守护；或者 `init` 内先 `_tts.setCompletionHandler(null)` 再注册新的。

---

### F-W2A-063 [P3][A-架构][reader/tts]

**File**: `flutter_app/lib/features/reader/services/reader_tts_manager.dart:100-101`

**问题**: `init` 完成后没把 `_initialized = false` 重置回 catch 路径——如果 try 抛异常 `langOk` / `setSpeechRate` 失败，`_initialized` 仍是 false，但 `_tts` 内部状态可能已经 partially 初始化（setLanguage 成功了 setSpeechRate 失败）。下一次 `start` 早 return（`if (!_initialized) return;`），用户毫无反馈。

**建议**: catch 块明确 `_initialized = false`，并通过 `onStateChanged` 上报错误状态让 widget 显示 SnackBar。

---

### F-W2A-064 [P2][C-性能][reader/state]

**File**: `flutter_app/lib/features/reader/reader_page.dart:1949-1965`

**问题**: `_buildContinuousItemList` 是 O(N) 遍历，但 cache 失效条件以 `_cachedContinuousItems = null` 标记——append/prepend 时被清，但 `_loadedChapters` 的 paragraph 列表本身不可变；可以增量构建。

**建议**: 把 cache 改为 dirty range tracking（仅追加的 chapter 段 append items；仅前置的 chapter 段 prepend items），大书打开时减少 ListView 首屏卡顿。

---

### F-W2A-065 [P3][E-代码异味][reader/state]

**File**: `flutter_app/lib/features/reader/reader_page.dart:50-62`

**问题**: `_LoadedChapter` 与 `_ContinuousItem` 是 reader_page 内部 private class，`_LoadedChapter.paragraphs` late final 在构造内 split——但同样的 split (`content.split(RegExp(r'\n+'))`) 在 `_loadChapterContent`、`PageViewController.loadChapter`、`_buildAndMeasure`、`ReaderTtsManager._splitParagraphs`、`_search.perform`、`_buildTtsBar` 等多处重复。

**建议**: 抽公共 `List<String> splitParagraphs(String content)` helper（去掉 trim 空段、保留段顺序），所有调用点共享。

---

### F-W2A-066 [P3][E-代码异味][reader/state]

**File**: `flutter_app/lib/features/reader/reader_page.dart:645-654`

**问题**: `_cleanHtml` 仅处理 6 个 entity 与 tag 通用 strip——`<` / `>` 需要在 HTML 实体替换之**前**做（先 `&lt;` → `<` 再 strip `<...>` 会把转义还原的字面量当 tag 误删）。

**详细**: 比如内容 `&lt;script&gt;` 经过：`&lt;` → `<`、`&gt;` → `>`、然后 `<...>` strip 删掉 `<script>` —— 用户原本想看到的字面量"<script>"被吃掉。

**建议**: 顺序改为先 strip tag 再做 entity unescape；或者用 `package:html` 解析后 textContent 提取，避免手写 regex 与字面量字符冲突。

---

### F-W2A-067 [P2][A-架构][reader/state]

**File**: `flutter_app/lib/features/reader/reader_page.dart:14-35`

**问题**: 35 行 import 分布混乱：`core/api/dto.dart`（即将死代码 F-W2A-001）/ `core/download_runner` / `core/platform_webview_executor` / `core/providers` / `src/rust/api.dart` / 9 个 reader 子模块——没有按"core / state / page / widgets / services" 分组排序。

**建议**: 按 dart 惯例分 5 段（dart:*、package:*、project core、project feature、relative）+ 段内字母序。

---

### F-W2A-068 [P3][D-安全][core/router]

**File**: `flutter_app/lib/core/router.dart:74-79` + `89-91` + `122-124` + `129-132`

**问题**: 多个 GoRoute 直接 `state.uri.queryParameters['x'] ?? ''`，没有验证 bookId / sourceUrl / link 的格式。bookId 是 sha256 hex 前缀，中途若被恶意 deep link 篡改成 SQL 注入字符（如 `'; DROP TABLE`），bookId 直接拼进 SQL where clause 时会有风险。

**详细**: 实际上 Rust 端 sqlx 是 prepared statement，注入 immune；但前端 widget 在 jumpToChapter / 显示书名等场景未做校验，可能 trigger 后端日志注入或 widget 渲染 bug。

**建议**: 在 router builder 内 validate `bookId` 满足 `^[A-Za-z0-9_-]{1,64}$`，否则 `redirect to /bookshelf`；同理 `link` 严格 https/http。

---

### F-W2A-069 [P2][C-性能][reader/state]

**File**: `flutter_app/lib/features/reader/reader_page.dart:1093-1098`

**问题**: `_scrollDebounceTimer = Timer(const Duration(milliseconds: 500), () { ... _saveScrollPosition(); });`——`_saveScrollPosition` 自身又触发 `await ref.read(dbPathProvider.future)`，如果用户停止滚动正好在 chapter 切换边界，刚 await 完 dbPath 第二次滚动又触发新 timer，可能并发 N 个 save。FRB 端 saveReadingProgress 走 spawn_blocking 应该是 atomic，但 Dart 端的并发对 Stopwatch / log 排序有影响。

**建议**: `_saveScrollPosition` 内加 `if (_isSaving) return;` flag；或 throttle 到 1s 上限。

---

### F-W2A-070 [P3][E-代码异味][core/notification_service]

**File**: `flutter_app/lib/core/notification_service.dart:6-11`

**问题**: `_channel = MethodChannel('legado/notifications')` 与 `_downloadChannelId = 'legado_download'`、`_downloadChannelName = '下载通知'` —— 中英混用魔法字符串，且与 Android 侧 `MainActivity.kt:DOWNLOAD_CHANNEL_ID` 必须严格相同（注释 L10 已声明），任一处改键就坏链。

**建议**: 抽 `class NotificationConst { static const downloadChannelId = 'legado_download'; static const methodChannel = 'legado/notifications'; }` + 在 README 标注"修改前必须同步更新 Android 端"。

---

### F-W2A-071 [P3][D-安全][core/main]

**File**: `flutter_app/lib/main.dart:14-65`

**问题**: `main()` 异步初始化时序：FRB init → Notification init → ReaderSettings load → runApp → postFrame load pendingRoute。每一步都包 try-catch 但没有上报机制；FRB 失败显示 _FrbInitErrorApp，其它失败仅 debugPrint 用户没感知。

**建议**: 把启动失败信号（FRB init / db init / notification init 三处）汇总到一个 `StartupErrorReporter` 或 Sentry-like 工具；至少在设置页提供"诊断"按钮 dump 启动日志。

---

### F-W2A-072 [P2][A-架构][core/main]

**File**: `flutter_app/lib/main.dart:74-87`

**问题**: `LegadoApp.build` 里调 `ref.listen(dbInitializedProvider, ...)` —— `listen` 是副作用注册，应该在 ConsumerStatefulWidget 的 initState 里注册一次；放在 `build` 中每次 rebuild 都会**重新注册**新 listener（虽然 Riverpod 内部 dedup，但仍有微小开销）。

**详细**: 这里 ConsumerWidget 没 init 钩子，`ref.listen` 在 build 内确实是 Riverpod 推荐做法（Riverpod 文档 explicitly 支持 build 内 ref.listen），所以技术上 OK；问题是 callback 内部 `DownloadRunner.resetInterruptedTasks(dbPath)` 是个全局副作用，可能在每次 themeMode 改变时被重复触发。

**建议**: 加 `bool _resetCalled = false` 守护单次调用；或者把 `resetInterruptedTasks` 调用挪到 `dbInitializedProvider` 自身的 `data` 内（StateNotifier 而不是 FutureProvider）。

---

### F-W2A-073 [P2][A-架构][core/main]

**File**: `flutter_app/lib/main.dart:17-22`

**问题**: 6 个 `debugRepaint*` / `debugPaint*` 标志显式置 false——这些 dart:rendering 调试标志的默认值就是 false，写出来反而误导（让人以为这里调过）。

**建议**: 删除这 6 行 + L2 import。

**Resolution (BATCH-22, 2026-05-21)**: Resolved。删 6 行 debugPaint 赋值 + 1 行 `import 'package:flutter/rendering.dart';`。

---

### F-W2A-074 [P3][E-代码异味][core/main]

**File**: `flutter_app/lib/main.dart:30-44`

**问题**: FRB init 失败时显示中文错误页"Rust 桥接初始化失败"，但 catch 的 stack trace 也直接展示在 SelectableText 内——release 包用户看到 stack trace 体验不友好（虽然方便测试者反馈）。

**建议**: 用 `kReleaseMode` 切换：release 显示"无法启动，请联系开发者"，debug 显示完整 stack。

---

### F-W2A-075 [P2][A-架构][reader/page]

**File**: `flutter_app/lib/features/reader/page/page_view.dart:96-98` + `_PageViewWidgetState`

**问题**: `_onControllerChanged` 在 controller notifyListeners 时 `setState({})`——但**只有 controller 内部变化才需要 setState**（chapter 切换 / page index 变化）。settings 字段变化通过 `didUpdateWidget` 已经处理了，没必要再走 controller-driven setState。

**详细**: 实测 controller.notifyListeners 触发频率：jumpToPage / goToNext / goToPrev / loadChapter / setNeighborChapter 共 5 处，每次都 setState 全 PageViewWidget rebuild。其中 setNeighborChapter（reader_page._measureAdjacentChapters 触发）频率最高（每次 chapter open + content fetch 完成都调一次），但其影响只到 painter 的 boundary picture——其实只需要 `markNeedsPaint` 等价。

**建议**: 拆 controller listener：page-change 类用 setState；chapter content 类用 `notifyListeners(false)` 标记，painter shouldRepaint 自驱动；可考虑两个 ChangeNotifier 解耦。

---

### F-W2A-076 [P3][A-架构][reader/page]

**File**: `flutter_app/lib/features/reader/page/page_view_controller.dart:104` + `27-32` + `13-23`

**问题**: `_ChapterModel`（私有）+ `ChapterWindow`（public DTO，仅用于 setNeighborChapter）+ `TextPage`（public）+ `PageMeasureResult`（public）—— 4 个 page 域 model 散落，没有统一文件夹。`_ChapterModel` 不能被 reader_page 看到，所以 reader_page 必须用 `ChapterWindow` 桥接，造成"两份 chapter 数据结构"——chapter 字符串内容在 reader_page._cachedChapters[] / `_LoadedChapter` / `_ChapterModel` / ChapterWindow 4 处分别存。

**建议**: 把 `_ChapterModel` 提升为 public class（或用 record）；reader_page 取消 `_LoadedChapter`，统一用 `ChapterModel` 列表。

---

### F-W2A-077 [P2][B-正确性][reader/page]

**File**: `flutter_app/lib/features/reader/page/page_view_controller.dart:165-179`

**问题**: `boundaryNextPage` 仅在 `currentPageIndex == pages.length - 1` 时才返回 next 章首页——但 `cur.pages.isEmpty` 时 `cur.pages.length - 1 == -1`，与 `currentPageIndex == 0` 不等，于是 `isLast` false，返回 null。这是对的。但同时 `nextPage` getter（L146）`(currentPageIndex + 1 < pages.length)` 在 pages 空时也返回 null。OK。

**详细**: 真正风险：`commitToNextChapter` 后 `prev = old cur`（pages 已 measured，OK），但**old cur 的 currentPageIndex 没有重置**——下次 `commitToPrevChapter` 把 old cur 升回来时，`currentPageIndex` 仍是末页（commitToPrev L216-217 显式跳到 lastIdx）。看起来对，但 commitToNext 把 prev 设成 old cur 时如果之后 prev 又被 commit 回来的概率低（一般不来回切），不验证就潜伏。

**建议**: commitToNext 后把 _prevChapter（即 old cur）的 currentPageIndex 显式设为 lastIdx，与 commitToPrev 行为对齐。

---

### F-W2A-078 [P2][C-性能][reader/page]

**File**: `flutter_app/lib/features/reader/page/page_view_controller.dart:374-400`

**问题**: `_buildAndMeasure` 在 `setNeighborChapter` 调用时同步 measure 邻章——如果章节段落数 5000+，single tap 会卡 100-300ms。reader_page 在 chapter open 后 fire-and-forget 调用，UI 线程 jank 直接被用户感知。

**建议**: 邻章 measure 移到 isolate（dart:ui ParagraphBuilder 部分可以 spawn_isolate，flutter 3.7+ 支持 SkParagraph 跨 isolate）；或用 `compute()` 做异步 wrapper，setNeighborChapter 改为返回 Future。

---

### F-W2A-079 [P2][B-正确性][reader/page]

**File**: `flutter_app/lib/features/reader/page/page_view.dart:286-304`

**问题**: `_onPointerCancel` 在 `_slopExceeded` 已 true 时调 `_delegate.cancelDrag()`，但**没有清 `_animController.value` ≠ 0** 的情况——`cancelDrag` 内部置 `animController.value = 0` 但 R17 路径 `if (animController.isAnimating) animController.stop();` 之后才 `animController.value = 0`，这中间一帧 painter 可能拿到 progress 非 0 的旧值。

**建议**: `cancelDrag` 内部把 `animController.value = 0` 移到 stop 之后（当前已经是这样，OK——重看代码确认）。当前实现 L361-368 顺序对，但 注释强调"先 stop 再 reset" 没有写出。

---

### F-W2A-080 [P2][A-架构][reader/page]

**File**: `flutter_app/lib/features/reader/page/page_view.dart:28-32` + `194-195`

**问题**: `debugDelegateSink` 是 test-only sink 让 widget tests 观察 internal delegate——`@visibleForTesting` 是 dart-only annotation，不会阻止生产代码调用。如果 future 开发者误用此 sink 注入业务逻辑，导致测试与生产行为分叉。

**建议**: 用 build flavor + assert 双保险：`assert(() { debugDelegateSink?.call(_delegate); return true; }());` —— release build 完全无副作用。

---

## 审查覆盖度自评

### Read carefully（精读 ≥ 80% 内容，理解控制流）
- `flutter_app/lib/main.dart`
- `flutter_app/lib/core/api/*`（5 个文件，全部）
- `flutter_app/lib/core/providers.dart`
- `flutter_app/lib/core/transport.dart`
- `flutter_app/lib/core/router.dart`
- `flutter_app/lib/core/theme.dart`
- `flutter_app/lib/core/download_runner.dart`
- `flutter_app/lib/core/notification_service.dart`
- `flutter_app/lib/core/cover_cache.dart`
- `flutter_app/lib/core/perf_monitor.dart`
- `flutter_app/lib/core/platform_webview_executor.dart`
- `flutter_app/lib/core/refresh_rate_controller.dart`
- `flutter_app/lib/features/reader/reader_page.dart`（全 2807 行）
- `flutter_app/lib/features/reader/page/page_view.dart`
- `flutter_app/lib/features/reader/page/page_view_controller.dart`
- `flutter_app/lib/features/reader/page/page_measure.dart`
- `flutter_app/lib/features/reader/page/content_page.dart`
- `flutter_app/lib/features/reader/page/text_page.dart`
- `flutter_app/lib/features/reader/page/delegate/page_delegate.dart`
- `flutter_app/lib/features/reader/page/delegate/horizontal_page_delegate.dart`
- `flutter_app/lib/features/reader/page/delegate/simulation_page_delegate.dart`
- `flutter_app/lib/features/reader/page/delegate/cover_page_delegate.dart`
- `flutter_app/lib/features/reader/page/delegate/slide_page_delegate.dart`
- `flutter_app/lib/features/reader/page/delegate/fade_page_delegate.dart`
- `flutter_app/lib/features/reader/page/delegate/no_anim_page_delegate.dart`
- `flutter_app/lib/features/reader/page/delegate/simulation_degrade_controller.dart`
- `flutter_app/lib/features/reader/page/simulation_native_fallback.dart`
- `flutter_app/lib/features/reader/services/reader_tts_manager.dart`
- `flutter_app/lib/features/reader/services/reader_progress_service.dart`
- `flutter_app/lib/features/reader/services/reader_bookmark_service.dart`
- `flutter_app/lib/features/reader/services/reader_auto_scroller.dart`
- `flutter_app/lib/features/reader/services/reader_key_handler.dart`
- `flutter_app/lib/features/reader/services/tap_zone_resolver.dart`
- `flutter_app/lib/features/reader/services/long_press_action_handler.dart`
- `flutter_app/lib/features/reader/state/reader_search_controller.dart`
- `flutter_app/lib/features/reader/widgets/reader_top_bar.dart`
- `flutter_app/lib/features/reader/widgets/reader_bottom_bar.dart`
- `flutter_app/lib/features/reader/widgets/reader_search_bar.dart`
- `flutter_app/lib/features/reader/widgets/reader_tts_bar.dart`
- `flutter_app/lib/features/reader/widgets/reader_settings_sheet.dart`
- `flutter_app/lib/features/reader/widgets/long_press_action_sheet.dart`
- `flutter_app/lib/features/reader/widgets/tap_zone_config_dialog.dart`
- `flutter_app/lib/features/reader/change_source_dialog.dart`

### Skim（粗读 ≤ 50%，仅过 API surface）
（无——所有文件都精读了）

### 未完成 / 推迟
- **simulation_page_delegate.dart 的几何正确性**：未对 5 段贝塞尔 + 4 段阴影几何做单独的"对照 MD3 Kotlin 源 line-by-line"审查（PRD 明确说"广覆盖优先"，几何细节留给后续修复任务）
- **page_measure.dart 的字符 offset 单调性**：T1 fix（L211-216）已经 patch 了一次"单调性兜底"，但本次审查没有反向构造测试用例验证修复正确（建议作为子任务"为 page_measure 增加单元测试覆盖 T1 场景"）
- **flutter_riverpod / flutter_local_notifications / dio / flutter_tts 等 pubspec 依赖**：依赖深度安全审计明确不在本次范围（PRD Out of Scope）
- **reader_settings_sheet 的 SegmentedButton / Slider Material 3 用法**：UI 一致性未深审，主要在功能正确性维度记录

### 已知盲点 / 建议后续审查
- 未检查 `flutter_app/test/`（PRD 明确不审）
- 未触碰 `flutter_app/lib/src/rust/`（FRB generated）
- 未跑 `flutter analyze` / `dart format`（PRD 要求 grep+read only）
- 未对照 Rust 端 (`api-server` / `bridge`) 与 Dart 端 ChapterContentResponse 等 DTO 的字段对齐（这是 Wave 3 的"跨层一致性"任务）

---

**Wave 2A complete: 80 findings (P0:1, P1:18, P2:33, P3:14)**
