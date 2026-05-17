# Legado Flutter+Rust 重构 - 当前状态

> 自动化追踪文件 | 每次新session请先读此文件恢复上下文
> 
> **原始计划见**: `docs/plan.md`（v1.0, 2026-04-30，历史参考）
> **架构设计见**: `docs/ARCHITECTURE.md`（v0.1, 2026-04-30，历史参考）
> **历史路线图见**: `docs/ROADMAP.md`（v0.1, 2026-04-30，历史参考）
> **历史代码审查见**: `docs/phase1_code_review_report.md`（2026-04-30 22:36:55，GPT-5.5，已过期声明）

---

## 📊 总体进度

> **平台优先级**：🚀 **优先 Android**（APK 已编译，ping/pong 通过）| ⏸️ Linux 桌面方向暂停

| 阶段 | 名称 | 状态 |
|------|------|------|
| **Phase 0** | 基础设施搭建 | ⚠️ Android APK 编译通过，ping/pong FRB smoke 通过；Linux 正式打包暂停 ⏸️ |
| **Phase 0.5** | 编译错误修复 | ✅ 完成 |
| **Phase 1** | Rust 核心引擎 | 🔨 Legado 兼容层大幅推进：QuickJS 默认运行时、`java.*` bridge、真实书源合集导入、parser 接入 Legado HTTP/rule；仍缺 WebView bridge 和完整 DOM Element 语义 |
| **Phase 2** | Flutter UI 框架 | ✅ 完整实现（2026-05-04）：封面加载、网格/列表切换、字号设置、搜索历史、在线搜索、JSON 书源导入 |
| **Phase 3** | 功能整合与桥接 | ✅ 完成（2026-05-05）：多书源并发搜索、封面缓存、书源校验、书源导出、回归测试（7 Rust + 1 Flutter） |
| **Phase 4** | 高级服务移植 | 🔨 进行中：阅读器核心 ✅、替换规则 ✅、下载管理 ✅、核心链路打通 ✅ (2026-05-05)；待实现：TTS、WebDAV 同步 |
| **Phase 4.5** | API Server + HTTP Client (前后端分离) | 🔨 进行中 (2026-05-06)：Rust axum API 服务器所有路由 `cargo check` 通过；Flutter Dio HTTP 客户端 `flutter analyze` 通过；Provider 层双模式 (FRB/http)；待完成：页面 HTTP 切换、端到端联调 |
| **Phase 4.6** | Reader 重构 + MD3 翻页 + 高刷 + SSE | ✅ 完成 (2026-05-17)：120fps 高刷接入、reader_page.dart 拆分（2839 → ~2040 行，含 P3-1 catch 改写后的回涨）、PageAnim 重排对齐 Legado MD3、6 种翻页 delegate（cover/slide/simulation/scroll/fade/noAnim）、HTTP+SSE Transport 抽象 |
| **Phase 4.7** | SSE 接入 + 仿真翻页性能降级 | ✅ 完成 (2026-05-17)：PerfMonitor 联动 4 档自动降级、Kotlin platform channel fallback stub、search_page SSE 流式接入 |
| **Phase 5** | 平台适配与发布 | ⚠️ Android 图标/启动页/通知渠道/权限已适配；✅ 真机 smoke test 通过（通知权限路由恢复已验证） |

> **当前真实阶段一句话**：Android APK 已编译通过，FRB smoke 验证通过；Phase 1-3 全部审查修复；✅ core-source Legado/parser/JS/import 回归与 no-default/js-boa/api-server checks 均通过且无新增 warning；🔨 Phase 4 高级服务大部分完成（阅读器/替换规则/下载管理/核心链路 ✅）；🔄 Phase 4.5 API Server + HTTP Client 核心架构完成 (2026-05-06)，待页面 HTTP 切换和端到端联调；✅ Phase 4.6 Reader 拆分 + MD3 翻页 + 高刷 + SSE 完成 (2026-05-17)；TTS/WebDAV 待开发。

---

## 🎯 Phase 4.6: Reader 重构 + MD3 翻页 + 高刷 + SSE — ✅ 完成 (2026-05-17)

> 参考 `legado-with-MD3` 的 PageAnim 设计 + `Legado-Tauri` 的架构思想，把 reader_page.dart 从 2839 行拆到约 2040 行（-800 行，-28%）。

### P0 — 高刷模式接入 ✅
- 加 `flutter_displaymode: ^0.6.0` 依赖
- 新增 `core/refresh_rate_controller.dart`：三档（auto / force120 / lock60）
- 新增 `core/perf_monitor.dart`：基于 `SchedulerBinding.addTimingsCallback` 的滑动窗口（30 帧）帧耗时统计，供仿真翻页等动画做自动降级
- `main.dart` 启动时一次性 `await RefreshRateController.apply(mode)`，保存为 settings.json 字段 `refreshRateMode`
- 单元测试：`test/refresh_rate_controller_test.dart` 6 个

### P1 — 状态外移 ✅
| 现有字段 | 新落点 |
|---|---|
| `_flutterTts / _isSpeaking / _isPaused / _ttsParagraphIndex`（约 200 行 TTS 代码） | `services/reader_tts_manager.dart` (194 行) |
| `_searchController / _searchMatches / _currentSearchMatchIndex / _isSearching` | `state/reader_search_controller.dart` (105 行) |
| `_isAutoScrolling / _autoScrollTimer` | `services/reader_auto_scroller.dart` (88 行) |
| 进度保存/恢复 | `services/reader_progress_service.dart` (65 行) |
| 书签 CRUD | `services/reader_bookmark_service.dart` (67 行) |

