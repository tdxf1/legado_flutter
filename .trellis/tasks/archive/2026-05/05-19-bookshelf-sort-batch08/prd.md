# 书架排序 (批次 8)

## Goal

让书架支持**多种排序方式**：用户可在书架页切换排序（默认 / 名称 / 作者 / 加入时间 / 上次阅读 / 章节数），与原 Legado `AppConfig.bookshelfSort` 对齐。批次 6 已加 `dur_chapter_time` / `order_time` 等字段，本批次只在 Rust DAO 加 `ORDER BY` 参数化 + Flutter UI 加排序选择菜单。

## What I already know

- 批次 6 已加字段：`books.order_time`（加入时间，已在 baseline 用过）、`books.dur_chapter_time`（上次阅读时间戳）、`books.chapter_count`、`books.name`、`books.author`
- 批次 7 已有 `list_books_by_group(group_id)` 和 `get_all_books`，**没有 sort 参数**
- Rust `book_dao.rs` 当前 SELECT 无 ORDER BY（默认按 rowid 顺序）
- Flutter `bookshelf_page.dart` 已有 AppBar PopupMenu（批次 7 加的"管理分组"），可加"排序"项
- 原项目 `BookSourceSort.kt` enum：Default / Name / Author / TimeAdd / TimeUpdate / DurTime / ChapterCount

## Decision

**实现路径**：
1. Rust: 新增 `BookSort` enum (i32 标识) + `book_dao.rs` 两个查询都接 `sort: BookSort`
2. Bridge: `list_books_by_group` / `get_all_books` 加 `sort_order: i32` 参数（0 默认 / 1 名称 / 2 作者 / 3 加入时间 / 4 上次阅读 / 5 章节数）
3. Flutter: `ReaderSettings` 加 `bookshelfSort: int`（v7） + AppBar 加排序菜单（PopupMenuButton）+ `booksByGroupProvider` 改成 family `(groupId, sortOrder)`
4. 排序方向：所有排序都用 DESC（最近加入/最近读/字数多 在前）；名称/作者用 ASC

## Requirements

### Rust 端
1. **新增 `BookSort` enum** in `book_dao.rs`：
   - `Default = 0` (rowid ASC，等价当前行为)
   - `Name = 1` (name COLLATE NOCASE ASC)
   - `Author = 2` (author COLLATE NOCASE ASC)
   - `TimeAdd = 3` (order_time DESC)
   - `DurTime = 4` (dur_chapter_time DESC)
   - `ChapterCount = 5` (chapter_count DESC)
2. **`book_dao.rs::list_by_group` 加 `sort: i32` 参数**（0..=5，越界回 Default）
3. **`book_dao.rs::get_all_books` 加 `sort: i32` 参数**
4. **bridge api 改 2 个 fn 签名**：
   - `list_books_by_group(db_path, group_id, sort_order: i32)` 
   - `get_all_books(db_path, sort_order: i32)`
   - 旧调用方 Flutter 全部改成显式传 sortOrder（默认从 settings 读 0）

### Flutter 端
5. **`ReaderSettings` v7**：加 `int bookshelfSort = 0` 字段，`fromJson` 用 `?? 0`
6. **`bookshelfSortProvider`**：从 settings 派生 `int`
7. **`booksByGroupProvider` 改 family `((int groupId, int sort))`**：现有所有调用方改传 (groupId, sort)
8. **`bookshelf_page.dart` AppBar 加排序 PopupMenuButton**（图标 sort）：
   - 6 项 RadioListTile：默认/名称/作者/加入时间/上次阅读/章节数
   - 选中后 `_settingsRepo.update(bookshelfSort: idx)` 持久化 + provider invalidate

## Acceptance Criteria

- [ ] Rust: `cargo test -p core-storage` 全绿（含 BookSort 排序单测 ≥ 3 个）
- [ ] Rust: `cargo build -p bridge` 通过 + FRB regen 后 Dart 端可调
- [ ] Flutter: `flutter analyze` 0 issue
- [ ] Flutter: `flutter test` ≥ 343 (340 baseline + 排序 ≥ 3 新单测)
- [ ] 实机: 切换 6 种排序方式，列表立刻刷新；杀进程重进保留排序

## Definition of Done

- cargo + flutter test 全绿
- analyze 0 issue
- debug APK 构建到 dist/legado-arm64-debug-batch08-bookshelf-sort.apk
- commit "feat: 第四十七批 — 书架排序 (批次 8)" + archive
