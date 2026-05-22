# Quality and Anti-Patterns

What the Flutter app rejects and why.

## Reader 正确性边界 (BATCH-19a)

reader 模块踩过 4 个 B-正确性 finding（F-W2A-004/005/006/007），沉淀出三条契约。新代码踩到任一条直接 review 卡。

### `ReaderSettings` ==/hashCode 契约

`ReaderSettings` 是 `StateProvider` 持有的数据类，reader_page 在 `build` 内拿它做 `providerSettings != _settings` short-circuit。**没有 `==` override 时 != 永远是 true**（reference 不等），导致每帧 schedule postFrame 回写 + setState，PageView 动画期间一秒数十次空跑。

契约：

- 4 处字段集合必须一致：构造器 / `copyWith` / `toJson` / `fromJson` / `==` / `hashCode`。
- `==`：先 `identical(this, other)` 短路 → `other is! ReaderSettings` 类型检查 → 全字段比较。
- `hashCode`：`Object.hashAll([...全部字段])`。
- `List<int>` 字段（如 `tapZones`）必须用 `listEquals` 深比较 + `Object.hashAll(field)` 入外层 `hashAll`，否则 == 返回 false 但 hashCode 相等会撞键。
- 单测 `flutter_app/test/reader_settings_equality_test.dart` 用参数化 mutator 列表把每个字段轮一遍 != case + `set_dedup` size 校验。新增字段时**必须同时改**：构造器、copyWith、toJson、fromJson、==、hashCode、equality 测试 mutator 列表（共 7 处）；测试里的 `mutators.length == 31` 断言会在漏改时先红。
- 不引 freezed / build_runner——手写够用，构建链不被打扰。

### `replaceRuleGenerationProvider` 主隔离边界

`StateProvider<int>` 计数器每次 ReplaceRule CRUD 后自增，Rust 端缓存 key 是 `(db_path, generation)`。**不同 isolate 各自从 0 计数**会导致两个 isolate 都 bump 到 1 但规则集不同，缓存撞键命中错误版本。

契约：

- 所有调 `bumpReplaceRuleGeneration(ref)` 的代码路径必须在 main isolate。当前 100% 满足（`replace_rule_page.dart` UI CRUD + import flow），`download_runner` 不写规则。
- 如果以后引入 download isolate / worker isolate 写规则，必须升级为 `StateProvider<({String salt, int counter})>` 把 process-startup salt 也带进 cache key（短 hex 串足够），Rust 侧同步把 `cache_key` 拼接为 `(db_path, salt, counter)` 三元组。
- 不在 dart 端加 `assert(Isolate.current.debugName == 'main')`：`debugName` 在 release build 不可靠，依赖它做 production assertion 会引入误报。spec 文档化即可。

### `_onScroll` 防抖隔离原则

reader_page `_onScroll` 内同时挂三种独立路径，每路径节流策略不同。原版用一个 `_scrollDebounceTimer` 早 return 拦下整个函数 → 长程滚动期间章节标题不更新、append/prepend 不触发。

契约：

- **save 路径**（`_saveScrollPosition`）独占 `_scrollDebounceTimer`：500ms 节流，timer 在 fire 后置 null 让下次 `_onScroll` 重新 schedule。
- **visible chapter 更新路径**（`_updateVisibleChapter`）用 `_visibleChapterTimer ??= Timer(...)`：300ms 防抖，窗口内只 schedule 一次但**不被** save debounce 拦下。
- **反向滚动检测 + append/prepend 触发**：每帧执行，**完全不防抖**。临界滚动到边缘时立即追加下一章，否则用户滚到底等 500ms 才拼章节，体验差。
- 新加滚动路径时按"防抖窗口语义不同就独占 timer"原则拆，不要复用 `_scrollDebounceTimer`。


## Reader 性能边界 (BATCH-19b)

reader 模块踩过 2 个 C-性能 finding（F-W2A-011 / F-W2A-014），沉淀出两条契约。BATCH-19a 的正确性边界是**前置条件**——`ReaderSettings` 有 `==` / `hashCode` 后，下面的 listen 才能按字段相等性 short-circuit。

### build 顶层不 watch settings（rebuild 链路）

reader_page 的 settings 真正 source of truth 是 `_State._settings` plain field，子树都从 `_settings` 读；`readerSettingsProvider` 只是跨页面同步通道（设置页 slider、bookshelf 排序、字号长按调节回写）。

契约：

- `build` 顶层 **不** 调 `ref.watch(readerSettingsProvider)`，改用 `ref.listen<ReaderSettings>(readerSettingsProvider, (prev, next) {...})`：
  - listen 在 build phase 调用是合法的（Riverpod 文档明确支持），回调 post-build 触发，无需 `addPostFrameCallback` 包裹。
  - 回调内 `if (mounted && _readerSettingsLoaded && next != _settings) _setReaderSettings(next);` 把 provider 端变更同步到 plain field + setState 触发本组件 rebuild。
- `_setReaderSettings` 必须包 `setState(() => _settings = settings)`：listen 不会触发本组件 rebuild，需要显式 setState 推动子树看到新 `_settings`。
- 首帧值由 `initState` 的 `loadReaderSettingsFromDisk().then((s) => _setReaderSettings(s, markLoaded: true))` 兜底；listen 接管后续 provider 端变更。
- `ReaderSettings.==` 必须语义相等（BATCH-19a 已建）：listen 在稳态下因 `next != _settings` 短路，避免空跑。

为什么要这样：之前 `build` 顶层 `ref.watch(readerSettingsProvider)` 让 settings 任一字段变化都全树 rebuild ReaderPage，包括 `_buildPageBody` 的 PageViewWidget 和 `_buildContinuousBody` 的 ListView.builder——`PageViewWidget.didUpdateWidget` 自己再做字段比对决定是否重测，但 LayoutBuilder 已经被 rebuild 了一轮。改 listen 后只有真实变更（设置页 slider 调整等）才进入 `_setReaderSettings → setState` 单路径，rebuild 链路收敛。

