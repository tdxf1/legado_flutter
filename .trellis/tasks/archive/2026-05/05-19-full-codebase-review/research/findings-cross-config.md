# Findings — Wave 3 (cross-layer + Android config + build scripts + dependencies)

**Scope**:
- Cross-layer FFI 数据契约 (`flutter_app/lib/src/rust/api.dart` ↔ `core/bridge/src/api.rs`)
- 错误码 / 错误消息 / 日志格式跨层一致性
- Android config (`AndroidManifest.xml` / `network_security_config.xml` / `MainActivity.kt`)
- Gradle / NDK / signing (`build.gradle.kts` × 2 / `settings.gradle.kts` / `gradle.properties`)
- 依赖锁定 (`pubspec.yaml` / `core/Cargo.toml` + 6 sub-crate `Cargo.toml`)
- FRB 配置 (`flutter_rust_bridge.yaml`)
- 构建脚本 (`build_android_debug.sh` / `build_android_release.sh`)
- `flutter_app/android/app/src/main/jniLibs/`

**Reviewed at**: 2026-05-20
**File count**: 18

## 统计

### 按严重度
| Severity | Count |
|---|---|
| P0 严重 | 1 |
| P1 主要 | 20 |
| P2 次要 | 17 |
| P3 nice-to-have | 5 |
| **合计** | **43** |

### 按维度
| 维度 | Count |
|---|---|
| A-架构 | 10 |
| B-正确性 | 3 |
| C-性能 | 3 |
| D-安全 | 12 |
| E-代码异味 | 15 |

### 按模块
| 模块 | P0 | P1 | P2 | P3 |
|---|---|---|---|---|
| FFI 契约 (bridge ↔ Dart api.dart) | 0 | 5 | 2 | 0 |
| 错误消息 / 日志 跨层 | 0 | 2 | 0 | 1 |
| Android Manifest | 0 | 3 | 2 | 0 |
| network_security_config | 0 | 2 | 1 | 0 |
| Gradle / NDK / signing | 0 | 2 | 5 | 0 |
| jniLibs / repo | 1 | 0 | 0 | 0 |
| pubspec.yaml | 0 | 1 | 0 | 1 |
| Cargo workspace 依赖 | 0 | 3 | 4 | 2 |
| frb yaml | 0 | 0 | 1 | 0 |
| build_android_*.sh | 0 | 2 | 2 | 1 |

---

## Findings

### F-W3-001 [P0 严重][D-安全 & A-架构][jniLibs / repo]

**File**:
- `flutter_app/android/app/src/main/jniLibs/armeabi-v7a/libbridge.so` (11.4 MB, 2026-05-14)
- `flutter_app/android/app/src/main/jniLibs/x86/libbridge.so` (15.7 MB, 2026-05-14)
- `flutter_app/android/app/src/main/jniLibs/x86_64/libbridge.so` (15.6 MB, 2026-05-14)
- `flutter_app/android/app/src/main/jniLibs/arm64-v8a/libbridge.so` (18.7 MB, 2026-05-19)

**问题**: 仓库里同时维护 4 个 ABI 的 `libbridge.so` 二进制；构建只编译并刷新 `arm64-v8a/`，其余 3 个停留在 2026-05-14 的旧版本（与 Rust 源码已经不一致），但 `build.gradle.kts` 的 `abiFilters` 只过滤 arm64-v8a，理论上不会被打进 APK；然而以下两个风险并存：

**详细**:
1. 任何后续若有人调整 `abiFilters` 想加 32 位 ARM 兼容，会**直接打进一个 stale 二进制**——其行为与当前 Rust 源码已经分歧（差 60+ commits），可能崩溃、可能产生数据破坏。这是经典的"半成品兼容资产"。
2. ~45 MB 二进制位于 Android 资产路径下而不是 LFS / artifact，每次 `git clone` 都拉它们；批次 b0dfa87 又刚把 arm64-v8a 二进制 push 进去，仓库已显著膨胀。
3. 构建脚本（`build_android_debug.sh:25-26` / `build_android_release.sh:56-57`）直接 `cp` 到固定路径，任何旧 ABI 文件不会被脚本主动清理，只在手 commit 时人眼检查。

**建议**:
1. 立即 `git rm flutter_app/android/app/src/main/jniLibs/{armeabi-v7a,x86,x86_64}/libbridge.so`，并把整个 `jniLibs/` 加进 `.gitignore`（与 build artefact 同等地位）；
2. 在 build script 末尾 `find flutter_app/android/app/src/main/jniLibs -name 'libbridge.so' ! -newer .git/HEAD` 类似的 stale 检测，或先 `rm -rf` 整个 jniLibs 目录再放新文件；
3. 评估是否用 Gradle 任务在编译前自动 invoke `cargo build`，彻底去掉手动 `cp` 这一步；或者从 release 流程把 .so 拉进 GitHub Release artefact，不进 git；
4. 文档明确"jniLibs/* 是 build output，不是源码"。

---

### F-W3-002 [P1 主要][D-安全][Android Manifest]

**File**: `flutter_app/android/app/src/main/AndroidManifest.xml:7-11`

**问题**: `<application>` 没有显式 `android:allowBackup="false"` 与 `android:dataExtractionRules`，等于**默认允许 ADB / Auto Backup 把 app 数据全量备份到 Google 云**，包含 `legado.db`（书源 / 阅读进度 / WebDAV 凭据明文）以及 `legado_local.json`（备份密码明文，见 F-W1A-020）。

**详细**: Android 6+ 默认 `allowBackup=true`，会把 internal storage 同步到 Google Drive。F-W1A-020 已经指出"备份密码明文存盘"——叠加默认 allowBackup，等于密码上云。现在又上线 WebDAV (`webdav_*` API) 把 WebDAV 凭据存进 DB，进一步扩大泄漏面。Auto Backup 默认排除 `no_backup/` 但本端口没有用这个目录。

**建议**:
1. 立即在 `<application>` 加 `android:allowBackup="false"`；或
2. 改成 `android:dataExtractionRules="@xml/data_extraction_rules"` + 一个白名单 XML，把敏感文件（DB、`legado_local.json`、`webdav_*` 相关）显式排除；
3. 与 F-W1A-020 的 Keystore 加固一并做。

---

### F-W3-003 [P1 主要][D-安全][network_security_config]

