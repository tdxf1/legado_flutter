# BATCH-27e: bookshelf 顶部菜单 add_url + import_bookshelf

## Goal

完成 bookshelf 顶部 PopupMenu 最后 2 项灰显占位（`add_url` 添加网址 +
`import_bookshelf` 导入书单），让 27a 表第 5/12 行达成「全部已实现」。
对齐 legado `BookshelfViewModel.addBookByUrl` (38-100) +
`importBookshelf` (131-186)。

## Requirements

### R1. add_url：添加网址

- bookshelf_page.dart PopupMenu 第 5 项 `add_url` 改 enabled +
  `_onAddUrl(context)` handler。
- 弹 `_AddUrlDialog`：单行 TextField「书籍 URL」+「添加」按钮。
  legado 支持多行 split，**MVP 先做单 URL**（多行留 27e-followup）。
- 调 Rust 新加 FRB `find_book_source_for_url(db_path, book_url)`
  (funcId 118)：先查 enabled 源 baseUrl 等 bookUrl 的 `getBaseUrl`，
  miss 则遍历 enabled 源中含 `book_url_pattern` 的 + regex 匹配。
- 找不到：SnackBar「未找到匹配书源，请先在「书源管理」中启用书源」
- 找到：调 `get_book_info_online(source_json, book_url)` 抓详情 +
  `get_chapter_list_online` 抓章节 → `save_book` + `replace_book_chapters`
- 抓抽报错：SnackBar「导入失败: $err」
- 成功：SnackBar「已添加：$bookName」+ `ref.invalidate(allBooksProvider)`

### R2. import_bookshelf：导入书单

- bookshelf_page.dart PopupMenu 第 12 项 `import_bookshelf` 改 enabled +
  `_onImportBookshelf(context)` handler。
- 弹 SimpleDialog 二选一：「手动粘贴 JSON」/「从文件导入」。对齐
  legado `importBookshelfAlert`（不含 isAbsUrl 抓 url 分支 — 留 followup）。
- 「手动粘贴」：`_PasteJsonDialog` 多行 TextField。
- 「从文件导入」：`file_picker.pickFiles(type: FileType.custom,
  allowedExtensions: ['json'])` → readAsString。
- json 格式：`List<Map<String, String?>>`，**容忍读** name+author
  （intro 可选忽略；legado 写 3 字段 export 但用户复制场景不一定齐）。
- 处理流程（对齐 legado `importBookshelfByJson:156-186`，复用
  search 栈范本）：
  1. parse json → 列表 `[{name, author, ...}]`
  2. 对每本：先查 `book_dao.has(name, author)` 重复跳过
  3. 调现有 `search_with_source_from_db_v2` 多源并行搜索 → 取首个
     匹配 `book.save()`
  4. 累计 `successCount / skipCount / failCount`
- 进度：**总结 SnackBar**「导入完成：成功 X / 跳过 Y / 失败 Z」（不
  弹 progress dialog；100 本以内可接受）。
- 失败 fallback：单本失败 try/catch + debugPrint，不弹错误流。

### R3. file_picker 依赖

- pubspec.yaml 检查 `file_picker` 是否已加（应该已有，import_local
  也用）；若没加 +0.0.x 版本 + `pub get`。

## Acceptance Criteria

- [ ] PopupMenu 第 5 项 `add_url` enabled / 第 12 项 `import_bookshelf`
      enabled
- [ ] 点 add_url 弹 dialog，输入 URL → 抓详情 → 入库 → SnackBar
- [ ] add_url 找不到匹配书源 → SnackBar「未找到匹配书源」
- [ ] add_url 抓抽报错 → SnackBar「导入失败: $err」
- [ ] 点 import_bookshelf 弹二选一 SimpleDialog
- [ ] 「手动粘贴」 → 多行 TextField → 解析 json → 批量 save
- [ ] 「从文件导入」 → file_picker → readAsString → 同上
- [ ] json 格式错（非 array / 字段缺失）→ SnackBar「格式不对」
- [ ] 总结 SnackBar「导入完成：成功 X / 跳过 Y / 失败 Z」
- [ ] flutter analyze 0 / flutter test all green
- [ ] ≥4 testWidgets：add_url 单 URL 成功 / 找不到书源 / import_bookshelf
      paste json 成功 / json 格式错

