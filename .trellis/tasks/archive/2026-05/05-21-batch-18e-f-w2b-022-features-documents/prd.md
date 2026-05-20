# BATCH-18e: F-W2B-022 features 层 documents 路径统一（方案 A）

## Goal

闭环 F-W2B-022（缩范围至方案 A）：把 `flutter_app/lib/` 内 5 处 features / core 层重复的 `Platform.isAndroid ? getApplicationDocumentsDirectory : getApplicationSupportDirectory` 三元式收拢到 BATCH-18c 已经公开的 `core/persistence/json_store.dart::resolvePersistenceDir()` helper。webdav.json 两处 read-modify-write 重复实现 + json_store API 是否支持任意 fileName 留独立批次（BATCH-18g）。

## What I already know

### 来自 BATCH-18d explore audit（2026-05-20）

**1. features 层 + core 层残余调用清单（共 5 处需改）**

| # | 文件 | 行号 | 用途 | 当前模式 |
|---|---|---|---|---|
| 1 | `flutter_app/lib/core/cover_cache.dart` | L30 | 封面缓存 `<dir>/covers/<hash>.<ext>` | 直调 `getApplicationDocumentsDirectory()` 不带 Platform 三元（默认 Android 路径，跨平台缺陷） |
| 2 | `flutter_app/lib/features/bookshelf/bookshelf_page.dart` | L280 | 透传给 Rust FRB `importLocalBook` | 直调 `getApplicationDocumentsDirectory()` 不带 Platform 三元 |
| 3 | `flutter_app/lib/features/bookshelf/book_info_edit_page.dart` | L286 | 封面文件复制 `<dir>/covers/<bookId>_<ts>.<ext>` | 直调 `getApplicationDocumentsDirectory()` |
| 4 | `flutter_app/lib/features/reader/widgets/reader_settings_sheet.dart` | L57-59 | 阅读器背景图 `<dir>/reader_backgrounds/bg_<ts>.jpg` | **完整三元式 `Platform.isAndroid ? Documents : Support`**（与 json_store 重复） |
| 5 | `flutter_app/lib/features/settings/webdav_config_page.dart` | L101-103 | `<dir>/webdav.json` 读写 | 直调 `getApplicationDocumentsDirectory()` 不带三元 |

**注意**：5 处中只有 1 处（`reader_settings_sheet.dart`）拷贝了完整 `Platform.isAndroid` 三元式，其它 4 处直接用 `getApplicationDocumentsDirectory()`，**Android 行为正确但其它平台拿到了错误目录**（Documents 而非 Support）。统一走 `resolvePersistenceDir()` 顺手修跨平台行为差异。

**2. 第 6 处 grep 命中**（已是 helper 不动）

`flutter_app/lib/core/persistence/json_store.dart:67-68` — 是 helper 定义本身，不动。

**3. backup_page.dart::_loadWebDavConfig (L474-494)**（**本批不动**）

```dart
final dir = widget.webdavConfigDirOverride ??
    (await getApplicationDocumentsDirectory()).path;
final f = File('$dir/webdav.json');
```

这里用了 `webdavConfigDirOverride` test override，且**整个 `_loadWebDavConfig` 函数是 webdav.json 完整 read-modify-write 模板**（与 webdav_config_page L108-117/180-187 重复）。本批方案 A 仅替换路径三元式，**保留 webdavConfigDirOverride 测试钩子**，仅把 fallback 路径换为 `resolvePersistenceDir()`。webdav.json read-modify-write 重复留 BATCH-18g 独立批次。

**4. 测试影响**

- `test/json_store_test.dart` 9 case 走 `directory:` 参数，与本批无关
- `test/backup_page_test.dart` 用 `webdavConfigDirOverride` override，不实际触发 path_provider，本批保留 override 不破
- `test/webdav_config_page_test.dart` 用 `configDirOverride: tmp.path` override，同上不破
- `test/bookshelf_local_import_test.dart` 用 `documentsDirOverride: '/fake/docs'` override，本批保留 override 不破
- 所有 5 处的 caller 行为等价（只多过了 `Platform.isAndroid` 三元式一层），**测试无需新增**

### 不在范围内（方案 A 缩范围）

- 扩 json_store API 支持任意 `fileName`（方案 B）
- webdav.json read-modify-write 模板抽公共 helper（重复在 webdav_config_page + backup_page 两处）
- `assetDirFor(name)` helper 抽 covers / reader_backgrounds 子目录创建（方案 C）

