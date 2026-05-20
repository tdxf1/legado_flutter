# Findings — 全量代码审查 (2026-05-20)

**Total**: 320 findings across 5 waves
**Reviewed scope**: ~64,000 lines (Rust core ~39,628 + Flutter app ~24,385 + Android config + build scripts + Cargo / pubspec dependency tree)
**Read-only audit**: 没有任何业务代码修改，所有发现仅指认问题 + 给方向；具体修复留给后续子任务。

---

## Wave Files

| Wave | Scope | File | Count | P0 | P1 |
|---|---|---|---|---|---|
| 1A | Rust data tier (core-storage / bridge / api-server) | [`findings-rust-data.md`](./findings-rust-data.md) | 54 | 2 | 22 |
| 1B | Rust logic tier (core-source / core-net / core-parser) | [`findings-rust-logic.md`](./findings-rust-logic.md) | 73 | 4 | 41 |
| 2A | Flutter core + reader | [`findings-flutter-core.md`](./findings-flutter-core.md) | 80 | 1 | 13 |
| 2B | Flutter remaining 9 features | [`findings-flutter-features.md`](./findings-flutter-features.md) | 70 | 2 | 26 |
| 3 | Cross-layer + Android config + build scripts + dependencies | [`findings-cross-config.md`](./findings-cross-config.md) | 43 | 1 | 20 |
| **Total** | | | **320** | **10** | **122** |

---

## 全量统计

### 按严重度
| Severity | Count |
|---|---|
| P0 严重 | 10 |
| P1 主要 | 122 |
| P2 次要 | 127 |
| P3 nice-to-have | 61 |
| **合计** | **320** |

### 按维度（primary tag）
| 维度 | Count |
|---|---|
| A-架构 | 66 |
| B-正确性 | 80 |
| C-性能 | 52 |
| D-安全 | 47 |
| E-代码异味 | 75 |

### 按 wave × 严重度（详细）
（与 Wave Files 表同；count 对齐：54+73+80+70+43=320, P0 2+4+1+2+1=10, P1 22+41+13+26+20=122）

---

## 主题汇总（Cross-cutting Themes）

把分散在各 wave 的 P0/P1 findings 按主题重新聚合，便于看到模式，而不是把 132 条单独看。每个主题给一句话"为什么是同一类问题"。

### 主题 1: JS 沙箱跑 Untrusted 远程书源代码 — 系统性 RCE 风险

QuickJS 在 `core-source/legado/js_runtime` 跑用户从 QR / URL 导入的书源 JS，但**沙箱 + 边界控制全面不足**：网络访问无 SSRF、文件系统通过环境变量豁免、内存/栈无限制、字体反爬路径会把任意 base64 输入当 ttf 解析。这是本仓库 P0 集中地。

- **F-W1B-001** java.ajax/get/post/connect 无 SSRF 防护（远程 JS 可访问内网 / 169.254.169.254 元数据）
- **F-W1B-002** java.downloadFile/getFile/deleteFile/unzipFile 通过 `LEGADO_FILE_ROOT` env var 决定可写根，泄漏即沙箱逃逸
- **F-W1B-003** QuickJS 无内存上限 / 栈大小限制，只有 wall-clock 超时
- **F-W1B-004** java.queryTtf 走 base64 路径解析任意输入（无 magic 校验）
- **F-W1B-005** ZIP 路径无 path-traversal 防护
- **F-W1B-006** `java._vars` 整体绑定全局，跨脚本泄漏书源用户变量
- **F-W1B-007** `https_only(false)` + 无 redirect scheme 限制，HTTP→file:// 跳转可能
- **F-W1B-008** `{{...}}` 模板表达式 dangerous-eval
- **F-W1B-009** `import_legado_source` 无大小/字段数上限，DoS
- **F-W1B-010** java HTTP 响应大小校验靠 `take(max_bytes+1)`，攻击者可通过 chunked 绕过
- **F-W1B-042** JSONPath 模板表达式手动 lookbehind 解析存在漏配
- **F-W3-015** Android 端 `LegadoJsBridge.addJavascriptInterface` 同源问题：50+ 方法暴露给 WebView 加载的远端页面 JS

**共同建议**: (1) 立刻把"远程 untrusted JS" 与"本地 trusted UI" 在沙箱内分两个上下文；(2) 给 java.* 调用加 host 黑白名单；(3) Cargo 加 `secrecy/zeroize`，Manifest 关 allowBackup（F-W3-002）作为防御深度；(4) `WebViewBridgeThreatModel.md` + 每方法 capability 化。

### 主题 2: 凭据 / 密钥 / 备份密码 明文存储

