# Findings — Wave 2B (Flutter remaining 9 features)

**Scope**: settings, rss, bookshelf, search, source, qr, rule_sub, replace_rule, download
**Reviewed at**: 2026-05-20
**File count**: 20
**Lines reviewed**: ~8,063

## 统计

### 按严重度
| Severity | Count |
|---|---|
| P0 严重 | 2 |
| P1 主要 | 26 |
| P2 次要 | 28 |
| P3 nice-to-have | 14 |
| **总计** | **70** |

### 按维度
| 维度 | Count |
|---|---|
| A-架构 | 12 |
| B-正确性 | 24 |
| C-性能 | 9 |
| D-安全 | 7 |
| E-代码异味 | 18 |

### 按模块（合并子项）
| 模块 | P0 | P1 | P2 | P3 | Total |
|---|---|---|---|---|---|
| settings (backup/cache/webdav/read_stats/settings_page) | 1 | 5 | 8 | 2 | 16 |
| rss (article_list/article_detail/source_manage/favorites/_) | 0 | 6 | 5 | 4 | 15 |
| bookshelf (含 book_info_edit / widgets / import) | 0 | 4 | 6 | 3 | 13 |
| search | 0 | 2 | 3 | 1 | 6 |
| source | 0 | 1 | 2 | 1 | 4 |
| qr | 1 | 1 | 2 | 1 | 5 |
| rule_sub | 0 | 1 | 1 | 1 | 3 |
| replace_rule | 0 | 1 | 1 | 0 | 2 |
| download | 0 | 0 | 1 | 1 | 2 |
| cross-feature | 0 | 2 | 1 | 1 | 4 |

---

## Findings

### F-W2B-001 [P0 严重][D-安全][settings/webdav]

**File**: `flutter_app/lib/features/settings/webdav_config_page.dart:181-187`

**问题**: WebDAV 凭据明文写入应用 documents 目录的 `webdav.json`，且代码明确注释"先存明文"。

**详细**: `_onSave` 直接 `jsonEncode({...password: _pwdCtl.text})` 后 `f.writeAsString` 落盘。documents 目录在 root 设备 / adb backup / 设备共享场景下易被读出。这与原 Legado 早期一致，但其后续已加入 AES 加密（批次 12 注释提到只对备份 zip 内的 webDavPassword 加密，本地 webdav.json 仍明文）。`_loadWebDavConfig` (backup_page.dart:474-494) 同样以明文读出。

**建议**: 用 `flutter_secure_storage`（Android Keystore 后端）替换 `webdav.json`；迁移路径：启动时若旧文件存在则读出 → 写入 secure storage → 删除文件。同时 `legado_local.json`（备份密码）已通过 Rust 端加密保存，但应同步迁移以保持一致。

**Resolution (BATCH-03, 2026-05-21，方案 A 缩范围)**: 闭环本批 P0 部分。仅迁移 WebDAV password；备份密码留 BATCH-03b（涉及 FRB `set_backup_password` / `get_backup_password` 接口签名变更，跨 Rust + Dart binary contract，effort 大）；F-W1A-023 token 明文日志已被 BATCH-23 处理；F-W2B-005 静默 catch 已被 BATCH-18g (json_store.readJsonFile null fallback) 处理。

实施：
- 加 `flutter_secure_storage: ^9.0.0` 依赖（lock 解析 9.2.4）。v9 默认 Android backend = `EncryptedSharedPreferences`（AES-256/GCM, key in Keystore），与项目 minSdk 23+ 兼容；iOS 走 Keychain（无额外代码）。
- 新建 `flutter_app/lib/core/security/secure_storage.dart`：abstract `SecureStorageImpl` interface + `_RealSecureStorage` 默认实现 + 顶层 `readSecret(key)` / `writeSecret(key, value)` / `deleteSecret(key)` 函数（与 `core/persistence/json_store.dart` 顶层 helper 模式同构）。`writeSecret(null/'')` 等价 delete。提供 `setSecureStorageOverrideForTest(SecureStorageImpl?)` 顶层测试钩子（@visibleForTesting），让 widget test 注入 `InMemorySecureStorage` 而不触发平台 channel 的 `MissingPluginException`。
- `webdav_config_page.dart::_onSave` 写：`writeJsonFile('webdav.json', { url, user, deviceName })`（**3 字段**，无 password）+ `await writeSecret('webdav_password', _pwdCtl.text)`。
- `webdav_config_page.dart::_loadConfig` 读 + 一次性迁移：从 webdav.json 读 4 字段，若 `legacyPwd.isNotEmpty && readSecret('webdav_password') == null` → `writeSecret('webdav_password', legacyPwd)` + 重写 webdav.json 仅留 3 字段（去 password）。幂等：第二次启动 readSecret 已非 null，迁移路径跳过；webdav.json 写入时永不再带 password 字段。
- `backup_page.dart::_loadWebDavConfig` 读：`readJsonFile + readSecret` → `_WebDavCredentials`（见 F-W2B-006 Resolution）。
- 测试基础设施：新建 `test/_secure_storage_fake.dart::InMemorySecureStorage`（Map-backed），由 `secure_storage_test.dart` (7 case) + `webdav_config_page_test.dart` (1 case) 共享。新增 8 case 单测覆盖 round-trip / null=delete / empty=delete / no-op delete / readSecret null on missing / override reset / @visibleForTesting / migration semantics。

行为变化：
- webdav.json 字段 4 → 3（password 移走）。grep `'password'` JSON 字段在 `flutter_app/lib/` 下仅 webdav_config_page.dart:124 迁移路径 1 处保留（读旧文件 legacyPwd），符合 PRD scope。
- 原 webdav.json 含 password 的旧版本升级路径自动迁移。

不在本批：F-W1A-020 备份密码（BATCH-03b）；secure_storage v8 → v9 backend 对比研究（直接选 v9 主流默认）；删 webdav.json 整文件（保留 3 字段非敏感）。

`flutter analyze` 0 issue；`flutter test` 429/429 PASS（旧 421 + 新 8）。task: 05-21-batch-03-secure-webdav-credentials。

---

### F-W2B-002 [P0 严重][D-安全][qr]

**File**: `flutter_app/lib/features/qr/legado_qr_protocol.dart:55-56`，`flutter_app/lib/features/qr/qr_import_handler.dart:31-44`

**问题**: 二维码扫到的 URL（包括 `legado://import/...?src=<URL>` 中的 src 与 bare `https?://...json`）直接走 dio.get 无任何 host/scheme 白名单或用户二次确认 URL 内容，存在 SSRF + 凭据回传风险。

**详细**: `parseLegadoQrPayload` 接受任意 `http://` / `https://` URL，`QrImportHandler._fetchText` 直接 dio GET。攻击者印一张二维码即可让用户的设备 GET 内网地址（路由器/打印机管理页）；返回内容直接灌进 `importSourcesFromJson` / `rssSourceImportJson`，可注入恶意书源（含远程 JS 规则）。当前 `_showConfirmDialog` 仅显示 URL，但用户通常不会校验 host。

**建议**: (1) 默认拒绝 `http://` 与 RFC1918 / 链路本地 / loopback；(2) 在确认 dialog 中 prominently 显示 host 是否首次出现；(3) 考虑维护可选白名单（如 raw.githubusercontent.com / gitee.com），非白名单走二次警告；(4) `_fetchText` 限制 max body size（避免 OOM）。

**Resolution (BATCH-05, 2026-05-21，方案 A 集中安全库)**: 闭环。引入 `core/security/webview_safety.dart` 4 件套（`enforceWebViewScheme` / `classifyHost` / `defaultUserAgent` / `safeJsResultDecode`）。
- `legado_qr_protocol.dart::parseLegadoQrPayload` 在两条解析分支末尾都调 `enforceWebViewScheme`：`legado://import/...?src=file:///etc/passwd` 直接被当"未识别"返回 null（与原"未识别 → 弹未识别 dialog"路径自然衔接，不需要额外 UX）。
- `qr_import_handler.dart::_fetchText` defense-in-depth 再调 `enforceWebViewScheme`，并加 `User-Agent: defaultUserAgent()` request header；新增 `validateFetchedBody(body, contentType)` `@visibleForTesting` static method 做 10 MB body 上限 + Content-Type allow-list（`json` / `text/plain` / `application/octet-stream` / 空 → 兼容许多源用 octet-stream 给 .json）。
- `qr_scan_page.dart::_showConfirmDialog` 多显示一行 host class 警告（loopback / linkLocal / privateNetwork / invalid 红字提示），public host 不显示，让用户辨别 SSRF。
- 单测：`webview_safety_test.dart` 全 4 fn 覆盖 30+ case；`legado_qr_protocol_test.dart` 加 3 case 验证 file:// / javascript: / data: src 都被拒；`qr_scan_page_test.dart` 加 4 case（permissionDenied UI + file:// 走未识别 + private host 警告 + public host 无警告）；`qr_import_handler_test.dart` 加 6 case 覆盖 validateFetchedBody 边界。

**未做**（PRD Out of Scope）：白名单 host（raw.githubusercontent.com / gitee.com），维护成本高且与 Trellis 项目"用户自主决策"哲学冲突；token 在 QR URL 中检测留 BATCH-22+。

---

### F-W2B-003 [P1 主要][B-正确性][settings/settings_page]

**File**: `flutter_app/lib/features/settings/settings_page.dart:50-66`

**问题**: `_onNotificationSwitchToggled(true)` 中调用 `setState` 后又调用 `if (mounted) ScaffoldMessenger.of(context)`，但 setState 已经在前面，整段逻辑在 async gap 之后未完整 mounted 检查。

**详细**: 第 53 行 `if (!mounted) return;` 之后调用 `setState`，这没问题。但 56-62 的 `if (mounted) ScaffoldMessenger.of(context).showSnackBar(...)` 中的 `mounted` 检查冗余（已在第 53 行检查过）；同时 dialog 路径 `_showDisableNotificationDialog` (line 68) 没有 mounted 检查，可能在 widget unmounted 时弹 dialog。

**建议**: 在 `_onNotificationSwitchToggled` 进入 `_showDisableNotificationDialog` 前加 mounted check；同时统一使用 `if (!mounted) return;` early return 而不是 nested `if (mounted) {}`。

**Resolution (BATCH-20, 2026-05-21)**: `settings_page._onNotificationSwitchToggled` 改为 `if (!mounted) return;` early-return 风格统一。删除冗余的 `if (mounted) ScaffoldMessenger...` 包装（line 53 已有 `if (!mounted) return;` 早返回）。`_showDisableNotificationDialog()` 调用前补 `if (!mounted) return;`。无新单测（行为不变）。task: 05-21-batch-20-settings-testability-cleanup。

---

### F-W2B-004 [P1 主要][A-架构][settings/backup]

**File**: `flutter_app/lib/features/settings/backup_page.dart:81-93`

**问题**: `BackupPage` 构造函数有 10 个 `*Override` 测试钩子参数，让生产代码 API 表面被测试需求严重污染。

**详细**: 9 个 `xxxOverride` 字段全部用于 widget test 注入 fake FRB 调用；同模式在 bookshelf_page (4 个 override)、cache_management_page (4 个)、rss_*_page (3-7 个)、qr_scan_page (6 个)、rule_sub_page (6 个) 大量重复。这种"在 widget 公共构造函数加 fake hook"模式让构造函数难读、文档冗余，且实质是把 testability 与 production API 耦合。

