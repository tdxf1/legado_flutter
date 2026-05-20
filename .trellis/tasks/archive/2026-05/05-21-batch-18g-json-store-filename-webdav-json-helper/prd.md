# BATCH-18g: json_store 任意 fileName + webdav.json 迁公共 helper

## Goal

闭环 F-W2A-058：扩 `flutter_app/lib/core/persistence/json_store.dart` 加 3 个公共 fn `readJsonFile` / `writeJsonFile` / `deleteJsonFile`（整文件 IO，与 BATCH-18c 既有的 `readJsonKey` / `writeJsonKey` / `deleteJsonKey` 共存 — 后者是 settings.json 多 key 共享单文件，前者是任意 fileName 一文件一对象）。迁 `webdav_config_page.dart::_loadConfig/_onSave` + `backup_page.dart::_loadWebDavConfig` 走新 helper，消除 webdav.json read-modify-write 模板重复。

## What I already know

### 来自 explore 审计（2026-05-21）

**1. json_store.dart 现状**（169 行，BATCH-18c）

- `File _settingsFile(String dir) => File('$dir/settings.json')` (L71) 唯一硬编码处
- 公开 API：`resolvePersistenceDir({String? directory})`、`readJsonKey<T>` / `writeJsonKey` / `deleteJsonKey`、private `_writeLock` (`_Mutex` 模块单例)
- 现有 doc-comment 完整覆盖：用法、并发模型、测试兼容性、_Mutex 失败传播策略

**2. webdav.json 三处 caller 完整源码**

`webdav_config_page.dart::_loadConfig` (L105-117)：
```dart
final dir = await _resolveConfigDir();
final f = File('$dir/webdav.json');
if (await f.exists()) {
  final text = await f.readAsString();
  final Map<String, dynamic> map = jsonDecode(text) as Map<String, dynamic>;
  _urlCtl.text = (map['url'] as String?) ?? '';
  // ... 4 个字段
}
```

`webdav_config_page.dart::_onSave` (L168-214) — 整文件覆盖式写：
```dart
final f = File('$dir/webdav.json');
final map = {'url': url, 'user': ..., 'password': ..., 'deviceName': ...};
await f.writeAsString(jsonEncode(map));
```

`backup_page.dart::_loadWebDavConfig` (L472-496) — read-only，比 webdav_config 多一层 url trim+empty→null 校验。

**3. 数据模型**：webdav.json 没有专用 `WebDavConfig` 类，两处 caller 各自手写 4 字段提取（url / user / password / deviceName）。本批不抽数据类（用户决策） — 模型形状不一致（一处填 controller、另一处返回 Map），抽数据类反而麻烦。

**4. 测试 override 兼容性**

- `webdav_config_page` 用 `configDirOverride`（test/webdav_config_page_test.dart:36/128 用 `tmp.path`）
- `backup_page` 用 `webdavConfigDirOverride`（**0 测试覆盖** — 已知 gap，本批不补）
- 新 helper 透传 `directory` 给 `resolvePersistenceDir(directory: directory)`，两个 override 路径自动复用

**5. helper API 设计** — 选候选 1（整文件级 IO-only）

理由：
- webdav.json 数据形状是"整对象一次 read，整对象一次 write"，候选 1 是天然投影
- settings.json key-based API 保留不动，两套 API 各管各的（settings.json = 多 key 共享一文件；webdav.json = 一文件一对象），语义清晰
- caller 改动最小（read 4 行→1 行；write 2 行→1 行）
- 实现简单（套用 `readJsonKey` / `writeJsonKey` 已有模板）
- 后续如有第三种文件需求（legado_local.json 等）直接复用 fileName 参数

**6. _Mutex 共享 vs 独立** — 选共用 `_writeLock`

理由：
- webdav.json 写频率极低（用户进配置页点保存才触发，<1/秒）
- 简单：复用现有 mutex，不引入 `Map<String, _Mutex>` 样板
- 安全：settings.json 与 webdav.json 之间无 happens-before 依赖
- 可扩展：将来发现热点文件再拆

**7. `writeJsonFile` 错误策略** — 选 rethrow（用户决策）