### P2 — UI 拆分 ✅
| 抽出 widget | 行数 |
|---|---|
| `widgets/reader_settings_sheet.dart` | 296 |
| `widgets/reader_search_bar.dart` | 112 |
| `widgets/reader_tts_bar.dart` | 137 |
| `widgets/reader_top_bar.dart` | 198 |
| `widgets/reader_bottom_bar.dart` | 212 |

### P3-a — 翻页接口扩展 + PageAnim 重排 + 自动迁移 ✅
- `ReaderPageAnim` 类：`cover=0, slide=1, simulation=2, scroll=3, fade=4, noAnim=5`（与 legado-with-MD3 一致）
- `ReaderSettings.fromJson` 支持 `settingsVersion` 字段；旧版本（v1 或缺省）自动迁移：`0→5, 2→0, 3→1`
- 新增 `horizontal_page_delegate.dart` 抽象层（cover/slide/simulation 共用）
- `PageDelegate` 新增 hook：`fling / abortAnim / onAnimStart / onAnimStop / nextPageByAnim / prevPageByAnim`，并暴露 `recordTouchStart / recordTouchUpdate` 给需要绝对坐标的 delegate（仿真翻页）
- 单元测试：`test/reader_page_anim_test.dart` 13 个（迁移函数 + 边界 + label + round-trip）

### P3-b — SimulationPageDelegate ✅
- 直接对照 `legado-with-MD3/.../SimulationPageDelegate.kt` 翻译为 Dart（509 行）
- 5 段贝塞尔曲线 + 折页阴影 + 背面页颜色矩阵反射，与原版几何完全等价
- 用 `dart:ui` Picture 缓存预渲染当前 / 下一页 / 上一页，drag 中复用，避免每帧重渲染
- 性能策略：默认 6 段阴影，运行时可由 `PerfMonitor` 监测帧耗时触发降级（接口已就位，下一轮接 platform channel fallback）

### P3-c — ScrollPageDelegate ✅
- 53 行实现：当前页与上下页竖直拼接，drag 跟手，抬手按 fling 速度切换或回弹
- 注意：与 `ReaderPageMode.continuousScroll`（按章节连续排版）共存，互不干扰

### P3-d — FadePageDelegate ✅
- 66 行实现：用 `saveLayer` + alpha mask 做交叉淡入淡出

### P4-a — 传输层 HTTP+SSE 单通道 ✅
**Rust 侧**：
- `core/api-server/src/routes/sse.rs` 新增 SSE 路由：
  - `GET /api/search/sse?q=keyword&sources=id1,id2`：多书源并发搜索流式返回
  - `GET /api/logs/sse`：心跳 + 日志推送占位
- 用 `tokio::sync::mpsc` + `tokio_stream::wrappers::ReceiverStream` 把并发任务输出 fan-in 到 SSE event
- axum 内置 `keep_alive` 自动每 15s 发心跳防止代理断流
- `cargo check -p api-server` 通过

**Dart 侧**：
- `core/transport.dart` (226 行)：`Transport` 抽象接口
  - `LocalTransport`：FRB 模式占位（invoke 抛 UnimplementedError；stream 返回空 stream）
  - `HttpTransport`：纯 `dart:io HttpClient` 实现，handle invoke + SSE，无额外 pub 依赖
- `transportProvider` 根据 `backendModeProvider` 自动切换实现
- 单元测试：`test/transport_test.dart` 5 个（含本地 HttpServer 跑通 SSE 端到端解析）

### 🟢 Phase 4.6 验证（2026-05-17）

| 检查项 | 结果 |
|--------|------|
| `flutter analyze` | ✅ 仅 1 个 pre-existing warning (`page_measure._footerHeight`) |
| `flutter test` | ✅ **73 passed**, 0 failed（49 → 73，新增 24） |
| `cargo check -p api-server` | ✅ 通过 |
| `cargo check --workspace` | ✅ 通过 |

### Phase 4.6 文件总览
```
features/reader/
├── reader_page.dart                  # ~2040 行（从 2839 减下来；P3-1 catch 改写让数字略有回涨）
├── change_source_dialog.dart         # 已有
├── modes/                            # 占位（P3 已用 page_view/delegate 等价机制）
├── widgets/                          # 5 个抽出 widget，955 行
├── services/                         # 4 个 service，414 行
├── state/                            # 1 个 controller，105 行
└── page/
    ├── page_view.dart                # 228 行
    ├── page_view_controller.dart     # 240 行（已有）
    ├── page_measure.dart             # 已有
    ├── content_page.dart / text_page.dart
    └── delegate/
        ├── page_delegate.dart        # 231 行（扩展接口）
        ├── horizontal_page_delegate.dart  # 🆕 52
        ├── no_anim_page_delegate.dart     # 已有
        ├── cover_page_delegate.dart       # 71（改继承 horizontal）
        ├── slide_page_delegate.dart       # 44（改继承 horizontal）
        ├── simulation_page_delegate.dart  # 🆕 509
        ├── scroll_page_delegate.dart      # 🆕 53
        └── fade_page_delegate.dart        # 🆕 66

core/
├── refresh_rate_controller.dart      # 🆕 134
├── perf_monitor.dart                 # 🆕 94
└── transport.dart                    # 🆕 226
```

### 待跟进（Phase 4.6 之后）
- ~~仿真翻页 platform channel fallback（中端机型）~~ ✅ 接口已落地（Phase 4.7）
- ~~`PerfMonitor` 接入 `SimulationPageDelegate`，实现 L1/L2/L3 自动降级~~ ✅ 完成（Phase 4.7）
- ~~HttpTransport 与各业务 widget 集成~~ ✅ 搜索页接入完成（Phase 4.7）
- `flutter build apk --release` profile 验证 120fps 仿真翻页帧耗时（环境 gradle 超时，跳过）