**建议**: 抽出 `RssApiClient` / `BackupApiClient` / `WebDavApiClient` 类（仅是 FRB 函数的命名包装），通过 Riverpod provider 注入，测试中 override provider 即可——既消除构造函数的 N 个钩子，又让 features 间共享相同抽象。这条件需要批次级重构，建议作为独立子任务。

**Resolution (BATCH-20, 2026-05-21)**: BackupPage 10 个 `*Override`（`pickDirectoryOverride` / `pickFileOverride` / `exportBackupOverride` / `importBackupOverride` / `validateZipOverride` / `webdavConfigDirOverride` / `webdavUploadOverride` / `webdavListOverride` / `webdavDownloadOverride`）全部删除。新建 `flutter_app/lib/core/services/backup_api_client.dart`（包装 `exportBackupZip` / `importBackupZip` / `validateBackupZip` / `webdavUploadBackup` / `webdavListBackups` / `webdavDownloadBackup` 6 个 FRB 调用 + `backupApiClientProvider`）+ `core/services/file_picker_service.dart`（包装 `FilePicker.platform.getDirectoryPath` / `pickFiles(zip)` + `filePickerServiceProvider`）。`backup_page.dart` 业务逻辑改 `ref.read(backupApiClientProvider).xxx()` / `ref.read(filePickerServiceProvider).pickXxx()`。`backup_page_test.dart` 2 个 case 全部迁到 `ProviderScope(overrides: [backupApiClientProvider.overrideWithValue(_FakeBackupApiClient(...)), filePickerServiceProvider.overrideWithValue(_FakeFilePickerService(...))], child: ...)`。`_FakeBackupApiClient extends BackupApiClient` 用可选回调字段（`onExport` / `onImport` / `onValidate`）覆写需要追踪调用次数 / 参数的方法，未配置的方法抛 `UnimplementedError`，比 PRD 草稿的"单 returnJson 字段"模式更接近原 `*Override` 语义。**`dbPathOverride` 保留**（cross-feature 测试 db 路径模式，与 fake FRB 性质不同）。task: 05-21-batch-20-settings-testability-cleanup。

---

### F-W2B-005 [P1 主要][B-正确性][settings/backup]

**File**: `flutter_app/lib/features/settings/backup_page.dart:474-494`

**问题**: `_loadWebDavConfig` 在 catch-all `catch (_)` 中静默返回 null，把所有错误（IO、JSON 解析、字段缺失）都当作"未配置"处理。

**详细**: 用户配过 webdav.json 但其中某字段格式坏了（如 deviceName 不是 string），整段 catch 吞掉异常，UI 弹"先去配置 WebDAV"误导用户。同样模式在 webdav_config_page.dart:128 `} catch (_) {}`，让用户首次配置失败时也无任何反馈。

**建议**: 区分 `FileSystemException`（不存在 → 静默）和 `FormatException`（解析失败 → 提示用户配置文件损坏，提供"重置"选项）。

---

### F-W2B-006 [P1 主要][B-正确性][settings/backup]

**File**: `flutter_app/lib/features/settings/backup_page.dart:540`

**问题**: `cfg['url']!` / `cfg['user']!` / `cfg['password']!` 三处 `!` 强制断言，但 `_loadWebDavConfig` 返回 Map 中 user/password 都被 `?? ''` 处理过，url 在 `_loadWebDavConfig` 内已 trim 后非空校验，所以 `!` 表面安全但若未来 `_loadWebDavConfig` 行为改变（如允许 null user）会立刻空指针。

**详细**: 行 537-540、577-579、624-627 重复出现该模式。`Map<String, String>?` 类型本身已声明 value 不可空，但用 `!` 表达"我相信这个 key 一定有"是 implicit contract，破坏后会抛 `Null check operator used on a null value`。

**建议**: 改用 `cfg['url'] ?? ''`（如果空就提前返回）或者把 cfg 类型化为带 4 个 final 字段的 class（如 `WebDavCredentials`）。

**Resolution (BATCH-03, 2026-05-21)**: 与 F-W2B-001 同批顺手清。原始估计 3 处 `!`，实测 **9 处**：分布 `_uploadBackup` (line 445/449/450/451) + `_listBackups` (line 482/483/484) + `_restoreBackup` (line 514/515/516)，全部断言 `cfg['url']!` / `cfg['user']!` / `cfg['password']!` 的混合用法。

实施：`backup_page.dart::_loadWebDavConfig` 返回值从 `Map<String, String>?` 改为 file-private 数据类 `_WebDavCredentials?`（4 final String 字段：url/user/password/deviceName）。internal 走 `readJsonFile('webdav.json')` 拿 url/user/deviceName + `readSecret('webdav_password')` 拿 password；password 缺失走空串（与原 `(map['password'] as String?) ?? ''` 行为对齐）。9 处 caller 全部从 `cfg['xxx']!` / `cfg['xxx']` 改为 `cfg.url` / `cfg.user` / `cfg.password` / `cfg.deviceName`，类型安全且消除 `!` 风险。grep `cfg\\[` 在 backup_page.dart 实际访问处 0 命中（剩 2 处都在文档注释里）。

`_WebDavCredentials` 选 file-private 而非 PRD 草稿建议的 pub `WebDavCredentials`：仅 backup_page.dart 内 1 处 caller，无跨文件复用需求；webdav_config_page 自己直接读 secure_storage + json，不走数据类。task: 05-21-batch-03-secure-webdav-credentials。

---

### F-W2B-007 [P1 主要][B-正确性][settings/cache_management]

**File**: `flutter_app/lib/features/settings/cache_management_page.dart:144-145`，`flutter_app/lib/features/settings/read_stats_page.dart:79-81`

**问题**: `PlatformInt64 → int` 转换的 `raw is int ? raw : raw.toInt() as int` 模式在多处重复，且 `as int` cast 在 web (BigInt) 平台上可能在 toInt() 后已是 int 时多余、在 BigInt > 2^53 时精度丢失但代码无任何警告。

**详细**: cache_management_page.dart:140-146、read_stats_page.dart:74-81、rss_source_manage_page.dart:185-187、233 都用同样的"native: int / web: BigInt → int"转换。语义本身是对的（章节计数不会超过 2^53），但未集中实现且没单测覆盖 BigInt 分支。

**建议**: 抽 `core/util/platform_int64.dart`：`int toInt(PlatformInt64 v) { final dynamic raw = v; return raw is int ? raw : (raw as BigInt).toInt(); }`，所有调用点统一使用。

**Resolution (BATCH-24, 2026-05-21)**: 抽 `flutter_app/lib/core/util/platform_int64.dart::platformInt64ToInt(dynamic raw) → int`。原始估计 6 处 caller，实际**7 处**（遗漏 read_stats_page.dart `totalDyn` 拼装样式略不同的一份）：rule_sub_page × 2 + rss_source_manage × 2 + cache_management × 2 + read_stats × 1 全部改用 helper，+ 3 case 单测（int 直传 / BigInt-like 走 toInt() / null 抛异常）。read_stats_page 改用 helper 后顺手删掉了 `flutter_rust_bridge_for_generated.dart` 显式 `PlatformInt64` 类型 import（caller 不再需要类型名）。

---

### F-W2B-008 [P1 主要][C-性能][settings/cache_management]

**File**: `flutter_app/lib/features/settings/cache_management_page.dart:101-107`，`233-282`

**问题**: `_sum('cached_chapters')` 与 `_sum('total_chapters')` 在每次 build 中分别遍历整个 `_records` 列表；列表几百本书时每次 setState 都会触发两次 O(N) 遍历。

**详细**: build 内调 `_sum` 两次（line 240-241），`_buildList` 内又对 records 走 ListView.builder（这是正常的）。但加载完成后 `_records` 不变，sum 应只算一次。

**建议**: 把 cachedTotal/totalTotal 缓存为 `_cachedTotal` / `_totalTotal` State 字段，在 `_load` / `_onClearAll` 后一次算好；或用 late final lazy。

**Resolution (BATCH-20, 2026-05-21)**: `_CacheManagementPageState` 加 `int _cachedTotal = 0` + `int _totalTotal = 0` 两个 State 字段 + 私有 helper `_recomputeTotals()`。`_load()` 在 `_records = ...` 写入后立即调 `_recomputeTotals()`（生产路径 + `recordsOverride` 路径都覆盖）；错误路径保持 `_records = const []` + 默认 0 不变。`_onClearAll` 用 `_cachedTotal` 替代 `_sum('cached_chapters')`。`build()` 内 line 234/235 改读缓存字段 O(1)。`_sum` 函数删除。无新单测（行为不变，性能优化）。task: 05-21-batch-20-settings-testability-cleanup。

---

### F-W2B-009 [P1 主要][B-正确性][rss/article_detail]

**File**: `flutter_app/lib/features/rss/rss_article_detail_page.dart:146-159`

**问题**: 找文章用 `rssListArticles` 后整个数组遍历找 `link == widget.link`，没有 RssArticleDao.getByOriginLink FRB 桥导致 N 次详情打开都做全量列表查询。

**详细**: 注释明确说"MVP 用全量过滤；列表通常不大"，但用户订阅 5+ 个高频源后单源轻松上千文章；每次进详情页都跑一次 `SELECT * FROM rss_articles WHERE origin=?` + jsonDecode + 线性查找。同时 detail 页 init 还要并行做 3 次 FRB（list、is_starred、fetch_html），FRB 单线程下后两者会被前一个阻塞。

**建议**: 在 Rust 端加 `rss_article_get_by_origin_link(origin, link) -> RssArticle` 桥；同时 detail 页用 `Future.wait` 并行发 list + is_starred + fetch_html（list 改成单条查询后开销可忽略）。

**Resolution (BATCH-21, 2026-05-21，方案 A 仅 Flutter 层)**: 闭环（缩范围）。`rss_article_detail_page.dart::_bootstrap` 把 source / article / isStarred 三个独立 FRB 调用包成 `Future.wait`（互不依赖），mark_read 仍串行（依赖 article.read_time），fetchHtml 也保留独立串行（保留独立错误分支语义：fetch 失败仍能展示 source/article 元数据 + 错误占位）。三个并行 fn 各自包 `Future`：sourceOverride 优先，否则 `rust_api.rssSourceGet`；articleOverride 优先，否则 `rssListArticles` + 全量遍历找 widget.link；isStarredOverride 优先，否则 `rssStarIsStarred`，并加 `.catchError((_) => false)` 与原静默 catch 语义对齐。Latency 收益：list (~50ms) + isStarred (~10ms) 串行 → 并行 max(50, 10) = 50ms，消减 ~10ms；FRB 桥 + fetchHtml 完全并行（含网络 ~200ms）需要 fetchHtml 加入 Future.wait，本批未做（保留独立错误分支语义优先）。

**未做**：FRB 桥 `rss_article_get_by_origin_link`（Rust dao 已有 line 147 + 单测 line 464，但缺 FRB pub fn + binding regen + .so 重打包）— PRD Out of Scope，留 BATCH-21b。FRB 桥能把全数组遍历从 ~50ms 降到 ~5ms（单条 SELECT），收益清晰但跨层 effort 大。