- **F-W1A-001** AES-128/ECB + MD5(password) 弱算法，用于备份 zip 加密
- **F-W1A-003** 密文无认证（无 HMAC / GCM tag）
- **F-W1A-020** 备份密码以明文 JSON 写盘 (`legado_local.json`)
- **F-W2B-001** WebDAV 凭据明文写到 `webdav.json`（注释自承"先存明文"）
- **F-W3-002** AndroidManifest 缺 `allowBackup="false"`，密码明文上 Google Auto Backup
- **F-W3-013** release APK 用 debug keystore 签名，任何人可伪造同包
- **F-W3-020** Cargo 工作区无 `zeroize/secrecy`，密码 / token 在内存中残留

**共同建议**: 用 Android Keystore 包裹敏感字段；引入 `secrecy::SecretString` 全 Rust 流转；Manifest 关 backup；release 签名独立 keystore。

### 主题 3: SQLite 事务 / 并发 / 错误处理一致性

- **F-W1A-004** WAL `synchronous` 默认值不安全
- **F-W1A-005** migrate 用手写 `BEGIN` / `COMMIT` / `ROLLBACK`，非 RAII
- **F-W1A-008** delete_batch 无事务，逐条 fsync
- **F-W1A-009** import_local_book 多 dao 多事务，FK 约束失败留脏数据
- **F-W1A-010** add_bookmark INSERT-only 而 chapter dao 走 upsert，风格不一致
- **F-W1A-014** StorageManager error type 用 `Box<dyn Error>` 与全 crate 不一致
- **F-W1A-017** download_dao 手写 BEGIN/COMMIT，ROLLBACK 用 `let _ =` 吞错
- **F-W1A-018** delete_book 多 dao 错误吞掉，留下孤儿 chapters/progress
- **F-W1A-021** download_and_save_chapter 7 次独立 commit
- **F-W1A-022** Empty 错误分支 update + recompute 写法散落
- **F-W1A-055** production WAL 未启用，BATCH-07b 加的 pragma 实际无效（Resolved by BATCH-08c）
- **F-W1A-056** backup_dao 未处理 WAL sidecar 文件（Dismissed by BATCH-08d audit — backup 走 SQL SELECT 不接触文件）
- **F-W1A-057** 占位：未来若引入 binary-level db backup 需重新评估 WAL checkpoint（Open，识别于 BATCH-08d）

**共同建议**: 引入 `bridge::with_transaction(db_path, |tx| ...)` helper 全统一；强制 `Connection::transaction()` RAII；error type 全 crate 用同一 `core_storage::Error` enum。

### 主题 4: 重复 SQL / 重复实现 / 死代码

- **F-W1A-006** source_dao 4 处硬编码 29 列 SELECT
- **F-W1A-011** books upsert SQL 在 3 处各写一份（book_dao / backup_dao / source_dao 同型）
- **F-W1A-018** chapter_dao.delete_by_book 与 progress_dao.delete 是死代码（FK CASCADE 已兜底）
- **F-W1B-032** core-source 存在两套并行规则系统（rule_engine vs legado/rule）
- **F-W1B-033** js_shim.rs 90 行 dispatcher 与 js_runtime 各一份"是否需要 JS"判断
- **F-W1B-037** execute_chapter_list_js_rule 内外两份同名函数
- **F-W1B-039** RSS BOM 剥离逻辑在 mod.rs 和 parse_xml.rs 各写一份
- **F-W2A-001** 整个 `core/api/` Dio 客户端目录是死代码（占位实现）
- **F-W2A-002** LocalTransport 是 UnimplementedError 占位
- **F-W2A-003** 11 个 settings.json IO 函数模式重复
- **F-W2B-022** 各 feature 各自 `getApplicationDocumentsDirectory()` 拼路径（Resolved by BATCH-18e 方案 A）
- **F-W2B-062** rule_sub / source_page / rss_source_manage_page 三套 ~400 行重复模板
- **F-W3-019** search_with_source_from_db v2 与 non-v2 同存，无 deprecation

**共同建议**: 整批拆"死代码删除任务"（删 `core/api/`、`LocalTransport` 占位、`delete_by_book` 死代码）；抽 SQL 列常量；统一文件 IO 进 `core/io_utils.dart`；选定 rule_engine vs legado/rule 一套保留。

### 主题 5: WebView / JS 边界缺安全 gating

- **F-W2A-009** WebView 始终 `JavaScriptMode.unrestricted`，userAgent / headers 无校验
- **F-W2A-010** `_normalizeJsResult` fallback 路径不 sanitize 字符串
- **F-W2B-002** QR 扫到的 URL 直接 dio.get，无 host 校验 / scheme 限制
- **F-W2B-010** RSS WebView 加载远端 HTML 时无 `setNavigationDelegate`
- **F-W2B-011** WebViewController 初始化失败 catch (e) silent
- **F-W2B-058** mobile_scanner 权限拒绝路径无 UI fallback
- **F-W3-015** LegadoJsBridge 50+ JavascriptInterface 方法对加载页 JS 全开