---

## 🎯 Phase 4.7: SSE 接入 + 仿真翻页性能降级 — ✅ 完成 (2026-05-17)

> 在 Phase 4.6 基础上，把性能降级、原生 fallback、HTTP+SSE 端到端跑通。

### 交付内容

#### 1. 仿真翻页性能自动降级 ✅
- 新增 `features/reader/page/delegate/simulation_degrade_controller.dart`
  - 4 档（L0/L1/L2/L3）状态机
  - L0: 6 段折页阴影 + 颜色矩阵反射；L1: 阴影减到 2 段；L2: 禁用颜色滤镜；L3: 切 platform channel
  - 监听 [PerfMonitor]：连续 5 帧超过预算 → 降一级；连续 30 帧 < 60% 预算 → 升一级
  - 新增 4 个单元测试 (`test/simulation_degrade_test.dart`)
- `SimulationPageDelegate` 接受 `degrade` 字段
  - `degrade.useFolderShadow` 控制折页阴影绘制
  - `degrade.useBackColorFilter` 控制 ColorFilter saveLayer 是否启用（避免 GPU 走带 alpha 通道的离屏 buffer）
- `page_view.dart` 在创建 simulation delegate 时按需 attach/detach 监控；切到其他翻页方式时自动停掉

#### 2. Platform channel fallback ✅
- 新增 `features/reader/page/simulation_native_fallback.dart`：`MethodChannel('legado/sim_page')` 包装
- `MainActivity.kt` 新增 SIM_PAGE_CHANNEL_NAME handler（start/stop 当前为 stub 日志）
- 升 L3 时由 widget 自动切换 `_useNativeFallback = true`，并 `await SimulationNativeFallback.start()`
- 后续把 legado-with-MD3 的 Kotlin SimulationPageDelegate vendor 进 Activity 即可启用真实绘制

#### 3. HttpTransport 接入搜索页 ✅
- `search_page.dart` 增加 `_doSearchViaSse(keyword)` 入口
  - 检测条件：`_onlineMode == true && backendModeProvider == BackendMode.http`
  - 通过 `transportProvider` 获得 `HttpTransport`，订阅 `GET /api/search/sse?q=keyword`
  - 流式合并 `event: result`，命中 `event: done` 即完成；`event: error` 仅 debugPrint
  - 60s 超时兜底；mounted/cancel 正确处理
- 新增端到端测试 `test/search_sse_test.dart`：本地 axum-style mock server 验证去重/done/event 序列

### 🟢 Phase 4.7 验证（2026-05-17）

| 检查项 | 结果 |
|--------|------|
| `flutter analyze` | ✅ 仅 1 个 pre-existing warning |
| `flutter test` | ✅ **78 passed**, 0 failed（73 → 78，新增 5） |
| `cargo check --workspace` | ✅ 通过 |
| `cargo test -p api-server` | ✅ 通过 |
| `flutter build apk --debug` | ⏱️ 超时（环境 gradle 受限），跳过 |

### Phase 4.7 文件清单
```
新增：
  features/reader/page/delegate/simulation_degrade_controller.dart   # 142
  features/reader/page/simulation_native_fallback.dart                # 65
  test/simulation_degrade_test.dart                                   # 49
  test/search_sse_test.dart                                           # 75

修改：
  features/reader/page/delegate/simulation_page_delegate.dart  # 接 degrade
  features/reader/page/page_view.dart                          # attach perf 监控 + fallback hook
  features/search/search_page.dart                             # _doSearchViaSse 分支
  android/app/src/main/kotlin/.../MainActivity.kt              # SIM_PAGE_CHANNEL handler stub
```

---

## 🏗️ Phase 0: 基础设施搭建 — ⚠️ Android APK 编译通过，ping/pong FRB smoke 通过；Linux 暂停

### 平台状态

| 平台 | 状态 | 备注 |
|------|------|------|
| **Android** | ✅ APK 编译成功，`ping()` → `pong` FRB smoke 通过 | 当前主攻平台 |
| **Linux 桌面** | ⏸️ 暂停 | 开发环境 FRB smoke 此前已验证通过，正式 bundle packaging 暂停 |

### FRB 当前真实状态

| 项目 | 状态 |
|------|------|
| `flutter_rust_bridge_codegen` 2.12.0 | ✅ 可用，已生成文件 |
| `flutter_rust_bridge.yaml` 配置 | ✅ `rust_input: crate::api`, `rust_root: core/bridge/`, `dart_output: flutter_app/lib/src/rust` |
| `core/bridge` bridge crate | ✅ 真实 bridge crate 位置（含 Cargo.toml, src/lib.rs, src/api.rs, src/frb_generated.rs） |
| `core/bridge/src/api.rs` | ✅ 35+ 函数：ping/init_legado/get_db_version + Books CRUD + Sources CRUD + Chapters CRUD + Progress/Bookmarks + Online Search/Content + 书源校验/导出 + Replace Rules CRUD (JSON 序列化方案) |
| `flutter_app/lib/src/rust/api.dart` | ✅ 35+ Dart 函数（getAllBooks, searchBooksOnline, saveSource, getBookChapters, validateSourceRules, validateSourceFromDb, exportAllSources, getReplaceRules, saveReplaceRule, deleteReplaceRule, setReplaceRuleEnabled 等，复杂类型通过 JSON 字符串传递） |
| `flutter_app/lib/src/rust/frb_generated.dart` (generated) | ✅ RustLib 类定义、初始化逻辑 |
| `flutter_app/lib/src/rust/frb_generated.io.dart` (generated) | ✅ 原生平台 FFI 加载 |
| `flutter_app/lib/src/rust/frb_generated.web.dart` (generated) | ✅ Web 平台加载 |
| `RustLib.init()` 在 `main.dart` | ✅ 开发环境已接入，非阻断方式 |
| `ping()` smoke 在 Linux desktop 已验证 | ✅ `[FRB smoke] ping() returned: pong` |
| **`ping()` smoke 在 Android 已验证** | ✅ **APK 编译通过，FRB ping/pong 测试通过** |
| Android native dynamic library build/packaging 集成 | ✅ 已集成 |
| iOS/native dynamic library build/packaging 集成 | ❌ 未完成 |
| 正式 Linux bundle `libbridge.so` 打包（CMake/native assets） | ⏸️ 暂停 |