**Resolution (BATCH-21b, 2026-05-22)**: 完整收尾。手动 wire FRB pub fn `rss_article_get_by_origin_link(db_path, origin, link) -> Result<String, String>`（funcId 110，三处同步：build.rs guard fragments + frb_generated.rs wire fn + 4253 行 dispatcher arm + frb_generated.dart abstract method + impl callFfi + ConstMeta）。Dart 端 `api.dart::rssArticleGetByOriginLink` wrapper + `rss_article_detail_page.dart::_bootstrap::articleFuture` 替换：旧 14 行 `rssListArticles + jsonDecode(arr) + for 找 link` IIFE 改为 8 行 `rssArticleGetByOriginLink + jsonDecode 单 Map`。null 处理走 `raw == 'null'` 与现有 `rss_source_get` 模式一致。dao 已有 3 case 单测覆盖（test_get_by_origin_link line 464）；本批未加新单测但 baseline 523 PASS 视为回归。`cargo build -p bridge` build.rs guard PASS = funcId 110 三处同步。task: 05-22-batch-21b-rss-detail-frb-bridge。

新增 1 case widget test 验证 isStarred future 在 fetch 启动前先发起（用 `Completer<bool>` + `Completer<Map>` 跟踪 started flag，验并行启动顺序）。

---

### F-W2B-010 [P1 主要][D-安全][rss/article_detail]

**File**: `flutter_app/lib/features/rss/rss_article_detail_page.dart:225-227`

**问题**: WebView 启用 `JavaScriptMode.unrestricted` 加载远端 RSS 文章 HTML，且没有 setNavigationDelegate / setOnConsoleMessage 限制。

**详细**: RSS 源是用户/订阅源加进来的远端站点；其文章 HTML 中可能有任意 `<script>`（包括 fetch 内网、调外部 JS），unrestricted 模式让这些 script 在 app 上下文中跑。虽然没有暴露 `JavascriptChannel` 到 Dart 端（这点是好的），但页面跳转、cookie、localStorage 都默认开。

**建议**: (1) 默认 `JavaScriptMode.disabled`，加用户开关"加载 JS"；(2) 配置 `setNavigationDelegate` 拦截非 article baseUrl 的跳转；(3) 考虑在 fetch 后用 readability-style sanitizer 剥离 `<script>`/`<iframe>`（Rust 端 `core-parser` 已有 HTML 解析，可加 sanitize 函数）。

**Resolution (BATCH-05, 2026-05-21)**: 闭环。`rss_article_detail_page.dart` WebViewController 初始化路径：(1) `JavaScriptMode.unrestricted` → `JavaScriptMode.disabled`（远端 RSS 文章 HTML 不需要 script 执行）；(2) 加 `setNavigationDelegate(NavigationDelegate(onNavigationRequest: ...))`：跨 host 导航返 `NavigationDecision.prevent`（同 host / 空 host 放行让锚点 / 同站资源加载），attempt-to-cross-origin 时 `debugPrint('[RssDetail] blocked cross-origin nav: $reqHost (base=$baseHost)')`；(3) 用户开关"加载 JS" PRD Out of Scope 留 P3 future work；(4) HTML sanitize（剥 `<script>`/`<iframe>`）需要 Rust 端 `core-parser` 加 sanitize 函数，跨层 effort 大，留 BATCH-05b。`disabled` JS + NavigationDelegate 已足够中和"远端 HTML 含 `<script>` 任意执行 + 用户点链接被劫持"的核心风险。同 file F-W2B-011 同 PR 解决。

---

### F-W2B-011 [P1 主要][B-正确性][rss/article_detail]

**File**: `flutter_app/lib/features/rss/rss_article_detail_page.dart:228-231`

**问题**: WebViewController 初始化失败时 catch (e) 静默把 controller 置 null，错误信息丢失。

**详细**: `try { controller = WebViewController() ..setJavaScriptMode... await controller.loadHtmlString }` 整段 catch 后只把 `controller = null`，没有 debugPrint、没有 error UI。生产环境下用户看到"HTML 长度=N"占位时无法判断是 WebView 不支持还是真实加载失败。

**建议**: catch 内 `debugPrint('[RssDetail] WebView init failed: $e')`；并把错误存到 `_webError` State，UI 占位时分"测试模式"vs"WebView 加载失败"两种文案。

**Resolution (BATCH-05, 2026-05-21)**: 闭环。`_RssArticleDetailPageState` 加 `String? _webError` 字段；`_bootstrap()` WebView init catch 块改为 `debugPrint('[RssDetail] WebView init failed: $e')` + 把 e.toString() 存到 local `webError` 变量再随 `setState({...})` 写入 `_webError` State；`_buildBody` 在 disableWebView / null controller 占位分支判 `_webError != null` 时多显示一行 "WebView 加载失败：$_webError"；`_retry()` 重置 `_webError = null`。同 file F-W2B-010 同 PR 解决。

---

### F-W2B-012 [P1 主要][B-正确性][rss/article_list]

**File**: `flutter_app/lib/features/rss/rss_article_list_page.dart:268-270`

**问题**: 用户点击 article 后立即修改原 article map 的 `read_time`（optimistic），但实际 mark_read 的写库由 detail 页 init 完成 — 用户从 detail 页 pop 回 list 页时，list 页的 `_articlesBySort` 已 stale，下次切 tab 重新拉取后才一致。

**详细**: 当前用户体验是"点击立即变灰 → 进入 detail → 返回 → list 仍灰"，看似正确。但若 detail 页 mark_read 失败（如 FRB 抛错），list 页错误显示已读状态，下次刷新才纠正。

**建议**: detail 页通过 GoRouter `state.extra` 或 Riverpod 通知 list 页"实际持久化结果"，list 页根据回调要么保留 optimistic 状态要么 rollback；最少加注释说明这是"软一致"行为。

**Resolution (BATCH-21, 2026-05-21，仅文档化)**: 闭环（缩范围）。`rss_article_list_page.dart::_onArticleTap` 既有注释扩充"软一致语义"段，明确说明：(a) optimistic 已读 dot 在点击时立即变灰；(b) mark_read 真正写入由 detail 页 init 完成（避免列表 + 详情双写）；(c) detail 写库失败时本次返回 list 仍显示已读（optimistic），但下次 _loadArticles 拉取会恢复 stale read_time = 0；(d) trade-off：避免双写 + 立即视觉反馈，代价是失败时下次自然修正而不是立即 rollback。

**未做**：detail → list 的 rollback 通信机制（GoRouter `state.extra` 回传 / Riverpod 通知）— PRD Out of Scope，留 BATCH-21c future work（rollback 复杂度高 ROI 低）。

**Resolution (BATCH-21c, 2026-05-22)**: 完整收尾。选 GoRouter result 路径而非 Riverpod 跨页 StateProvider（不引入跨页状态管理复杂度）。新增 `MarkReadResult` 三态枚举（`success` / `failed` / `skipped`）置 `rss_article_detail_page.dart` 顶部公开。`_RssArticleDetailPageState._bootstrap` mark_read 三路径设值：try 成功 → `success`；catch → `failed`；不进 if 分支（readTime != 0 / link 空）保持默认 `skipped`。`build` 用 `PopScope(canPop: true, onPopInvokedWithResult: (didPop, _) {})` 包 `Scaffold` + AppBar `leading: IconButton(arrow_back, onPressed: () => context.pop(_markReadResult))` 替换默认 back 让 result 携带（Flutter 3.41.9 SDK，3.22+ 新 API）。list 端 `_onArticleTap` `await context.push<MarkReadResult>(...)`，仅 `result == failed` 时 setState 回滚 `read_time = 0` + SnackBar；`success` / `skipped` / `null`（OS back）保留 optimistic 走老软一致兜底。OS back 路径 result null 是已知 limitation（PopScope 在 OS back 时 pop 已发生无法携带 result），文档化在 spec 「跨页通信模式 (BATCH-21c)」段。新增 6 widget test：detail 3 case（success/failed/skipped）+ list 3 case（failed rollback / success 保留 / null 保留）。flutter test 542 PASS（baseline 536 + 6 新）。task: 05-22-batch-21c-rss-detail-rollback。

---

### F-W2B-013 [P1 主要][C-性能][rss/article_list]

**File**: `flutter_app/lib/features/rss/rss_article_list_page.dart:357-364`

**问题**: 每次 `_loadArticles` 都 setState 整个 `_articlesBySort` map，触发整个 TabBarView 中所有 tab 的 ListView.builder rebuild（即便只更新了一个 sort）。

**详细**: TabBarView 的 children 列表是 `[for t in _tabs _buildArticleList(...)]`，每次 setState 父组件 build 后所有 tab 的 `_buildArticleList` 都会重新调，里面 `RefreshIndicator + ListView.builder` 也跟着 rebuild。ListView.builder 自身有 viewport 优化，但 4-5 个 tab 同时 rebuild 累计 GC 压力不小。

**建议**: 把每个 tab 的 article 列表抽成 ConsumerWidget 配合 `StateProvider<List<...>>.family((sort))`，仅订阅自己 sort 的 provider；或退而求其次用 `AutomaticKeepAliveClientMixin` 让未激活 tab 不参与 build。

**Resolution (BATCH-21, 2026-05-21，方案 A 退而求其次 KeepAlive)**: 闭环（PRD 选 KeepAlive 不选 family 重构）。`rss_article_list_page.dart` 把 `_buildArticleList` 方法抽成 `_ArticleTabView extends StatefulWidget` + `_ArticleTabViewState with AutomaticKeepAliveClientMixin`；`wantKeepAlive => true`，build 内必须调 `super.build(context)`。`_buildArticleTile` / `_buildThumbnail` 同步从 `_RssArticleListPageState` 私有 method 改为 file-private top-level fn（无状态依赖，可独立提取）。TabBarView children 从 `[for t in _tabs _buildArticleList(context, t.name)]` 改为 `[for (final t in _tabs) _ArticleTabView(key: ValueKey('rss_tab_${t.name}'), sortName: t.name, articles: _articlesBySort[t.name], onRefresh: () => _loadArticles(t.name, refresh: true), onTap: _onArticleTap)]`；ValueKey 让 tab 列表重排时正确复用。父组件 setState 重建 TabBarView 时，KeepAlive 让切走的 tab 保留 ListView state + scroll position（不丢）。

新增 1 case widget test 验证：30 条文章的 tab 滚到中段 → 切到另一 tab → 切回原 tab，验"标题 0"仍不可见（KeepAlive 保留 scroll offset；如失效会回到顶部）。

**未做**：`StateProvider<List<...>>.family((sort))` 完整 per-tab 重构（roadmap 推荐方案）— PRD Out of Scope，~150 行 article_list_page.dart 重写，KeepAlive 是退而求其次方案，最小改动消除 tab 切换 scroll position 丢失 + ListView state 重建问题。

---

### F-W2B-014 [P1 主要][B-正确性][rss/source_manage]

**File**: `flutter_app/lib/features/rss/rss_source_manage_page.dart:191-196`

**问题**: `_onToggleEnabled` 直接修改原 record map（`record['enabled'] = newValue`），跳过重拉列表的代价是 mutation aliasing — 同一个 map 在 `_records` 与 grouped 计算结果中共用，单次 toggle 后 grouping 仍正确，但同 source 同时被另一个 codepath 修改（如 import/delete）会有数据竞态。