### GlobalKey 反查保存恢复对称（paragraph index 精度）

滚动模式 paragraph index 的保存与恢复必须**走同一种算法**：cap 内 GlobalKey 反查 + cap 外估算 fallback。任一边只用估算另一边用反查会引入 ±1-2 段漂移，下次恢复 ensureVisible 落到错误位置。

契约：

- 保存路径（`_updateVisibleParagraph`）：
  1. 拿 `_listViewKey` 的 RenderBox 视口
  2. 遍历当前 visibleChapter 的前 `_kParagraphKeyCap` 个 `_paragraphKeys[_paragraphKeyId(ch.index, idx)]`，取第一个 `box.localToGlobal(Offset.zero, ancestor: listBox).dy >= 0` 的最小 idx
  3. 找不到（key 全在视口之上 / 全没 layout / 章超过 cap）→ fallback 到原标题 dy + 平均段高估算
- 恢复路径（`_restoreProgress`）已是这套（P2-13 提交时建立）：cap 内用 `Scrollable.ensureVisible(key.currentContext)`，cap 外用 `_scrollController.jumpTo(titleHeight + approxParagraphHeight * idx)`。
- `_paragraphKeyId(chapterIndex, paragraphIndex)` 返回 `'$chapterIndex|$paragraphIndex'`，构造路径（`_buildContinuousBody`）和 lookup 路径必须用同一个 helper，不要在 lookup 处手写字符串。
- GlobalKey lookup 必须先 `box?.hasSize == true` 过滤——子节点未 layout 时 `localToGlobal` 返回 dummy 值会污染查找。
- cap = 200 paragraphs 是长篇小说内存预算（每章只为前 200 段建 GlobalKey）。每次滚动 debounce 300ms 跑一次 200 key 遍历是 µs 级，可忽略。


## Reader 渲染边界 (BATCH-19c)

reader 模块踩过 2 个 C-性能 finding（F-W2A-012 子项 1 / F-W2A-013），沉淀出两条契约。BATCH-19a/b 是前置条件——`ReaderSettings.==/hashCode` + `ref.listen` 让稳态 setting 变更不进入 painter；本批进一步处理 painter 触发与 ChangeNotifier 时机问题。

### `_measureChapter` 末 phase-aware notifyListeners

`_measureChapter` 完成同步分页后必须把 `notifyListeners()` 路径根据当前 `SchedulerBinding.instance.schedulerPhase` 分流，而非一律 postFrame：

```dart
final phase = SchedulerBinding.instance.schedulerPhase;
final canNotifySync =
    phase == SchedulerPhase.idle || phase == SchedulerPhase.postFrameCallbacks;
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
```

契约：

- **能同步则同步**：`SchedulerPhase.idle` / `postFrameCallbacks` 阶段同步 `notifyListeners` 不会 reentr build/layout/paint，直接消除"加载圆圈 → 空白章节 → 真正内容"三段闪烁——`build` 帧拿到的就是已 measure 完的 `pages` 而不是 `const []`。
- **build / layout / paint / persistentCallbacks 阶段保留 postFrame 兜底**：极少数路径会从 build 内（典型：Riverpod selector 在 build 内 read provider）触发 `loadChapter` → `_measureChapter`，此时同步 notify 会"setState during build"。postFrame 是兜底保险，不能省。
- 章节身份校验（`_currentChapter?.chapterIndex == chapterIndex` + `!_disposed`）两路径都保留：sync 路径理论上不会脏，但写法对称避免日后 refactor 漏漏；postFrame 路径用户可能在帧间已切走章节。
- 已通过 `flutter test`（baseline 523）回归验证：sync 路径在 widget test 跑 reader UI 不触发 setState during build assert。

### AnimatedBuilder Listenable 拆层评估结论（保留合并）

`page_view.dart` 的 `AnimatedBuilder(animation: Listenable.merge([controller, animController]))` 经评估**不拆**，原因：

`PageViewController.notifyListeners` 7 个调用点全部是离散低频用户/系统事件：

| 调用点 | 触发场景 | 频率 |
|---|---|---|
| `setNeighborChapter` | 外层灌入邻章后 | 跨章 1 次 |
| `commitToNextChapter` / `commitToPrevChapter` | 跨章动画完成 | 跨章 1 次 |
| `jumpToPage` | TOC / 跳页 | 用户操作 1 次 |
| `goToNextPage` / `goToPrevPage` | 章内 tap / 翻页完成 | 用户操作 1 次 |
| `_measureChapter` | 章节加载 / 设置变化 | 加载 1 次 |

并发上限 ≈ 用户连续 tap 频率（≤ 3-5 次/秒）。合并 listenable 引入的"无效 painter rebuild"——controller notify 触发 `_PageViewPainter` rebuild 但 `shouldRepaint` 多数字段相等——成本可忽略。

嵌套方案（外 anim-only `AnimatedBuilder` / 内 controller-only `AnimatedBuilder`）每帧 anim 推进时**仍**重建内层 builder + painter，只在 anim **未跑**期间收益（controller 单独 notify 不触发 painter）；考虑到非 anim 期 notify 频率本来就低，嵌套引入的可读性成本不划算。

复评触发条件：

- 若未来引入 controller 高频更新（滚动进度条同步 / 实时书签 hover 高亮 / 朗读高亮等），单 `notifyListeners` 频率超过 10 次/秒，重新拆嵌套 `AnimatedBuilder`，此时外层只听 `_animController` 驱动 anim 帧、内层只听 `controller` 处理新增高频源。
- 若 `_PageViewPainter.shouldRepaint` 比对字段大幅扩张（>20 字段）、单次比较成本上升到不可忽略，也是触发条件之一。
- 若新增 listenable（DragDelegate 单独的 ValueNotifier 等），优先用 `Listenable.merge` 加进去而不是嵌套 builder。

### `_calcPoints` 早退缓存与 LinearGradient shader 缓存评估结论（Resolved-by-Design / 不动）