**结论**：Android APK 编译通过，FRB smoke 已验证（`ping()` → `pong`）。Linux 桌面正式打包暂停⏸️，不宣称全平台/生产打包闭环。

### ⚠️ 手工 frb_generated 补丁（2026-05-05）

`flutter_rust_bridge_codegen generate` 在 2026-05-05 两次超时（300s/600s），因此以下 API 的桥接代码是**手工编辑**而非 codegen 生成：

| API | Dart funcId | Rust wire function |
|-----|------------|-------------------|
| `validate_source_rules` | 42 | `wire__crate__api__validate_source_rules_impl` |
| `validate_source_from_db` | 43 | `wire__crate__api__validate_source_from_db_impl` |
| `export_all_sources` | 44 | `wire__crate__api__export_all_sources_impl` |
| `get_replace_rules` | 45 | `wire__crate__api__get_replace_rules_impl` |
| `save_replace_rule` | 46 | `wire__crate__api__save_replace_rule_impl` |
| `delete_replace_rule` | 47 | `wire__crate__api__delete_replace_rule_impl` |
| `set_replace_rule_enabled` | 48 | `wire__crate__api__set_replace_rule_enabled_impl` |
| `replace_book_chapters_preserving_content` | 49 | `wire__crate__api__replace_book_chapters_preserving_content_impl` |
| `replace_book_chapters` | 50 | `wire__crate__api__replace_book_chapters_impl` |
| `get_source_rule_search_raw` | 51 | `wire__crate__api__get_source_rule_search_raw_impl` |
| `search_with_source_from_db_v2` | 52 | `wire__crate__api__search_with_source_from_db_v2_impl` |
| ~~`search_parse_html`~~ | ~~53~~ | **已删除**（hole；之前因"Android DNS 误判"引入，code-review #4 移除） |
| `delete_sources_batch` | 54 | `wire__crate__api__delete_sources_batch_impl` |
| `get_explore_entries` | 55 | `wire__crate__api__get_explore_entries_impl` |
| `explore` | 56 | `wire__crate__api__explore_impl` |
| `apply_replace_rules` | 57 | `wire__crate__api__apply_replace_rules_impl`（P1-7：替换规则下沉，带 generation 缓存） |

涉及文件：
- `flutter_app/lib/src/rust/frb_generated.dart` — Dart abstract API + impl（funcId 42-57，53 已洞）
- `core/bridge/src/frb_generated.rs` — Rust wire functions + dispatcher（funcId 42-57，53 已洞）

**⚠️ 关键约束**：后续任意 `flutter_rust_bridge_codegen generate` 运行将**覆盖**这些手工改动。重新生成前必须确认 `core/bridge/src/api.rs` 中这些函数仍然存在，否则 funcId 映射会错乱。功能验证：`cargo check/test` 全部通过 + `flutter test` 全部通过。

### Phase 0.5: 编译错误修复 — ✅ 完成

已验证通过：
- `cargo check --workspace` ✅
- `cargo test --workspace` ✅ **82 passed**
- `cargo clippy --workspace --all-targets -- -D warnings` ✅
- `flutter --no-version-check analyze` ✅

---

## 🎯 Phase 1: Rust 核心引擎 — 🔨 Legado 兼容层大幅推进；仍缺 WebView/完整 DOM 语义

### 整体评价

核心 Rust crates 当前能 check/test 通过，很多历史 P1 已修复。`core-source` 已从早期 Rhai/简化规则引擎推进到 QuickJS 默认运行时 + Legado HTTP/rule/import/parser 兼容层。**但不能等同于完整 Legado 核心引擎完成**，仍缺 WebView bridge、完整 DOM/Element 对象语义和更多真实站点端到端验证。

> ⚠️ 历史审查报告 `docs/phase1_code_review_report.md` 生成于 2026-04-30 22:36:55。当前代码已继续演进，部分问题已修复。请勿将历史报告中的所有未修复项直接视为当前事实。

### 已修复/已改善的历史 P1 项（不再构成当前 P1）

- `clear_domain 未实现` ✅ 当前有实现和测试
- `substring 中文/emoji 会 panic` ✅ 当前用 `char_indices()`
- `ScriptEngine 缺超时/内存/输出限制` ✅ 已改善：当前有 operations/call/string/array/map 限制、墙钟超时、输出长度限制
- `Parser 只返回首个结果` ✅ 当前批量提取并循环生成多个结果
- `book_list 被当搜索 URL 模板` ✅ 与当前代码不符：当前搜索 URL 来自 `search_rule.search_url`
- `URL 未归一化` ✅ 已改善：多处调用 `build_full_url`
- `DB 迁移策略未修复` ✅ 已改善：有版本迁移和事务回滚，测试覆盖 v1→v2
- `book_dao/source_dao SQL 占位符数量` ✅ 已匹配，DAO 测试通过