理由：
- caller 外层有 try-catch 显示 SnackBar `保存失败: $e`，rethrow 保留这条 UX 路径
- 与 `writeJsonKey` 吞错策略不对齐，但 doc-comment 明确说明"settings.json 写失败不可见 vs 任意文件写失败 caller 决定"
- `readJsonFile` 仍 fallback 到 null（不抛），与 `readJsonKey` fallback default 对齐

## Open Questions

（已收敛）

## Requirements (final)

### MVP scope（5 项）

1. **改 `flutter_app/lib/core/persistence/json_store.dart`**
   - 末尾加 3 个公共 fn + 1 个私有 `_jsonFile(dir, fileName)` helper
   - `readJsonFile(String fileName, {String? directory}) → Future<Map<String, dynamic>?>`：fallback null on missing/parse error/IO error
   - `writeJsonFile(String fileName, Map<String, dynamic> data, {String? directory}) → Future<void>`：rethrow on error，整覆盖（非 read-modify-write）
   - `deleteJsonFile(String fileName, {String? directory}) → Future<void>`：missing 静默 no-op
   - 共用 `_writeLock`（写/删串行化）
   - doc-comment 说明与 `readJsonKey` 一组的语义差异 + "约定：settings.json 不要混用两套 API"

2. **改 `flutter_app/lib/features/settings/webdav_config_page.dart`**
   - `_loadConfig` 从 4 行 read 模板缩为 `await readJsonFile('webdav.json', directory: dir)` + null check 后填 controller
   - `_onSave` 从 2 行 write 模板缩为 `await writeJsonFile('webdav.json', map, directory: dir)`（外层 try-catch 保留处理 rethrow）
   - 删 `dart:io` import（如其它代码不再用 File/Directory；需 grep 验证）
   - 删 `dart:convert` import（如其它代码不再用 jsonEncode/jsonDecode）

3. **改 `flutter_app/lib/features/settings/backup_page.dart::_loadWebDavConfig`**
   - 整体改为：`final map = await readJsonFile('webdav.json', directory: widget.webdavConfigDirOverride)` + null check + url trim/empty→null 校验保留 + 字段提取
   - 外层 try-catch 删（`readJsonFile` 自吞），与原 `catch (_) → return null` 等价
   - **不动** backup_page 其它代码（仍用 File/jsonEncode 等于其它路径）

4. **新增 8 个 test 到 `flutter_app/test/json_store_test.dart`**（不新建文件）
   - round-trip / missing / malformed JSON / overwrite / delete / no-op delete / 错误吞掉 / 共用 mutex 串行化 / 文档化"settings.json 不要混用"约定

5. **master report 同步**
   - F-W2A-058 标 "Resolution (BATCH-18g)"
   - 注：findings-flutter-features.md 既有 follow-up 段尾追加 Resolution

### 不在范围内

- 抽 `WebDavConfig` 数据类（用户决策不抽）
- 补 backup_page WebDAV upload/download widget test（用户决策不补）
- legado_local.json / 其它 ad-hoc 文件迁移（独立 finding）

## Acceptance Criteria

- [ ] `json_store.dart` 末尾含 3 个新公共 fn + `_jsonFile` 私有 helper
- [ ] `webdav_config_page.dart::_loadConfig` 走 `readJsonFile`，body 缩 ~4 行
- [ ] `webdav_config_page.dart::_onSave` 走 `writeJsonFile`，body 缩 ~2 行
- [ ] `backup_page.dart::_loadWebDavConfig` 走 `readJsonFile`，body 缩 ~10 行
- [ ] grep `File\('\\$dir/webdav.json'\)` 在 `flutter_app/lib/` 下 0 命中
- [ ] grep `jsonDecode|jsonEncode` 在 `webdav_config_page.dart` + `backup_page.dart::_loadWebDavConfig` 周围 0 命中（或仅其它路径用）
- [ ] `flutter_app/test/json_store_test.dart` 新增 8 case，全部 PASS
- [ ] `flutter analyze` 0 warning
- [ ] `flutter test` 全部 PASS（旧 393 + 新 8 = 401 维持）
- [ ] master report `findings-flutter-features.md` F-W2A-058 标 "Resolution (BATCH-18g)"
- [ ] master report `findings.md` 主索引同步

## Definition of Done

- json_store helper 支持任意 fileName（settings.json key-based + 任意 fileName 整文件 IO 两套 API 共存）
- webdav.json 三处 caller 全部走新 helper，read-modify-write 模板消除
- 测试覆盖完整（包含约定文档化）
- F-W2A-058 闭环