`SimulationPageDelegate._calcPoints` 与 `draw` 内 4 处 `ui.Gradient.linear` 经评估**不加缓存**，原因：

仿真翻页 painter 的实际重绘路径只有 3 类：

| 路径 | currentTouch 行为 | painter `shouldRepaint` | 早退 / shader 缓存命中 |
|---|---|---|---|
| 用户 drag 期间 | 跟手指每帧变（slop 越过后） | `isRunning=true` 必返 true | `_calcPoints` guard 不命中（touch 每帧不同）；shader 缓存键也每帧 miss |
| tap 触发的 anim 期间 | 由 `_animStartTouch` → `_animTargetTouch` lerp，每帧不同 | `isRunning=true` 必返 true | 同上 |
| anim 完成后 idle | currentTouch 不再变 | `isRunning=false` + 字段相等返 false → **draw 不被调用** | guard / 缓存都触不到 |

drag / anim 是仿真翻页**唯一**的 painter 热路径；这两条路径上 `currentTouch` 每帧都不同（手指位置 / lerp 进度），早退 guard 永远 miss。idle 期 painter 的 `shouldRepaint` 已经把 `currentTouch` / `direction` / `animProgress` 加进比较，外层 `AnimatedBuilder` 触发时 `shouldRepaint` 返 false → `paint` 不会被调用 → 也不存在"draw 被多调一次需要 guard 拦掉"的问题。

LinearGradient shader 缓存的 cache key 必须包含 `(_isRtOrLb, _bs1x, _bs1y, _bc1x, _bc1y, _bc2x, _bc2y, _be1x, _be1y, _be2x, _be2y, headColor, tailColor)`——这些坐标全部由动态 `currentTouch` 派生，drag/anim 期每帧不同，**与 `_calcPoints` guard 同样的 miss 率**。同 file 注释已承认 LinearGradient shader 创建"开销可控"。

复评触发条件：

- 加上 fps 基线测试（widget benchmark 或 driver 追 frame budget），实测仿真翻页在 60Hz / 120Hz 设备上跑出 jank、且 profile 抓出热点确实落在 `_calcPoints` 的 atan2/sqrt 或 shader 创建上时，再回头评估。
- 若仿真翻页改 anim 模型（不再每帧 lerp currentTouch，而是固定帧数离散推进 + 中间帧复用同一几何），则早退 guard 命中率提升，那时再加。
- 若 `_calcPoints` 输出几何被多个 painter 共享（目前只有 simulation 一个用），缓存收益放大，也是触发点。


## Lint Bar

`flutter_app/analysis_options.yaml` enables the default flutter_lints set with project-specific tightenings. `flutter analyze` must report **0 issues** before any commit.

When you must use `// ignore:`:

- Always include the lint name (`// ignore: invalid_use_of_protected_member`).
- Always add a one-line comment explaining why.
- Reserve `// ignore_for_file:` for generated code only.

Example used by `core/widgets/safe_setstate.dart`:

```dart
// ignore: invalid_use_of_protected_member
setState(fn);
```

This is acceptable because the extension is a thin syntactic wrapper. New `// ignore` lines that don't have a similar justification will be flagged.

## Forbidden Patterns

| Pattern | Why | Reference |
|---|---|---|
| `if (mounted) setState(() => ...)` inside `lib/features/` | 31 sites collapsed to `safeSetState`. Reintroduction breaks the convention. | BATCH-25 sweep |
| `getApplicationDocumentsDirectory()` outside `core/persistence/` | Bypasses the resolver + test hook. | BATCH-18e |
| `File('$dir/foo.json').readAsString` for new persistence | Bypasses `_Mutex` write serialization. | BATCH-18c json_store |
| `final dynamic raw = n; return raw is int ? raw : raw.toInt() as int;` | Use `platformInt64ToInt(n)` instead. | BATCH-24 |
| Hand-rolled `_formatRelativeTime` | Use `formatRelativeTime(int sec)` from `core/util/time_format.dart`. | BATCH-24 |
| Re-implementing the import-summary label string | Use `formatImportSummaryLabel(...)`. | BATCH-24 |
| Single-line `return author.isEmpty ? '未知作者' : author;` for fallback display name when there is a richer helper | Keep small inline helpers in feature when truly local; promote when 2nd caller appears. | BATCH-24 promotion rule |
| Using `print` / `debugPrint` for production logs | Use `core/perf_monitor.dart` or `tracing` (via FRB) for telemetry. `debugPrint` is fine for dev-time hints. | n/a |
| `setState` after `await` without a mounted check | See [async-and-mounted](./async-and-mounted.md). | BATCH-25 |
| Two providers exposing the same conceptual value | Derive one from the other. | BATCH-18d (`fontSizeProvider`) |
| Writing passwords / API tokens / WebDAV credentials / 备份密码 to `settings.json` / `legado_local.json` / 任何 per-feature `*.json` | Use `core/security/secure_storage.dart` (`writeSecret/readSecret/deleteSecret`). See "凭据保险柜 (Credential Vault, BATCH-03 / BATCH-03b)" below. | BATCH-03 / BATCH-03b |
| `Map<String, String>!` accessor pattern (`cfg['url']!`) for known-shape config | Use a file-private data class with `final` fields. The config "shape" should be encoded in the type, not implied via `!`. | BATCH-03 (`_WebDavCredentials`) |
| `Uri.parse(remoteUrl)` 不经 `enforceWebViewScheme` 直接走 `loadRequest` / `dio.get` | 让 `file://` / `javascript:` / `data:` 越界 scheme 进 webview 是 SSRF / 任意代码执行入口。任何远端 URL 必经 scheme 白名单。 | BATCH-05 (`webview_safety.dart`) |
| New webview caller uses `JavaScriptMode.unrestricted` without ADR | reader is the only business-justified case; new callers default to `disabled` and must document the necessity. | BATCH-05 |
| JS 返回值 fallback `text.substring(1, text.length - 1)` 粗暴去引号 | 在 JSON-string 含转义时丢内容；用 `safeJsResultDecode(rawResult)`。 | BATCH-05 (F-W2A-010) |
| `record['x'] = newValue` 原地修改 list-of-maps 元素 | 列表上多个 caller 持原 record 引用时 mutation aliasing；用 `_records = List.of(_records)..[idx] = {...record, 'x': newValue}` immutable update。 | BATCH-21 (F-W2B-014) |
| 多 future 调用入口缺 seq token | 用户连续触发同一 async action（搜索、刷新）时旧 future 后完成会"幽灵"覆盖新结果；加 `int _xxxSeq` 自增 token + 每个 await 后 `seq == _xxxSeq` 校验 + finally 内同样校验。 | BATCH-21 (F-W2B-019) |
| TabBarView children 直接 `[for t in _tabs _buildXxx(...)]` method 返回 | 父 setState 让所有 tab 同时 rebuild + 切走的 tab 丢 scroll position；抽 `_XxxTabView` `StatefulWidget` + `AutomaticKeepAliveClientMixin`，build 内调 `super.build(context)`。 | BATCH-21 (F-W2B-013) |