**File**: `flutter_app/android/app/src/main/res/xml/network_security_config.xml:22-27`

**问题**: `<base-config cleartextTrafficPermitted="true">` 全局允许所有 HTTP 明文流量；与现有 `MainActivity.kt::isPrivateHost` SSRF 黑名单防护互补不足。

**详细**: 注释解释"很多 Legado 书源仍走 HTTP"——这是真实业务约束。但**所有**域都允许 HTTP 等于：
- 任何中间人攻击者（公共 Wi-Fi）可改写书源 JSON / 章节内容 / 替换规则 → 注入恶意 webJs（rquickjs 沙箱不够强，见 F-W1B 系列）
- API server 自己（`core/api-server`）的本地回环已经通过 SSRF 黑名单拦下，但**远程 API server 部署**（端口转发到 LAN/公网）若用户没设 HTTPS，token 也是明文传输

`MainActivity.kt::isUrlSafeForFetch` 只在自定义 WebView/JS bridge 场景内生效；正常 `dio` / `reqwest` 出去的 HTTP 流量不走这个 gate。

**建议**:
1. 把 `cleartextTrafficPermitted` 收窄到 `<domain-config>` 形式，仅对**已知合规的 HTTP-only 书源域**白名单允许；其他全部走 HTTPS-only；
2. 考虑给用户一个 "HTTPS-only mode" 设置开关（默认开），书源测试时若发现 HTTP 直接红字提示；
3. 与 R56 (api-server token) 的设计意图一致——都是"风险显式化"。

---

### F-W3-004 [P1 主要][D-安全][Android Manifest]

**File**: `flutter_app/android/app/src/main/AndroidManifest.xml:12-20`

**问题**: `MainActivity` `android:exported="true"` 但没有显式 deeplink intent-filter 之外的限制；同时 `android:taskAffinity=""` 是空字符串。

**详细**:
1. `exported=true` 是 Flutter 默认模板，但加上 Launcher 之外**没有任何 deeplink intent**，即仅 LAUNCHER 暴露——这是好的；但若日后加 deeplink（rule_sub 订阅 / qr 扫码导入这类场景已经有 in-app 导入流程），需要严格 `android:scheme` + verify。
2. `android:taskAffinity=""` 会让 activity 与系统其它 app 共享 task stack（Strandhogg-类劫持的常见跳板）；之前 commit 应该是为了跨 task 行为修的，但需要与 `launchMode=singleTop` 配合检查。

**建议**:
1. 文档化 `taskAffinity=""` 的修复理由（指向引入它的 commit）；
2. 评估是否改为 `android:taskAffinity="${applicationId}"`（明确隔离）；
3. 加 release CI 跑 `aapt dump xmltree` 做 manifest 静态扫描，监控以后**任何**新加的 exported component。

---

### F-W3-005 [P1 主要][A-架构][FFI 契约]

**File**: `flutter_app/lib/src/rust/api.dart:1-863` + `core/bridge/src/api.rs:全部 109 个 pub fn`

**问题**: FFI 全表用 **JSON-string-as-payload** 模式（"复杂类型使用 JSON 字符串传递，避免 FRB 类型解析问题"——`api.rs:1-3` 注释明示）；这是一种**主动放弃 FRB 类型校验**的设计选择，跨层契约完全靠 caller 自觉。

**详细**:
- ~80% 的 pub fn 签名是 `Result<String, String>`，Rust 端 `serde_json::to_string(&books)`，Dart 端 `jsonDecode(json) as List<dynamic>`，全过程**类型擦除**
- 任何 schema 变更（字段加减 / 重命名）都不会被编译器发现；只能靠运行时 `as Map<String, dynamic>` 然后 `book['某字段'] as String?`，缺字段时 silently 拿到 null
- FRB 已经能生成强类型 record / class（同期项目已普遍这么用），本项目坚持 JSON 化的主因可能是 freezed 联合类型 / Vec<Map> 早期 FRB 支持不全；现在 FRB 2.12 应已不是问题
- `replace_book_chapters_preserving_content` (`api.rs:289`) / `import_sources_from_json` (`api.rs:230`) 等高频路径每次都要做一次 `serde_json::from_str` + `serde_json::to_string` 的双向 marshalling

**建议**:
1. **不必一刀切重构**，但可挑 5-10 条**热路径** + **schema 复杂**的 fn 改成强类型（如 `add_bookmark` 入参改 struct、`get_all_books` 返回 `Vec<BookSummary>`）；
2. 制定一份"何时用 JSON / 何时用强类型"的 spec（建议进 `.trellis/spec/backend/`）：复杂嵌套用 JSON、扁平 1 层用强类型；
3. 与 F-W2A-001 / F-W2A-002（core providers 直接吃 dynamic）一并 Target 修复。

---

### F-W3-006 [P1 主要][A-架构][FFI 契约]

**File**:
- `core/bridge/src/api.rs:107-117` (`update_book_group(id: i64, ...)`)
- `core/bridge/src/api.rs:148-162` (`set_book_group(group_id: i64, ...)`)
- `flutter_app/lib/src/rust/api.dart:62-72` (`PlatformInt64`)

**问题**: `book_groups.id` / `chapters.id` / `read_record.delta_seconds` / `download_size` / `bookmark.ts` 等字段在 FRB 接口都用 `i64` ↔ `PlatformInt64`；但 Dart 端到达 ORM/jsonDecode 后都是 `int`（VM 内是 64bit）/ `num`，**FRB 类型与下游 Dart 实际处理类型不一致**。

**详细**:
- `PlatformInt64` 在 IO target 下是 `int`；在 web target 下是 `BigInt` 包装。`flutter_rust_bridge.yaml` 里只有 `dart_output`，没有指定 target，所以 web 编译时同一份 `api.dart` 会强制要求 caller 传 `BigInt`——但项目实际就是 Android-only。
- 实际 caller 大部分写 `groupId: int` 然后 `as PlatformInt64` 隐式接受；少数地方手动 `BigInt.from(...)` 才能编译过 web，但 web 不在 scope。
- 真正的"i64 必要性"只在 timestamps（毫秒级）和 `download_size` 这两类场景；普通自增 `id` 用 `i32` / Dart `int` 完全够用。