**详细**: 这种 in-place 修改在 immutable-data 风格的 Riverpod / setState 流程里属于异类。注释承认"局部更新 record 避免重拉整个列表（也方便测试断言）"，但混合 mutable 与 immutable 状态后期维护风险高。

**建议**: 改用 `_records = List.of(_records)..[idx] = {...record, 'enabled': newValue}`，保持 immutable update。

**Resolution (BATCH-21, 2026-05-21)**: 闭环。`rss_source_manage_page.dart::_onToggleEnabled` 把 `setState(() { record['enabled'] = newValue; })` 改成：

```dart
final idx = _records.indexOf(record);
if (idx < 0) return; // record 已不在列表（被 import/delete 替换）
setState(() {
  _records = List.of(_records)
    ..[idx] = {...record, 'enabled': newValue};
});
```

`List.of(_records)` 复制顶层 list；`{...record, 'enabled': newValue}` 复制目标 record map；旧 `_records` 引用 / 旧 record 引用都不变 —— 调用方持原引用做对比时拿到原值，不会被原地改写。`indexOf` 用 reference equality（Map 没 override `==`），符合"找到 record 自身"语义；若 record 已不在列表（比如导入/删除发生在 await 期间）idx = -1 早返回，不抛错。

新增 1 case widget test 验证：持原 record 引用，toggle 后 `originalRecord['enabled']` 仍是旧值（true，未被原地改），UI Switch.value 已显示新值（false）。

---

### F-W2B-015 [P1 主要][B-正确性][bookshelf/import]

**File**: `flutter_app/lib/features/bookshelf/bookshelf_page.dart:299-306`

**问题**: 解析 importLocalBook 返回 JSON 时 catch 块 `bookId = null`，但 `result['book_id']` 为非 string 类型时同样落入 catch，错误被吞掉。

**详细**: 用户得到的反馈是"导入成功"但拿不到 bookId（不会跳到 reader），看起来像是 silent UX bug。同时 catch (_) 没有 debugPrint，调试时无线索。

**建议**: 改为分别处理 jsonDecode 失败（log + "导入完成但响应格式异常"）和 book_id 缺失（log + 不跳转但不报错）。

---

### F-W2B-016 [P1 主要][A-架构][bookshelf]

**File**: `flutter_app/lib/features/bookshelf/bookshelf_page.dart:122-156`

**问题**: AppBar PopupMenu 共有 9 个跳转项（manage_groups / backup / import_local / read_stats / cache_management / rss_source_manage / rss_favorites / rule_subs / qr_scan），远超出"书架页"职责范围；这是因为没有专门的"工具/设置"二级菜单页。

**详细**: 注释里明确提到这是各批次（11/13/14/15/16/18/19/20）功能逐步追加的结果，呈现典型的"book shelf is the hub" antipattern。settings_page.dart 只保留通知/字体/主题/替换规则 4 项，反而是更专门的页面被空着；rss_favorites 在两处可达（bookshelf 菜单 + rss_source_manage），用户心智模型混乱。

**建议**: 重新规划导航：bookshelf 只保留"书架自身相关"操作（导入本地书、管理分组）；其余移到设置页或独立的"工具"页。可作为独立子任务。

**Resolution (BATCH-18f, 2026-05-21，方案 1 保守拆分)**: 闭环。bookshelf AppBar PopupMenu 从 9 项缩到 4 项，仅保留书架场景高频：`manage_groups`（管理分组）+ `import_local`（导入本地书）+ `qr_scan`（扫码导入）+ `rss_source_manage`（RSS 源管理，与 source_page 风格对齐书源/订阅源同级入口）。其余 5 项移到 `settings_page.dart` "工具"段（与既有 `replace_rules` 共置）：`backup`（备份/恢复）+ `read_stats`（阅读统计）+ `cache_management`（缓存管理）+ `rss_favorites`（RSS 收藏）+ `rule_subs`（订阅源）。`router.dart` 路由表 0 改动（入口位置变更，路径不变）。新增 `test/settings_page_test.dart` 2 case 验证工具段 6 项 ListTile 全部存在 + chevron_right 可点击指示。`flutter analyze` 0 issue；`flutter test` 404/404 PASS（旧 402 + 新 2）。BATCH-18 路线图 6 条 Flutter finding 全部清完（W2A-001/002/003/008 + W2B-016/022 + 衍生 F-W2A-081）。

---

### F-W2B-017 [P1 主要][C-性能][bookshelf]

**File**: `flutter_app/lib/features/bookshelf/bookshelf_page.dart:411-414`

**问题**: 列表/网格切换通过整个 widget tree rebuild，没用 AutomaticKeepAlive，切换 tab 后再切回会重新拉数据（`booksByGroupProvider` 是 future provider，会缓存，但 ListView state 重建意味着滚动位置丢失）。

**详细**: TabBarView + ConsumerWidget 默认 disposes 不可见 tab；用户切到第 5 个 tab 看了一半，回第 1 tab 后再回第 5 tab，滚动 reset 到顶。GridView 同理。

**建议**: `_BookListView` 加 `AutomaticKeepAliveClientMixin`，`wantKeepAlive = true` 并在 build 调 `super.build(context)`。

---

### F-W2B-018 [P1 主要][C-性能][search]

**File**: `flutter_app/lib/features/search/search_page.dart:439-444`，`469-473`

**问题**: SSE 流式搜索每收到一条 result 就 `_results.value = List.unmodifiable(view)` + 重算 precision 过滤，N 条 SSE event 触发 N 次 ListView 全量 rebuild。

**详细**: `applyPrecisionFilter` 是 O(N) 三次遍历；当书源 20+ 个、每源返回 5 条时累计 100+ 次 rebuild 全量列表 + 过滤。`ValueListenableBuilder` 触发的是子树 rebuild，但 ListView.builder 的 itemCount 改变会触发整个 viewport 重算。

**建议**: throttle SSE updates（如 100ms 一批），或仅在 stream 累积到一定数量时触发 setState；同时 precision 过滤结果可缓存（增量计算：新到的条目单独过滤后追加）。

**Resolution (BATCH-18b, 2026-05-19，间接 Resolved)**: 闭环。BATCH-18b 在 search_page.dart 整体重构时删除了 `_doSearchViaSse` 路径（连同 transport / SSE 整组 ~700 行），search 改回纯 Future-based 多书源并行模式。`List.unmodifiable` 在 search_page.dart 中已无残留（grep 0 命中）。F-W2B-018 描述的"SSE 每条 result 都重算 precision 过滤"问题随 SSE 路径删除自然消失。

BATCH-21 PRD 实测确认本 finding 已 Resolved，未做任何额外改动；master findings.md 双 Resolution 标记 (Resolved by BATCH-18b)。

---

### F-W2B-019 [P1 主要][B-正确性][search]

**File**: `flutter_app/lib/features/search/search_page.dart:347-358`

**问题**: 多书源并行搜索时，用户切换关键词 `_doSearch` 会再次跑 `Future.wait(futures)`，但旧的 futures 没法取消（FRB 无 cancel API），结果会"幽灵"覆盖新搜索的结果。

**详细**: 用户输入"剑来" → enter → 同时输入"凡人" → enter；旧"剑来"的 futures 仍在跑，后完成时 `_results.value = ...` 会覆盖"凡人"的结果。`_loading` flag 也跟着变化，导致 UI 抖动。

**建议**: 用 `int _searchSeq` 自增 token，每次 `_doSearch` 检查"我是不是最新一次"再 setState；或退而求其次只在 `mounted && _searchCtrl.text == keyword` 时才更新结果。SSE 路径 `_doSearchViaSse` 同问题。

**Resolution (BATCH-21, 2026-05-21)**: 闭环。`search_page.dart::_SearchPageState` 加 `int _searchSeq = 0;` 字段 + `@visibleForTesting int get debugSearchSeq`。`_doSearch` 入口先 `final seq = ++_searchSeq;` 再走原 await 链；每个 await 后 + finally 内都改 `if (!mounted || seq != _searchSeq) return;`（替代原 `if (!mounted) return;`），共 ~9 处校验点。语义：用户在第一次 search 未完成时启动第二次 → seq 从 1 自增到 2，第一次 await 完成后 `seq=1 ≠ _searchSeq=2` 拦截 early-return，不会写 `_results.value` / 不会改 `_loading`。第二次 search seq=2 与 _searchSeq 一致，正常完成。

SSE 路径已被 BATCH-18b 删除（见 F-W2B-018），不再涉及。

新增 1 case widget test 验证：用 hanging `dbInitializedProvider` future 让两次 `_doSearch` 都悬停在 await 处；第一次输入 "A" 后 `_searchSeq=1`、`_lastSearchKeyword='A'`；第二次输入 "B" 经 `onSubmitted` 触发后 `_searchSeq=2`、`_lastSearchKeyword='B'`；解开 future 后两次 await 都恢复，但旧的 seq 校验拦截，`_lastSearchKeyword` 仍为 'B'（未被旧 future 覆盖回 'A'）。

`grep _searchSeq lib/features/search/search_page.dart` 命中 15 处（声明 + debug getter + 入口自增 + 多个 await 后校验 + finally 内）。

---

### F-W2B-020 [P1 主要][A-架构][source]

**File**: `flutter_app/lib/features/source/source_page.dart:14-43`

**问题**: 测试钩子 `LiveTestRunner` typedef + `debugLiveTestRunnerOverride` global mutable variable + `showLiveTestDialogForTesting` 公开函数全部混在生产代码 file 头部。

**详细**: 这是 testability 漏出到 module API 的重灾区。生产代码读者看到顶部 30 行全是测试基础设施才能开始读 SourcePage 业务。同模式在 bookshelf_page (10 个 override 参数)、qr_scan_page、rss_*_page 重复出现，但 source_page 是最严重的（用了 module-level 可变 global）。

**建议**: 把 typedef + override + showLiveTestDialogForTesting 移到 `test/source_page_test_hooks.dart`（仅 test target 引入），生产代码完全不知道它们存在。需要的话用 `assert` block 或 conditional import 控制。

**Resolution (BATCH-20, 2026-05-21)**: `source_page.dart` 顶部 module-level `LiveTestRunner` typedef + `debugLiveTestRunnerOverride` global mutable 全部删除。新建 `flutter_app/lib/core/services/source_validation_service.dart`：`class SourceValidationService { Future<String> validateLive({required dbPath, required sourceId, required keyword}) → rust_api.validateSourceLive(...) }` + `sourceValidationServiceProvider`。`_LiveTestDialog` 从 `StatefulWidget` 转 `ConsumerStatefulWidget`（state class 转 `ConsumerState`），`runner = debugLiveTestRunnerOverride ?? rust_api.validateSourceLive` 替换为 `ref.read(sourceValidationServiceProvider).validateLive(...)`。**`showLiveTestDialogForTesting` 保留**（带 `@visibleForTesting` 注解的合法 export，与 mutable global 性质不同；属 PRD 显式保留边界）。`source_validation_live_test_test.dart` 2 个 case 迁到 `ProviderScope(overrides: [sourceValidationServiceProvider.overrideWithValue(_FakeSourceValidationService(...))])`，删除 `setUp/tearDown` 重置 `debugLiveTestRunnerOverride` 的样板。task: 05-21-batch-20-settings-testability-cleanup。