## 凭据保险柜 (Credential Vault, BATCH-03 / BATCH-03b)

**敏感字段必须走 `core/security/secure_storage.dart`，不允许进 `settings.json` / per-feature `*.json` / FRB string payload**。canonical 例子：WebDAV password（BATCH-03）+ Legado 备份密码（BATCH-03b）。

凭据存储主题已闭环：F-W2B-001（webdav password）+ F-W1A-020（backup password）全部 Resolved。

### 何为「敏感字段」

- 用户密码、API token、设备私钥、OAuth refresh token、HTTP basic auth credential、WebDAV password、Legado 备份密码。
- 反例（**非敏感**，仍可走 `json_store`）：URL / username / device-name / preference flags / cache keys / search history。

### key 命名空间

| key | 引入批次 | 旧路径 |
|---|---|---|
| `webdav_password` | BATCH-03 (F-W2B-001) | webdav.json `password` 字段 |
| `backup_password` | BATCH-03b (F-W1A-020) | legado_local.json `password` 字段（FRB `set/get_backup_password`） |

### IO 路径

```dart
// 写
import 'package:flutter_app/core/security/secure_storage.dart';
await writeSecret('webdav_password', controller.text);
// 顺手把非敏感字段单独走 json_store，不混在一起
await writeJsonFile('webdav.json', { 'url': url, 'user': user, 'deviceName': dev });

// 读
final pwd = await readSecret('webdav_password') ?? '';

// 删除（写 null 或空串等价）
await writeSecret('webdav_password', null);
// 或者
await deleteSecret('webdav_password');
```

后端：Android = `EncryptedSharedPreferences` (AES-256/GCM, key in Keystore，flutter_secure_storage v9 默认，与 minSdk 23+ 对齐)；iOS = Keychain；其它平台由 `flutter_secure_storage` 内置默认（不在主线优先级）。

### 测试钩子

```dart
import 'package:flutter_app/core/security/secure_storage.dart';
import '_secure_storage_fake.dart';

setUp(() {
  setSecureStorageOverrideForTest(InMemorySecureStorage());
});

tearDown(() {
  setSecureStorageOverrideForTest(null); // 恢复 production 实现
});
```

`InMemorySecureStorage` 在 `flutter_app/test/_secure_storage_fake.dart`，是共享 fake；不要在每个测试文件各自重写。

### 为什么 top-level fn override 而不是 ProviderScope

`secure_storage` 是 cross-feature 工具（凭据全局唯一），不绑业务 Provider；与 `core/persistence/json_store.dart` 一致用 top-level fn + `setXxxOverrideForTest` 钩子。这与 BATCH-20 的「features 用 service provider + ProviderScope.overrides」不矛盾——后者针对**业务领域**（FRB 调用、文件选择等），前者针对**基础设施**。

### 迁移路径模板

旧版本可能把敏感字段写在普通 JSON 里（典型：webdav.json 含 password）或通过 FRB 写入 Rust 端管理的 JSON 文件（典型：legado_local.json 中 backup password 由 `set/get_backup_password` 操作）。迁移逻辑放对应 page 的 `_loadConfig`（页面入口），首次访问触发一次性搬迁，幂等。

#### 模板 A：旧字段在 dart 直读 JSON（webdav.json 模式 / BATCH-03）

```dart
final map = await readJsonFile<Map<String, dynamic>>(...);
final legacyPwd = (map['password'] as String?) ?? '';
final securePwd = await readSecret('webdav_password');

if (legacyPwd.isNotEmpty && securePwd == null) {
  // 一次性迁移：写入保险柜 + 重写 json 去掉敏感字段
  await writeSecret('webdav_password', legacyPwd);
  await writeJsonFile('webdav.json', {
    'url': map['url'], 'user': map['user'], 'deviceName': map['deviceName'],
    // password 不再写入
  });
}
```

#### 模板 B：旧字段在 Rust 端 FRB 管理（legado_local.json 模式 / BATCH-03b）

旧路径无法 dart 直接读 JSON（字段由 Rust 端 helper 管理 + 文件可能有损坏 .bak 兜底机制）；走 FRB read → secure_storage write → FRB write 空串清理的三步迁移。

```dart
final securePwd = await readSecret('backup_password');
if (securePwd != null) {
  _backupPwdCtl.text = securePwd; // 命中直接用
} else {
  try {
    final legacyPwd = await rust_api.getBackupPassword(documentsDir: dir);
    if (legacyPwd.isNotEmpty) {
      await writeSecret('backup_password', legacyPwd);
      try {
        await rust_api.setBackupPassword(documentsDir: dir, password: '');
      } catch (_) {
        // 清理失败不阻塞迁移；下次启动 secure_storage 命中即可
      }
      _backupPwdCtl.text = legacyPwd;
    } else {
      _backupPwdCtl.text = '';
    }
  } catch (_) {
    _backupPwdCtl.text = ''; // 桥未初始化等异常退回
  }
}
```