**建议**:
1. 把不需要 64bit 的字段（`book_groups.id` 是 SQLite ROWID，i32 上限 21 亿够用）降级为 `i32`，让 Dart 侧自然用 `int`；
2. 确认 `flutter_rust_bridge.yaml` 是否声明 `c_output: false` / web 是否真的目标，若否则可以全用 `int` 而不用 `PlatformInt64`；
3. 在一份 spec 里固化"i32 vs i64 选型规则"。

---

### F-W3-007 [P1 主要][A-架构 & B-正确性][FFI 契约]

**File**: `core/bridge/src/api.rs:1815-1875` (`rss_get_articles`) + `flutter_app/lib/src/rust/api.dart:699-710`

**问题**: `rss_get_articles` 入参 `sortName: String, sortUrl: String` 是 `""` 表示 "单 URL 模式 / 无 sort"——这种**空串当 None**的 sentinel 与同 API 集合里 `rss_list_articles` 用 `sort: Option<String>` 的方式**不一致**。

**详细**:
- `rss_list_articles` (`api.rs:1881`) Dart 端是 `String? sort`（FRB 自动 Option<&str> ↔ Dart 可空 string）
- `rss_get_articles` 同样的语义却用 `String + ""` 的 sentinel，违反 spec 一致性
- 类似情况见 `add_bookmark` 用 `Option<String>` / `update_download_chapter_status` 用 `Option<String>` 表示可空 ——本项目 Option 的支持是 OK 的，没必要在 rss_get_articles 这一处退化为 sentinel

**建议**: 把 `rss_get_articles` 的 `sortName` / `sortUrl` 改为 `Option<String>`，调用方改传 null；同时检查全 109 个 pub fn 里所有 `""` 当 None 的位置统一收口。

---

### F-W3-008 [P1 主要][D-安全 & A-架构][错误消息 / 日志]

**File**:
- `core/bridge/src/api.rs:740, 768, 774, 835, 849, 1505` (中文 Err)
- `core/core-storage/src/legado_aes.rs:72-114` (中文 Err)
- `core/core-source/src/legado/http.rs:95` (英文 Err `WEBVIEW_REQUIRED:`)
- `core/core-source/src/legado/regex_rule.rs:35` (英文 Err)
- `core/core-source/src/legado/js_runtime.rs:256` (英文 Err)
- `flutter_app/lib/features/search/search_page.dart:292,353,521`（中文 debugPrint）

**问题**: Rust 端错误消息**中英混用**：bridge / parser / aes 大部分中文（如 `"章节内容为空"`、`"PKCS7 反填充失败"`），core-source/legado 子模块多英文（`"WEBVIEW_REQUIRED:"` / `"AllInOne rule pattern is empty"`）。Flutter 端再透传到 SnackBar / 异常文本，UI 层 i18n 完全做不了。

**详细**:
- Dart 侧 `_showError("${e}")` 这种透传方式 → 用户最终看到的可能是中文一行 / 英文一行 / 一会儿一会儿
- 部分错误带"语义前缀"（如 `WEBVIEW_REQUIRED:`）做协议化，但**未文档化也未 enum 化**——这种"基于 String 前缀的隐式类型"是 cross-layer 反模式（spec 已警告，见 `cross-layer-thinking-guide.md` "Implicit Format Assumptions"）
- 与 `WEBVIEW_REQUIRED:` 类似的 sentinel：`api.rs:1505` `"文件解析后无任何章节"`、`http.rs:95` `"WEBVIEW_REQUIRED:"`，分别走中英两种命名风格

**建议**:
1. Rust 端引入一个 `pub enum BridgeError` (用 thiserror)，所有 bridge::api 函数统一返回 `Result<T, BridgeError>` → FRB 自动序列化；
2. 用户面错误文案完全在 Dart 端做（`switch (error.kind)`）；Rust 端只暴露**机器可读的 kind + 可选 detail**；
3. 短期：先把"协议化前缀"（`WEBVIEW_REQUIRED:` 等）抽成常量（如 `core_source::legado::http::ERR_WEBVIEW_REQUIRED`）并在 Dart 端有对应常量，避免拼写漂移。

---

### F-W3-009 [P1 主要][A-架构 & E-代码异味][错误消息 / 日志]

**File**:
- Rust: `core/core-storage/src/*` 几乎每个文件 `tracing::warn!/error!/info!` 各 1-2 处
- Dart: 全代码库 140+ `debugPrint('[ModuleName] xxx failed: $e')`

**问题**: 日志格式跨层完全不统一：Rust 走 `tracing::warn!("...")` （无 prefix tag）+ field-style；Dart 全用 `debugPrint('[ModuleName.Tag] ...')` 字符串拼接。release build 里 `debugPrint` 失效但 tracing 仍输出（看 platform）。

**详细**:
1. **关联性丢失**：用户报问题截屏 logcat → Rust 端 `WARN core_storage::source_dao: ...` 与 Dart 端 `[Reader] ...` 不在一个 logger，无 trace ID 串联
2. **生产 vs 调试不一致**：Dart 端 `debugPrint` release 不输出，但 `tracing` 默认 release 仍输（除非 logger guard）；用户复现 bug 时只剩 native 半边
3. **格式风格差异**：Rust 用 structured fields (`tracing::warn!("msg", field=%val)`)；Dart 全用 string 内插，无字段化

**建议**:
1. 短期：在 Dart 端加 `class Log { static void warn(String tag, String msg, [Object? err]) }` 统一格式，所有 `debugPrint` 走它；release 时 forward 到 platform `Log.w()` 让两端日志能同 logcat 看到；
2. 中期：通过 FRB 给 Rust 端加一个 hook，让 tracing event 也走到 Dart Log 接口（双向 channel）；
3. 撰写 `.trellis/spec/backend/logging-guidelines.md`（目前是 placeholder），把上述约定固化。

---

### F-W3-010 [P1 主要][C-性能][FFI 契约]

**File**:
- `core/bridge/src/api.rs:1018-1109` (`apply_replace_rules`)
- `flutter_app/lib/src/rust/api.dart:451-464`

**问题**: `apply_replace_rules` 入参 `content: String, cache_generation: i64, book_name: Option<String>, book_origin: Option<String>, apply_to_title: bool` ——`content` 是**整章正文**，每次切章节都要从 Dart 复制到 Rust 再返回，single chapter 50KB × FRB JSON marshal 双向来回。