---

### F-W2B-021 [P1 主要][B-正确性][cross-feature]

**File**: 多处（bookshelf_page.dart:80-82, search_page.dart:82, replace_rule_page.dart:39 等）

**问题**: `if (mounted) setState(() => ...)` 与 `if (!mounted) return;` 模式混用，没有统一规范。

**详细**: 同一页面两种风格并存（如 search_page line 82 用 `if (mounted) setState`，line 88 用 `if (!mounted) return`）。`mounted` 检查在 PopupMenu 异步分支后频繁缺失，bookshelf_page line 124-156 中 9 个分支只有 popup 自身的 `context.mounted` 检查，没有 setState 后的 mounted check（实际不需要 setState，故没出 bug，但风格上易出错）。

**建议**: 统一在 `core/widgets/safe_setstate.dart` 加 extension `void safeSetState(VoidCallback fn)`；统一用 `if (!mounted) return;` early return 风格。

**Resolution (BATCH-25, 2026-05-21，缩范围)**: 抽 `flutter_app/lib/core/widgets/safe_setstate.dart` 提供 `extension SafeSetState on State<T>` + `safeSetState(VoidCallback fn)` syntax sugar。在 features 层把 31 处 B 模式（`if (mounted) setState(...)`）机械替换为 `safeSetState(...)`，跨 12 个文件。**顺手修一个真实潜在 bug**：`reader_page.dart::_replaceBookSource` 在 `await replaceBookChapters` + `await saveBook` 双 await 后直接 `setState({...})`，缺 mounted 检查，dialog 关闭后用户立即返回会触发 setState-after-dispose；在 setState 前补 `if (!mounted) return;`。3 case widget test 验证 mounted=true 触发 / mounted=false no-op / 多次累积。回归 flutter analyze 0 issue + flutter test 421/421 PASS。

**未做**：C 模式 57 处（`if (mounted) <非 setState>`）含复合条件、Navigator.pop、ScaffoldMessenger、showDialog 多种异质语义，机械替换风险高 ROI 低，留给后续按需重构；A 模式 132 处（`if (!mounted) return;` 早返回）已是推荐风格不动；D 模式 21 处（`context.mounted` 在 Builder 内 BuildContext 上）与 `State.mounted` 语义不同保留。审查完整 audit 见 BATCH-25 archive `prd.md`。

---

### F-W2B-022 [P1 主要][A-架构][cross-feature]

**File**: 多处（settings/backup_page.dart:474-494, webdav_config_page.dart:105-133, search_page.dart:80-83）

**问题**: 各 feature 自行 `getApplicationDocumentsDirectory()` + `File('$dir/foo.json').readAsString` 重复实现 settings IO，没有抽出公共工具。Wave 2A F-003 已点出 16 处类似模式，本 wave 在 features 层又找到 5 处。

**详细**: 各 feature 自己做 IO + jsonDecode + 字段提取，错误处理风格各异（有的 catch 静默、有的弹 SnackBar），没有 schema 校验。webdav.json / search_history.json / settings.json / pendingRoute / 阅读统计 cache 等都是 ad-hoc 实现。

**建议**: 抽 `core/persistence/json_store.dart`：`Future<T> read<T>(String name, T Function(Map) parser, T defaultValue)` + `Future<void> write(String name, Object value)`。features 不再直接接触 path_provider / File。

**Resolution (BATCH-18e, 2026-05-20，方案 A 缩范围)**: F-W2B-022 闭环。BATCH-18c 已建立 `core/persistence/json_store.dart` + `resolvePersistenceDir()` 公开 helper，BATCH-18e 把 features/core 层 6 处 caller 全部收拢到 `resolvePersistenceDir()`：
- `core/cover_cache.dart:30`（封面缓存目录）
- `features/bookshelf/bookshelf_page.dart:280`（透传 Rust FRB importLocalBook）
- `features/bookshelf/book_info_edit_page.dart:286`（封面文件复制）
- `features/reader/widgets/reader_settings_sheet.dart:57-59`（阅读器背景图，唯一与 json_store 完全重复的 Platform 三元式）
- `features/settings/webdav_config_page.dart:101-103`（webdav.json 配置目录）
- `features/settings/backup_page.dart:476-477`（webdav.json 读路径）

顺手修跨平台行为差异：4 处之前直接 `getApplicationDocumentsDirectory()` 不带三元式，桌面端拿到 Documents 目录与 db 路径（Support）不一致；统一走 `resolvePersistenceDir()` 后跨平台对齐。`flutter analyze` 0 issue；`flutter test` 393/393 PASS 维持。`path_provider` import 在 `flutter_app/lib/` 下仅 `json_store.dart` 一处。

**Follow-up — 新 finding (F-W2A-081)**：webdav.json 完整 read-modify-write 模板（"打开 → jsonDecode Map → 字段提取 → 改字段 → jsonEncode → writeAsString"）在 `webdav_config_page.dart:108-117/180-187` + `backup_page.dart:474-494` 重复实现。json_store helper 当前仅支持 `settings.json` 单文件，不能直接迁。修复方向：扩 json_store API 支持任意 fileName（如 `readJsonFile<T>` / `writeJsonFile` / `deleteJsonFile`）+ 迁两处 caller。等价 BATCH-18d audit 列出的方案 B（约 +80 行）。Status: Open（占位，BATCH-18g 处理）。

**注**：BATCH-18e 录入此 follow-up 时误用 ID `F-W2A-058`（已与 `findings-flutter-core.md:677` 的真实 finding "ReaderAutoScroller 模式切换 race" 撞号），BATCH-18g 重新分配为 `F-W2A-081`（master report 主索引同步修正）。

**F-W2A-081 Resolution (BATCH-18g, 2026-05-21)**: 闭环。`json_store.dart` 加 3 个公共 fn `readJsonFile` / `writeJsonFile` / `deleteJsonFile`（整文件 IO，与既有 key-based API 共存），共用 `_writeLock`。`writeJsonFile` 设计为 rethrow（与 `writeJsonKey` 吞错策略不同），让 caller 外层 try-catch 保留 SnackBar UX。`webdav_config_page.dart::_loadConfig` + `_onSave` + `backup_page.dart::_loadWebDavConfig` 三处 caller 全部走新 helper，read-modify-write 模板消除。删 `webdav_config_page.dart` 顶部 `dart:io` + `dart:convert` import；删 `backup_page.dart` 顶部 `dart:io` import（其它代码不再用 File/Directory）。新增 8 个 test case（writeJsonFile round-trip / null on missing / null on malformed / 整覆盖语义 / deleteJsonFile / no-op delete / rethrow on IO error / 共用 mutex 串行化 / settings.json 不要混用约定）。`flutter analyze` 0 issue；`flutter test` 402/402 PASS（旧 393 + 新 9）。

---

### F-W2B-023 [P2 次要][B-正确性][settings/backup]

**File**: `flutter_app/lib/features/settings/backup_page.dart:266`

**问题**: 使用 `'$dir/${_buildBackupFileName()}'` 拼接路径，未用 `path` 包的 `join`，Windows 反斜杠 / 末尾斜杠去重等问题留隐患。

**详细**: 当前主线是 Android，dir 必含 `/` 不带尾斜杠，所以 `$dir/$file` 正常工作。但 PRD 提及未来跨平台扩展，路径拼接应一致用 `path.join`。

**建议**: 使用 `import 'package:path/path.dart' as p; p.join(dir, _buildBackupFileName())`。

---

### F-W2B-024 [P2 次要][E-代码异味][settings/backup]

**File**: `flutter_app/lib/features/settings/backup_page.dart:367-383`，`631-647`

**问题**: ImportSummary 解析逻辑（books / groups / bookmarks / rules / sources / errors）在两处（本地导入 + WebDAV 恢复）重复 ~20 行。

**详细**: 字段解析、`label` 拼接、错误个数处理完全一样，仅 prefix "导入完成: " vs "从 WebDAV 恢复: " 不同。

**建议**: 抽 `String _formatImportSummary(String json, {required String prefix})` helper。

**Resolution (BATCH-24, 2026-05-21)**: 抽 `flutter_app/lib/core/util/import_summary_label.dart::formatImportSummaryLabel(String json, {required String prefix, required String fallback}) → String`。caller 显式传 `fallback` 让 catch 兜底文案在 caller 处可见（本地导入 fallback="导入完成"，WebDAV 恢复 fallback="从 WebDAV 恢复完成"）。两处 caller 各从 ~17 行降到 5 行 + 4 case 单测覆盖完整 JSON / errors > 0 / 字段缺失 ?? 0 / 解析失败 fallback 4 个边界。

---

### F-W2B-025 [P2 次要][B-正确性][settings/backup]

**File**: `flutter_app/lib/features/settings/backup_page.dart:499-505`

**问题**: `_buildRemoteBackupFileName` 生成的文件名 `backup<date>-<dev>.zip` 不含时分秒，同一天多次备份会同名相互覆盖。

**详细**: 注释说"对齐原 Legado `Backup.getNowZipFileName`"，但若上传两次同一天的备份，远端会覆盖第一份；用户感知不到。

**建议**: 加上 hour/min（`backup2026-05-19-1430-Pixel.zip`），或保留同名时上传前重命名（添加 `_2`, `_3` 后缀）。

---

### F-W2B-026 [P2 次要][E-代码异味][settings/webdav]

**File**: `flutter_app/lib/features/settings/webdav_config_page.dart:71-95`

**问题**: 5 个 TextEditingController 字段，dispose 顺序与声明顺序耦合，扩展字段时易漏。

**详细**: 已经 dispose 全 5 个；但若新增"deviceName2"等字段，必须记得在 dispose 内对应加。这是常见漏 dispose bug 模式（已有先例：reader_page 历史 bug）。

**建议**: 用 `final List<TextEditingController> _ctls = [];` 注册 + `dispose` 中统一 `for (final c in _ctls) c.dispose()`；或用 hooks_riverpod 的 useTextEditingController。

---

### F-W2B-027 [P2 次要][B-正确性][settings/webdav]

**File**: `flutter_app/lib/features/settings/webdav_config_page.dart:135-166`

**问题**: `_onTestConnection` 在 url 空时 `ScaffoldMessenger.of(context)` 没有 mounted 检查（line 141）。

**详细**: 用户开页面后立即按"测试连接"按钮，`_loaded` 还是 false 时进不了 build 此 ListView，但理论上若 init 异步路径 + 用户立即点（不存在用户路径），会有时序竞态。

**建议**: 加 `if (!mounted) return;` 一致性。

---

### F-W2B-028 [P2 次要][E-代码异味][settings/cache_management]

**File**: `flutter_app/lib/features/settings/cache_management_page.dart:139-146`

**问题**: clearAllCacheOverride / clearBookCacheOverride 内嵌 PlatformInt64 → int 转换的相同 6 行逻辑。

**详细**: 与 read_stats_page.dart 完全相同，已在 F-W2B-007 提及。

**建议**: 见 F-W2B-007。

---

### F-W2B-029 [P2 次要][A-架构][settings/cache_management]

**File**: `flutter_app/lib/features/settings/cache_management_page.dart:151`

**问题**: 全局清空缓存后只 `ref.invalidate(bookChaptersProvider)`，没有 invalidate 与"是否已下载"相关的 download 进度 provider；若 download_page 同时打开，进度不会归零。