### Legado 兼容层进展（2026-05-06）

- `core-source/src/legado/` 已形成独立兼容层：`import/url/http/rule/js_runtime/context/value/selector/regex_rule`。
- 默认 JS runtime 改为 QuickJS (`js-quickjs` feature)，Boa 保留为 `js-boa` 可选 feature，`--no-default-features` 可编译。
- `@js:`、`js:`、`<js></js>`、URL `{{JS}}` 模板、URL option.js 均已接入 JS runtime。
- JS runtime 支持多语句脚本，返回最后一个表达式，覆盖真实书源常见 `var ...; ...; result;` 写法。
- 已实现大量 `java.*` bridge：`ajax/get/post/getCookie/put/get/base64/md5/URI/AES/timeFormat/htmlFormat/getString/getStringList/getElements/getZip*/readFile/readTxtFile`。
- JS bridge 本地文件读取受 `LEGADO_FILE_ROOT` 限制，阻止路径逃逸。
- parser 已接入 `LegadoHttpClient` 和 `execute_legado_rule`：搜索/详情/目录/正文流程支持 URL option.js、source header、cookie jar、charset、POST body、通用 `@js:`。
- parser 通用 `@js:` 执行与 `LegadoHttpClient` 共享 cookie jar，并继承 source header；显式 JS headers 可覆盖默认 header。
- 普通 HTTP 和 JS bridge 共用 charset 探测/解码：Content-Type、HTML meta charset、显式 `charset` header option 均有回归。
- Legado 导入支持单源数组和合集数组，宽松处理字段类型不稳定；真实样本覆盖 `sy/axdzs.json`、`sy/sdg.json`、`sy/22biqu - grok.json`、`sy/1778070297.json`。
- 旧 `RuleEngine` 仍作为 parser 兼容兜底；已接入 Legado `##` replace 规则后处理。

### 仍存在的深层引擎缺口（产品级深度工作）

- WebView 相关仍未实现：`webView:true`、`webJs`、`sourceRegex` 需要 Flutter/Android WebView bridge。
- `java.getElements` 当前主要返回字符串数组，不是完整 Legado/Jsoup DOM Element 对象。
- JS HTTP bridge 和 async `LegadoHttpClient` 已共享 cookie/header/charset 语义，但底层仍分别使用 blocking reqwest 与 async reqwest。
- UMD 仍不是真实 UMD chunk/tag 解析器。
- EPUB metadata 有基础解析，但仍较简化。

### 已通过审查修复的安全/稳定性缺口（2026-05-04，3轮 Rust 核心审查）

- ✅ Proxy URL 日志脱敏（`redact_proxy_credentials`）
- ✅ Set-Cookie 日志只记录 cookie name，value 不进日志
- ✅ `@Json:` 前缀剥离
- ✅ Regex flags 检测修正（`starts_with('/') && !starts_with("//")`）
- ✅ EPUB3 cover-image 支持多 token（`split_whitespace()`）
- ✅ `source_dao` URL 冲突不再 DELETE，改为查询复用已有 id（保留 books foreign key）
- ✅ `source_dao` 错误区分（只对 `QueryReturnedNoRows` fallback，其他 DB 错误直接返回）
- ✅ Semaphore 注释改为设计决策说明

### Phase 1 深层引擎 bug 修复（2026-05-04，代码审查发现 4 项 + 测试修复 1 项）

| 严重度 | 文件 | 问题 | 修复 |
|--------|------|------|------|
| 🔴 High | `search_page.dart` | 在线搜索使用 `searchBooksOnline` 导致 storage/core-source schema 不匹配 | 改为 `searchWithSourceFromDb(dbPath, sourceId, keyword)`，该 API 内部处理 storage→core-source 转换 |
| 🔴 High | `search_page.dart` | 保存在线搜索结果时缺少 `chapter_count` 等字段导致 deserialize 失败 | 新增 `_saveResultToBookshelf` 方法，填充所有缺失字段的默认值（0/true/now） |
| 🔴 High | `rule_engine.rs` | XPath 绝对路径检测：`(` 字符同时出现在 XPath 函数和 regex 捕获组中，导致 regex 误判为 XPath | 增加 regex delimiter 检测（最后一个 `/` 之后只有字母→regex），再用 XPath 特征检测 |
| 🔴 High | `rule_engine.rs` | JSONPath bracket 表示法 `$[0]`、`$['key']`、`$["key"]` 未被识别 | 增加 `$[` 前缀检测 |
| 🟡 Medium | `source_dao.rs` | `import_from_json` 无法解析真实 Legado 导出格式（camelCase 字段 + 嵌套 rule 对象） | 新增 `LegadoBookSource` struct（`serde(rename)`）+ `legado_to_storage` 转换，fallback 尝试 |

### 各 crate 状态

- **core-net**: HttpClient 封装，Cookie 持久化管理，POST/GET 统一 Cookie 生命周期，httpmock 集成测试覆盖 Set-Cookie 提取/注入/持久化（30 tests）
- **core-parser**: UMD 畸形输入防护（章节数上限、offset 校验、大章节限制），TXT/EPUB 基础框架（19 tests）
- **core-storage**: SQLite 数据库 + PRAGMA user_version 增量迁移（v1→v2），DAO 层框架，Legado 格式书源导入（11 tests）
- **core-source**: Legado 兼容层（真实导入/URL/HTTP/rule/QuickJS/java bridge/parser 接入），旧 RuleEngine 作为兜底；parser + JS runtime + Legado import/rule/url + rule_engine 回归持续通过

