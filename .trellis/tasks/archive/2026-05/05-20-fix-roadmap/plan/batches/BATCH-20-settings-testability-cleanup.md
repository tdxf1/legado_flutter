# BATCH-20: settings 测试钩子收口 + cache mgmt + global mutable

**Stage**: P1
**Slug**: `settings-testability-cleanup`
**Effort**: M (≤500 行)
**Depends on**: BATCH-18 (json_store / Provider 抽象到位)

## 1. 范围

settings & feature 中"测试钩子污染生产 API + module-level mutable global + 通知 toggle 反模式 + PlatformInt64 转换重复 + cache_management 全量 sum + mounted setState 风格混用"七条 P1 一次性收口；统一引入 `RssApiClient` / `BackupApiClient` / `WebDavApiClient` 等 API client 类做 Riverpod 注入。

## 2. 包含的 findings

- [F-W2B-003] notification toggle 多次 setState + ScaffoldMessenger — `flutter_app/lib/features/settings/settings_page.dart:50-66`
- [F-W2B-004] BackupPage 10 个 *Override 测试钩子 — `flutter_app/lib/features/settings/backup_page.dart:81-93`
- [F-W2B-007] PlatformInt64 → int 模式重复 — `flutter_app/lib/features/settings/cache_management_page.dart:144-145`
- [F-W2B-008] cache_management _sum() 每次 build 全量遍历 — `flutter_app/lib/features/settings/cache_management_page.dart:101-107, 233-282`
- [F-W2B-020] LiveTestRunner global mutable override — `flutter_app/lib/features/source/source_page.dart:14-43`
- [F-W2B-021] mounted setState 模式混用 — cross-feature
- [F-W2B-065] replace_rule module-level mutable global `_r24NoticeShown` — `flutter_app/lib/features/replace_rule/replace_rule_page.dart:13`

## 3. 影响文件

- `flutter_app/lib/core/api/rss_api_client.dart` / `backup_api_client.dart` / `webdav_api_client.dart` (新增) — 命名包装 FRB 调用，通过 Riverpod provider 注入
- `flutter_app/lib/features/settings/backup_page.dart:81-93` — 删除 10 个 `*Override` 参数，构造函数恢复干净；测试用 `ProviderScope.override`
- `flutter_app/lib/features/settings/cache_management_page.dart:101-107, 233-282` — sum 缓存为 State 字段；PlatformInt64 转换走 `core/util/platform_int64.dart`
- `flutter_app/lib/core/util/platform_int64.dart` (新增) — 集中 PlatformInt64 → int 转换
- `flutter_app/lib/features/source/source_page.dart:14-43` — typedef + override + showLiveTestDialogForTesting 移到 `test/source_page_test_hooks.dart`（仅 test target 引入）
- `flutter_app/lib/features/replace_rule/replace_rule_page.dart:13` — global bool 改 `final _r24NoticeShownProvider = StateProvider<bool>((_) => false);`
- `flutter_app/lib/features/settings/settings_page.dart:50-66` — 通知 toggle async path 加 mounted 检查 + 统一 `if (!mounted) return;` 风格
- `flutter_app/lib/core/widgets/safe_setstate.dart` (新增) — `void safeSetState(VoidCallback fn)` extension；多处 mounted setState 收口

## 4. 修复方向

复用 master findings-flutter-features.md 主题 10 "测试钩子污染生产 API"集体建议 + 各条具体建议。

## 5. 测试策略

- Widget test：BackupPage / SourcePage / RssSourceManagePage 通过 ProviderScope.override 替换 API 实现
- Widget test：cache_management 的 sum 仅在 _records 改时重算
- Lint：grep `module-level mutable` / `dynamic xxOverride` 类应消失（BATCH 完成后做一次 grep 兜底）

## 6. 验收

- [ ] master finding F-W2B-003/004/007/008/020/021/065 全部消解
- [ ] 全代码库无 module-level mutable global state（除 const 外）
- [ ] PlatformInt64 转换仅在 1 处定义

## 7. implement.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-flutter-features.md", "reason": "本批次涉及的 wave 2B findings"}
{"file": "flutter_app/lib/features/settings/backup_page.dart", "reason": "测试钩子收口"}
{"file": "flutter_app/lib/features/settings/cache_management_page.dart", "reason": "sum 缓存 + PlatformInt64"}
{"file": "flutter_app/lib/features/source/source_page.dart", "reason": "LiveTestRunner global"}
{"file": "flutter_app/lib/features/replace_rule/replace_rule_page.dart", "reason": "_r24NoticeShown global"}
{"file": "flutter_app/lib/features/settings/settings_page.dart", "reason": "通知 toggle"}
{"file": "flutter_app/lib/core/api/", "reason": "新增 API client wrappers (注：本目录在 BATCH-18 已删除，新文件路径需调整为 core/services/ 等)"}
```

## 8. check.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md", "reason": "master report 主题：测试钩子污染生产 API"}
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-flutter-features.md", "reason": "Wave 2B"}
{"file": ".trellis/tasks/05-20-fix-roadmap/plan/batches/BATCH-20-settings-testability-cleanup.md", "reason": "本批次自身验收清单"}
```