**详细**: 用户在 download_page 看到 50% 进度，回到 cache_management 全局清空后，回 download_page 仍看到旧进度（实际已被清）。

**建议**: 加 `ref.invalidate(downloadTasksProvider)` 兜底，或定义"清缓存"事件总线。

---

### F-W2B-030 [P2 次要][E-代码异味][settings/read_stats]

**File**: `flutter_app/lib/features/settings/read_stats_page.dart:170-186`

**问题**: `_formatRelativeTime` 与 `bookshelf_page.dart:523-535` 同名 helper 完全重复（注释明说"避免无谓抽象"）。

**详细**: 两处实现完全一样（"刚刚 / N 分钟前 / N 小时前 / N 天前 / yyyy-MM-dd"），从代码复用角度应抽公共 lib。

**建议**: 移到 `core/util/time_format.dart`，两边 import；与 F-W2B-022 的 settings IO 抽取一起做。

**Resolution (BATCH-24, 2026-05-21)**: 抽 `flutter_app/lib/core/util/time_format.dart::formatRelativeTime(int sec) → String`。两处私有 helper 删除，bookshelf_page + read_stats_page 各自 import 同一函数。**顺手修隐含 bug**：bookshelf 端原版没有 `if (sec <= 0) return '从未';` early-return，输入 sec=0 会走到末尾返回 "1970-01-01"（书从未读过的场景下显示历史日期）。新 helper 沿用 read_stats 版的 `<= 0 → '从未'` 边界，bookshelf 同步获得修复。+ 7 case 单测覆盖 sec=0 / sec<0 / 30s / 90s / 2h / 5d / >30 天 yyyy-MM-dd 格式 7 个区间。

---

### F-W2B-031 [P3 nice-to-have][E-代码异味][settings/read_stats]

**File**: `flutter_app/lib/features/settings/read_stats_page.dart:192-198`

**问题**: `formatReadDuration(0)` 返回 "0 分"，但 Card 显示"累计阅读时长 0 分"对刚装 app 的用户不友好。

**详细**: 体验细节而非 bug。

**建议**: <60 秒时返回 "<1 分钟"；总和为 0 时显示"暂无记录"。

---

### F-W2B-032 [P1 主要][B-正确性][rss/article_list]

**File**: `flutter_app/lib/features/rss/rss_article_list_page.dart:255-256`

**问题**: `_loadArticles` 的 catch 中调用 `setState(() => _refreshingSort = null)` 后立即调 `ScaffoldMessenger.of(context).showSnackBar`，没有 `if (!mounted) return;` 保护。

**详细**: 异步 await rssGetArticles 失败后，setState 已检查 mounted（line 254 `if (!mounted) return;` 在 try 中），catch 中也有 `if (!mounted) return;`（line 254）但 ScaffoldMessenger 调用在 setState 之后无 mounted 重检；理论上 setState 调用本身在 unmounted 时是 no-op，但 ScaffoldMessenger 抛 assertion。

**建议**: 在 ScaffoldMessenger 调用前加 mounted 检查，或把 try-catch 内 mounted check 提到方法开头并用 early return。

**Resolution (BATCH-21, 2026-05-21，verified clean)**: 闭环（实测无需改动）。审查 `rss_article_list_page.dart::_loadArticles` 当前 catch 块（line 253-259）已是 early-return 风格：

```dart
} catch (e) {
  if (!mounted) return;            // ← line 254 已有早返回
  setState(() => _refreshingSort = null);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('拉取失败: $e')),
  );
}
```

Finding 描述"没有 if (!mounted) return; 保护"略不准 —— 254 行已经有 early-return，后续 setState + ScaffoldMessenger 都安全。BATCH-21 PRD 实测确认本 finding 已 OK，未做任何代码改动；仅在 master findings 标 Resolved-by-BATCH-21 让索引一致。

姊妹 catch 块（`_bootstrap` line 169-175 + `_RssSourceManagePageState._load` 等）抽样审查，均已是 early-return 风格，无需修改。BATCH-25 已完成 features 层 `safeSetState` 系统性扫荡，覆盖了 mounted check 风格统一议题。

---

### F-W2B-033 [P2 次要][C-性能][rss/article_list]

**File**: `flutter_app/lib/features/rss/rss_article_list_page.dart:425-443`

**问题**: 每个 article tile 的缩略图都用 `CachedNetworkImage` + 缺图占位，但所有 tile 共用同一个 `ClipRRect` 包装，没有 const 化；ListView.builder 高频 rebuild 时这些 const 性 widget 会被反复创建。

**详细**: 性能影响小，但可被简单 const 化。同时 thumbnail 默认尺寸 64×64，没设置 `memCacheWidth/Height`，CachedNetworkImage 会按原图尺寸缓存（典型 300×300），内存浪费 5 倍。

**建议**: 加 `memCacheWidth: 128, memCacheHeight: 128`；考虑 placeholder/errorWidget 抽 `static const _defaultIcon`。

---

### F-W2B-034 [P3 nice-to-have][E-代码异味][rss/article_list]

**File**: `flutter_app/lib/features/rss/rss_article_list_page.dart:178-195`

**问题**: `_parseSortUrl` 的回退实现与 Rust 端 `rssGetSortTabs` 同语义，但两侧维护风险——Rust 改了协议 Dart 端不会跟着改。

**详细**: 注释承认"失败时降级解析"，作为容错可接受；但若 Rust 端协议变更（如支持 `name||url` 双竖线），Dart 端不会自动同步。

**建议**: 注释中加版本约定（`// Mirror of core/core-source/.../rss_get_sort_tabs.rs L42-L60`）方便后续 grep 找到 sync 点；或干脆移除 fallback，让 Rust 失败时直接显示错误。

---

### F-W2B-035 [P2 次要][D-安全][rss/article_detail]

**File**: `flutter_app/lib/features/rss/rss_article_detail_page.dart:329-337`

**问题**: "阅读原文" IconButton 点击后只显示"阅读原文功能将在后续批次实装"，但 widget 已显示（用户可能误以为可以使用），且实际目标 URL `widget.link` 没有任何 scheme 校验。

**详细**: 当批次 19+ 实装时，需要确保只 launchUrl 已知 scheme（http/https），过滤 `javascript:` / `intent:` / `file:` 等；现在留空可以，但 TODO 应明确写。

**建议**: TODO 注释加 `// FIXME: 实装时必须用 url_launcher.canLaunchUrl + 仅允许 http/https`。

---

### F-W2B-036 [P3 nice-to-have][A-架构][rss]

**File**: `flutter_app/lib/features/rss/` 整个目录

**问题**: 4 个 page 文件同级，没有公共 `widgets/` / `providers/` / `models/` 子目录，所有 helper / 数据模型 / FRB override 都重复定义在各 page 内。

**详细**: 与 reader/ 模块对比（有 page/ services/ widgets/ state/ 子目录），rss/ 显得扁平。`_buildThumbnail` 在 rss_article_list_page.dart:425 与 rss_favorites_page.dart:213 完全一致。

**建议**: 抽 `rss/widgets/article_thumbnail.dart`、`rss/models/parsed_qr.dart` 等。

---

### F-W2B-037 [P2 次要][E-代码异味][rss/source_manage]

**File**: `flutter_app/lib/features/rss/rss_source_manage_page.dart:111-131`

**问题**: `_groupRecords` 中 keys 排序逻辑写得复杂（`if (a.isEmpty) return 1` 等），可读性差。

**详细**: 4 行 if-else 表达"未分组永远最后"，可改用单行：`keys.sort((a,b) => a.isEmpty ? 1 : b.isEmpty ? -1 : a.compareTo(b))`。

**建议**: 改为 ternary 或抽出 named comparator。

---

### F-W2B-038 [P2 次要][B-正确性][rss/source_manage]

**File**: `flutter_app/lib/features/rss/rss_source_manage_page.dart:150`

**问题**: `File(pickedPath).readAsString()` 没指定 encoding，在 Windows 下读取 UTF-8 BOM 文件可能解析失败。

**详细**: Android/iOS 默认 UTF-8 没问题；但用户从 PC 复制的 RSS 源 JSON（带 BOM）会让 `jsonDecode` 抛 FormatException。当前代码 catch 后只显示"导入失败"，用户难定位。

**建议**: 用 `utf8.decode(await File(p).readAsBytes(), allowMalformed: true)` 或检测 BOM 后剥离。

---

### F-W2B-039 [P3 nice-to-have][E-代码异味][rss/source_manage]

**File**: `flutter_app/lib/features/rss/rss_source_manage_page.dart:181-188`

**问题**: `setEnabledOverride` 默认实现内部又做 PlatformInt64 → int 转换；与 cache_management 等其他页同模式，属于该转换逻辑的第 N 处复制（见 F-W2B-007）。

**建议**: 见 F-W2B-007 抽公共工具。

---

### F-W2B-040 [P3 nice-to-have][B-正确性][rss/favorites]

**File**: `flutter_app/lib/features/rss/rss_favorites_page.dart:73-77`

**问题**: `rssStarList(limit: -1, offset: 0)` MVP 不分页；收藏 1000+ 时一次拉全部 + 一次性渲染 ListView 卡顿。

**详细**: 注释承认"MVP 不做分页"，留作 future work。当前用户量小可接受。

**建议**: 加分页（infinite scroll）；或至少 limit=200 显示"还有更多请到管理页"。

---

### F-W2B-041 [P1 主要][B-正确性][bookshelf]

**File**: `flutter_app/lib/features/bookshelf/bookshelf_page.dart:64-67`

**问题**: `initState` 中 `loadBookshelfGridViewFromDisk().then(...)` 没 await，未捕获 future 完成时 widget 已 unmount 的情况——虽然有 `if (mounted)` 检查，但 future 抛错时 unhandled exception。

**详细**: `loadBookshelfGridViewFromDisk` 是个 Future，`.then` callback 内有 mounted check，但 `.catchError` 没加；如果 path_provider 异常，会出现 unhandled future error → red banner。

**建议**: 用 `_loadGridView()` async 方法 + try-catch debugPrint，避免 dangling Future。

---

### F-W2B-042 [P1 主要][A-架构][bookshelf]

**File**: `flutter_app/lib/features/bookshelf/bookshelf_page.dart:240-247`

**问题**: TabBarView 的 children 直接 `[for t in tabSpec _BookListView(...)]`，每次 sortOrder 改变都重新创建所有 _BookListView 实例（导致内部 ConsumerWidget 重建 + 重新 watch booksByGroupProvider）。

**详细**: sortOrder 是 `_BookListView` 的 final 字段，改变时 widget 等价于"新实例"；Flutter element 复用机制不会保留旧 state（_BookListView 是 stateless ConsumerWidget 倒还好），但 watch 链路全部重建。如果改成 stateful，scroll position 会重置。

**建议**: sortOrder 改为通过 ref.watch 在 _BookListView 内部读取（Riverpod provider），父组件不传——element 类型不变，复用更稳定。

---

### F-W2B-043 [P2 次要][C-性能][bookshelf]

**File**: `flutter_app/lib/features/bookshelf/bookshelf_page.dart:418-446`