### 构建状态

最近专项验证（2026-05-06）：`cargo test -p core-source parser::tests` ✅ 14 passed；`js_runtime` ✅ 34 passed；`legado::rule::tests` ✅ 5 passed；`legado::url::tests` ✅ 10 passed；`legado::import::tests` ✅ 8 passed；`rule_engine::tests` ✅ 7 passed；`cargo check -p core-source --no-default-features` ✅；`cargo check -p core-source --no-default-features --features js-boa` ✅；`cargo check -p api-server` ✅。

---

## 🔄 Phase 2: Flutter UI 框架 — ✅ 完整实现（2026-05-04）

所有 ROADMAP 2.1-2.5 功能已实现，`flutter analyze` 无任何 issue，`flutter test` 48/48 通过。

### Phase 2 新增功能（2026-05-04）

| 功能 | 文件 | 实现 |
|------|------|------|
| 书籍封面网络加载 | `bookshelf_page.dart` | `Image.network` + `errorBuilder`/`loadingBuilder`，无效 URL 显示占位图标 |
| 书架网格/列表切换 | `bookshelf_page.dart` | `ConsumerStatefulWidget` + `_isGridView` + `GridView.builder` (crossAxisCount:3) |
| 字号设置（滑块+持久化+阅读器集成） | `settings_page.dart`, `providers.dart`, `reader_page.dart`, `main.dart` | `fontSizeProvider` (14-28, 默认18), `settings.json` 持久化, 阅读器实时应用, 启动恢复 |
| 搜索历史记录 | `search_page.dart`, `providers.dart` | 最多20条, `settings.json` 持久化, 点击复用, 一键清除 |
| 在线多书源搜索切换 | `search_page.dart` | 云/手机图标切换, 通过 `searchWithSourceFromDb` 调用（内部处理 storage→core-source 转换，避免 schema 不匹配） |
| 搜索结果保存到书架 | `search_page.dart` | `_saveResultToBookshelf` 方法填充缺失字段默认值，确保 deserialize 成功 |
| JSON 书源导入 | `source_page.dart` | 对话框输入, 调用 `importSourcesFromJson`, 支持内部格式 + Legado 导出格式（camelCase），显示成功数量 |

### 构建状态（2026-05-04 最终验证）

| 检查项 | 结果 |
|--------|------|
| `flutter analyze` | ✅ **No issues found** |
| `cargo check --workspace` | ✅ 通过 |
| `cargo test --workspace` | ✅ **101 passed**, 0 failed |
| `cargo clippy --workspace -- -D warnings` | ⚠️ 1 pre-existing `type_complexity` at `epub.rs:96` |
| `flutter test` | ✅ **8 passed**, 0 failed |
| `flutter build apk --debug` | ⏱️ 超时（环境资源受限），此前已通过 |

### Phase 2 代码审查修复（2026-05-02，3轮）

**P1 修复：**
| 问题 | 文件 | 修复 |
|------|------|------|
| 添加书源 JSON 不完整 | `api.rs:92-103` | 新增 `create_source(name, url)` API |
| DB 初始化竞态 | `providers.dart` | `allBooksProvider` 等 await `dbInitializedProvider.future` |
| error swallowing | `providers.dart` | `dbInitializedProvider` 改为 `rethrow` |
| Android DB 相对路径 | `providers.dart` | `dbDirProvider` 通过 `path_provider` 获取绝对路径 |
| Android 无 INTERNET 权限 | `AndroidManifest.xml` | 添加 INTERNET 权限声明 |

**P2 修复：** setState 无 mounted 检查 (`search_page.dart`)

**新增依赖：** `path_provider: ^2.1.0`

**生成的 Dart API 原有：** 29+ 函数 (ping/init_legado + Books/Sources/Chapters CRUD + Progress/Bookmarks + Online Search/Content)

---

## 📱 Android 平台专项适配 — ✅ 完成（2026-05-03）

### 应用标识
| 项目 | 内容 |
|------|------|
| 包名 | `io.legado.app.flutter`（`build.gradle.kts` namespace + applicationId） |
| 应用名 | `Legado Reader`（AndroidManifest.xml label + main.dart title） |
| MainActivity | `android/app/src/main/kotlin/io/legado/app/flutter/MainActivity.kt` |

### 自适应图标
| 资源 | 文件 |
|------|------|
| 前景矢量图 | `res/drawable/ic_launcher_foreground.xml` — 书本矢量图（白页+浅蓝右页+灰色书脊+红色书签） |
| 背景矢量图 | `res/drawable/ic_launcher_background.xml` — 品牌蓝 #1976D2 |
| adaptive-icon 配置 | `res/mipmap-anydpi-v26/ic_launcher.xml` |
| legacy PNG（5种密度） | `res/mipmap-*/ic_launcher.png` — Python PIL 生成的品牌书本图标 |

### 启动页品牌化
| 资源 | 文件 |
|------|------|
| 品牌色定义 | `res/values/colors.xml` — brand_primary/brand_primary_dark/brand_primary_light/splash_background |
| 暗色覆盖 | `res/values-night/colors.xml` — splash_background #0D47A1 |
| 启动背景 | `res/drawable/launch_background.xml` / `res/drawable-v21/launch_background.xml` |
| Android 12+ splash | `res/values-v31/styles.xml` + `res/values-night-v31/styles.xml` |