Rust 端 FRB（`set/get_backup_password`）保留 binary contract（funcId 71/72）以备未来 backup zip 加密复用，doc 标 deprecated 注释（**不**加 `#[deprecated]` attr —— Dart 端迁移路径仍要调）。新代码读写备份密码请走 `readSecret / writeSecret('backup_password')`，不要重新调 FRB。

#### 幂等保证

第二次启动 `securePwd != null` 命中 secure_storage 短路返回；模板 A 的 `writeJsonFile` 永不再带敏感字段；模板 B 的 FRB read 拿到空串后不再触发清理路径。三种状态机均收敛到稳态。

### Forbidden 反向

- ❌ `await writeJsonFile('webdav.json', { 'password': pwd, ... })` — 把密码混进普通 JSON
- ❌ `await writeJsonKey('webdav_password', pwd)` — 写 settings.json 也不允许
- ❌ FRB API 把 password 当 String 透传 + Rust 端写普通文件（F-W1A-020 备份密码即此问题，BATCH-03b 已闭环；新增凭据字段不要再走这条路）
- ❌ 在 widget test 直接构造 `FlutterSecureStorage()` 跑——会触发 platform channel `MissingPluginException`；用 `setSecureStorageOverrideForTest(InMemorySecureStorage())`


## WebView / Untrusted-Network 边界 (BATCH-05)

**所有把远端 untrusted URL / HTML / JS 引入应用的入口必须走 `core/security/webview_safety.dart`**。canonical 例子：reader webview / RSS 文章 webview / QR 扫码 fetch。

### 何时算"untrusted 入口"

- 任意 URL 来自书源 JSON、订阅源 JSON、RSS 源、扫码二维码、用户粘贴的 deep link
- 任意 HTML / JS 字符串来自远端 HTTP 响应、书源解析结果、用户导入的文件
- 任意 dio.get / WebView.loadRequest 的目标 URL，只要 URL 不是项目 hardcoded 的 host

### IO 路径

```dart
import 'package:flutter_app/core/security/webview_safety.dart';

// 1. scheme 白名单防线 —— 任意 Uri.parse(remoteUrl) / dio.get(url) 之前必经
enforceWebViewScheme(url);  // 越界 throws WebViewSafetyException

// 2. host 风险分类 —— UI 决定是否警告 / 拒绝
final hostClass = classifyHost(url);
if (hostClass == HostClass.privateNetwork) {
  showSnackBar('⚠️ 警告：这是内网/本地地址');
}

// 3. 项目统一 UA —— 不暴露 webview-flutter 默认 UA 指纹
final headers = {'User-Agent': defaultUserAgent()};

// 4. JS 调用返回值的安全解码 —— 不再粗暴 substring(1, len-1) 去引号
final content = safeJsResultDecode(rawJsResult);
```

### JS Mode 由 caller 决定

`webview_safety.dart` **不**强制 JS mode：

| Caller | JS mode | 原因 |
|---|---|---|
| reader (`platform_webview_executor.dart`) | `unrestricted` | 业务必须 —— 远端 webJs 规则要跑（selector / DOM 改写 / cookie 读取） |
| RSS 文章 (`rss_article_detail_page.dart`) | `disabled` | 仅展示订阅文章 HTML，不需要远端 script 执行 |
| 新增 caller | 默认 `disabled` | 新 caller 必须显式 opt-in `unrestricted` 并在 ADR 里说明业务必要性 |

reader webview 保留 unrestricted JS 是 ADR 决定，文档化在 `PlatformWebViewExecutor` class doc。

### NavigationDelegate（RSS / 非 reader caller）

跨 host 导航默认拒绝，避免用户在文章 webview 内点击外链时让攻击者控制的页面进 webview：

```dart
controller.setNavigationDelegate(NavigationDelegate(
  onNavigationRequest: (req) {
    try {
      final reqHost = Uri.parse(req.url).host;
      final baseHost = Uri.parse(baseUrl).host;
      if (reqHost.isEmpty || baseHost.isEmpty || reqHost == baseHost) {
        return NavigationDecision.navigate;
      }
      return NavigationDecision.prevent;
    } catch (_) {
      return NavigationDecision.prevent;
    }
  },
));
```

外链应在后续批次用 `url_launcher` 跳系统浏览器，更安全。

### QR 扫码 host 警告

二维码扫到的 URL 在 confirm dialog 里多显示一行 host 类警告（loopback / linkLocal / privateNetwork 红字提示），让用户辨别 SSRF 攻击。`enforceWebViewScheme` 在 protocol parser 入口就拦下越界 scheme（`legado://import/...?src=file:///...` 直接当"未识别"返回 null）。

### dio body / Content-Type 边界

QR 扫码 `_fetchText` 加：

- 10 MB body cap（防恶意源推大流量）
- Content-Type allow-list（`json` / `text/plain` / `application/octet-stream` / 空）—— 防被骗下载二进制

`QrImportHandler.validateFetchedBody(body, contentType)` 是 `@visibleForTesting` 静态方法，单测验证边界。

### Forbidden 反向

- ❌ 直接 `Uri.parse(remoteUrl)` 不经 `enforceWebViewScheme` —— 让 `file://` / `javascript:` / `data:` 等越界 scheme 进入 webview
- ❌ 新增 webview caller 默认 `JavaScriptMode.unrestricted` 而无 ADR
- ❌ 把 dio 的 `.get(remoteUrl)` 当 trusted —— 不加 timeout / body 上限 / Content-Type 校验
- ❌ JS 返回值解码 fallback 写 `text.substring(1, text.length - 1)` 粗暴去引号 —— 用 `safeJsResultDecode`
- ❌ 把 reader webview 的 `unrestricted JS` 决定 copy-paste 到新 caller —— reader 是业务豁免，新 caller 默认 disabled

### 测试钩子