这三项留 **BATCH-18g**（webdav.json 重复 + json_store fileName 扩展，~80 行）独立批次。F-W2B-022 在本批 dismissed→缩范围闭环，BATCH-18g 是新独立 finding F-W2A-058 的修复批次（见下文）。

## Open Questions

（已收敛）

## Requirements (final)

### MVP scope（5 项 path 替换 + 1 项新 finding 录入 + 1 项 master report 同步）

1. **改 `flutter_app/lib/core/cover_cache.dart:30`**
   - `final dir = await getApplicationDocumentsDirectory(); final coversDir = Directory('${dir.path}/covers');`
   - 改为：`final dir = await resolvePersistenceDir(); final coversDir = Directory('$dir/covers');`
   - 加 `import '../core/persistence/json_store.dart';` 或相对 import
   - 顺手修跨平台行为：之前直接 `getApplicationDocumentsDirectory()` 在桌面平台拿 Documents 目录，与 db 路径（Support）不一致

2. **改 `flutter_app/lib/features/bookshelf/bookshelf_page.dart:280`**
   - `(await getApplicationDocumentsDirectory()).path` → `await resolvePersistenceDir()`
   - 改 import：`import 'package:legado_flutter/core/persistence/json_store.dart';`（路径以实际为准）
   - 透传 Rust FRB 的 documentsDir 应该和 dbPath 同一目录 — Android 不变，桌面对齐

3. **改 `flutter_app/lib/features/bookshelf/book_info_edit_page.dart:286`**
   - 同上模式

4. **改 `flutter_app/lib/features/reader/widgets/reader_settings_sheet.dart:57-59`**
   - 删除 3 行三元式 `final dir = Platform.isAndroid ? ... : ...`
   - 改为 `final dir = await resolvePersistenceDir();`
   - **顺手删** `import 'dart:io'`（如果文件其它地方不再用 `Platform`）— 这是该 finding 描述的"5 处中唯一与 json_store 完全重复"的代码

5. **改 `flutter_app/lib/features/settings/webdav_config_page.dart:101-103`**
   - `Future<String> _resolveDir() async { final docsDir = await getApplicationDocumentsDirectory(); return docsDir.path; }` 改为对 `resolvePersistenceDir()` 的简单 wrapper（保留 `configDirOverride` test 钩子）
   - 或直接删 `_resolveDir` 私有 helper，所有 caller 直接 `await resolvePersistenceDir()`（如果 override 处理不在 helper 内）— 看实际代码结构决定

6. **新增 finding F-W2A-058**（master report 录入，本批不修复）
   - 标题：webdav.json read-modify-write 模板在 webdav_config_page + backup_page 重复实现
   - File: `flutter_app/lib/features/settings/webdav_config_page.dart` + `flutter_app/lib/features/settings/backup_page.dart`
   - Status: Open（占位 BATCH-18g 处理）

7. **master report 同步**
   - F-W2B-022 标 "Resolved by BATCH-18e (方案 A 缩范围)"
   - 注意：发现 4 处直接 `getApplicationDocumentsDirectory()` 缺三元式跨平台问题，本批顺手修

### 不在范围内

- json_store API 扩展（任意 fileName）— BATCH-18g
- webdav.json read-modify-write 公共 helper — BATCH-18g
- assetDirFor(name) helper（covers / reader_backgrounds 等子目录）— 留独立 finding 或不做
- F-W2B-016 bookshelf PopupMenu 重组 — BATCH-18f

## Acceptance Criteria

- [ ] 5 处 caller 全部改为 `resolvePersistenceDir()`
- [ ] grep `getApplicationDocumentsDirectory\|getApplicationSupportDirectory` 在 `flutter_app/lib/` 下仅 1 处（`json_store.dart` helper 定义内部）
- [ ] grep `Platform.isAndroid.*getApplicationDocumentsDirectory` 在 `flutter_app/lib/` 下 0 命中（reader_settings_sheet 三元式已删）
- [ ] `flutter analyze` 0 warning
- [ ] `flutter test` 全部 PASS（393 维持，无需新增 test）
- [ ] master report `findings-flutter-features.md` F-W2B-022 标 "Resolution (BATCH-18e, 方案 A)"
- [ ] master report `findings.md` 主索引同步
- [ ] master report `findings-flutter-features.md` 新增 F-W2A-058 entry（webdav.json 重复模板，Open）
- [ ] master report `findings.md` 主索引加 F-W2A-058 行
- [ ] 现有 test override（`documentsDirOverride` / `webdavConfigDirOverride` / `configDirOverride`）保留不破