**问题**: 列表视图 ListView.builder 内每个 item 用 GestureDetector + Card + ListTile + onTap + onLongPress，DOM 嵌套 5 层；500+ 本书时滚动时 viewport 内的几十个 item 重建 GC 压力大。

**详细**: itemExtent 已设为 72，是个优化；但 Card 内的 ListTile + Row + Text 组合可考虑 const 化或用 ListTile.dense + custom InkWell 替代 Card。

**建议**: 性能 profiling 实测后再优化；优先级 P2。

---

### F-W2B-044 [P2 次要][B-正确性][bookshelf]

**File**: `flutter_app/lib/features/bookshelf/bookshelf_page.dart:537-549`

**问题**: `_buildCover` 用 `Image.file` 的 `cacheWidth: 100, cacheHeight: 150` 强制缩放；但用户在网格视图（每个 item 较大）下也用同尺寸，导致网格大封面变模糊。

**详细**: 列表视图 leading 是 ~50×75，cacheWidth=100 是 2x 倍数；网格 item 高度 ~200，cacheWidth=100 在 3:2 比例下显示宽度~133 → 缩放后模糊。

**建议**: 列表/网格用不同 cacheWidth；或使用 LayoutBuilder 动态计算。

---

### F-W2B-045 [P3 nice-to-have][E-代码异味][bookshelf]

**File**: `flutter_app/lib/features/bookshelf/bookshelf_page.dart:511-519`

**问题**: `_formatBookSubtitle` 与 `dur_chapter_title` / `dur_chapter_time` 字段紧耦合，未来字段改名（如 `last_chapter_title`）需在多处修改。

**详细**: 同字段名也在 reader_page、book_info_edit_page 重复出现。

**建议**: 在 `core/models/book.dart` 中定义 typed Book class，封装这些字段访问。

---

### F-W2B-046 [P3 nice-to-have][E-代码异味][bookshelf]

**File**: `flutter_app/lib/features/bookshelf/bookshelf_page.dart:511-519`

**问题**: 函数名 `_formatBookSubtitle` 与实际行为（"如有阅读记录显示进度，否则显示作者"）不匹配；新读者难理解逻辑分支。

**建议**: 重命名为 `_formatBookProgressOrAuthor` 或添加返回值含义注释。

---

### F-W2B-047 [P2 次要][A-架构][bookshelf/widgets]

**File**: `flutter_app/lib/features/bookshelf/widgets/book_group_dialogs.dart:251-322`

**问题**: `GroupSelectDialog` 内自定义"ListTile + check icon"模拟单选（line 286-288 注释说为避免 RadioListTile deprecation），但同模式在 settings_page.dart:166-172 仍用 RadioListTile + RadioGroup（Flutter 3.32 推荐替代）。

**详细**: 同 codebase 内单选 UI 实现风格不一致：dialog 里用自定义 check tile，settings 主页用 RadioGroup（也对应 Flutter 3.32+ 推荐方式）。

**建议**: 统一全 codebase 单选 UI 用 `RadioGroup` + `RadioListTile`（Flutter 3.32+ API），或抽 `core/widgets/single_select_list.dart`。

---

### F-W2B-048 [P2 次要][B-正确性][bookshelf/book_info_edit]

**File**: `flutter_app/lib/features/bookshelf/book_info_edit_page.dart:115-122`

**问题**: 在 build 内通过 `WidgetsBinding.instance.addPostFrameCallback` setState — 反模式。

**详细**: build 应是 pure；用 postFrameCallback setState 是绕过限制。`bookByIdProvider` 加载完成后直接 `data: (book) { ... }` 重建 widget，应该利用 ConsumerWidget 模式，不要在 build 中 schedule setState。

**建议**: 重构：把 `_bookSnapshot` 改成 `final book = ref.watch(bookByIdProvider(widget.bookId))`，controllers 在 didChangeDependencies 中初始化（仅一次）；或彻底改用 hooks_riverpod 的 useState/useTextEditingController。

---

### F-W2B-049 [P2 次要][C-性能][bookshelf/book_info_edit]

**File**: `flutter_app/lib/features/bookshelf/book_info_edit_page.dart:90-92`

**问题**: `_nameCtl.addListener(() { if (mounted) setState(() {}); })` 每次输入字符都重建整页 widget tree。

**详细**: 目的是让"保存"按钮 enabled 状态跟随 name 是否为空；但用 setState 等于全页 rebuild。

**建议**: 用 ValueListenableBuilder 仅监听 _nameCtl 变化更新 button enabled；或拆出 SaveButton stateful widget。

---

### F-W2B-050 [P3 nice-to-have][D-安全][bookshelf/book_info_edit]

**File**: `flutter_app/lib/features/bookshelf/book_info_edit_page.dart:282-300`

**问题**: 复制封面文件未做大小限制；用户选 100MB 图片会被复制到 documents/covers，占满存储。

**详细**: `File(srcPath).copy(destPath)` 直接复制；也未压缩 / resize。

**建议**: 复制前 stat 文件大小，>5MB 提示用户；或用 image package 直接 resize 到 600×900 后再写。

---

### F-W2B-051 [P2 次要][E-代码异味][search]

**File**: `flutter_app/lib/features/search/search_page.dart:233`

**问题**: `_searchWithSource(dynamic source, ...)` 参数类型 `dynamic` — 可读性差，编辑器无法自动补全。

**详细**: `source` 实际是 `Map<String, dynamic>`，但用了 dynamic 让 `source['id']`、`source['name']` 都不会有类型提示。

**建议**: 改为 `Map<String, dynamic> source`。

---

### F-W2B-052 [P2 次要][B-正确性][search]

**File**: `flutter_app/lib/features/search/search_page.dart:296-314`

**问题**: 添加书架成功后的 SnackBar 文案中 `bookData['name']` 在中间被改写（line 314 显示书名时此时 bookData 已包含 chapter_count 改写但 name 未变），代码看似 OK 但混合 mutable bookData 是脆弱模式。

**详细**: 整个 `_saveResultToBookshelf` 把 bookData 当作 mutable map 多次修改（line 216、283、285、288），易在未来 review 时漏掉某次修改导致 race。

**建议**: 拆成 immutable 阶段：buildInitialBook → saveBook → fetchChapters → buildUpdatedBook → saveBook。

---

### F-W2B-053 [P2 次要][E-代码异味][search]

**File**: `flutter_app/lib/features/search/search_page.dart:13-52`

**问题**: `applyPrecisionFilter` static method 定义在 SearchPage（Stateless container）类内，`@visibleForTesting`。把 pure function 放在 widget class 内只为测试可访问，是组织上的次优。

**建议**: 抽 `lib/features/search/precision_filter.dart`，导出 top-level function。

---

### F-W2B-054 [P3 nice-to-have][E-代码异味][search]

**File**: `flutter_app/lib/features/search/search_page.dart:419-419`

**问题**: SSE 事件 switch 的 `'result'` / `'error'` / `'done'` 字符串 magic constants，未提取为 const。

**建议**: 在 transport.dart 或本文件顶部定义 `const _eventResult = 'result'`。

---

### F-W2B-055 [P2 次要][A-架构][source]

**File**: `flutter_app/lib/features/source/source_page.dart:613-625`

**问题**: `_LiveTestDialog` 是私有 StatefulWidget，但持有大量业务状态（4 个 stage、staticIssues、运行 flag、错误消息）；未来扩展（如增加 stage、并行执行）会让单文件膨胀。

**详细**: 当前 250+ 行的 dialog state 应分离。

**建议**: 移到 `features/source/widgets/live_test_dialog.dart`，与父页面解耦。

---

### F-W2B-056 [P2 次要][E-代码异味][source]

**File**: `flutter_app/lib/features/source/source_page.dart:636-647`

**问题**: stage keys (`'search'`, `'book_info'`, `'toc'`, `'content'`) 是 hard-coded magic strings，与 Rust 端 [`validate_source_live`] 返回值的 stage 字段名隐式契约。

**详细**: Rust 端改名（如 `bookInfo` → `book_info` → `book-info`）会让 Dart 端默默匹配不到。

**建议**: 在 FRB 桥的 contract 文档中明确 stage 名称；或在 Rust 端定义 enum + 用 #[serde(rename_all)] 锁定。

---

### F-W2B-057 [P3 nice-to-have][D-安全][source]

**File**: `flutter_app/lib/features/source/source_page.dart:483-525`

**问题**: `_importFromFile` 直接从用户选的本地 .json 读取后调 `importSourcesFromJson`，没有大小限制 / 内容校验。

**详细**: 攻击者构造的恶意书源 JSON 进入 Rust 端解析（Rust 端 quickjs 沙箱有自己的限制，参考 F-Rust-* 系列），但 Dart 层未做任何 pre-check。

**建议**: 限制文件大小 < 10MB；调用前 quick-validate（顶层是不是 JSON Array）。

---

### F-W2B-058 [P1 主要][D-安全][qr]

**File**: `flutter_app/lib/features/qr/qr_scan_page.dart:88-104`

**问题**: 相机权限拒绝路径未处理 — MobileScannerController 创建后若用户拒绝权限，UI 显示一片黑没有任何提示。

**详细**: `_isRealCameraMode` 只判断 `!kIsWeb && scanResultOverride == null`，没有检查实际权限状态。MobileScanner 内部权限被拒后 onDetect 永不触发，用户无任何反馈。

**建议**: 进页前用 permission_handler 检查 camera 权限；拒绝时显示 "请授予相机权限以使用扫码功能"页 + 跳转设置按钮。

**Resolution (BATCH-05, 2026-05-21)**: 闭环。不引入 `permission_handler` / `app_settings` 包（保持依赖最小）；改用 mobile_scanner v5 自身的权限拒绝信号 —— `MobileScannerController` 是 `ValueNotifier<MobileScannerState>`，权限被拒时 `state.error?.errorCode == MobileScannerErrorCode.permissionDenied`。
- `_QrScanPageState` 加 `bool _permissionDenied` 字段 + `addListener(_onScannerStateChanged)` 监听 controller value changes；检测到 permissionDenied → setState 翻 true；`dispose` 配套 `removeListener`。
- 加 `_PermissionDeniedView`（私有 StatelessWidget）：`Icons.no_photography` 大图标 + "相机权限被拒绝"标题 + "请到系统设置 → 应用 → 当前应用 → 权限 中开启相机权限"引导文案 + "返回"按钮（`context.pop()`）。
- 加 `permissionDeniedOverride` 测试钩子让 widget test 直接置位拒绝状态（mobile_scanner platform channel 在 widget test 环境难 mock）。
- 单测：1 case 验证 `permissionDeniedOverride=true` 时 UI 显示拒绝引导文案、不显示扫码框文案。

PRD Out of Scope：跳系统设置按钮（需要 `app_settings` 或 platform-specific intent）；本批仅给文案引导让用户自行操作。

---

### F-W2B-059 [P2 次要][B-正确性][qr]

**File**: `flutter_app/lib/features/qr/qr_scan_page.dart:280-292`

**问题**: `MobileScanner.onDetect` 内 `for (final b in capture.barcodes) { ... break; }` 只处理第一个 barcode，但 `_detected` 检查放在外层；理论上同帧内多个 barcode 都会进入 for 循环（虽然第一个就 break）。

**详细**: 当前实现 OK（第一个 barcode 后 break），但 `_detected` flag 设置在异步 `_onDetect` 内，下一帧的 onDetect 回调可能在 _detected 设为 true 前再次触发（FFI 回调线程模型不确定）。