**共同建议**: 集中一个 `WebViewSafety` policy gate（host whitelist + JS interface capability + navigation lock）；QR 扫码协议化（`legado://import`）+ 二次确认对话框 + scheme 严格校验。

### 主题 6: Reader 状态机 / 渲染性能问题

- **F-W2A-005** build 内 addPostFrameCallback 调 `_setReaderSettings` 改 provider，违反 build 期纯函数原则
- **F-W2A-006** _onScroll 每次回调创建 Timer 但早退检查不严
- **F-W2A-007** _fetchSourceInfo mounted 检查通过后做多次 await，中间可能 unmount
- **F-W2A-008** fontSize 与 readerSettings.fontSize 双 source of truth（Resolved by BATCH-18d）
- **F-W2A-011** ReaderPage build 同时 watch readerSettings + bookChapters，触发 rebuild 链
- **F-W2A-012** AnimatedBuilder 把 controller + animController 合并 listenable，每帧重建
- **F-W2A-013** _measureChapter 在 postFrameCallback 内 notifyListeners，配合 loadChapter 形成多次相互触发
- **F-W2A-014** 滚动模式段高估算误差大
- **F-W2B-013** RSS article_list setState 整个 _articlesBySort map 重建
- **F-W2B-018** SSE 流式搜索每 result 都 `List.unmodifiable` + 重算 precision
- **F-W2B-042** TabBarView children 直接列表推导，sortOrder 改时全量重建

**共同建议**: 引入 Riverpod selector 拆分；reader 状态机 controller 化（专门一个 ReaderController class），UI 层只 watch derived state；常用 list view 加 const + key 复用。

### 主题 7: FFI 契约：JSON-string 模式 + 无类型校验

- **F-W3-005** 109 个 pub fn 大部分返回 `Result<String, String>`，全程 jsonDecode → cast<Map<String, dynamic>>，schema 漂移完全靠运行时
- **F-W3-006** PlatformInt64 / i64 滥用（不需要 64bit 的 id 也用），平添 web 复杂度
- **F-W3-007** rss_get_articles 用 `""` sentinel；同模块 rss_list_articles 用 `Option<String>`
- **F-W3-010** apply_replace_rules 每次切章传整章 content 字符串过 FFI marshal
- **F-W3-019** v1/v2 fn 同存

**共同建议**: 选 5-10 条热路径迁移到强类型 FRB（class / record）；spec 写"何时用 JSON / 何时用强类型"；i64/i32 选型规则 + sentinel 禁止；废弃 v1，保留 v2。

### 主题 8: 错误信息 / 日志 跨层不一致

- **F-W3-008** Rust 端错误消息中英混用（"章节内容为空" vs "WEBVIEW_REQUIRED:"）
- **F-W3-009** Rust `tracing` 与 Dart `debugPrint` 风格 / release 行为完全不统一
- **F-W3-042** 全代码库无错误码集中索引

**共同建议**: Rust 端引入 `BridgeError` enum (thiserror)；Dart 端 `class Log { ... }` 统一格式；release 模式日志桥接 logcat；spec `logging-guidelines.md` + `error-codes.md` 落地（`.trellis/spec/backend/` 5 份 placeholder 中正好已经有 logging / error 两份）。

### 主题 9: Cargo workspace 依赖治理

- **F-W3-011** base64 / md5 / zip / urlencoding 6 个 crate 各自版本号，3+ 处不一致
- **F-W3-012** core-source 反向依赖 core-storage，破坏分层
- **F-W3-020** workspace 缺 `zeroize/secrecy`
- **F-W3-030** tempfile 重复在 deps + dev-deps
- **F-W3-031** core-source 同时依赖 ureq + reqwest 两个 HTTP 客户端
- **F-W3-033** edition 2021 vs README 声称 2024 不一致
- **F-W3-039** 缺 `[workspace.package]` 集中元数据
- **F-W3-040** 缺 `[lints]` 强制 clippy 规则

**共同建议**: 整批 Cargo workspace 重构任务：`[workspace.dependencies]` + `[workspace.package]` + `[lints]` 一次性引入；core-source 反向依赖单独子任务整改；tempfile / md5/md-5 trivial fix。

### 主题 10: Reader / Bookshelf / Settings 中的测试钩子污染生产 API

- **F-W2B-004** BackupPage 构造函数 10 个 `*Override` 参数
- **F-W2B-020** LiveTestRunner typedef + global `debugLiveTestRunnerOverride`
- **F-W2B-065** replace_rule 用 module-level mutable global `_r24NoticeShown`

**共同建议**: 全部走 ProviderScope override 而不是构造函数注入；global mutable 改 ref.read 的 StateProvider。

---

## 单条索引（按严重度）