**详细**:
- 阅读器流畅度的瓶颈之一：每次切页 / 切章都走 FRB sync 调用，content 字符串大时 marshal 成本会被记到 UI worker
- 同样的问题见 `replace_book_chapters_preserving_content` (`api.rs:289`)、`import_sources_from_json` (`api.rs:230`)——传整个 chapter list / source list 的 JSON
- F-W1A-019 已经提到 lock 内 SQL io 阻塞主线程；这个 finding 是同一性能债的另一面：**不仅 SQL 在 lock 内，content 也跨 FFI 跑两遍**

**建议**:
1. 把"已读章节"按 `chapter_id` 缓存到 Rust 端 LRU（`OnceLock<RwLock<LruCache<String, Arc<String>>>>`），caller 只传 `chapter_id`；
2. 或改成接受 `&str`（FRB 不复制内部 buffer）+ 返回 `Vec<u8>`（避免 String 二次 alloc）；
3. profile 一次确认 marshal 占比是不是真瓶颈再决定。

---

### F-W3-011 [P1 主要][A-架构][Cargo workspace 依赖]

**File**:
- `core/core-storage/Cargo.toml:25-26` (`base64 = "0.21"`, `md-5 = "0.10"`)
- `core/core-source/Cargo.toml:27` (`base64 = "0.22"`, `md5 = "0.7"`)
- `core/api-server/Cargo.toml` (`base64 = "0.22"`)
- `core/core-net/Cargo.toml:23` (`base64 = "0.21"`)
- 全 workspace `Cargo.toml`

**问题**: 同一 workspace 内 6 个 crate 各自声明依赖版本，存在 3+ 处版本不一致：
- `base64`：core-storage / core-net 用 `0.21`，core-source / api-server 用 `0.22`
- `md5`：core-storage 用 `md-5 = "0.10"`（RustCrypto 系列）；core-source 用 `md5 = "0.7"`（旧版 / 不同维护者）—— **两个完全不同的 crate**
- `urlencoding`：core-net 用 `"2"`，core-source 用 `"2.1"`
- `zip`：core-storage 用 `"2"`，core-parser / core-source 用 `"0.6"`

**详细**:
1. cargo 会同时编译两份 base64 crate（0.21 + 0.22）、两份 zip crate（0.6 + 2.x），bridge crate 链接时**两份都进 .so**——19MB libbridge.so 里有相当一部分是冗余依赖
2. `md5` (legacy) vs `md-5` (RustCrypto) 接口完全不同，未来若有人复制粘贴代码（"在 core-storage 这样写"）拿去改 core-source 会立刻不编译
3. 没有 `[workspace.dependencies]` 集中声明，每加一个依赖都要在 6 个 Cargo.toml 里手对版本

**建议**:
1. 立即在 `core/Cargo.toml` 加 `[workspace.dependencies]`，集中管理 base64 / zip / serde / serde_json / tokio / chrono / uuid / regex / encoding_rs 等共用依赖；各子 crate 改成 `base64 = { workspace = true }`；
2. `md5` 全部统一到 `md-5`（RustCrypto 同生态）；
3. 把 `cargo tree --duplicates` 跑一次清单贴进本 finding 后续 PR；
4. 写进 `.trellis/spec/backend/quality-guidelines.md`：禁止子 crate 内联版本号。

---

### F-W3-012 [P1 主要][A-架构 & E-代码异味][Cargo workspace 依赖]

**File**: `core/bridge/Cargo.toml` + `core/api-server/Cargo.toml` + `core/core-source/Cargo.toml`

**问题**: bridge 与 api-server 都依赖 `core-source` / `core-storage` / `core-net` / `core-parser`——形成一种"两个上层各连四个底层" 的 fan-in；但 `core-source` 又**反向依赖 `core-storage`**（`Cargo.toml:51`），破坏分层。

**详细**:
- 原意大概率是 core-source 需要把 JS 解析的中间结果落进 SQLite 缓存。但这就让"解析层依赖存储层"——按 spec 通常是反过来的（存储层不该懂业务，业务层用存储）
- 这种循环让单元测试 core-source 时必须连 SQLite（实际看 dev-deps 用了 tempfile）
- `bridge` 同时依赖 4 个底层，且本身就是"FFI thin wrapper"——理想是 `bridge → core-source → core-net/parser/storage` 单向流，bridge 不直接 reach core-storage

**建议**:
1. 评估能否把 core-source 内的 SQLite cache 抽成 trait，由 caller (bridge / api-server) 注入实现，core-source 只 `Box<dyn Cache>`；
2. 让 bridge 不直接依赖 core-storage，所有 DB 操作走 core-source 或单独的 facade；
3. 写 `.trellis/spec/backend/directory-structure.md` 把"允许的依赖方向矩阵"画清楚。

---

### F-W3-013 [P1 主要][D-安全][Gradle / signing]

**File**: `flutter_app/android/app/build.gradle.kts:48-54`

**问题**: `release { signingConfig = signingConfigs.getByName("debug") }` —— **release build 用 debug keystore 签名**，注释也承认"仅适合个人分发"。

**详细**:
1. Debug keystore 是 SDK 安装时自动生成、对开发者公开的密钥；任何拿到 APK 反编译 + 用同 debug key 签名的 fork 都能在用户设备上替换升级（debug key 全网公开 → 任何攻击者都能伪造你的 APK）
2. 与 `build_android_release.sh` 一起组成"我们打 release"的语义，但 release 安全模型完全是 debug；用户从 GitHub Release 下载 APK 装好以后，**任何攻击者拿到 debug.keystore 就能签名 patch 进同包**
3. 注释"上架前需替换为正式签名"是默认假设——但 Repository 没有明示有 release keystore，CI / 个人分发仍走 debug key

**建议**:
1. 立即引入 `flutter_app/android/key.properties` + `release.keystore`（gitignore），release build 必须读这个文件签名；
2. 在 README 加"如何生成 release keystore" 文档；
3. CI 可以保留 debug-signed dev-build，但 GitHub Release 工件必须是 release-signed；脚本 `build_android_release.sh` 在没有 `key.properties` 时直接拒绝构建。

---

### F-W3-014 [P1 主要][A-架构][Gradle / signing]

**File**: `flutter_app/android/app/build.gradle.kts:48-54`

**问题**: `buildTypes` 没有定义 `minifyEnabled` / `proguardFiles`，release build 不做 R8 / shrinking / obfuscation。