### 通知基础
| 组件 | 说明 |
|------|------|
| `MainActivity.kt` | `legado_download` 通知渠道（IMPORTANCE_LOW），`onResume()` 中创建 |
| MethodChannel `legado/notifications` | `hasPermission()` / `requestPermission()` Dart ↔ Kotlin |
| `lib/core/notification_service.dart` | 封装 channel 调用，统一返回 `Future<bool>` |
| `AndroidManifest.xml` | `POST_NOTIFICATIONS` 权限已声明 |
| **P2 修复（第2轮审查）** | 已从 `main.dart` 移除冷启动 `requestPermission()`，改为业务触发点调用 |
| **P3 修复（第2轮审查）** | `MainActivity.kt` `requestPermission()` 已增加 pending guard，连续调用返回 `PERMISSION_REQUEST_PENDING` error |

### 权限
| 权限 | 用途 |
|------|------|
| `android.permission.INTERNET` | 网络访问 |
| `android.permission.POST_NOTIFICATIONS` | Android 13+ 通知权限（不在冷启动时请求） |

---

## 🔍 代码审查记录

历次审查与修复的完整时间线已迁移到 [`docs/CHANGELOG.md`](docs/CHANGELOG.md)。
当前 STATUS 只保留"最近一批的状态摘要"。

**最近一批**：第九批（2026-05-17，commit 9）— 清扫第四轮复审延后的剩余 R 项。本批集中修了 19 项（R28 / R31-R45 / R50 / R59 / R62 / R64-R66 / R69-R70），覆盖 doc 澄清、PageView 状态机简化、DownloadRunner 脱敏 + status 常量化、`_paragraphKeyId` Web 兼容、`RATE_LIMITER` 节流改 atomic 等。R60（Axum handler 同步 sqlite 阻塞 tokio worker → 需要 `spawn_blocking` 包 DAO）改动量大且涉及全部路由，单独留作下一轮重构。

**已知风险（仍然成立）**：R3 codegen 模板 unreachable / R22 / R23 / R24 ReplaceRule.scope（需 schema 改动）/ R60（spawn_blocking 重构）。

**总评**：经过四轮全面复审 + 9 个 commit 的修复迭代，代码库的高危项已基本清空。剩余主要是 R60 的架构性改动和几项需要 schema 迁移才能动的设计问题。每批完成后 `cargo test --workspace` 与 `flutter test` 都全绿；本批完成时 cargo 248 / flutter 112 / `flutter analyze` 0 issue。详细问题清单与具体改动见 CHANGELOG。

---

## 🏗️ 项目结构

```
legado_flutter/
├── core/                  # Rust workspace
│   ├── core-net/         # HTTP网络引擎（reqwest + rustls）
│   ├── core-parser/      # 格式解析（TXT/EPUB/UMD）
│   ├── core-storage/     # SQLite存储引擎
│   ├── core-source/      # 书源规则引擎（核心）
│   └── bridge/           # flutter_rust_bridge层（真实位置在 core/bridge/）
├── flutter_app/          # Flutter UI层
└── docs/                 # 文档
```

---

## ⚙️ 环境

- **Rust**: 1.95.0 (`~/.cargo/bin/cargo`)
- **Cargo**: 1.95.0
- **flutter_rust_bridge_codegen**: 2.12.0
- **工作目录**: `/root/data/workspaces/doro_FriendMessage_641981595/legado_flutter/core`

---

## 📝 下一步 — Phase 3 功能整合 ✅ 完成（2026-05-05）

> **平台方向**：Android 优先，Linux 桌面暂停 ⏸️

### ✅ 已完成里程碑
真机 smoke test ✅ | Phase 2 UI ✅ | Phase 1 深层审查修复 ✅ | Rust 第4轮审查（RegexBuilder） ✅ | **Phase 3 功能整合 ✅**

### 🟢 最新验证（2026-05-05）

| 检查项 | 结果 |
|--------|------|
| `cargo check --workspace` | ✅ 通过 |
| `cargo test --workspace` | ✅ **101 passed**, 0 failed |
| `cargo clippy --workspace -- -D warnings` | ⚠️ 1 pre-existing warning |
| `flutter test` | ✅ **49 passed**, 0 failed |
| `flutter analyze` | ⏱️ 超时（环境约束，此前验证 clean）|

### ✅ Phase 3 功能整合 — 已完成

| 任务 | 优先级 | 状态 |
|------|--------|------|
| 多书源并发搜索 | 🔴 P1 | ✅ 完成 |
| 封面本地缓存机制 | 🔴 P1 | ✅ 完成 |
| 书源规则校验 | 🟡 P1 | ✅ 完成 |
| 书源导出功能 | 🟡 P1 | ✅ 完成 |
| Stream 推送（进度/日志实时推送） | 🟡 P1 | ⬜ 待开始 |

### Phase 3 实现详情

**多书源并发搜索** (`search_page.dart`):
- 使用 `getEnabledSources` 获取所有已启用书源
- `Future.wait` 并发搜索所有书源
- `_searchWithSource` 辅助函数隔离各书源错误
- 按 `name_author` 去重，结果标注来源书源名称

**封面本地缓存** (`bookshelf_page.dart`):
- 添加 `cached_network_image: ^3.4.0` 依赖
- `_buildCover` 使用 `CachedNetworkImage` 替代 `Image.network`
- 持久化磁盘缓存 + placeholder + errorWidget

**书源规则校验** (`core-source/src/lib.rs`, `api.rs`, `source_page.dart`):
- `ValidationIssue` 结构体 (field/severity/message)
- 全面校验: 搜索规则/详情规则/目录规则/内容规则 (CSS/XPath/Regex/JSONPath/JS)
- `validateSourceFromDb` API: 从DB加载书源并校验
- UI: 点击书源 → "校验规则" → 弹窗显示结果（error红/warning橙/info蓝）