### P0 严重 (10)

- **[F-W1A-001]** 备份加密用 AES-128/ECB + MD5(password) 弱算法 — `core/core-storage/src/legado_aes.rs:33-131`
- **[F-W1A-002]** FRB 同步 fn `explore` 内部 `block_on` 嵌套 runtime 风险 — `core/bridge/src/api.rs:933`
- **[F-W1B-001]** java.ajax 系列 JS 桥接无 SSRF 防护，可访问内网 / 元数据服务 — `core/core-source/src/legado/js_runtime.rs:886-998`
- **[F-W1B-002]** java.downloadFile/getFile/deleteFile/unzipFile 沙箱可被环境变量豁免 — `core/core-source/src/legado/js_runtime.rs:1733-1796`
- **[F-W1B-003]** QuickJS 沙箱无内存 / 栈上限，仅 wall-clock 超时 — `core/core-source/src/legado/js_runtime.rs:301-329`
- **[F-W1B-004]** java.queryTtf 把任意 base64 输入当 ttf 解析 — `core/core-source/src/legado/js_runtime.rs:1966-1999`
- **[F-W2A-009]** WebView 始终 unrestricted JS + 无 userAgent / headers 校验 — `flutter_app/lib/core/platform_webview_executor.dart:104-105`
- **[F-W2B-001]** WebDAV 凭据明文写入应用 documents 的 `webdav.json` — `flutter_app/lib/features/settings/webdav_config_page.dart:181-187`
- **[F-W2B-002]** QR 扫到的 URL 直接 dio.get，无 host 校验 — `flutter_app/lib/features/qr/legado_qr_protocol.dart:55-56`
- **[F-W3-001]** 仓库内 4 个 ABI 的 `libbridge.so` 二进制（3 个 stale）— `flutter_app/android/app/src/main/jniLibs/`

### P1 主要 (122)

