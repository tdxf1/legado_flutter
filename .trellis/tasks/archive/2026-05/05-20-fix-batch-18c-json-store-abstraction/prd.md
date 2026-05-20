# BATCH-18c: settings.json IO 抽象 json_store helper

## Goal

闭环 F-W2A-003：把 `flutter_app/lib/core/providers.dart` 内 17 个 settings.json IO 函数（load/save/clear 系列）的重复 read-modify-write 模板抽到新的 `flutter_app/lib/core/persistence/json_store.dart` helper 模块。同时顺手解决 finding 末段提到的并发写竞态（同时切多个 settings 时 read-modify-write 后写者覆盖前写者）— helper 内置 `_Mutex` 串行化所有 write，read 保持无锁。17 个 wrapper 函数保留签名仅替换 body，caller 零改动。

## What I already know

### 来自 explore 审计（2026-05-20，本批次）

**1. 17 个 settings IO 函数完整清单**（`flutter_app/lib/core/providers.dart` L217-1028）

| # | 函数 | key | 默认值 / parse |
|---|---|---|---|
| 1-2 | `load/saveThemeModeToDisk(.., {String? directory})` | `themeMode` (int) | `ThemeMode.system` / `ThemeMode.values[v as int? ?? 0]` |
| 3-5 | `save/load/clearPendingRoute({String? directory})` | `pendingRoute` (String) | `null` / `as String?` |
| 6-7 | `load/saveFontSizeToDisk` | `fontSize` (num) | `18.0` / `(v as num).toDouble().clamp(14, 28)` |
| 8-9 | `load/saveSearchHistoryToDisk` | `searchHistory` (List) | `[]` / `(v as List).map(toString)` |
| 10-11 | `load/saveSearchPrecisionToDisk` | `searchPrecision` (bool) | `false` / `v is bool ? v : false` |
| 12-13 | `load/saveReaderSettingsToDisk` | `readerSettings` (Map) | `const ReaderSettings()` / `ReaderSettings.fromJson(map)` |
| 14-15 | `load/saveBookshelfGridViewToDisk` | `bookshelfGridView` (bool) | `false` / `v is bool ? v : false` |
| 16-17 | `load/saveRefreshRateModeToDisk` | `refreshRateMode` (int) | `RefreshRateMode.auto` / `RefreshRateModeLabel.fromIndex` |

**2. 重复模板**（每个函数 ~12 行）：
```dart
// load 路径
final dir = Platform.isAndroid
    ? (await getApplicationDocumentsDirectory()).path
    : (await getApplicationSupportDirectory()).path;
final file = File('$dir/settings.json');
if (!await file.exists()) return DEFAULT;
final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
// ... type guard + parse
catch (e) { return DEFAULT; }

// save 路径（read-modify-write）
final Map<String, dynamic> data = file.existsSync()
    ? jsonDecode(await file.readAsString()) as Map<String, dynamic>
    : {};
data[key] = value;
await file.writeAsString(jsonEncode(data));
catch (e) { debugPrint('Failed to save ...'); }
```

**3. directory 参数现状（分裂）**
- **5 个有 `{String? directory}`**：Theme + PendingRoute 系列（L217-293）
- **12 个无 directory 参数**：FontSize / SearchHistory / SearchPrecision / ReaderSettings / BookshelfGridView / RefreshRateMode（L295-1028）
- 分裂原因：theme 系列被 `widget_test.dart` 用 `directory: tempDir` 直接绕开 path_provider；其余测试通过 `PathProviderPlatform.instance = _TmpPathProvider(tmpDir)` 替换底层

**4. caller 分布**（共 ~17 个 prod + ~13 个 test）
- `main.dart`：4 个 load（Theme / FontSize / RefreshRateMode / PendingRoute）+ 1 个 clearPendingRoute
- `settings_page.dart`：4 个 save（Theme / PendingRoute / FontSize 等）
- `search_page.dart`：load/save SearchHistory + SearchPrecision
- `reader_page.dart` / `bookshelf_page.dart`：各 1-2 个 load/save
- `widget_test.dart` / `search_precision_test.dart`：13 处 test caller
- **`saveRefreshRateModeToDisk` 0 caller**（潜在死代码，本批不动）