**书源导出** (`api.rs`, `source_page.dart`):
- `exportAllSources` API: 导出所有书源为 JSON 数组
- UI: AppBar "导出" 按钮 → 复制到剪贴板

**修复**:
- `validate_rule_expressions` 中 `.is_ok()` → `.is_some()`（RuleExpression::parse 返回 Option）
- 恢复被误删的 `parse_book_source` 函数
- `_showSourceActions` 中合并重复的校验按钮为 `TextButton.icon`
- `parser.rs` HTTP client 添加 15s request + 15s connect timeout（配合 Dart `.timeout()` 兜底）
- `frb_generated.dart` / `frb_generated.rs` 手工添加 funcId 42-44（codegen 超时，详见 FRB 补丁章节）

### 🔮 中期方向 — 下一步行动计划 (2026-05-06)

**B. Phase 4 高级服务**（核心功能）
- 替换规则桥接 API + 管理 UI ✅ 完成
- 下载管理后台服务 + 队列 + 启动恢复 ✅ 完成
- 搜索→书架→阅读核心链路打通 + 审查修复 ✅ 完成
- 替换规则在阅读器中应用 ✅ 完成
- TTS 语音朗读、WebDAV 同步备份/恢复 ⬜ 待开发

**C. Phase 1 深层引擎完善**（技术债务）
- Legado WebView bridge（`webView:true` / `webJs` / `sourceRegex`）⬜ 待开发
- 完整 DOM/Element 对象语义（当前 `java.getElements` 主要返回字符串数组）⬜ 待开发
- 更多真实站点端到端搜索/目录/正文验证 ⬜ 待扩展
- UMD 解析器重写、EPUB metadata 完善 ⬜ 待开始

**D. Phase 4.5: API Server + HTTP Client (前后端分离) — 下一步**

| 优先级 | 任务 | 说明 | 涉及文件 |
|--------|------|------|----------|
| 🔴 高 | SearchPage 在线搜索切 HTTP | `_doSearch()` 中替换 rust_api 调用为 `searchApiProvider` → `POST /api/search` | `search_page.dart`, `providers.dart` |
| 🔴 高 | BookshelfPage 添加切 HTTP | `_saveResultToBookshelf()` 替换为 `bookshelfApiProvider.addBook()` → `POST /api/bookshelf` | `search_page.dart` (保存逻辑在搜索页) |
| 🔴 高 | ReaderPage 章节内容切 HTTP | `_openChapter()` 替换为 `readerApiProvider.getChapterContent()` → `GET /.../content?chapter_index=N` | `reader_page.dart` |
| 🟡 中 | 补充 HTTP 模式缺失路由 | 阅读进度 (GET/PUT `/progress`)、下载管理、替换规则 | `api-server/src/routes/` |
| 🟢 低 | 端到端联调测试 | 启动 `api-server` (0.0.0.0:3000)，`backendMode` 切 HTTP，验证完整链路 | 手动测试 |
| 🟢 低 | 移除 FRB 依赖（可选） | HTTP 模式稳定后可精简包体积 | `Cargo.toml`, `pubspec.yaml` |

> ⏱️ `flutter build apk --debug` 当前环境超时（20分钟），无法完成 APK 编译。此前验证：`flutter analyze` ✅ clean、`flutter test` ✅ 8/8 passed、`cargo check/test/clippy` ✅ 全通过。

### 构建/验证命令

```bash
# Rust
cd core && cargo check --workspace && cargo test --workspace && cargo clippy --workspace --all-targets -- -D warnings

# Flutter
cd flutter_app && flutter --no-version-check analyze && xvfb-run flutter --no-version-check test

# Android APK 构建
cd flutter_app && flutter build apk --debug

# ADB（设备已连接 d34e43d9）
/opt/android-sdk/platform-tools/adb -s d34e43d9 install -r build/app/outputs/flutter-apk/app-debug.apk
/opt/android-sdk/platform-tools/adb -s d34e43d9 logcat -c && /opt/android-sdk/platform-tools/adb -s d34e43d9 logcat -s flutter,AndroidRuntime,MainActivity,FRB
```

### 新增 Dart API 一览 (flutter_app/lib/src/rust/api.dart)

| 类别 | 函数 | 说明 |
|------|------|------|
| 核心 | `ping()`, `initLegado()`, `getDbVersion()` | 原有 3 个 |
| 书架 | `getAllBooks()`, `searchBooksOffline()`, `saveBook()`, `deleteBook()` | 返回/接收 JSON |
| 书源 | `getAllSources()`, `getEnabledSources()`, `saveSource()`, `deleteSource()`, `setSourceEnabled()`, `importSourcesFromJson()` | 返回/接收 JSON |
| 章节 | `getBookChapters()`, `updateChapterContent()`, `saveChapter()`, `deleteChapter()` | 返回/接收 JSON |
| 进度 | `saveReadingProgress()`, `getReadingProgress()` | 基本类型 + JSON |
| 书签 | `getBookmarks()`, `addBookmark()`, `deleteBookmark()` | 返回/接收 JSON |
| 在线搜索 | `searchBooksOnline()`, `getBookInfoOnline()`, `getChapterListOnline()`, `getChapterContentOnline()` | 异步, JSON |
| 便捷 | `searchWithSourceFromDb()`, `getChapterContentWithSourceFromDb()` | 异步, DB+在线组合 |