- **[F-W1A-003]** 备份解密无认证（无 HMAC / GCM tag），filter 路径可绕过 — `core/core-storage/src/legado_aes.rs`
- **[F-W1A-004]** WAL synchronous 调优缺失，断电可能丢提交 — `core/core-storage/src/database.rs:14-53`
- **[F-W1A-005]** migrate 手写 BEGIN/COMMIT，非 RAII — `core/core-storage/src/database.rs:455-494`
- **[F-W1A-006]** source_dao 4 处硬编码 29 列 SELECT，列漂移风险 — `core/core-storage/src/source_dao.rs:118-185`
- **[F-W1A-007]** source_dao.upsert 中 silently rewrite id 行为，caller 无感知 — `core/core-storage/src/source_dao.rs:69-78`
- **[F-W1A-008]** delete_batch 无事务，N 条触发 N 次 fsync — `core/core-storage/src/source_dao.rs:188-203`
- **[F-W1A-009]** import_local_book 多 dao 多事务，FK 失败留脏数据 — `core/core-storage/src/chapter_dao.rs:115-160`
- **[F-W1A-010]** add_bookmark INSERT-only，重复 id 失败 — `core/core-storage/src/progress_dao.rs:117-145`
- **[F-W1A-011]** books upsert SQL 在 3 处重复，schema 加列必漏 — `core/core-storage/src/backup_dao.rs:495-578`
- **[F-W1A-012]** backup zip 解压无单文件大小限制，zip-bomb 可 OOM — `core/core-storage/src/backup_dao.rs:187-203`
- **[F-W1A-013]** group bitmask 多分组语义无法 round-trip — `core/core-storage/src/legado_field_map.rs:618-685`
- **[F-W1A-014]** StorageManager error type 用 boxed Error 与全 crate 不一致；StorageManager 实际是死代码 — `core/core-storage/src/lib.rs:73-82`
- **[F-W1A-015]** cache_dao.get 用 unwrap_or_default 静默吞 SQL 错误 — `core/core-storage/src/cache_dao.rs:13-20`
- **[F-W1A-016]** download_dao 模块级 static DOWNLOAD_ROOT 全局可变状态 — `core/core-storage/src/download_dao.rs:9-21`
- **[F-W1A-017]** download_dao create_task_with_chapters 手写 BEGIN/COMMIT，ROLLBACK 用 `let _` 吞错 — `core/core-storage/src/download_dao.rs:164-183`
- **[F-W1A-018]** delete_book 多 dao let _= 吞错（同时是死代码，FK CASCADE 已兜底）— `core/bridge/src/api.rs:72-80`
- **[F-W1A-019]** apply_replace_rules 全局 Mutex，章节切换时主线程串行 — `core/bridge/src/api.rs:1066-1109`
- **[F-W1A-020]** 备份密码明文 JSON 写盘 — `core/bridge/src/api.rs:1407-1429`
- **[F-W1A-021]** download_and_save_chapter 多次 open_db 无事务，~7 次独立 commit — `core/bridge/src/api.rs:730-790`
- **[F-W1A-022]** Empty 错误分支 update + recompute 写法散落，下次易漏 — `core/bridge/src/api.rs:733-741`
- **[F-W1A-023]** api-server 临时 token 在 warn 日志里输出明文 — `core/api-server/src/main.rs:108-119`
- **[F-W1A-054]** legado_field_map 用 `created_at*1000` 当主键 id，并发导入冲突 — `core/core-storage/src/legado_field_map.rs`
- **[F-W1A-055]** production `database::init_database` 不启用 WAL，BATCH-07b 加的 `synchronous=NORMAL` + `wal_autocheckpoint=1000` 实际无效 — `core/core-storage/src/database.rs:14-76` (Resolved by BATCH-08c)
- **[F-W1A-056]** backup_dao 未处理 -wal/-shm sidecar 文件，启用 WAL 后未 checkpoint 时备份会丢未 commit 改动 — `core/core-storage/src/backup_dao.rs` (Dismissed by BATCH-08d audit — 走 SQL SELECT 不接触 db 文件)
- **[F-W1A-057]** 占位：未来若引入 binary-level db backup（`fs::copy` / `VACUUM INTO` / `sqlite3_backup_init`）需在备份前 checkpoint — `core/core-storage/src/backup_dao.rs`（潜在新增路径） (Open，识别于 BATCH-08d)
- **[F-W1B-005]** ZIP 路径无 traversal 防护 — `core/core-source/src/legado/js_runtime.rs`
- **[F-W1B-006]** java._vars 全局绑定，跨脚本变量泄漏 — `core/core-source/src/legado/js_runtime.rs`
- **[F-W1B-007]** LegadoHttpClient https_only(false) + 无 cross-scheme redirect 限制 — `core/core-source/src/legado/http.rs`
- **[F-W1B-008]** {{...}} 模板表达式 dangerous-eval — `core/core-source/src/legado/url.rs`
- **[F-W1B-009]** import_legado_source 无大小/字段数上限 — `core/core-source/src/legado/import.rs`
- **[F-W1B-010]** java HTTP 响应大小检查靠 `take(max+1)`，chunked 可绕过 — `core/core-source/src/legado/js_runtime.rs`
- **[F-W1B-011]** 每次 eval 都 new Runtime + Context，性能 + 状态泄漏 — `core/core-source/src/legado/js_runtime.rs`
- **[F-W1B-012]** JSON.stringify(undefined) 序列化 — `core/core-source/src/legado/js_runtime.rs`
- **[F-W1B-013]** js_script_to_expression 字符串拼接生成 JS，注入风险 — `core/core-source/src/legado/js_runtime.rs`
- **[F-W1B-014]** legado_value_to_js_expr 用 HashMap 序列化键序不稳 — `core/core-source/src/legado/js_runtime.rs`
- **[F-W1B-015]** _resolveUrl JS 实现与 Rust 端 build_full_url 行为不一致 — `core/core-source/src/legado/js_runtime.rs`
- **[F-W1B-016]** java_time_format 整数 / 毫秒判断启发式有 bug — `core/core-source/src/legado/js_runtime.rs`
- **[F-W1B-017]** apply_format_js 每章节 eval 两次 — `core/core-source/src/parser.rs:1866`
- **[F-W1B-018]** resolve_image_src_headers 每次新建 regex 不缓存 — `core/core-source/src/parser.rs`
- **[F-W1B-019]** 章节为空时 final_next_chapter_url 链路异常 — `core/core-source/src/parser.rs`
- **[F-W1B-020]** 多页目录拉取失败时 chapter_offset 已累加，后续 index 错位 — `core/core-source/src/parser.rs:1075`
- **[F-W1B-021]** 多页 toc next_urls 队列无去重无上限 — `core/core-source/src/parser.rs`
- **[F-W1B-022]** resolve_image_src_headers regex 在循环内 unwrap — `core/core-source/src/parser.rs`
- **[F-W1B-023]** QuickJS Runtime 每次新建注册 30+ Function — `core/core-source/src/legado/js_runtime.rs`
- **[F-W1B-024]** chapter list js_lib 每章新建 runtime — `core/core-source/src/parser.rs`
- **[F-W1B-025]** parse_chapters_from_page 每章 extract_from_contexts — `core/core-source/src/parser.rs:1294-1297`
- **[F-W1B-026]** resolve_template_expressions 每个 {{}} 块新建 runtime — `core/core-source/src/legado/url.rs`
- **[F-W1B-027]** execute_js_rule / execute_inline_js_rule 各自 new Runtime — `core/core-source/src/legado/rule.rs`
- **[F-W1B-028]** search 每个 item 单独 extract_from_contexts — `core/core-source/src/parser.rs`
- **[F-W1B-029]** execute_single_css 重复 parse_document — `core/core-source/src/legado/rule.rs`
- **[F-W1B-030]** RATE_LIMITER std::sync::Mutex 高并发时阻塞 — `core/core-source/src/parser.rs`
- **[F-W1B-031]** font_mappings_json 序列化所有 codepoint→glyph 反复 JSON.parse — `core/core-source/src/legado/js_runtime.rs`
- **[F-W1B-032]** core-source 存在两套并行规则系统 — `core/core-source/`
- **[F-W1B-033]** js_shim.rs 90 行重复 dispatcher — `core/core-source/src/legado/js_shim.rs`
- **[F-W1B-034]** clean_legado_url 用 rsplit_once(',') 与 url::extract 不一致 — `core/core-source/src/legado/import.rs`
- **[F-W1B-035]** content_rule_field 处理空字符串过滤逻辑分散 — `core/core-source/src/parser.rs`
- **[F-W1B-036]** resolve_conditional_page 处理 <,{{page}}> 模板逻辑分散 — `core/core-source/src/legado/url.rs`
- **[F-W1B-037]** execute_chapter_list_js_rule 内外两份同名函数 — `core/core-source/src/parser.rs`
- **[F-W1B-038]** spawn_blocking 调阻塞 reqwest，可能 starvation — `core/core-source/src/parser.rs`
- **[F-W1B-039]** RSS BOM 剥离逻辑双份 — `core/core-source/src/rss/`
- **[F-W1B-040]** execute_css_rule || break 语义错位 — `core/core-source/src/legado/rule.rs`
- **[F-W1B-041]** execute_legado_rule 空 rule_str 返回 html，等价无差别 — `core/core-source/src/legado/rule.rs`
- **[F-W1B-042]** JSONPath 模板 lookbehind 漏配 — `core/core-source/src/legado/url.rs`
- **[F-W1B-043]** add_cookie dedup 每条都 Url::parse — `core/core-net/src/cookie.rs`
- **[F-W1B-044]** save_persistent_cookies 每次全量序列化 pretty JSON — `core/core-net/src/cookie.rs`
- **[F-W1B-045]** WebDavClient 30s timeout 偏长，下载阻塞 — `core/core-net/src/webdav.rs`
- **[F-W2A-001]** core/api/ Dio 客户端目录是死代码 — `flutter_app/lib/core/api/`
- **[F-W2A-002]** LocalTransport 是 UnimplementedError 占位 — `flutter_app/lib/core/transport.dart`
- **[F-W2A-003]** 11 个 settings.json IO 函数模式重复 — `flutter_app/lib/core/providers.dart` (Resolved by BATCH-18c)
- **[F-W2A-004]** replaceRuleGenerationProvider 多 isolate 撞值风险 — `flutter_app/lib/core/providers.dart:196-205`
- **[F-W2A-005]** ReaderPage build 内 addPostFrameCallback 改 provider — `flutter_app/lib/features/reader/`
- **[F-W2A-006]** _onScroll 每次回调创建 Timer — `flutter_app/lib/features/reader/`
- **[F-W2A-007]** _fetchSourceInfo mounted 检查通过后多次 await — `flutter_app/lib/features/reader/`
- **[F-W2A-008]** fontSize 双 source of truth — `flutter_app/lib/core/providers.dart` (Resolved by BATCH-18d)
- **[F-W2A-010]** _normalizeJsResult fallback 路径不 sanitize — `flutter_app/lib/core/platform_webview_executor.dart:189`
- **[F-W2A-011]** ReaderPage build watch 多个 provider 引发 rebuild 链 — `flutter_app/lib/features/reader/`
- **[F-W2A-012]** AnimatedBuilder 合并 listenable，每帧重建 — `flutter_app/lib/features/reader/page/`
- **[F-W2A-013]** _measureChapter 与 loadChapter 多次相互触发 — `flutter_app/lib/features/reader/`
- **[F-W2A-014]** 滚动模式段高估算误差 — `flutter_app/lib/features/reader/`
- **[F-W2B-003]** notification toggle 多次 setState + ScaffoldMessenger — `flutter_app/lib/features/settings/settings_page.dart`
- **[F-W2B-004]** BackupPage 10 个 `*Override` 测试钩子参数污染生产 API — `flutter_app/lib/features/settings/backup_page.dart`
- **[F-W2B-005]** _loadWebDavConfig catch (_) 静默返回 null — `flutter_app/lib/features/settings/backup_page.dart`
- **[F-W2B-006]** webdav cfg 三处 `!` 强制断言 — `flutter_app/lib/features/settings/backup_page.dart`
- **[F-W2B-007]** PlatformInt64 → int 模式重复 — `flutter_app/lib/features/settings/cache_management_page.dart`
- **[F-W2B-008]** _sum() 每次 build 全量遍历 — `flutter_app/lib/features/settings/cache_management_page.dart`
- **[F-W2B-009]** rss article detail 找文章用全数组遍历 — `flutter_app/lib/features/rss/article_detail_page.dart`
- **[F-W2B-010]** RSS WebView unrestricted JS 加载远端 HTML 无 NavigationDelegate — `flutter_app/lib/features/rss/article_detail_page.dart`
- **[F-W2B-011]** WebViewController init 失败 catch silent — `flutter_app/lib/features/rss/article_detail_page.dart`
- **[F-W2B-012]** RSS optimistic mark_read 与 detail 异步写库时序 — `flutter_app/lib/features/rss/article_list_page.dart`
- **[F-W2B-013]** rss article_list setState 整 map 重建 — `flutter_app/lib/features/rss/article_list_page.dart`
- **[F-W2B-014]** rss source manage onToggleEnabled 直接修改原 map — `flutter_app/lib/features/rss/source_manage_page.dart`
- **[F-W2B-015]** importLocalBook 解析 catch null book_id — `flutter_app/lib/features/bookshelf/import.dart`
- **[F-W2B-016]** AppBar PopupMenu 9 个跳转项无组织 — `flutter_app/lib/features/bookshelf/`
- **[F-W2B-017]** 列表/网格切换无 KeepAlive — `flutter_app/lib/features/bookshelf/`
- **[F-W2B-018]** SSE 流式搜索每条 result List.unmodifiable — `flutter_app/lib/features/search/search_page.dart`
- **[F-W2B-019]** 多书源并行搜索旧 future 无法取消 — `flutter_app/lib/features/search/search_page.dart`
- **[F-W2B-020]** LiveTestRunner global mutable override — `flutter_app/lib/features/source/`
- **[F-W2B-021]** mounted setState 模式混用，无统一规范 — cross-feature
- **[F-W2B-022]** 各 feature 自行拼 documents 路径 — cross-feature (Resolved by BATCH-18e 方案 A)
- **[F-W2A-081]** webdav.json read-modify-write 模板在 webdav_config_page + backup_page 重复 — `flutter_app/lib/features/settings/` (Resolved by BATCH-18g；原 BATCH-18e 误用 ID F-W2A-058，与 core 既有 finding 撞号已重分配)
- **[F-W2B-032]** rss _loadArticles catch 中 setState + ScaffoldMessenger 顺序 — `flutter_app/lib/features/rss/article_list_page.dart`
- **[F-W2B-041]** initState 中 then(...) 未 await，未捕获 future — `flutter_app/lib/features/bookshelf/`
- **[F-W2B-042]** TabBarView children 直接列表推导，sortOrder 改时全量重建 — `flutter_app/lib/features/bookshelf/`
- **[F-W2B-058]** mobile_scanner 权限拒绝路径无 UI fallback — `flutter_app/lib/features/qr/`
- **[F-W2B-062]** rule_sub / source_page / rss_source 三套 ~400 行重复模板 — `flutter_app/lib/features/`
- **[F-W2B-065]** replace_rule module-level mutable global `_r24NoticeShown` — `flutter_app/lib/features/replace_rule/`
- **[F-W3-002]** AndroidManifest 缺 allowBackup="false" — `flutter_app/android/app/src/main/AndroidManifest.xml:7-11`
- **[F-W3-003]** network_security_config 全局 cleartext — `flutter_app/android/app/src/main/res/xml/network_security_config.xml`
- **[F-W3-004]** MainActivity exported=true + taskAffinity="" 未文档化 — `AndroidManifest.xml:12-20`
- **[F-W3-005]** FFI 全表 JSON-string 模式，无类型校验 — `flutter_app/lib/src/rust/api.dart`
- **[F-W3-006]** PlatformInt64 / i64 滥用 — `core/bridge/src/api.rs`
- **[F-W3-007]** rss_get_articles 用 `""` sentinel 与 Option 共存 — `core/bridge/src/api.rs:1815-1875`
- **[F-W3-008]** Rust 端错误消息中英混用 — multiple files
- **[F-W3-009]** Rust tracing vs Dart debugPrint 风格不统一 — multiple files
- **[F-W3-010]** apply_replace_rules 每次切章传整章 content — `core/bridge/src/api.rs:1018-1109`
- **[F-W3-011]** Cargo workspace 同 crate 多版本（base64 / md5 / zip / urlencoding）— `core/*/Cargo.toml`
- **[F-W3-012]** core-source 反向依赖 core-storage，破坏分层 — `core/core-source/Cargo.toml`
- **[F-W3-013]** release APK 用 debug keystore 签名 — `flutter_app/android/app/build.gradle.kts:48-54`
- **[F-W3-014]** release build 不做 R8 / shrinking / obfuscation — `flutter_app/android/app/build.gradle.kts:48-54`
- **[F-W3-015]** LegadoJsBridge 50+ JavascriptInterface 方法对加载页 JS 全开 — `flutter_app/android/.../MainActivity.kt:300`
- **[F-W3-016]** release script analyze/test 在 cp .so 之后，污染 jniLibs — `build_android_release.sh:60-65`
- **[F-W3-017]** pubspec 全 ^ 范围 + 未 commit pubspec.lock — `flutter_app/pubspec.yaml`
- **[F-W3-018]** release 工作区脏检查只 grep `^??`，不阻断 — `build_android_release.sh:38-46`
- **[F-W3-019]** search_with_source_from_db v1/v2 同存 — `core/bridge/src/api.rs:474-580`
- **[F-W3-020]** Cargo workspace 缺 zeroize/secrecy — `core/Cargo.toml`
- **[F-W3-021]** network_security_config 缺 pin-set，远程 api-server 可 MITM — `flutter_app/android/.../network_security_config.xml`