`webview_safety.dart` 是纯函数，无需 override 钩子；在 widget test 里直接调 `enforceWebViewScheme('https://x') / classifyHost('http://192.168.1.1')` 即可。caller-level 测试（如 `qr_scan_page_test.dart`）通过既有 `*Override` 钩子覆盖（`scanResultOverride` / `permissionDeniedOverride` 等）。

### WebView dispose 清理 + IPv6/IPv4 完整 (BATCH-05b)

**WebView caller dispose 契约**：所有 `WebViewController()` 持有方都必须 override `dispose()` 调
`controller.clearCache().catchError((_) {})` + `controller.clearLocalStorage().catchError((_) {})`
后再 `super.dispose()`。webview_flutter 4.13 起跨 Android/iOS 统一支持。
异步 Future 不 await（dispose 不能 async），失败静默。

适用 caller：

- `core/platform_webview_executor.dart::_WebViewExecutionPageState` (reader webview rule executor)
- `features/rss/rss_article_detail_page.dart::_RssArticleDetailPageState` (RSS 文章 webview)

未来新加的 caller 加进表。

**`classifyHost` 与 Rust `ssrf_guard::is_url_safe_for_fetch` 对齐**：
两边 host 分类范围必须保持一致，参考 `core/core-source/src/legado/ssrf_guard.rs:86-110`。
当前覆盖：

| 分类 | IPv4 | IPv6 |
|------|------|------|
| loopback | 127.0.0.0/8, 0.0.0.0/8, localhost | ::1, ::ffff:127.x.x.x |
| linkLocal | 169.254.0.0/16 | fe80::/10 |
| privateNetwork | 10/8, 172.16/12, 192.168/16, 100.64/10 (CGNAT), 224.0.0.0/4 (multicast) | fc00::/7 (ULA), ff00::/8 (multicast), ::ffff:RFC1918 (mapped) |

IPv4-mapped IPv6 (`::ffff:host`) 走 IPv4 重分类，避免攻击者用 `::ffff:127.0.0.1` 绕过 IPv4 检查。


## 列表 reactivity 模式 (BATCH-21)

**TabBarView 多 tab 列表、list-of-maps 局部 update、长 async 链路下的旧 future 防护**三个高频场景在 RSS / search 主题集中出现。BATCH-21 把它们的最小防御模板沉淀下来。

### KeepAlive vs StateProvider.family 选择

| 场景 | 推荐方案 |
|---|---|
| TabBarView children 直接 method 返回 widget，setState 重建 → 多 tab 同时 build + scroll position 丢 | 抽 `_XxxTabView extends StatefulWidget` + `AutomaticKeepAliveClientMixin`（退而求其次） |
| 同上 + 单 tab 数据需要细粒度订阅 / 跨页面共享 | `StateProvider.family((sort))` per-tab（最优，但侵入大） |

`AutomaticKeepAliveClientMixin` 模板：

```dart
class _XxxTabView extends StatefulWidget {
  final String sortName;
  final List<Map<String, dynamic>>? articles;
  // ... callbacks ...
  const _XxxTabView({super.key, ...});

  @override
  State<_XxxTabView> createState() => _XxxTabViewState();
}

class _XxxTabViewState extends State<_XxxTabView>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context); // KeepAlive 必须，否则 mixin 不生效
    // ... build body
  }
}
```

TabBarView children 用 ValueKey 锁 tab 名，让 tab 列表重排时正确复用：

```dart
TabBarView(
  controller: _tabController,
  children: [
    for (final t in _tabs)
      _XxxTabView(
        key: ValueKey('xxx_tab_${t.name}'),
        sortName: t.name,
        // ...
      ),
  ],
)
```

KeepAlive 让切走的 tab 保留 ListView state + scroll position。父组件 setState 重建 TabBarView 时，未激活 tab 不参与 build。

### Immutable update 模板

list-of-maps 局部更新单个元素：

```dart
// ❌ 反模式：原地修改 record map
setState(() {
  record['enabled'] = newValue;
});

// ✅ 推荐：immutable update
final idx = _records.indexOf(record);
if (idx < 0) return; // record 已不在列表（被另一 codepath 替换）
setState(() {
  _records = List.of(_records)
    ..[idx] = {...record, 'enabled': newValue};
});
```

`List.of(_records)` 复制顶层 list；`{...record, 'enabled': newValue}` 复制目标 record map。旧 `_records` / 旧 record 引用都不变 —— 多个 caller 持引用时拿到原值，不会被原地改写造成 mutation aliasing。

`indexOf` 用 reference equality（Map 没 override `==`），符合"找到 record 自身"语义；找不到 idx = -1 早返回不抛错。

### Future seq token 模板

用户连续触发同一 async action（搜索 / 刷新 / 加载下一页）时，旧 future 仍在跑（FRB 无 cancel API），后完成时会"幽灵"覆盖新结果。模板：

```dart
class _XxxState extends State<XxxPage> {
  int _xxxSeq = 0;

  Future<void> _doXxx() async {
    // ...入口校验 + 同步赋值...
    final seq = ++_xxxSeq;
    setState(() => _loading = true);
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      if (!mounted || seq != _xxxSeq) return;
      final data = await rust_api.fetchSomething(dbPath: dbPath);
      if (!mounted || seq != _xxxSeq) return;
      // ...处理结果，写 _data...
    } catch (e) {
      if (!mounted || seq != _xxxSeq) return;
      // ...处理错误...
    } finally {
      if (mounted && seq == _xxxSeq) {
        setState(() => _loading = false);
      }
    }
  }
}
```

每个 await 后判 `seq == _xxxSeq` 拦截旧 future；finally 内同样校验避免旧 future 把 _loading 改回 false。建议加 `@visibleForTesting int get debugXxxSeq => _xxxSeq;` 让 widget test 验证 seq 自增 + 旧值不被覆盖。

### 测试钩子（BATCH-21 范本）