**建议**: 将 `_detected = true` 移到 `_onDetect` 调用前的同步块内（line 285 `_detected = true; _onDetect(raw);` 这样的顺序），避免竞态。

---

### F-W2B-060 [P2 次要][E-代码异味][qr]

**File**: `flutter_app/lib/features/qr/qr_import_handler.dart:61-79`

**问题**: `handle` 方法的 6 个 override 参数让方法签名 7 行；类型系统对错误使用 override 完全没有保护（你可以传 `importBookSourcesOverride` 而 type 是 rssSource，不会报错）。

**详细**: 与 F-W2B-004 同问题（override 测试钩子膨胀），qr_import_handler 是 static 类，比 BackupPage 的 widget class 更适合改为 client class。

**建议**: 改为 instance class with constructor injection (`QrImportHandler({required FetchClient fetch, required FrbApi api})`).

---

### F-W2B-061 [P3 nice-to-have][A-架构][qr]

**File**: `flutter_app/lib/features/qr/legado_qr_protocol.dart:50-56`

**问题**: 顶级 `final RegExp` 在每次 import 该 lib 时初始化一次，是预编译的；但 `_bareJsonUrlRegExp` 的 `caseSensitive: false` 应用 `[^\s]+\.json` 部分会让 \\.json 也大小写不敏感，没必要。

**建议**: 可拆为 case-sensitive 的 host 部分 + case-insensitive 的 ext 部分，提高匹配精度；或加注释说明这是有意为之。

---

### F-W2B-062 [P1 主要][A-架构][rule_sub]

**File**: `flutter_app/lib/features/rule_sub/rule_sub_page.dart:31-66`

**问题**: 与 source_page、rss_source_manage_page 重复了大量"列表 + 添加 + 编辑 + 删除 + 导入 + 刷新"模板代码（~400 行 / 共 543 行）。

**详细**: `_load`、`_onAdd`、`_onDelete`、`_showEditDialog`（4 控件 + 单选）几乎是 source_page / rss_source_manage_page 的复刻。Wave 2A 已点出 16 处类似 IO 模板，本 wave features 层又多 3 处。

**建议**: 抽 `core/widgets/list_manage_scaffold.dart` — 接受 List provider + create/update/delete/refresh callbacks 渲染统一 UI。RSS / source / rule_sub 三处都能复用。

---

### F-W2B-063 [P2 次要][E-代码异味][rule_sub]

**File**: `flutter_app/lib/features/rule_sub/rule_sub_page.dart:111-135`

**问题**: `_subTypeLabel` / `_subTypeIcon` 用 switch + magic numbers 0/1/2，没用 enum 表达"sub_type 域"。

**详细**: Rust 端 sub_type 也是 i32 magic number。两端一致地用 magic int 是 contract weak link。

**建议**: Dart 端定义 `enum RuleSubType { bookSource, rssSource, replaceRule }` + `int get value => index`；Rust 端用 `#[repr(i32)]` enum 锁定。

---

### F-W2B-064 [P3 nice-to-have][C-性能][rule_sub]

**File**: `flutter_app/lib/features/rule_sub/rule_sub_page.dart:262-285`

**问题**: 单条刷新使用 SnackBar "正在刷新《name》..."，但若刷新时间长（30s），用户切到别的 tab 后 SnackBar 已消失（默认 4s），无视觉反馈。

**详细**: SnackBar 不适合长任务进度；应使用 LinearProgressIndicator 或 banner。

**建议**: 刷新中用 ProgressIndicator 占位行内 + disable 该行；或用 progress sheet。

---

### F-W2B-065 [P1 主要][B-正确性][replace_rule]

**File**: `flutter_app/lib/features/replace_rule/replace_rule_page.dart:13`

**问题**: `bool _r24NoticeShown` 是 module-level mutable global，破坏 Riverpod / setState 数据流的"单一真理来源"原则。

**详细**: 注释说"不持久化（不靠 SharedPreferences）— 每次启动 app 重新提示一次"，但全局 mutable bool 在测试中难以 reset（widget test 复用同一进程时会让第二个测试拿不到 SnackBar）。同时这个 flag 不在任何 dispose 中重置。

**建议**: 改为 `final _r24NoticeShownProvider = StateProvider<bool>((_) => false);`，测试可 override。

**Resolution (BATCH-20, 2026-05-21)**: `replace_rule_page.dart::_r24NoticeShown` module-level mutable bool 删除。新建私有 `final _r24NoticeShownProvider = StateProvider<bool>((_) => false);`。`_ReplaceRulePageState.initState` 改用 `ref.read(_r24NoticeShownProvider)` 读 + `ref.read(_r24NoticeShownProvider.notifier).state = true` 写。生产行为完全不变（同进程内仍只显示一次 SnackBar 提示），但测试可通过 `ProviderScope.overrides` 重置该 flag 而无需考虑跨测试静态状态泄漏。无新单测。task: 05-21-batch-20-settings-testability-cleanup。

---

### F-W2B-066 [P2 次要][E-代码异味][replace_rule]

**File**: `flutter_app/lib/features/replace_rule/replace_rule_page.dart:336-337`

**问题**: 生成 rule id 用 `'${now}_${Random().nextInt(99999)}'`，碰撞概率虽低但非零（5位随机数空间）；与 search_page、bookshelf 的 sha256-base64 模式不一致。

**详细**: 同一秒内创建 2+ 规则碰撞概率约 1/100k；多用户场景概率更高。

**建议**: 用 uuid 包或 Rust 端生成 id（与 SearchResult 一致的 sha256 模式）。

---

### F-W2B-067 [P3 nice-to-have][C-性能][download]

**File**: `flutter_app/lib/features/download/download_page.dart:104`

**问题**: `LinearProgressIndicator(value: progress)` 每次 `downloadTasksProvider` 刷新都触发整个 Card rebuild；下载中频繁刷新（如 1 次/秒）会让整个列表 rebuild。

**详细**: 当前任务列表小，性能影响不显著。但批量任务 + 高频刷新场景下应优化。

**建议**: 进度部分单独抽 `ProgressRow` ConsumerWidget watch 单条任务的 progress provider；或用 ValueListenableBuilder。

---

### F-W2B-068 [P2 次要][B-正确性][download]

**File**: `flutter_app/lib/features/download/download_page.dart:153-155`

**问题**: `_deleteTask` 后 `ref.invalidate(downloadTasksProvider)`，但没有 `if (context.mounted)` 保护（line 156-162 的 catch 内有 mounted 检查，成功路径反而没有）。

**详细**: 删除任务的 SnackBar 反馈没有 — 只有失败时弹提示，成功时静默；可能误导用户"是不是没生效"。

**建议**: 成功路径加 `ScaffoldMessenger ... '已删除'` snack，并保证 mounted 检查。

---

### F-W2B-069 [P3 nice-to-have][E-代码异味][cross-feature]

**File**: 多处（rss_source_manage_page.dart:362, rule_sub_page.dart:511 等）

**问题**: PopupMenuItem 的 child 用 ListTile + leading + title + contentPadding: EdgeInsets.zero 是文档建议的反模式（PopupMenuItem 内部已有 padding）。

**详细**: Material 3 文档建议 PopupMenuItem.child 直接用 Row + Icon + Text；ListTile 嵌套会浪费高度。

**建议**: 抽 `_popupMenuRow(IconData, String, {Color?})` helper。

---

### F-W2B-070 [P2 次要][A-架构][cross-feature]

**File**: 多处 features (rss_*, source, rule_sub, qr, settings/*)

**问题**: 各 feature 自管 `_loading` / `_error` / `_records` triple — Riverpod AsyncValue 已存在但被绕过；导致每页都自己实现"加载中 → 加载失败 → 数据"三态 UI。

**详细**: cache_management_page、read_stats_page、rss_*_page、rule_sub_page 全是这套手写模式，与 bookshelf / source 用 AsyncValue.when 风格不一致。

**建议**: 全部改用 `FutureProvider` + AsyncValue.when；或抽 `AsyncListPage<T>` widget。

---

## 审查覆盖度自评

### Read carefully（完整通读）
- `flutter_app/lib/features/search/search_page.dart` (918 行)
- `flutter_app/lib/features/source/source_page.dart` (856 行)
- `flutter_app/lib/features/bookshelf/bookshelf_page.dart` (704 行)
- `flutter_app/lib/features/settings/backup_page.dart` (665 行)
- `flutter_app/lib/features/rss/rss_article_list_page.dart` (444 行)
- `flutter_app/lib/features/rss/rss_article_detail_page.dart` (386 行)
- `flutter_app/lib/features/rule_sub/rule_sub_page.dart` (543 行)
- `flutter_app/lib/features/replace_rule/replace_rule_page.dart` (439 行)
- `flutter_app/lib/features/qr/qr_scan_page.dart` (337 行)
- `flutter_app/lib/features/settings/cache_management_page.dart` (313 行)
- `flutter_app/lib/features/settings/webdav_config_page.dart` (300 行)
- `flutter_app/lib/features/bookshelf/book_info_edit_page.dart` (361 行)
- `flutter_app/lib/features/bookshelf/widgets/book_group_dialogs.dart` (328 行)
- `flutter_app/lib/features/rss/rss_source_manage_page.dart` (378 行)
- `flutter_app/lib/features/settings/settings_page.dart` (243 行)
- `flutter_app/lib/features/settings/read_stats_page.dart` (198 行)
- `flutter_app/lib/features/rss/rss_favorites_page.dart` (232 行)
- `flutter_app/lib/features/qr/qr_import_handler.dart` (137 行)
- `flutter_app/lib/features/qr/legado_qr_protocol.dart` (117 行)
- `flutter_app/lib/features/download/download_page.dart` (164 行)

### 完成情况
- ✅ 全部 20 个 in-scope 文件均纵览（read carefully）
- ✅ 总行数 ~8,063 行 100% 覆盖
- ✅ B 正确性维度（mounted check / future await / 资源释放）逐文件检查
- ✅ D 安全维度（凭据存储 / WebView 沙箱 / SSRF / 输入校验）专项检查
- ✅ 跨 feature 一致性（命名 / IO 模板 / override 钩子模式）覆盖
- ⚠️ 未实际跑 `flutter analyze` — 部分隐式 bool 比较 / 类型 cast 警告可能未发现
- ⚠️ 未对每个 feature 的 widget test 文件做配套审查（PRD scope 排除测试代码本身）
- ⚠️ widget tree 深度嵌套 / 过度 setState 范围这类需要 Performance overlay 才能精确量化的问题仅靠 reading 给出方向性建议（多为 P2/P3）

### 已知未深挖的点（留给后续修复子任务自行 re-verify）
- F-W2B-002 SSRF：需要测试实际 dio 请求是否能命中 RFC1918 地址
- F-W2B-010 WebView XSS：需要构造测试 RSS 页面验证 unrestricted JS 行为
- F-W2B-018 SSE rebuild：需要 widget test + Performance overlay 量化实际 fps 影响
- F-W2B-058 相机权限：需要在物理设备上验证 mobile_scanner 在权限拒绝时的具体行为

---

**Wave 2B 完成。** 下一步建议 Wave 3 做"跨层一致性 + 配置 & 构建"汇总。