## Decision (ADR-lite)

**Context**: BATCH-18e 闭环 F-W2B-022 时识别出 webdav.json read-modify-write 模板在 webdav_config_page + backup_page 重复，json_store helper 仅支持 settings.json 单文件无法直接迁。F-W2A-058 占位留独立批次。

**Decision**: 候选 1（整文件级 IO-only API，与 key-based API 共存）+ 共用 `_writeLock` + `writeJsonFile` rethrow + 不抽 WebDavConfig 数据类 + 不补 backup_page widget test。

**Consequences**:
- 净 ~+111 行（生产代码 +26 / -9 = +17，测试 +85）
- 消除 2 处 webdav.json read-modify-write 模板
- 引入轻微 API 双重性（key-based + file-based），doc-comment 明确两套用途
- `writeJsonFile` rethrow 与 `writeJsonKey` 吞错不对齐 — 是 caller 实际需要（保留 SnackBar），不是设计缺陷
- backup_page 的 `webdavConfigDirOverride` 0 测试覆盖问题不解决（已有问题，本批不 regress）

## Technical Notes

### 风险点

- **`writeJsonFile` rethrow 与 `writeJsonKey` 吞错不对齐**：doc-comment 显式说明，避免后人误解为遗忘
- **整覆盖语义**：`writeJsonFile` 整覆盖（不是 read-modify-write），与 webdav_config_page._onSave 现有 `f.writeAsString(jsonEncode(map))` 等价；不能误用到 settings.json（会清掉 readJsonKey 写过的内容）— 测试 case 9 文档化此约定
- **共用 `_writeLock`**：settings.json 写 + webdav.json 写互相阻塞极小概率影响（webdav 写 <1/秒，无可感知争用）

### 实施顺序

1. read `json_store.dart` 当前结构找尾部插入点
2. 加 `_jsonFile` 私有 + 3 个公共 fn + doc-comment（约 +35 行）
3. 改 `webdav_config_page.dart::_loadConfig` + `_onSave`
4. 改 `webdav_config_page.dart` 顶部 import（删 `dart:io` / `dart:convert` 如不再用）
5. 改 `backup_page.dart::_loadWebDavConfig`
6. 改 `backup_page.dart` 顶部 import（grep 确认 `File` / `jsonEncode` 是否其它路径仍用）
7. 加 8 个 test 到 `json_store_test.dart`
8. `flutter analyze` 验证
9. `flutter test` 验证（用户跑）
10. 更新 master report

### 测试 case 设计

```dart
group('json file (whole-file IO)', () {
  test('writeJsonFile then readJsonFile returns same map');
  test('readJsonFile returns null when file missing');
  test('readJsonFile returns null when content is malformed JSON');
  test('writeJsonFile is whole-file overwrite (does not merge)');
  test('deleteJsonFile removes the file');
  test('deleteJsonFile is a no-op when file missing');
  test('writeJsonFile rethrows on IO error (does not silently swallow)');
  test('concurrent writes to different fileNames serialize via shared lock');
  test('settings.json must not be used with whole-file API (documenting convention)');
});
```

注意第 7 个 test：与 explore audit 草稿不同 — 既然选 rethrow 策略，test 应验证 throw 行为，而不是验证静默吞错。

### 净 diff 估算

| 文件 | +行 | -行 | 净 |
|---|---|---|---|
| `lib/core/persistence/json_store.dart` | +35 | 0 | +35 |
| `lib/features/settings/webdav_config_page.dart` | +9 | -11 | -2 |
| `lib/features/settings/backup_page.dart` | +9 | -16 | -7 |
| `test/json_store_test.dart` | +85 | 0 | +85 |
| **合计** | **+138** | **-27** | **+111** |

## Research References

- 本任务 explore audit（in-context，未持久化到 research/）
- BATCH-18c archive：`.trellis/tasks/archive/2026-05/05-20-fix-batch-18c-json-store-abstraction/`（建立 json_store key-based API + _Mutex）
- BATCH-18e archive：`.trellis/tasks/archive/2026-05/05-21-batch-18e-f-w2b-022-features-documents/`（闭环 F-W2B-022 + 录入 F-W2A-058）
- F-W2A-058 finding：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-flutter-features.md`（F-W2B-022 Resolution 段尾 follow-up）