**详细**:
1. APK 体积偏大（19MB libbridge.so + Flutter runtime + Dart code），但 Dart AOT 已 tree-shake；Java/Kotlin 侧（虽不多）完全没 R8。MainActivity.kt 的 1200+ 行 JS bridge 全名暴露
2. 关键反编译保护：JavascriptInterface 的方法名、token 校验逻辑、SSRF 黑名单字段名等若关键路径需要混淆
3. R8 同时也能减少 APK 体积、catch 一部分潜在反射 bug（用 keep rules 显式声明）

**建议**:
1. release `minifyEnabled = true` + `proguardFiles getDefaultProguardFile("proguard-android-optimize.txt")` + 项目专属 `proguard-rules.pro`；
2. 配套 `-keep class io.legado.app.flutter.MainActivity$LegadoJsBridge { *; }` 防 JavascriptInterface 方法名被混淆；
3. 跑一次 release build + 真机回归（特别是 webview JS bridge）确认不破。

---

### F-W3-015 [P1 主要][D-安全][Android Manifest / WebView]

**File**: `flutter_app/android/app/src/main/AndroidManifest.xml` 全文 + `MainActivity.kt:300` `webView.addJavascriptInterface(...)`

**问题**: `LegadoJsBridge` 通过 `addJavascriptInterface(LegadoJsBridge(...), "legadoNative")` 注入了 50+ 个 `@JavascriptInterface` 方法（http / cacheGet / aesCrypt / readFile / unzipFile 等），暴露给加载的页面 JS 直接调用。

**详细**:
- 虽然 `isAllowedWebViewUrl` 拦了私网地址，但**只要书源页面是 http(s)、host 不在 SSRF 黑名单**，加载的页面 JS 就能调 `legadoNative.readFile('/data/data/.../legado.db')`（受 `resolvePath` sandbox 限制）/ `legadoNative.downloadFile(url, path)` 等
- `resolvePath` (`MainActivity.kt:1040`) 把所有 path 限制在 `cacheDir/legado_webview/` 之内，是好的；但 50+ 个 method 的攻击面密度本身就大，任一边界 bug 都可能 RCE
- `aesCrypt` / `aesEncodeToBase64String` 等加密 oracle 暴露给 untrusted 页面 JS——可被用于 padding oracle attack
- WebView 注入的设计假设是"webJs 是用户信任的书源 JS"——但书源是 imported by user from 互联网/QR，trust boundary 模糊

**建议**:
1. 把 `LegadoJsBridge` 注入限制为**只在执行用户的 webJs 时启用**（先 `removeJavascriptInterface` → `loadUrl` → `evaluateJavascript(webJs)` → 立即 `removeJavascriptInterface`）
2. 把"高危"方法（`readFile` / `downloadFile` / `unzipFile` / `aesCrypt`）拆出来用 capability flag 控制，默认 off，只在书源 explicit opt-in 时打开
3. 撰写一份 `WebViewBridgeThreatModel.md` 显式记录对每个 method 的威胁分析；后续加 method 必须更新此文档。

---

### F-W3-016 [P1 主要][B-正确性][build_android_*.sh]

**File**: `build_android_release.sh:60-65`

**问题**: release script 第 3/4 步是 `flutter analyze` + `flutter test`，跑在 `cd flutter_app` 之后；但前面已经做完 Rust cross-compile + cp .so —— 如果 analyze / test 失败，**前面的 .so 已经污染 jniLibs**。

**详细**:
1. release 流程的语义假设是"全绿才打 APK"——但脚本顺序违背了"先 quality gate，后构建产物"：第 1/2 步先 produce 副作用文件（jniLibs 下覆盖），第 3 步才 quality 检查
2. 失败后再次启动脚本，第 1 步会重新覆盖；但若用户 ctrl+C 在 step 1 / 2 之间，新旧 .so 混合，无幂等性兜底
3. 没有 `git_status_clean` 校验后的失败路径回退 / 不会自动 revert jniLibs

**建议**:
1. 调整顺序：先 `flutter analyze` + `flutter test`（在仅 Dart 改动时不必先编 .so），全绿后再 cargo build + cp + flutter build；
2. 或者在脚本入口先检测 jniLibs 是否 dirty，是的话先 `git checkout` 还原；
3. 或更简单：把 cp 改成"build 临时目录 → 在 flutter build 时通过 `--source-map-base` / `srcDirs` 指向那个目录"，永远不污染 jniLibs。

---

### F-W3-017 [P1 主要][E-代码异味 & A-架构][pubspec.yaml]

**File**: `flutter_app/pubspec.yaml:14-56`

**问题**: 依赖全部用 `^X.Y.Z` 范围版本，没有 `pubspec.lock` 提交（看 `.gitignore` 应该排除）；同时 `flutter_riverpod` / `freezed` / `freezed_annotation` 用 `^2.4.0` 但 `mobile_scanner` 5.x、`flutter_local_notifications` 18.x、`go_router` 14.x 已是更新世代——版本节奏不一致，可能埋兼容陷阱。

**详细**:
- `^` 范围只锁主版本号；下个 patch release 自动滚动。CI 重跑同 commit 也可能拉到新版本
- 项目没在 README 强调"必须 commit `pubspec.lock`"，但根据 Flutter 应用 conventions，application-level 项目（非 library）**应该** commit `pubspec.lock` 保证可复现
- riverpod 2.x 已发布 3.x；freezed 2.x 已发布 3.x —— 没立即升级 OK，但要文档化"为什么停在 2.x"

**建议**:
1. 立即 `git add -f flutter_app/pubspec.lock`（如果 .gitignore 排除了，删除排除项）；
2. 在 `.trellis/spec/` 加一份 `dependency-policy.md` 写"app-level 锁 lock，library 不锁"；
3. 跑一次 `flutter pub outdated` 把过期依赖列表贴进 prd 末尾或单独一个修复任务；
4. 评估 `mobile_scanner` 5.x 已有的安全 / 性能修复是否需要升级。

---

### F-W3-018 [P1 主要][D-安全][build_android_release.sh]

**File**: `build_android_release.sh:38-46`

**问题**: 工作区脏检查只 grep `^??` 排除新文件，不阻断打包；用户回车 y 即继续 build —— release artefact 可能包含未提交改动。

