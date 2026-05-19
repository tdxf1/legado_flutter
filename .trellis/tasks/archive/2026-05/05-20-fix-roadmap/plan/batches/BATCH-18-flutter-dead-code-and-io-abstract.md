# BATCH-18: Flutter 端死代码清理 + settings IO 抽象

**Stage**: P1
**Slug**: `flutter-dead-code-and-io-abstract`
**Effort**: M (≤500 行)
**Depends on**: none

## 1. 范围

集中清理 Flutter 端 5 条架构问题：`core/api/` Dio 客户端目录死代码、LocalTransport / HttpTransport 占位、settings.json IO 11 函数模板、fontSize 双 source of truth、bookshelf AppBar PopupMenu 9 跳转项、各 feature 自管 documents 路径。这是"删 + 抽公共"两类纯减法工作。

## 2. 包含的 findings

- [F-W2A-001] core/api/ Dio 客户端目录是死代码 — `flutter_app/lib/core/api/`
- [F-W2A-002] LocalTransport 是 UnimplementedError 占位 — `flutter_app/lib/core/transport.dart`
- [F-W2A-003] 11 个 settings.json IO 函数模式重复 — `flutter_app/lib/core/providers.dart`
- [F-W2A-008] fontSize 双 source of truth — `flutter_app/lib/core/providers.dart:78`
- [F-W2B-016] AppBar PopupMenu 9 跳转项无组织 — `flutter_app/lib/features/bookshelf/bookshelf_page.dart:122-156`
- [F-W2B-022] 各 feature 自行 getApplicationDocumentsDirectory()  拼路径 — cross-feature

## 3. 影响文件

- `flutter_app/lib/core/api/` — 整目录删除（或迁去 `legacy/`）；同时删除 `apiClientProvider` / `readerApiProvider` / `bookshelfApiProvider` / `sourceApiProvider` / `searchApiProvider` / `apiBaseUrlProvider` / `apiTokenProvider` / `BackendMode.http` / `transportProvider` 的 http 分支
- `flutter_app/lib/core/transport.dart` — 删除 `Transport` 抽象 + `HttpTransport` + `LocalTransport` + `BackendMode` enum；保留 SSE 解析（如有真实 caller）
- `flutter_app/lib/core/persistence/json_store.dart` (新增) — `Future<T> read<T>(String name, T Function(Map) parser, T defaultValue)` + `Future<void> write(String name, Object value)`
- `flutter_app/lib/core/providers.dart` — 11 个 settings IO 函数改用 json_store；删除 `fontSizeProvider` + `loadFontSizeFromDisk` + `saveFontSizeToDisk`，改 `final fontSizeProvider = Provider<double>((ref) => ref.watch(readerSettingsProvider).fontSize);`
- `flutter_app/lib/features/bookshelf/bookshelf_page.dart:122-156` — bookshelf 只保留"书架自身相关"操作（导入本地书 / 管理分组）；其余移到 settings 页或独立"工具"页（路由调整）
- `flutter_app/lib/core/router.dart` — 同步路由调整
- 各 feature 改用 json_store（settings / search_history / cache stats 等）
- `flutter_app/lib/main.dart` — 删除 `loadFontSizeFromDisk` 调用

## 4. 修复方向

复用 master findings-flutter-core.md / findings-flutter-features.md "建议"段落 + 主题汇总"共同建议"。

## 5. 测试策略

- Widget test：bookshelf 仅显示书架相关菜单；其它菜单走 settings 入口
- Widget test：fontSize 改 readerSettings 后所有依赖 fontSizeProvider 的 widget 同步更新
- 现有 Flutter 测试套件回归通过

## 6. 验收

- [ ] master finding F-W2A-001/002/003/008 / F-W2B-016/022 全部消解
- [ ] grep `getApplicationDocumentsDirectory` 仅在 json_store 中出现
- [ ] grep `fontSizeProvider` 仅在 readerSettings 派生定义中出现一次
- [ ] dio 依赖在 pubspec.yaml 仅被 cover_cache 一处使用（或换 package:http）

## 7. implement.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-flutter-core.md", "reason": "本批次涉及的 wave 2A findings（F-W2A-001/002/003/008）"}
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-flutter-features.md", "reason": "本批次涉及的 wave 2B findings（F-W2B-016/022）"}
{"file": "flutter_app/lib/core/api/api_client.dart", "reason": "死代码主体"}
{"file": "flutter_app/lib/core/transport.dart", "reason": "Transport 抽象"}
{"file": "flutter_app/lib/core/providers.dart", "reason": "settings IO 重复 + fontSizeProvider"}
{"file": "flutter_app/lib/features/bookshelf/bookshelf_page.dart", "reason": "AppBar PopupMenu 重组"}
{"file": "flutter_app/lib/core/router.dart", "reason": "路由跟着调整"}
{"file": "flutter_app/lib/main.dart", "reason": "删除 loadFontSizeFromDisk"}
{"file": "flutter_app/pubspec.yaml", "reason": "评估 dio 依赖去留"}
```

## 8. check.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md", "reason": "master report 主题：重复 SQL / 重复实现 / 死代码"}
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-flutter-core.md", "reason": "Wave 2A"}
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-flutter-features.md", "reason": "Wave 2B"}
{"file": ".trellis/tasks/05-20-fix-roadmap/plan/batches/BATCH-18-flutter-dead-code-and-io-abstract.md", "reason": "本批次自身验收清单"}
```