- `rss_article_list_page_test.dart::BATCH-21 (F-W2B-013): KeepAlive` — 30 篇文章滚到中段 → 切 tab → 切回，验"标题 0"仍不可见（如 KeepAlive 失效会回到顶）
- `rss_source_manage_page_test.dart::BATCH-21 (F-W2B-014): immutable update` — 持原 record 引用，toggle 后断言原引用未被原地改写
- `search_page_test.dart::BATCH-21 (F-W2B-019): seq token` — 用 hanging dbInitializedProvider future 让两次 `_doSearch` 都悬停，验 `debugSearchSeq` 从 1 自增到 2，`debugLastSearchKeyword` 不被旧 future 覆盖


## 跨页通信模式 (BATCH-21c)

GoRouter `context.push<T>(...).then((result) { ... })` 是项目跨页通信首选模式。**不**为简单的"detail → list 状态回传"引入 Riverpod 跨页 `StateProvider` / `StateProvider.family`，避免无谓的状态管理复杂度。

### MarkReadResult 模式（detail → list 三态回传）

适用场景：detail 页有 optimistic state 需要 rollback / commit 决策；list 端按结果分支处理。BATCH-21c 用此模式收尾 F-W2B-012 — RSS list optimistic read_time 在 detail mark_read **失败**时主动 rollback。

```dart
// detail 端：top-level enum + state field 跟踪三种结果
enum MarkReadResult {
  success,  // 真正写库成功（含原本已读跳过的情况）
  failed,   // 写库抛异常（FRB / 网络 / db lock）
  skipped,  // 未走到写库（早返回 / 入参缺 / 状态已是目标值）
}

class _XxxDetailState extends ConsumerState<XxxDetail> {
  MarkReadResult _result = MarkReadResult.skipped; // 默认兜底

  Future<void> _bootstrap() async {
    // ...拉数据...
    if (条件) {
      try {
        await rust_api.markRead(...);
        _result = MarkReadResult.success;
      } catch (_) {
        _result = MarkReadResult.failed;
      }
    }
    // 不进 if 分支保持默认 skipped
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {},
      child: Scaffold(
        appBar: AppBar(
          // 替换默认 leading 让 AppBar back 携带 result
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => context.pop(_result),
          ),
          // ...
        ),
      ),
    );
  }
}

// list 端：await context.push + 仅 failed 时 rollback
final result = await context.push<MarkReadResult>('/detail?...');
if (!mounted) return;
if (result == MarkReadResult.failed) {
  setState(() {
    article['read_time'] = 0; // rollback optimistic
  });
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('已读状态同步失败，下次刷新会重试')),
  );
}
// success / skipped / null（OS back）→ 保留 optimistic
```

### OS back 限制（已知 trade-off）

`PopScope.onPopInvokedWithResult` 在 OS back / 手势返回 / iOS swipe back 时 `didPop=true` 表示 pop 已发生，**无法**再携带 result。这条路径上 list 收到的 `result` 是 `null`，必须走 fall-back 软一致策略：保留 optimistic state，等下次刷新自然修正。

仅 **AppBar leading IconButton / 主动 `context.pop(result)`** 路径携带 result。

不适合扩展到"任何 detail 修改都要回传 list rollback"——detail 修改的 state 已是单一 source of truth（无 optimistic）时不需要这条通道。

### 三态 vs 两态

为什么 `success / failed / skipped` 而非 `bool`：
- `failed` 要 rollback；`success` 不要 rollback；`skipped` **也不要** rollback（db 状态未变）
- `bool` 表达不出 success vs skipped 的区别 —— skipped 路径 (article 原本已读 / link 空 / _error 早返回) 让默认 `false` 会被误判为 failed 触发 rollback
- enum 让 detail 端「未进 mark_read 分支」与「mark_read 抛错」语义分离

### 显式类型参数

GoRouter `context.push<T>(...)` 必须显式声明类型参数。无类型参数时返回 `Future<Object?>`，强转风险大；显式 `context.push<MarkReadResult>(...)` 让 Dart 直接推断为 `Future<MarkReadResult?>`（null 兜 OS back 路径）。

### 测试钩子（BATCH-21c 范本）

- `rss_article_detail_page_test.dart::BATCH-21c (F-W2B-012)` × 3 — markRead success / throws / skipped (already read) 三路径分别走 `MaterialApp.router(GoRouter(...))` push detail → tap leading back → 验 `Future<MarkReadResult?>` 落到对应枚举值
- `rss_article_list_page_test.dart::BATCH-21c (F-W2B-012)` × 3 — 把 `/rss-articles-detail` 路由 stub 成 `_DetailStubPage` 在 postFrame 立刻 `context.pop(returns)`，验 list 端在 failed → setState rollback + SnackBar；success / null → 保留 optimistic 不弹 SnackBar


## 页面布局对齐 (BATCH-26)

flutter_app 的顶层导航 + 二级页面入口位置以原 legado/ Android 项目为锚（仓内对照源码：`/root/data/workspaces/doro_FriendMessage_641981595/legado/`）。新增页面时优先按原版位置摆，避免重新出现 5/6 tab 蔓延或入口埋深。

### 4 tab destination 锚（对齐 `legado/main_bnv.xml`）

| index | path | builder | label | icon | selectedIcon |
|---|---|---|---|---|---|
| 0 | /bookshelf | BookshelfPage | 书架 | library_books_outlined | library_books |
| 1 | /explore | ExplorePage | 发现 | explore_outlined | explore |
| 2 | /rss | RssTabPage | 订阅 | rss_feed_outlined | rss_feed |
| 3 | /my | MyHubPage | 我的 | person_outline | person |

`StatefulShellRoute.indexedStack`，`initialLocation: '/bookshelf'`。任何想加第 5 个底栏 tab 的需求都先评估**能否归入「我的」hub 或现有 tab 顶部 menu**。

### My hub 14 项 + 3 分组（对齐 `legado/pref_main.xml`）

`flutter_app/lib/features/my/my_hub_page.dart` 是 `StatelessWidget`（不引 ViewModel/Provider），Body `ListView` 严格按下表 3 分组顺序：