**5. 并发风险（finding 原文）**
- 所有 17 个写函数纯 read-modify-write，**无任何锁/Mutex**
- 真实场景：用户在 settings 页快速点多个 toggle，前一个写未完成时下一个开始读 → 后者读到旧文件 → 写时丢失前者改动
- 本批解：helper 加 module-level `_Mutex` 串行化 write，read 不锁

**6. enum 序列化**
- ThemeMode：`mode.index` ↔ `ThemeMode.values[v]`
- RefreshRateMode：`mode.persistIndex` ↔ `RefreshRateModeLabel.fromIndex(v)`（带越界保护）
- ReaderSettings：`settings.toJson()` ↔ `ReaderSettings.fromJson(map)`
- helper 用 `T parse(dynamic raw)` 签名让 caller 自己处理 type guard，统一可表达

## Open Questions

（已收敛）

## Requirements (final)

### MVP scope（4 项）

1. **新建 `flutter_app/lib/core/persistence/json_store.dart`**
   - `Future<T> readJsonKey<T>(String key, T Function(dynamic raw) parse, T defaultValue, {String? directory})`
   - `Future<void> writeJsonKey(String key, Object? value, {String? directory, String? errorTag})`
   - `Future<void> deleteJsonKey(String key, {String? directory})`
   - module-level `_Mutex` 串行化所有 write/delete，read 保持无锁
   - `_resolveDir(String? directory)` helper 处理 Android/其它平台默认目录
   - 完整 doc-comment 说明用法、并发模型、test 兼容性

2. **重写 `providers.dart` 内 17 个 IO 函数**
   - **保留签名**（caller 零改动）
   - body 替换为对 helper 的单行调用
   - 5 个带 `{String? directory}` 的 wrapper 透传 directory 给 helper
   - error tag 沿用各函数原 debugPrint 文案（`'theme mode'` / `'font size'` / `'reader settings'` 等）

3. **测试策略**
   - 现有 widget test / search_precision_test 不动，自动通过（helper 透传 directory；mock path_provider 仍生效）
   - 新增 `flutter_app/test/json_store_test.dart`：
     - 基础 read/write/delete round-trip
     - 不存在 key 返回 default
     - parse 抛异常返回 default
     - 并发 write 不丢更新（串行化验证：起 N 个 future 各写一个 key，全部完成后所有 key 都在文件里）
     - read 与 write 并发不死锁

4. **master report 同步**
   - F-W2A-003 标 "Resolved by BATCH-18c"
   - 注：findings-flutter-core.md 而非 findings-rust-data.md

### 不在范围内

- F-W2A-001 / 002 / 008 等其它 W2A finding（独立批次）
- `saveRefreshRateModeToDisk` 0 caller 死代码删除（独立 finding）
- 引入 `shared_preferences` 替换 settings.json（依赖增加 + 迁移成本，与本批"局部抽象"目标不符）
- BATCH-18 路线图原文里的 fontSize 双 source of truth (F-W2A-008) / bookshelf PopupMenu 重组 (F-W2B-016) / documents 路径分散 (F-W2B-022)

## Acceptance Criteria