**详细**:
1. release APK 的 commit hash 嵌在文件名里 (`-${COMMIT_SHORT}`)，但实际 artefact 内容**与该 commit 的 git 内容不严格对应**——若有 unstaged / uncommitted 改动也会被打进去
2. 用户后续 push 该 commit 到 GitHub，下载者按 commit hash 去 reproducible build，结果对不上 SHA256
3. release build 应该是 reproducible 的，至少强制要求 clean 工作区 / 单独 staging area

**建议**:
1. release script 强制 `git diff --quiet || exit 1`，移除"问 y/N"的妥协；
2. 或者复制源码到 `dist/build-stage/` 临时目录构建，确保 artefact 与 commit 严格对应；
3. 写进 README 的 release flow。

---

### F-W3-019 [P1 主要][A-架构 & E-代码异味][FFI 契约]

**File**: `core/bridge/src/api.rs:474-580` (`search_with_source_from_db_v2` / `search_with_source_from_db` / `get_chapter_content_with_source_from_db`)

**问题**: 同一语义有 2 个 fn (`v2` 与 non-v2)；`v2` 用 `[{"ok":true,"data":[...]}]` / `[{"ok":false,"error":"..."}]` 包装结果，non-v2 直接返回 array——**两套契约同时存在**而无 deprecation 标记。

**详细**:
- `searchWithSourceFromDbV2` (`api.dart:263`) 注释说"包装结果"；`searchWithSourceFromDb` 没说，看代码是 plain array
- 调用方 (`flutter_app/lib/features/search/search_page.dart` / `download_runner.dart`) 用哪个？需要 grep；如果新代码已迁到 v2，旧 fn 是死代码
- 这是典型的 "API v1 / v2 并存且没 sunset 计划"

**建议**:
1. 立即 grep 调用方，把 non-v2 标记为 `#[deprecated(note = "use search_with_source_from_db_v2")]`；下次 PRD 显式删除；
2. 或反过来——若 v2 包装层多余，统一回 plain array；
3. 在 Rust 端 spec 加"FFI 不允许同 fn 多版本并存超过 1 个 release"。

---

### F-W3-020 [P1 主要][D-安全][Cargo workspace 依赖]

**File**:
- `core/bridge/Cargo.toml` (没有 `tokio-util` / `secrecy` / `zeroize`)
- `core/core-storage/src/legado_aes.rs` (含明文 key 的 `Vec<u8>`)
- `core/api-server/Cargo.toml:18` (`subtle = "2"` 已加但未广泛用)

**问题**: 工作区缺少敏感数据"零化"基础设施（`zeroize` / `secrecy` crate）；密码 / token / WebDAV 凭据等在 Rust 内存里以普通 `String` / `Vec<u8>` 形式存在，函数返回后内存不会主动清空。

**详细**:
- `set_backup_password` (`api.rs:1407`) → `password: String` → 序列化进 JSON → 写盘；过程中 `password` 在堆上一直存在到 GC，攻击者拿到 process dump 还能读出来
- `webdav_upload_backup` (`api.rs:1309`) `password: String` 全程明文
- `subtle = "2"` 已引入做 token 比较的 constant-time，但只解决了"timing attack"，没解决"内存残留"

**建议**:
1. 引入 `zeroize = "1"` + `secrecy = "0.8"`；密码 / token 类入参用 `SecretString`；
2. WebDAV / api-server token 类的 storage 字段用 `Secret<String>`；
3. 写 `.trellis/spec/backend/quality-guidelines.md` 强制"敏感字段必须 SecretString"。

---

### F-W3-021 [P1 主要][D-安全][network_security_config 缺失项]

**File**: `flutter_app/android/app/src/main/res/xml/network_security_config.xml:22`

**问题**: 缺少 `<pin-set>` / 证书 pinning 配置；本地 `core/api-server` 走 HTTP（loopback OK），但远程 WebDAV / 书源若用户走自部署 NAS 需要 HTTPS，攻击者拿到泄漏的 root CA 仍能 MITM。

**详细**: 与 F-W3-003 互补——cleartext 是"允许 HTTP"，pinning 是"HTTPS 时验证特定证书"。两个互不干涉。但本端口都没做：
- WebDAV 已知是个人 NAS 场景（用户填 https URL + user + pass），用户自己填的 URL 我们 pin 不了
- 书源也是用户从 QR / URL 导入，pin 不了

但**对 api-server 自部署**场景（用户在 NAS 跑 api-server，APP 远程接入）有 pin 机会：让用户在 settings 填 server URL 时 capture 一次证书 fingerprint。

**建议**:
1. 不必全局 pin，但给 api-server URL 加个"首次连接可信任 fingerprint" UI flow（TOFU 模式）；
2. 或允许用户手动指定"可信证书指纹列表"。

---

### F-W3-022 [P2 次要][D-安全][Android Manifest]

**File**: `flutter_app/android/app/src/main/AndroidManifest.xml:11`

**问题**: 缺少 `android:enableOnBackInvokedCallback="true"` (Android 13+ predictive back gesture) 与 `android:supportsRtl="true"`（虽然内容是中文但 i18n 准备）。

**建议**: 若不打算支持，加注释说明；若支持，按 Flutter 3.16+ 的迁移文档处理。

---

### F-W3-023 [P2 次要][D-安全][Android Manifest]

**File**: `flutter_app/android/app/src/main/AndroidManifest.xml:39-47`

**问题**: `<queries>` 只列出 PROCESS_TEXT / TTS_SERVICE；但代码 `share_plus` 包会调 ACTION_SEND，需要相应 query；`mobile_scanner` 用 CAMERA 已在 manifest 但若以后调原生 picker 也需要 query。

**建议**: 补充 `<intent><action android:name="android.intent.action.SEND"/></intent>` 等 share / scanner 相关查询；用 lint `QueryAllPackagesPermission` 兜底。

---

### F-W3-024 [P2 次要][A-架构][network_security_config]

**File**: `flutter_app/android/app/src/main/res/xml/network_security_config.xml:28-33`

**问题**: `<debug-overrides>` 信任 user CA，配合 `BuildConfig.DEBUG` 旁路；但**没有 `<domain-config cleartextTrafficPermitted="false">` 给已知 HTTPS-only 域**做 hard enforcement。