## Definition of Done

- spec 「bookshelf 顶部 menu (BATCH-27a)」表第 5/12 行同步 BATCH-27e
- spec 加 27e 子节（add_url URL→source pattern matching 契约 +
  import_bookshelf json 格式契约 + Forbidden 反向 ≥3 条）
- bookshelf_menu_test.dart 对齐 enabled/disabled 列表（add_url +
  import_bookshelf 移到 enabled）

## Decision (ADR-lite)

**Context**: 27a 顶部 PopupMenu 最后 2 项灰显占位需补齐。

**Decision**:

- 两项一起做（Q1，spec 一次升级），不拆 27e + 27e-followup
- add_url 走 Rust helper FRB `find_book_source_for_url`
  (Q2，避免 50KB+ JSON Dart 端 regex)
- import_bookshelf 二选一 dialog（Q3，对齐 legado）
- json 容忍读 name+author（Q4，与 legado 表现一致 + 复制场景友好）
- 总结 SnackBar 不弹 progress dialog（Q5，简化）
- add_url 两阶段失败分别提示（Q6，UX 友好）

**Consequences**:

- Rust 端加 1 个 dao helper + 1 个 FRB（funcId 118） — 工作量较 27c-2
  轻（仅 1 funcId）
- import_bookshelf 完全复用现有 `search_with_source_from_db_v2`，不
  引入 ImportBookshelfRunner（与 27b/27c-3 Runner 模式差异：单批
  100+ 本量级 acceptable，不需要后台续跑）
- 单 URL add（不批量多行）— 与 legado 行为有差距，留 27e-followup
- 不抓 URL json（legado isAbsUrl 分支）— 不常用，留 follow-up

## Out of Scope

- 多行 URL 批量 add（legado `\n` split） — 27e-followup
- import_bookshelf 「URL → 抓 json」（legado `text.isAbsUrl()` 分支）
  — 27e-followup
- ImportBookshelfRunner 后台续跑 — 不需要
- 书源管理 UI 改造 — 不在 27e 范围

## Technical Notes

### 锚源

- `legado/.../ui/main/bookshelf/BookshelfViewModel.kt:38-100`（addBookByUrl）
- `legado/.../ui/main/bookshelf/BookshelfViewModel.kt:131-186`（importBookshelf）
- `legado/.../ui/main/bookshelf/BaseBookshelfFragment.kt:102/119/242-260`
- `legado/.../data/dao/BookSourceDao.kt`（hasBookUrlPattern / getBookSourceAddBook）

### Flutter 端改动文件

- `flutter_app/lib/features/bookshelf/bookshelf_page.dart`：
  - PopupMenu 第 5/12 项 enabled + onSelected push 处理
  - 加 `_onAddUrl` + `_onImportBookshelf` handler
- 新建 `flutter_app/lib/features/bookshelf/_add_url_dialog.dart`
- 新建 `flutter_app/lib/features/bookshelf/_import_bookshelf_dialog.dart`

### Rust 端改动

- `core/core-storage/src/source_dao.rs` 加
  `find_source_for_book_url(book_url: &str)` helper（先 baseUrl 等于
  match，miss 则 enabled+book_url_pattern regex match）+ unit test
- `core/bridge/src/api.rs` 加 `find_book_source_for_url` (funcId 118)
- `core/bridge/build.rs` REQUIRED_*_FRAGMENTS 加 funcId 118
- `core/bridge/src/frb_generated.rs` wire impl + dispatcher arm

### 测试策略

- bookshelf_menu_test.dart：移 add_url + import_bookshelf 从
  disabledValues 到 enabledValues
- 新建 `bookshelf_add_url_test.dart` × 2-3 testWidgets
- 新建 `bookshelf_import_bookshelf_test.dart` × 2-3 testWidgets
- Rust unit test：`find_source_for_book_url` round-trip + 多种
  pattern 测试

## Research References

无（决策已通过 legado 锚源摸清 + Rust 端能力盘点 + Flutter search
栈复用度评估，不需 research-first）