(P2 / P3 不在此索引；查询单条详情请打开对应 wave 文件。)

---

## 推荐第一批修复（5-10 个 P0/P1 条目）

按"风险高 + 修复成本低 + 可独立成子任务"挑出 8 条。每条都已经在某个 wave 里有详细分析，子任务直接复用其上下文。

| # | finding id | 风险 | 一句话 | 建议子任务 slug | 预估范围 |
|---|---|---|---|---|---|
| 1 | F-W3-013 | 高 | release APK 用 debug keystore 签名（任何人可伪造同包升级用户） | `fix-release-keystore` | `android/app/build.gradle.kts` + 新增 `key.properties.example` + README 文档；~30 行 |
| 2 | F-W3-002 | 高 | AndroidManifest 缺 `allowBackup="false"`，凭据 / DB 上 Google Auto Backup | `fix-manifest-disable-backup` | 1 行 manifest + README 备注；~5 行 |
| 3 | F-W3-001 | 高 | 仓库内 4 个 ABI stale `libbridge.so` 占 45MB / 升级时可能误打包 | `cleanup-stale-jnilibs` | `git rm` 3 个目录 + `.gitignore` 加规则 + 双 build script 加清理；~10 行 |
| 4 | F-W2B-001 | 高 | WebDAV 凭据明文写 `webdav.json` | `secure-webdav-credentials` | 引入 Android Keystore wrapper（同时复用给 F-W1A-020 备份密码）；~150 行 |
| 5 | F-W1A-020 | 高 | 备份密码明文写 `legado_local.json` | (合并进 #4 同子任务，统一引入凭据保险柜) | 同 #4 |
| 6 | F-W1B-001 | 高 | java.ajax 系列 JS 桥无 SSRF 防护 | `harden-js-shim-ssrf` | 在 `core-source/legado/js_runtime` 加 host 黑名单（复用 `MainActivity.kt::isPrivateHost` 等价 Rust 实现）；~200 行 + tests |
| 7 | F-W3-011 | 中 | Cargo workspace 同 crate 多版本（base64 / md5 / zip / urlencoding） | `cargo-workspace-deps-cleanup` | 引入 `[workspace.dependencies]` + 6 个 sub-crate Cargo.toml 改写；~80 行 |
| 8 | F-W2A-001 + F-W2A-002 + F-W1A-018 | 低 | 删除 3 处死代码（core/api/ Dio 目录、LocalTransport 占位、delete_book 多余 dao 调用） | `remove-dead-code-batch-1` | 删除 ~500 行 + 调整少量 import；纯减法 |

**为什么是这 8 条**:
- #1-#3 是"低改动 + 高安全收益 + 不依赖业务逻辑变化"的 quick wins，最适合作为第一批修复 commit
- #4-#5 合并是因为两者都需要引入凭据保险柜基础设施，分两次 PR 浪费
- #6 是 P0 中风险最集中、修复路径最清晰的一条（已有 Android 端 `isPrivateHost` 可参考）
- #7 是技术债清理的 baseline——后续所有依赖升级都依赖此次集中化
- #8 是纯减法，无回归风险，commit 历史清爽

**不推荐第一批做的高风险 P0 / P1**:
- F-W1B-002~005 (JS 沙箱 / ZIP / 文件) — 修复需重设计 JS Bridge capability 模型，风险高，建议第二批专项
- F-W3-005 (FFI JSON-string 全表迁移) — 工作量超大，分多个子任务，先选 1-2 条热路径迁移做样板
- F-W2A-005~014 (Reader 状态机重构) — 涉及阅读器流畅度回归，需要 reader test harness 先到位
- F-W1B-032 (两套规则系统并存) — 选择哪套保留是产品决策，不是单纯技术修复