**第一组（无 header）**：

| pref key | title | flutter 状态 | onTap |
|---|---|---|---|
| bookSourceManage | 书源管理 | ✓ | → /sources |
| txtTocRuleManage | TXT 目录规则 | ✗ 灰 | null |
| replaceManage | 替换净化 | ✓ | → /replace-rules |
| dictRuleManage | 字典规则 | ✗ 灰 | null |
| themeMode | 主题模式 | ✗ 灰（settings 内有真功能） | null |
| webService | Web 服务 | ✗ 灰 SwitchListTile（value:false / onChanged:null） | n/a |

**「设置」分组**：

| pref key | title | flutter 状态 | onTap |
|---|---|---|---|
| web_dav_setting | 备份与恢复 | ✓ | → /backup |
| theme_setting | 主题设置 | ✗ 灰 | null |
| setting | 其他设置 | ✓ | → /settings |

**「其它」分组**：

| pref key | title | flutter 状态 | onTap |
|---|---|---|---|
| bookmark | 书签 | ✗ 灰 | null |
| readRecord | 阅读记录 | ✓ | → /read-stats |
| fileManage | 文件管理 | ✗ 灰 | null |
| about | 关于 | ✗ 灰 | null |
| exit | 退出 | ✗ 灰（Flutter app 一般不需要） | null |

### 占位策略

未实现项**全部**走 `ListTile(enabled: false)` + onTap 不写（不弹 SnackBar，不显示「待实现」字样 — 灰显本身就是信号）。Web 服务保留 SwitchListTile 形态以视觉对齐原版「这是个 toggle」语义。

新功能落地时**只需把灰显项的 enabled / onTap 替换**，标题 + icon + 分组位置不要动 — 用户心智 = 原 legado。

### 不进 hub 的迁移项

按 R4 决策**不**进 hub，避免与 pref_main.xml 1:1 锚错位：

- 缓存/导出 → 书架 PopupMenu（对齐原 `main_bookshelf.xml` line 44-47 `menu_download` / `@string/cache_export`）
- RSS 源管理 / RSS 收藏 → RSS tab AppBar 顶部 IconButton（对齐 `main_rss.xml` 6/12/22 收藏 / 分组 / 设置三 always icon）
- 订阅源（RuleSub） / 二维码扫码 → 暂留 settings_page 工具段（属 BATCH-18f 重组）

### 过渡性双入口（spec 临时态）

BATCH-18f 在 settings_page line 183-229 加的「工具」段 6 项（备份/恢复 / 阅读统计 / 缓存管理 / RSS 收藏 / 订阅源 / 替换规则）与 26b 加的 hub 入口**双入口共存**。临时态 acceptable，让用户从两个习惯路径都能到达。

收敛节奏：等用户体感稳定后再开 26c/follow-up 删 settings 工具段，单入口由 hub 提供。在 26c 前**不要**单方面删 settings 工具段。

新加的管理类入口默认归入 hub，**不再**往 settings_page 工具段加新项。

### 测试钩子（BATCH-26b 范本）

- `my_hub_page_test.dart::BATCH-26b: hub 显示 14 项 + 3 分组结构` — `scrollUntilVisible` 验 14 项标题全可见 + 「设置」/「其它」section header
- `my_hub_page_test.dart::BATCH-26b: 灰显项 enabled false / SwitchListTile onChanged null` — viewport 800x2400 一帧构建后循环 8 项 ListTile + Switch 验
- `my_hub_page_test.dart::BATCH-26b: 已实现项 onTap` × 3 — 书源管理 / 替换净化 / 阅读记录；用 `routerDelegate.currentConfiguration.matches.last.matchedLocation` 验路由（go_router 14 的 `uri` 字段在 `imperative push` 下不更新）

### Forbidden 反向

- ❌ 加第 5 个底栏 tab — 任何 hub 能容纳的内容都不该提为 tab
- ❌ 在新页面里复刻 settings_page 「工具段」式的 6 项二次入口 — 现有过渡态已饱和
- ❌ 灰显项加 onTap 弹 SnackBar — 灰显本身就是信号，多弹一层是噪声
- ❌ MyHubPage / ExplorePage / RssTabPage 引入 Provider — hub 当前是纯 StatelessWidget，未来加状态时先评估「真要 hub 自己持有 state，还是子页 state」


## Performance Notes

- `cached_network_image` is the only blessed image cache. Don't add a parallel `Image.network` call site.
- `ListView` should be `ListView.builder` for any list whose length depends on user data. Eager `ListView(children: [...])` is allowed only for short fixed menus (settings rows, etc.).
- Reader page is the largest file (~2900 lines) and uses `RepaintBoundary` carefully. Do not casually wrap widgets in `RepaintBoundary`; profile first.
- `safeSetState` after FRB is cheap; the FRB call itself is the expensive part. Don't aggressively `setState({})` inside reader pan/scroll callbacks.

## Code Style

- Follow `dart format` defaults (80-col wrap, trailing commas where they help diff readability).
- Class members ordered: fields → constructor → static helpers → public methods → `build`/`createState` → private methods.
- Avoid `late` for fields that can have a sensible default; reserve it for FRB-injected handles.
- Use `const` constructors where possible. Linter will flag missing ones.

## Verification Cadence

Before commit:

```bash
cd flutter_app
flutter analyze
flutter test
```

Both must be 0-issue / all-green. The repo does not currently run `flutter format --output=none --set-exit-if-changed`, but matching `dart format` style is expected.

## When You Spot a New Anti-Pattern

1. Check if it appears 2+ times in the codebase. One-off slips don't warrant a rule.
2. Either fix it in the same change set, or open a Trellis batch task that captures the audit.
3. Add the pattern to the table above with a reference to the batch.

The historical record lives in `findings-flutter-features.md` (Wave 2B) and `findings-flutter-core.md` (Wave 2A). Reading a few entries before starting a refactor calibrates what we already know is bad.