**建议**: 给 `api-server` 远程部署的常见域名（如 `*.legado.app` 假设有）加 HTTPS-only domain config；或者给用户在 settings 填的 api-server URL 默认 reject http://。

---

### F-W3-025 [P2 次要][E-代码异味 & A-架构][Gradle / NDK]

**File**:
- `flutter_app/android/app/build.gradle.kts:11` (`ndkVersion = "28.2.13676358"`)
- `build_android_debug.sh:11` / `build_android_release.sh:17` (`NDK_VER="28.2.13676358"`)
- README "Android NDK: 28.2.13676358"

**问题**: NDK 版本号在 3 处硬编码（gradle / 2 个 build script / README）；任何升级都要 4 处同步，遗漏即 mismatch。

**建议**: 抽到 `flutter_app/android/gradle.properties` 的 `legado.ndkVersion` property，gradle 与 build script 都从那里读；README 用 `grep` 注释指向源。

---

### F-W3-026 [P2 次要][E-代码异味][Gradle]

**File**: `flutter_app/android/app/build.gradle.kts:31`

**问题**: `applicationId = "io.legado.app.flutter"` 与原 Legado app 同一根命名空间 `io.legado.app`——可能与原 Legado / Legado-MD3 安装包冲突（用户同时装了原 Legado 和本 fork）。

**详细**: applicationId 是 Android 唯一标识，重复会导致 install fail / 升级到错误 app。`io.legado.app.flutter` 比 `io.legado.app` 多一段，理论可共存；但建议加显式注释说明"为什么用这个命名"以及"是否考虑独立 namespace"。

**建议**: 在 build.gradle.kts 加一行注释说明命名策略；考虑 release build 用 `io.legadoflutter.app` 或类似独立 namespace 减少混淆。

---

### F-W3-027 [P2 次要][E-代码异味][Gradle]

**File**: `flutter_app/android/app/build.gradle.kts:30-32`

**问题**: 残留 `// TODO: Specify your own unique Application ID` 与 `// TODO: Add your own signing config` Flutter 模板生成注释——一个项目接近 release 的状态不应保留 TODO 模板注释。

**建议**: 删除 TODO 注释或替换为 ADR-lite 形式说明决策。

---

### F-W3-028 [P2 次要][E-代码异味][Gradle]

**File**: `flutter_app/android/build.gradle.kts:8-17`

**问题**: 自定义 `buildDirectory` 改到 `../../build`（项目根的 `build/`），但 `subprojects { project.evaluationDependsOn(":app") }` 同时打开依赖求值——没有注释说明动机。

**建议**: 加注释说明为什么要把 build dir 移出 `flutter_app/android/`；或评估是否仍必要。

---

### F-W3-029 [P2 次要][C-性能][Gradle]

**File**: `flutter_app/android/gradle.properties:1-4`

**问题**: 没有显式 `kotlin.incremental=true`、`org.gradle.daemon=true`、`android.enableR8.fullMode=true`；JVM heap 2GB 在 24GB 内存机器上偏低。

**建议**: 评估增加上述属性；4GB heap 对 R8 / lint 任务更稳。

---

### F-W3-030 [P2 次要][E-代码异味][Cargo workspace]

**File**: `core/bridge/Cargo.toml:24-25` (重复 `tempfile = "3"` 在 deps 与 dev-deps)

**问题**: `tempfile = "3"` 同时出现在 `[dependencies]` (`l 22`) 与 `[dev-dependencies]` (`l 25`)——dev-deps 是冗余项。

**建议**: 删除 dev-dependencies 里的 tempfile；cargo 自动包含 deps 的依赖供 test 用。

**Resolution (verified clean by BATCH-23, 2026-05-21)**: 已修复。`core/bridge/Cargo.toml:25-26` 现在仅在 `[dependencies]` 一处含 `tempfile = { workspace = true }`，注释明确说明"统一进 [dependencies] 即够；dev-deps 不再重复"。修复发生在某次早前批次（具体 commit 难追溯，可能 BATCH-06 workspace deps 整理时一并解决），本批仅核实代码与文档对齐 + 补 Resolution 标记。

---

### F-W3-031 [P2 次要][E-代码异味][Cargo workspace]

**File**: `core/core-source/Cargo.toml:18-23, 60-62`

**问题**: 注释 "keep reqwest only for backward compat" + 实际仍 active 依赖 `reqwest` —— 注释与代码状态不一致；同时同时依赖 `ureq` + `reqwest` 两个 HTTP 客户端是反模式。

**建议**: 决定到底用哪个，删另一个；ureq 是同步 / reqwest 是异步，两者并存意味着调用方需要区分上下文。如果当前设计就是"async 路径用 reqwest，sync 路径用 ureq"，写进 spec。

---

### F-W3-032 [P2 次要][E-代码异味][Cargo workspace]

**File**: `core/core-source/Cargo.toml:54-58` (`features` 中 `js-quickjs` `js-boa` 二选一)

**问题**: feature flag `js-quickjs` (default) 与 `js-boa` 互斥但**没用 `mutually-exclusive-features` 校验**；用户启用 `--features js-boa` 时 quickjs 不会自动 disable，两个都被 link。

**建议**: 在 lib.rs 加 `#[cfg(all(feature = "js-quickjs", feature = "js-boa"))] compile_error!("...");`；CI 跑 `cargo check --no-default-features --features js-boa` 验证。

---

### F-W3-033 [P2 次要][E-代码异味][Cargo workspace]

**File**: `core/api-server/Cargo.toml:1-4`

**问题**: `edition = "2021"` 而 README 说"Rust edition 2024"——需求文档与 Cargo.toml 不一致。同样 `core/bridge/Cargo.toml` 用 `2021`。

**建议**: 统一到 README 声明的 edition（2024 是 nightly 特性，需确认 stable 已 land）；或更新 README 改回 2021。

---

### F-W3-034 [P2 次要][E-代码异味][build_android_*.sh]

**File**: `build_android_debug.sh:34` (`adb install -r ... || adb install ...`)

**问题**: `||` fallback 模式静默吃错——用户看到 "Done" 但其实是第 2 次 install 也失败的边缘场景没有清晰报错。

**建议**: 改成显式 if-else，第 2 次失败时打印诊断信息（adb devices 输出 / 设备状态）。

---

### F-W3-035 [P2 次要][C-性能][build_android_*.sh]

**File**: `build_android_debug.sh:22` / `build_android_release.sh:51`

