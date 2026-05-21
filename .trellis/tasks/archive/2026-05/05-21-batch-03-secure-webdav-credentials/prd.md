# BATCH-03: WebDAV 凭据迁移到 secure_storage（最小范围 — 1 条 P0 + 1 条 P1）

> Roadmap：`.trellis/tasks/archive/2026-05/05-20-fix-roadmap/plan/batches/BATCH-03-secure-credentials-via-keystore.md`
> Master report：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md` 主题 2: 凭据 / 密钥 / 备份密码明文存储

## Goal

把 WebDAV 凭据（URL/user/password/deviceName 4 字段中的 password）从 `webdav.json` 明文写盘迁移到 Android Keystore（iOS Keychain）-backed `flutter_secure_storage`；其余 3 个非敏感字段（URL/user/deviceName）继续走 webdav.json 不变。同步顺手收拾 backup_page.dart 中 9 处 `cfg['url']!` / `cfg['user']!` / `cfg['password']!` 强制断言。

清理 2 条 finding：

1. **F-W2B-001 [P0]** WebDAV 凭据明文写 `webdav.json` — 核心迁移
2. **F-W2B-006 [P1]** webdav cfg 三处 `!` 强制断言（实测 9 处） — 同文件同上下文一并整改

不做：
- **F-W1A-020** 备份密码明文写 `legado_local.json` — Resolved-by-Design (BATCH-09)，且跨 FRB 调用链调整面广，单独 BATCH-03b
- **F-W1A-023** api-server token 明文日志 — Resolved by BATCH-23
- **F-W2B-005** `_loadWebDavConfig catch (_) silent` — 已被 BATCH-18g (json_store.readJsonFile null fallback) 处理

## 范围内改动

### F-W2B-001 — WebDAV password 走 secure_storage

**当前**：
- `webdav_config_page.dart:179-184` 写 `webdav.json` 4 字段（含 password 明文）
- `webdav_config_page.dart:108-113` 读同上 4 字段
- `backup_page.dart:399-408` `_loadWebDavConfig` 读同上文件，返回 `Map<String, String>` 4 字段（password 也在 map 里）
- `backup_page.dart:439/440/441 + 472/473/474 + 504/505/506` 9 处 `cfg['url']! / cfg['user']! / cfg['password']!` 调 FRB upload/list/download

**方案**：
- 加 `flutter_secure_storage: ^9.x` 依赖（pubspec.yaml）
- 新建 `flutter_app/lib/core/security/secure_storage.dart` —— 薄包装：
  - `Future<String?> readSecret(String key)` — 读，失败 / 不存在返回 null
  - `Future<void> writeSecret(String key, String? value)` — value=null/空串等价 delete
  - `Future<void> deleteSecret(String key)`
  - 内部用 `FlutterSecureStorage` 单例（`AndroidOptions(encryptedSharedPreferences: true)` —— flutter_secure_storage v9+ 默认走 Android Keystore-backed AES/GCM；老版 v8 走自管 Cipher，v9 默认 ESP）
  - **测试钩子**：暴露 `setSecureStorageOverrideForTest(SecureStorageImpl impl)` 让 widget test 注入内存实现（避免触发 FlutterSecureStorage 平台 channel 在 widget test 下 fail）
- 常量 key：`webdav_password`（仅本批使用；未来扩展加 `backup_password` 等同 key 命名空间）
- `webdav_config_page.dart`：
  - 写：`writeJsonFile('webdav.json', { 'url': ..., 'user': ..., 'deviceName': ... })`（**3 字段**，不含 password）+ `await writeSecret('webdav_password', _pwdCtl.text)`
  - 读：`readJsonFile('webdav.json')` 拿 3 字段 + `await readSecret('webdav_password') ?? ''` 填 _pwdCtl.text
- `backup_page.dart::_loadWebDavConfig`：
  - 改返回 `WebDavCredentials?`（新数据类，pub fn / 非 freezed，4 final String 字段：url/user/password/deviceName）—— 既消除 `Map['url']!` 类断言，也类型化 schema
  - 内部读 webdav.json → 3 字段 + readSecret → password；password 缺失走空串（与原行为对齐 — 用户可能后续填）
- 9 处 `cfg['xxx']!` 一律改 `cfg.url / cfg.user / cfg.password / cfg.deviceName`（Map → 数据类）。空 url 仍触发 "未配置" 早返回（已在 `_loadWebDavConfig` 内 trim+empty 判 null 返回）。

### 启动迁移路径

第一次跑新版本时，旧 `webdav.json` 还含 password 字段。单次迁移逻辑：

1. `_loadConfig` 从 webdav.json 读 4 字段
2. 若 `map['password']` 非空且 `readSecret('webdav_password')` 为 null：
   - 调 `writeSecret('webdav_password', map['password'])`
   - **直接覆盖写** webdav.json 移除 password 字段（保留其它 3 字段）
3. 后续走 secure_storage 单一路径
4. 无需"保留两套"过渡 — flutter_secure_storage 在 Android 没初始化好的边角 case 由 readSecret null fallback + 用户重输覆盖

迁移在 `_loadConfig` body 内做 once-per-instance，无显式版本号；webdav.json 写入时永不再带 password 字段，旧密码字段会被下一次 _onSave 自然清掉。

### F-W2B-006 — `cfg['xxx']!` 改数据类

**实测**：`backup_page.dart` 内 9 处（line 435/439/440/441/472/473/474/504/505/506），分布在 `_uploadBackup` / `_listBackups` / `_restoreBackup` 三个方法。

**方案**：把 `_loadWebDavConfig` 返回值从 `Map<String, String>?` 改为新数据类 `WebDavCredentials?`：

```dart
class WebDavCredentials {
  final String url;
  final String user;
  final String password;
  final String deviceName;
  const WebDavCredentials({
    required this.url,
    required this.user,
    required this.password,
    required this.deviceName,
  });
}
```

放在 `flutter_app/lib/features/settings/backup_page.dart` 顶部 file-private 即可（不需要跨文件复用 — webdav_config_page 自己直接读 secure_storage + json，不走这个数据类）。

9 处 caller 一律 `cfg.url` / `cfg.user` / `cfg.password` / `cfg.deviceName`（实测 line 435 已是 `cfg['deviceName']` 不带 `!`，但读起来不一致；统一改）。

## Requirements

- 新增 `flutter_secure_storage` 依赖（pubspec.yaml + pubspec.lock）
- 新建 `flutter_app/lib/core/security/secure_storage.dart` wrapper（含测试钩子）
- `webdav_config_page.dart`：password 走 secure_storage；webdav.json 不再含 password 字段
- `backup_page.dart::_loadWebDavConfig`：返回数据类 `WebDavCredentials`；9 处 `!` 断言全部消除
- 启动迁移：旧 webdav.json 含 password 时一次性迁到 secure_storage + 从 json 删除
- 测试钩子：`setSecureStorageOverrideForTest` 让现有 webdav_config_page_test.dart + backup_page_test.dart 不触发真实 platform channel

## Acceptance Criteria

- [ ] `flutter analyze` 0 issues
- [ ] `flutter test` 全过（含 webdav_config_page_test.dart + backup_page_test.dart 既有 + 本批新增 1-2 单测）
- [ ] grep `flutter_app/lib` 中 `'password'` JSON 字段：仅在 secure_storage migration 路径中出现一次（迁移读旧文件）
- [ ] grep `cfg\[` 在 backup_page.dart 中 0 命中（全部走 cfg.field）
- [ ] 新增至少 1 单测：`webdav_password_migrates_to_secure_storage` 模拟旧 webdav.json 含 password → 启动后 secure_storage 命中 + json 文件不再含 password
- [ ] master finding F-W2B-001 / F-W2B-006 Resolution 落 master findings.md + findings-flutter-features.md
- [ ] 升级路径：手测装旧版本写 webdav.json → 升级后 secure_storage 命中（手测不强求做，单测覆盖即可）

## Definition of Done

- 测试：1+ 新单测 + 既有全过
- Lint：flutter analyze 0 issues；flutter test green
- 文档：master report 2 条 Resolution + spec 加「凭据保险柜：敏感字段必须走 secure_storage（Android Keystore / iOS Keychain）；WebDAV password 是 canonical 例子」段
- Commit：3 个（fix + spec + archive，按 BATCH-13 模式）

## Out of Scope

- F-W1A-020 备份密码迁移（独立 BATCH-03b；改 Rust set/get_backup_password 调用链 + Dart 端 secure_storage 中转，effort 远超本批）
- F-W1A-023 token 明文日志（Resolved by BATCH-23）
- 删除旧 webdav.json 整文件（保留 3 字段非敏感；F-W2B-001 仅要求 password 不再明文）
- iOS / Desktop 平台 secure_storage 行为验证（项目主线 Android；flutter_secure_storage 跨平台 API 一致，iOS 走 Keychain，无需额外代码）
- secure_storage v8 vs v9 backend 对比研究（直接用最新 v9，AndroidOptions encryptedSharedPreferences=true 是 v9 默认且配 Android API 23+，与项目 minSdk 匹配）

## Technical Notes

- **flutter_secure_storage 版本选 v9.x**：API 23+ 默认 `EncryptedSharedPreferences`（AES-256/GCM, key in Keystore），符合项目 minSdk。v8 与 v9 公共 API 一致（read/write/delete），主要差异在 Android backend 实现。
- **平台 channel 在 widget test 下需 mock**：`FlutterSecureStorage` 在 unit/widget test 环境下调 platform channel 会抛 MissingPluginException。本批引入的 `SecureStorageImpl` interface + 内存 fake `_InMemorySecureStorage` 模式让测试零侵入；测试钩子由 top-level `setSecureStorageOverrideForTest(SecureStorageImpl?)` 控制。
- **迁移幂等性**：迁移逻辑只在 `readSecret('webdav_password') == null` 且 `webdav.json.password 非空` 时触发；多次启动 / 多次 _loadConfig 也安全（第二次 readSecret 已非 null，跳过）。
- **password 空串 vs 缺失**：旧版本可能写 `password: ''` 给 webdav.json — 这种不算"敏感数据"，迁移时 writeSecret 跳过即可（直接 readSecret 返回 null 等价空串）。
- **测试钩子 vs 生产路径**：webdav_config_page.dart 已有 `*Override` 钩子，secure_storage wrapper 走 top-level test override 而非构造函数注入（保持 `WebDavConfigPage()` 构造签名稳定）。pattern 与 `LiveTestRunner debugLiveTestRunnerOverride`（已被 BATCH-20 整改）相反 —— BATCH-20 收口到 ProviderScope.overrides，但本批用 top-level static 是因为 secure_storage 是 cross-feature 工具不绑 Provider 注入（json_store helper 也是 top-level fn 模式）。
- **删 9 处 `!` 风险**：原 `cfg['xxx']!` 假设 webdav.json 4 个字段都是 String；迁移后 password 来自 secure_storage（可能 null）。`WebDavCredentials.password` 字段类型保持 non-null String，由 `_loadWebDavConfig` 内填空串兜底（与原 `(map['password'] as String?) ?? ''` 行为对齐）。upload/list/download 调 FRB 时若 password 为空 → 由 webdav 服务器返 401，与原行为一致。
- **lock 文件**：项目已 commit `pubspec.lock`（BATCH-06），新依赖加进 yaml 后必须 `flutter pub get` 更新 lock 同 commit。

## Decision (ADR-lite)

**Context**：F-W2B-001 是 P0 凭据明文风险，但完整迁移（含 backup password + token + WebDAV）跨 3 层（Dart UI / Rust FRB / Android Keystore），effort 大。master report 主题 2 列 7 条相关 finding，roadmap BATCH-03 batch 文档建议合并做但 PRD 本次最小范围仅取最痛点的 1+1 条。

**Decision**：方案 A — 仅迁移 WebDAV password。引入 `flutter_secure_storage` 工具基础设施 + 数据类型化 (F-W2B-006)；备份密码 / token / api-server 凭据等留独立批次。

**理由**（vs 方案 B 全合并）：
- 方案 B 改 Rust set/get_backup_password 调用链：要让 Dart 端拿到 secure_storage 中的密码再传给 Rust 的 `encrypt_legado_aes` —— FRB 接口签名变 (从 `set_backup_password(documents_dir, password)` 变成 `encrypt_with_password(zip_bytes, password)`，password 由 Dart 端中转拿)，影响 zip 导出 / 导入 2 个调用点 + Rust 端写盘逻辑全删。effort 至少 +200 行 + 跨层 binary contract 变化，回归风险大。
- 方案 A 只动 Dart 层：webdav.json 写少一个字段，secure_storage 多一个 key，9 处 `!` 改类型字段。Rust 完全不动，FRB 不动，迁移路径在 Dart 内闭环。

**Consequences**：
- ✅ webdav password 不再明文写盘（解决 P0 主要风险）
- ✅ webdav.json 字段精简到 3 个非敏感字段（url/user/deviceName）
- ✅ 9 处 `!` 断言消除，类型安全提升
- ✅ secure_storage 基础设施落地（后续 BATCH-03b/c 复用）
- ⚠️ backup password 仍明文（master finding 主题 2 不全清）— 留 BATCH-03b
- ⚠️ flutter_secure_storage 是新外部依赖（v9 由 mogol 维护，社区主流，~2.6K star）— 项目接受
- ⚠️ pubspec.lock 改动；CI 需要重跑 `flutter pub get`
