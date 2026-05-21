# BATCH-20: settings 测试钩子收口 + cache mgmt 性能 + global mutable（5 条 P1 finding）

> Roadmap：`.trellis/tasks/archive/2026-05/05-20-fix-roadmap/plan/batches/BATCH-20-settings-testability-cleanup.md`
> Master report：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-flutter-features.md`

## Goal

清理 5 条 P1 finding：

1. **F-W2B-003** `settings_page.dart::_onNotificationSwitchToggled` mounted 检查冗余 + dialog 路径无 mounted check
2. **F-W2B-004** `BackupPage` 10 个 `*Override` 测试钩子污染生产 API
3. **F-W2B-008** `cache_management_page.dart::_sum` 每次 build 全量遍历 O(N)（list 几百本时两次 sum 4×N）
4. **F-W2B-020** `source_page.dart` 顶部 30 行 `LiveTestRunner` typedef + `debugLiveTestRunnerOverride` global mutable + `showLiveTestDialogForTesting` 公开测试钩子
5. **F-W2B-065** `replace_rule_page.dart::_r24NoticeShown` module-level mutable global

不做：F-W2B-007（已 BATCH-24 resolved）；F-W2B-021（已 BATCH-25 resolved）；BackupPage 之外的页面（cache_management / qr_scan / rss_*）也有同模式 *Override，但 BATCH-20 范围只收 BackupPage + SourcePage 两处最严重的（10 个 + global mutable），其余等模式稳定后下一批扫荡。

## Findings 落点

### F-W2B-004 — `BackupPage` 10 个 *Override + F-W2B-020 LiveTestRunner global

**核心方案**（**A: API client + Riverpod**）：

- **新建 `flutter_app/lib/core/services/backup_api_client.dart`**：
  - `class BackupApiClient` 包装 5 个 FRB 调用：`exportBackupZip` / `importBackupZip` / `validateBackupZip` / `webdavUploadBackup` / `webdavListBackups` / `webdavDownloadBackup`。
  - 每个方法签名与 `rust_api.xxx` 1:1 对应，参数命名一致；构造函数无参，方法直接 `await rust_api.xxx(...)`。
  - 提供 `final backupApiClientProvider = Provider<BackupApiClient>((ref) => BackupApiClient());`
  - 测试用 `backupApiClientProvider.overrideWith((ref) => FakeBackupApiClient())` 注入 fake。
- **新建 `flutter_app/lib/core/services/file_picker_service.dart`**：
  - `class FilePickerService { Future<String?> pickDirectory(); Future<String?> pickZipFile(); }`，包装 `file_picker` 调用。
  - `final filePickerServiceProvider = Provider<FilePickerService>((ref) => FilePickerService());`
  - 这一层抽象同时覆盖 `pickDirectoryOverride` + `pickFileOverride`。
- **`BackupPage` 构造函数**：删 10 个 `*Override` + `dbPathOverride`（保留 `dbPathOverride` —— 它在 dbPathProvider 之外是 cross-feature 测试模式，先保留兼容；或者改为 `dbPathProvider.overrideWith(...)`）。
  - **保守做法**：`dbPathOverride` 保留（很多测试用），其它 10 个 `*Override` 全删。
  - 业务逻辑改为 `final api = ref.read(backupApiClientProvider); await api.exportBackup(...)`。
  - `pickFile` / `pickDirectory` 走 `ref.read(filePickerServiceProvider).pickXxx()`。
- **`BackupPage` 测试迁移**：`backup_page_test.dart` 改为 `ProviderScope(overrides: [backupApiClientProvider.overrideWith(...), filePickerServiceProvider.overrideWith(...)], child: ...)`。新建 fake 类（`_FakeBackupApiClient` / `_FakeFilePickerService`）放测试文件内或 `test/_helpers/fakes.dart`。
- **`SourcePage` LiveTestRunner**：
  - 删 module-level `LiveTestRunner` typedef + `debugLiveTestRunnerOverride` 全局 mutable。
  - 新建 `flutter_app/lib/core/services/source_validation_service.dart`：
    - `class SourceValidationService { Future<String> validateLive({required String dbPath, required String sourceId, required String keyword}) => rust_api.validateSourceLive(...); }`
    - `final sourceValidationServiceProvider = Provider<SourceValidationService>((ref) => SourceValidationService());`
  - `_LiveTestDialog` 内 `final svc = ref.read(sourceValidationServiceProvider); await svc.validateLive(...)`。
  - **`showLiveTestDialogForTesting` 处理**：保留 `@visibleForTesting` annotation 不变（它本身是合法 export，与 mutable global 不同）。这函数只是个跳转 helper，不需要移动。
  - `source_validation_live_test_test.dart` 改用 `ProviderScope(overrides: [sourceValidationServiceProvider.overrideWith(...)])` 注入 fake。

### F-W2B-008 — `cache_management_page::_sum` cache

- 在 `_CacheManagementPageState` 加 `int _cachedTotal = 0; int _totalTotal = 0;` 字段。
- `_load()` 在 `_records` 改值时同时算好两个 sum 缓存。
- `_onClearAll()` 用 `_cachedTotal` 而非 `_sum('cached_chapters')`。
- `build()` 内对应位置（line 234/235）改用缓存字段。
- 删除 `_sum` 函数（或 keep 作 helper，但 build/_onClearAll 不再调）。

### F-W2B-003 — `settings_page._onNotificationSwitchToggled` mounted 风格统一

- 删除 line 53 之后的冗余 `if (mounted) ScaffoldMessenger...` 包装（line 53 已 early-return，后续不需要再 check）。
- `_onNotificationSwitchToggled` 进入 `_showDisableNotificationDialog` 前加 `if (!mounted) return;`（虽然走 false 分支没 await，但 `value` 参数来自 Switch 异步回调，从规范角度需要 check）。
- 整段统一 `if (!mounted) return;` early-return 风格，不用 nested `if (mounted) {}`。

### F-W2B-065 — `_r24NoticeShown` global → StateProvider

- 在 `replace_rule_page.dart` 顶部删 `bool _r24NoticeShown = false;`（line 13）。
- 新建 `final _r24NoticeShownProvider = StateProvider<bool>((_) => false);`（私有 — 双下划线开头）。
- `_ReplaceRulePageState.initState`：`final shown = ref.read(_r24NoticeShownProvider); if (!shown) { ref.read(_r24NoticeShownProvider.notifier).state = true; ... }`
- 行为不变（同进程内仍只显示一次），但测试可 override 重置。

## Requirements

- F-W2B-004 BackupPage *Override 改 `BackupApiClient` + `FilePickerService` 双 provider 注入；测试迁移 `ProviderScope.overrides`
- F-W2B-020 SourcePage `LiveTestRunner` global mutable 删；新建 `SourceValidationService` provider；测试迁移
- F-W2B-008 `_sum()` 改 State field cache，build 期 O(1) 读
- F-W2B-003 `_onNotificationSwitchToggled` mounted 风格统一为 `if (!mounted) return;` early-return
- F-W2B-065 `_r24NoticeShown` 改 StateProvider（私有，与生产行为一致）

## Acceptance Criteria

- [ ] `flutter analyze` 0 issues
- [ ] `flutter test` 全过（特别注意 `backup_page_test.dart` + `source_validation_live_test_test.dart` 两个迁移用例）
- [ ] **新建 5 个文件**：
  - `flutter_app/lib/core/services/backup_api_client.dart`
  - `flutter_app/lib/core/services/file_picker_service.dart`
  - `flutter_app/lib/core/services/source_validation_service.dart`
  - （可选）`flutter_app/test/_helpers/fakes.dart` —— 测试 fake 类集中处
- [ ] **修改 6 个文件**：
  - `flutter_app/lib/features/settings/backup_page.dart`（删 10 *Override + 改用 provider）
  - `flutter_app/lib/features/source/source_page.dart`（删 LiveTestRunner global）
  - `flutter_app/lib/features/settings/cache_management_page.dart`（_sum cache）
  - `flutter_app/lib/features/settings/settings_page.dart`（mounted 风格）
  - `flutter_app/lib/features/replace_rule/replace_rule_page.dart`（StateProvider）
  - `flutter_app/test/backup_page_test.dart` + `flutter_app/test/source_validation_live_test_test.dart`（测试迁移）
- [ ] 5 条 finding Resolution 落 master findings.md + findings-flutter-features.md
- [ ] grep 兜底：`debugLiveTestRunnerOverride|_r24NoticeShown\s*=` 应该都不再匹配（除 spec 引用）

## Definition of Done

- 测试：现有 11 个 widget test（backup + source_validation_live + cache_management）全部 PASS
- Lint：`flutter analyze` 0 issues
- 文档：master report 5 条 Resolution（按 BATCH-23/24/25 模板）
- Commit：单 `fix(flutter): 第 20 批 settings 测试钩子收口 + cache mgmt 性能 + global mutable（5 条 finding）`

## Out of Scope

- F-W2B-007 / F-W2B-021（已 resolved，BATCH-24 / BATCH-25）
- BackupPage 之外的 *Override 模式：`cache_management_page` 还有 `recordsOverride` / `dbPathOverride` / `clearAllCacheOverride` 等 4 个；`rss_source_manage_page` / `rule_sub_page` / `qr_scan_page` 各有 3-7 个。**等 BATCH-20 模式稳定后下一批扫荡**——本批先收最严重 2 处（BackupPage 10 个 + SourcePage global mutable）。
- F-W2B-066 rule id 碰撞概率（P2，独立批次）
- 通知服务本身重构（NotificationService 当前是 static class，本批不动）

## Technical Notes

- **`dbPathOverride` 保留**：BackupPage / cache_management 等都用，统一删除会引发跨页面测试改动。本批保留——它是"测试用 db 路径而不是 path_provider"的小钩子，与"测试用 fake FRB"性质不同。如果想统一，下一批专门处理。
- **`@visibleForTesting`**：`showLiveTestDialogForTesting` 已有 annotation，保留。生产代码调用会被 analyzer warn——这是符合现状的 testability boundary。
- **测试 fake 命名**：参考 `bookshelf_page_test.dart::bookGroupsProvider.overrideWith((ref) async => groupList)` 简洁 inline 模式；fakes.dart 暂不强求集中（视实施规模决定）。
- **`SourceValidationService.validateLive` 签名**：保持与 `rust_api.validateSourceLive` 1:1，`required String dbPath, required String sourceId, required String keyword`，避免 callers 改动。
- **`_LiveTestDialog` 内 ref 取用**：`_LiveTestDialog` 当前是私有 widget，需查它是否 ConsumerStatefulWidget。如不是 Consumer，需要 wrap 一层。

## Decision (ADR-lite)

**Context**：5 条 P1 都是 Flutter testability / 性能 / 风格 finding，本批集中清理 settings 区 + cross-feature module-level mutable。F-W2B-004 finding 自陈"建议作为独立子任务"——本批承接。

**Decision**：
- 004：API client class + Riverpod provider 模式（PRD 预设方案 A）；建立 `core/services/` 目录新基础设施
- 020：同 004 的 service class 模式；module-level mutable global 全删
- 008：State field cache（最简方案）
- 003：mounted early-return 风格统一
- 065：StateProvider 替代 module-level global

**Consequences**：
- ✅ 5 条 P1 一批清，建立 `core/services/` 基础设施供后续批次扫荡其它 *Override 用
- ✅ BackupPage 构造函数恢复干净，10 个 override 删除
- ✅ Riverpod provider override 模式与现有测试（bookshelf_page / search_page / source_page 等）保持一致
- ⚠️ 测试改动量大：backup_page_test.dart 现有 2 个 case + source_validation_live_test_test.dart 2 个 case 都要迁移
- ⚠️ `dbPathOverride` 保留作为 testability vs production 的边界 trade-off
- ⚠️ 其它 4 处页面（cache_mgmt 4 个 / rss_* 3-7 个 / rule_sub 6 个 / qr_scan 6 个）不在本批，留 future cleanup