- [ ] 新文件 `flutter_app/lib/core/persistence/json_store.dart` 存在，含 3 个 public fn + `_Mutex` 实现
- [ ] `providers.dart` 内 17 个 IO 函数 body 全部缩减为对 helper 的 1-3 行调用
- [ ] grep `'$dir/settings.json'` 在 `flutter_app/lib/` 下仅 1 处（json_store.dart 内部定义）
- [ ] grep `getApplicationDocumentsDirectory|getApplicationSupportDirectory` 在 `flutter_app/lib/core/providers.dart` 下 0 命中（全部下沉到 helper）
- [ ] `flutter analyze` 无新 warning
- [ ] `flutter test` 全部 PASS（现有 widget_test + search_precision_test + 新增 json_store_test）
- [ ] 新 `json_store_test.dart` 至少 5 个 case：round-trip、default、parse 异常、并发 write、并发 read+write
- [ ] master report `findings-flutter-core.md` F-W2A-003 标 "Resolved by BATCH-18c"
- [ ] 净 diff 约 -100~-150 行（17 wrapper 各 -8~-10 行 + helper +80 行 + 测试 +50 行）

## Definition of Done

- 17 个 IO 函数 body 简化为 helper 调用
- caller 零改动（17 个 wrapper 签名保留）
- F-W2A-003 race 通过 `_Mutex` 解决
- 测试套件全 PASS

## Decision (ADR-lite)

**Context**: 路线图 BATCH-18 含 F-W2A-001/002/003/008 + F-W2B-016/022 共 6 条 Flutter finding。BATCH-18a 已闭环 F-W2A-001（删 core/api/）+ 缩范围 F-W2A-008；BATCH-18b 已闭环 F-W2A-002（删 Transport）。本批专攻 F-W2A-003（settings IO 抽象 + race），其它留 BATCH-18d/e/f。

**Decision**: 选项 1（推荐方案）— helper + 保留 wrapper + 顺手上 Mutex。

**Consequences**:
- caller 改动量为 0（17 个 wrapper 签名不变），降低回归风险
- 新模块 `core/persistence/json_store.dart` 后续如果接入新 settings 字段直接走 helper，避免再写新模板
- F-W2A-003 race 一并解决（finding 末段提到但路线图未明确包含）
- 净 diff 约 -100 行（17 × ~10 减去 helper ~80 加上测试 ~50）
- saveRefreshRateModeToDisk 0 caller 不在本批解（保留观察期）

## Technical Notes

### 风险点

- **Mutex 死锁**：read 保持无锁，write/delete 通过 Mutex 串行。如果 helper 内部某个 future 不 complete，整个 write 链路会卡住。`_Mutex.run` 用 try/catch 把 body 异常 forward 到 completer，确保 lock 一定释放。
- **测试 mock 兼容**：现有 `search_precision_test.dart` 走 `PathProviderPlatform.instance = _TmpPathProvider(tmpDir)`，helper 内部仍调 `getApplicationDocumentsDirectory()` → mock 返回 tmpDir → 透明兼容。
- **directory 透传**：5 个原本带 `{String? directory}` 的 wrapper 必须把这个参数透传给 helper，否则 widget_test 走 `directory: tempDir` 会失效。

### 实施顺序

1. 新建 `core/persistence/json_store.dart`（helper + Mutex）
2. 改写 `providers.dart` 17 个 IO 函数 body
3. 新建 `test/json_store_test.dart`（5 个 case）
4. 跑 `flutter analyze` 验证零 warning
5. 跑 `flutter test` 验证全 PASS
6. 更新 master report F-W2A-003 状态

### 测试 case 设计

```dart
test('round-trip: writeJsonKey then readJsonKey returns same value');
test('readJsonKey returns default when key missing');
test('readJsonKey returns default when parse throws');
test('concurrent writes serialize correctly: all 10 keys persisted');
test('read does not block write and vice versa');
```

## Research References

- 本任务 explore audit（in-context，未持久化到 research/）
- BATCH-18 路线图：`.trellis/tasks/archive/2026-05/05-20-fix-roadmap/plan/batches/BATCH-18-flutter-dead-code-and-io-abstract.md`
- BATCH-18a archive：`.trellis/tasks/archive/2026-05/05-20-fix-batch-18a-pure-dead-code/`
- BATCH-18b archive：`.trellis/tasks/archive/2026-05/05-20-fix-batch-18b-transport-sse-analysis/`