## Definition of Done

- 5 处路径三元式收拢到 `resolvePersistenceDir()`
- 跨平台行为一致（Android Documents / 其它 Support，与 db 路径对齐）
- F-W2B-022 闭环（方案 A）
- F-W2A-058 录入留 BATCH-18g

## Decision (ADR-lite)

**Context**: BATCH-18d explore audit 摸清 F-W2B-022 现状：5 处 features/core 层有 path 三元式或直调 `getApplicationDocumentsDirectory()`，外加 webdav_config_page + backup_page 两处 webdav.json read-modify-write 重复模板。三个候选方案 A/B/C 改动范围 50/100/120 行递增。

**Decision**: 选项 A（用户决策）— 仅路径三元式收拢，最小改动，零决策、零风险。webdav.json 重复 + json_store fileName 扩展拆 BATCH-18g 独立批次。

**Consequences**:
- ~50 行净 diff，5 个文件 1-3 行改动 + 4 处跨平台行为顺手修
- F-W2B-022 闭环（缩范围 by ADR-lite，不再覆盖 webdav.json 模板）
- F-W2A-058 新 finding 占位防 webdav.json 重复模板被遗忘
- 测试零新增（5 处行为等价）

## Technical Notes

### 风险点

- **跨平台行为变化**：cover_cache / bookshelf_page / book_info_edit_page / webdav_config_page 当前在桌面平台拿 Documents 目录，统一走 `resolvePersistenceDir()` 后桌面会改用 Support 目录。Android 行为不变（Documents）。**用户的 cover 缓存 / webdav 配置在桌面端会"失效"** — 旧文件留在 Documents，新文件写到 Support。
- 评估：当前主线是 Android（pubspec/CI 看），桌面端是否真有用户?
- 缓解：cover_cache 失效是缓存丢失，无害（重新下）；webdav.json 配置丢失要用户重新填，需评估
- **如果决定保留桌面端旧路径**：方案 A 不动，加注释说明 `resolvePersistenceDir()` 在桌面端是 Support 目录。或本批对应 5 处只改有 Platform 三元式的 1 处（reader_settings_sheet），其它 4 处保持现状

### 实施前需确认（**Blocking**）

桌面端是否真有用户？如果是 Android-only：5 处全改没风险。如果有桌面用户：cover_cache 改无所谓，webdav_config_page 改可能让用户重填配置。

### 实施顺序

1. read 5 处 caller 当前代码（确认 import 风格 + 测试 override）
2. 按 5 处依序改：cover_cache → bookshelf_page → book_info_edit_page → reader_settings_sheet → webdav_config_page
3. 每改一个 grep 验证 caller 无残留 path 三元式
4. `flutter analyze` 验证 import 清理 + 无 unused
5. 用户跑 `flutter test`
6. 更新 master report：F-W2B-022 标 Resolution + 新增 F-W2A-058 entry
7. archive + commit

### F-W2A-058 草稿（master report）

```
**F-W2A-058: webdav.json read-modify-write 模板在 features 层重复实现**

Status: Open（识别于 BATCH-18e，2026-05-20）
Files: 
- flutter_app/lib/features/settings/webdav_config_page.dart:108-117 (load) + L180-187 (save)
- flutter_app/lib/features/settings/backup_page.dart:474-494 (load only)

webdav.json 配置文件的"打开 → jsonDecode Map → 字段提取 → 改字段 → 
jsonEncode → writeAsString"完整 read-modify-write 模板在两个文件分别
重写。json_store helper 当前仅支持 settings.json 单文件。

修复方向：扩 json_store API 支持任意 fileName（如 readJsonFile<T> / 
writeJsonFile / deleteJsonFile）+ 迁 webdav.json 两处 caller 走新 helper。
等价 BATCH-18d audit 列出的方案 B（约 +80 行）。

不阻塞 BATCH-18e（方案 A 已闭环 F-W2B-022），独立 BATCH-18g 处理。
```

## Research References

- 本任务沿用 BATCH-18d explore audit（in-context，未持久化到 research/）
- BATCH-18c archive：`.trellis/tasks/archive/2026-05/05-20-fix-batch-18c-json-store-abstraction/`（建立 json_store helper + resolvePersistenceDir）
- BATCH-18d archive：`.trellis/tasks/archive/2026-05/05-20-batch-18d-flutter-w2a-w2b-finding/`（沿用 audit）
- F-W2B-022 finding：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-flutter-features.md:298-307`