**问题**: 每次都全量 `cargo build --release`，没有 `--locked`。CI / local rerun 时若 Cargo.lock 漂移，build 不可复现。

**建议**: 加 `--locked` flag（要求 Cargo.lock 必须 commit）；同时在 CI 单独 step 跑 `cargo update --dry-run` 监控版本漂移。

---

### F-W3-036 [P2 次要][E-代码异味][frb yaml]

**File**: `flutter_rust_bridge.yaml:1-3`

**问题**: 配置只有 3 行（`rust_input` / `rust_root` / `dart_output`），缺 `rust_output` / `dart_root` 显式声明；如果 future FRB 版本默认值改变，behavior 会突变。

**建议**: 显式声明所有路径；同时加注释说明"哪些字段被生成 / 哪些不生成"。

---

### F-W3-037 [P2 次要][B-正确性][FFI 契约]

**File**: `core/bridge/src/api.rs:42-50` + 全部返回 JSON 字符串的 fn

**问题**: Rust 端 `Vec<Book>` → `serde_json::to_string()` 时若 vec 为空会返回 `"[]"`；Dart 端 `jsonDecode("[]") as List<dynamic>` OK。但若 caller 传入 `db_path` 不存在 / 空 DB，Rust 端拿到的 SQL 结果是**空 vec**而不是 error——空数据与"DB 缺失"无法区分。

**详细**: `getAllBooks` 空数据返回 `[]`，与"DB 还没初始化"返回 `Err("...")` 在 UI 都会被吞成"空书架"。

**建议**: 至少在 `init_legado` 后第一次 caller 走完整 round-trip 之前，bridge 端记录 `INITIALIZED: bool`，未初始化时主动 fail-fast；Dart 端区分两种状态展示不同 empty UI。

---

### F-W3-038 [P2 次要][B-正确性][FFI 契约]

**File**: `flutter_app/lib/src/rust/api.dart:608` (`getTotalReadTime` 返回 `Future<PlatformInt64>`)

**问题**: 返回 Long 但单位是"秒"——Dart 端拿到一个 int 但**单位约定**只在 doc comment 里。如果未来 Rust 端改成毫秒，Dart 端编译过但语义全错。

**建议**: 用一个 newtype-like 包装（`Duration` 或自定义 typedef）；或返回 ISO8601 string 强制 caller parse。

---

### F-W3-039 [P3 nice-to-have][E-代码异味][Cargo workspace]

**File**: 全 workspace `Cargo.toml`

**问题**: 缺 `[workspace.package]` 集中声明 version / authors / license / repository；当前每个 crate 单独 `version = "0.1.0"`，统一更新困难。

**建议**: 引入 `[workspace.package]`，子 crate 用 `version.workspace = true` 等。

---

### F-W3-040 [P3 nice-to-have][E-代码异味][Cargo workspace]

**File**: 全 workspace `Cargo.toml`

**问题**: 缺 `[lints]` 配置；`cargo clippy` / `cargo fmt` 没有项目级强制规则。

**建议**: 加 workspace 级 `[lints.clippy]` 与 `[lints.rust]`；启用 `unwrap_used = "warn"` 给 P0/P1 unwrap 滥用问题做 baseline。

---

### F-W3-041 [P3 nice-to-have][E-代码异味][build script]

**File**: `build_android_release.sh:96` 输出"签名: Debug keystore（仅适合个人分发）"

**问题**: 警告文案在 release script 终端 output 里——但用户可能 pipe 到 log 文件忽略它；**release artefact 自身**没体现这个属性。

**建议**: 把这条信息嵌进 APK metadata（`android:label` 加 `(unsigned-debug)` 后缀 / 或 BuildConfig 字段在 about 页显示）。

---

### F-W3-042 [P3 nice-to-have][A-架构][错误消息 / 日志]

**File**: 全代码库

**问题**: 没有"错误码表"——错误以字符串形式散布，没有集中索引。F-W3-008 改成 enum 后可天然解决。

**建议**: 实现 F-W3-008 后顺带生成一份 `error-codes.md`。

---

### F-W3-043 [P3 nice-to-have][E-代码异味][pubspec.yaml]

**File**: `flutter_app/pubspec.yaml:7-8`

**问题**: `sdk: '>=3.0.0 <4.0.0'` 与 `flutter: ">=3.35.0"` 范围太宽；mobile_scanner 5.x 要求 Dart 3.3+，理论上可与 sdk 3.0 冲突。

**建议**: 把 sdk 下限提到 3.3.0（与 mobile_scanner 对齐）；`pubspec.lock` 一旦 commit 也能间接固定。

---

## 审查覆盖度自评

**已覆盖**:
- ✅ FFI 契约：109 个 pub fn 签名、Dart 侧 jsonDecode 模式、PlatformInt64 / String 字段对齐
- ✅ 错误消息：跨层中英文混用、隐式 sentinel 前缀（`WEBVIEW_REQUIRED:` 等）
- ✅ 日志：tracing vs debugPrint 风格差异
- ✅ Android Manifest：权限 / exported / allowBackup 缺失 / queries
- ✅ network_security_config：cleartext 全局允许 / pin 缺失
- ✅ Gradle：NDK 版本三处硬编码 / debug keystore 签名 release / 缺 R8
- ✅ Dependencies：base64 / md5 / zip / urlencoding 版本不一致 / `[workspace.dependencies]` 缺失
- ✅ build script：顺序 / 幂等性 / 工作区脏检查 / NDK 版本同步
- ✅ jniLibs：4 ABI stale binary / 仓库膨胀

**未深挖（非本 wave 重点）**:
- ❌ `MainActivity.kt::LegadoJsBridge` 逐方法威胁建模（F-W3-015 已点出，深挖留专项 audit）
- ❌ R8 / proguard-rules.pro 具体规则
- ❌ Flutter `analyze_options.yaml` (未读取，但本仓库似乎没有 — 可作为 P2 finding)
- ❌ Cargo `cargo-deny` / supply-chain audit
- ❌ Reproducible build 验证（仅指出 release script 未保证）

**置信度**:
- High: FFI / Cargo / Gradle / build script (静态可读完整性高)
- Medium: 错误消息 / 日志 (代码量大，仅采样验证)
- Low: WebView JS bridge 逐方法漏洞 (深度审查需独立任务)
