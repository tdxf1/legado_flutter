# 缓存管理（按书统计 / 全局清空） (批次 15)

## Goal

让用户在设置页看到每本书已缓存了多少章节正文，并支持单本清空 / 全局清空。对齐原 Legado `CacheActivity.kt` 的"按书显示已缓存章节数 + 清空"功能。

## What I already know

- **chapters 表的 content 字段**：现有 `chapters.content TEXT` 字段，下载完成或 reader 读完后会被填入正文。"已缓存章节数 = `WHERE book_id = ? AND content IS NOT NULL AND content != ''`"
- **现有 download_dao**：`delete_with_files_in_root(task_id, root)` 在删 task 时一并清磁盘文件，但**不动 chapters.content**
- **chapter_dao 已有**：`update_content(chapter_id, content)`（写入正文），`delete_by_book(book_id)` 删整本章节（用于换源）
- 没有现成"清空 content 但保留章节列表"的 helper
- bookshelf "上次阅读" 副标题（批次 14）已经显示 dur_chapter_title，本批次的"按书统计"放到独立设置页

## Decision

**MVP 范围**：

### Rust 端
1. **新增 `core/core-storage/src/cache_stats_dao.rs`**：
   - `pub struct CacheStatsDao<'a>`
   - `fn count_cached_chapters_for_book(book_id: &str) -> i64` — 单本已缓存章节数
   - `fn list_books_with_cache_stats() -> Vec<BookCacheStats>` — 所有书 + 已缓存章节数（按 cached_count DESC）
   - `fn clear_book_cache(book_id: &str) -> i64` — 单本清空：`UPDATE chapters SET content = NULL WHERE book_id = ?`，返回受影响行数
   - `fn clear_all_cache() -> i64` — 全局清空：`UPDATE chapters SET content = NULL`，返回受影响行数
2. **新增 `BookCacheStats` struct**：`{ book_id, book_name, total_chapters, cached_chapters }`
3. **bridge api 加 4 个 pub fn**（同步）：
   - `count_cached_chapters_for_book(db_path, book_id) -> i64`
   - `list_books_with_cache_stats(db_path) -> JSON Vec<BookCacheStats>`
   - `clear_book_cache(db_path, book_id) -> i64`
   - `clear_all_cache(db_path) -> i64`

### Flutter 端
4. **新建 `lib/features/settings/cache_management_page.dart`** ConsumerStatefulWidget：
   - AppBar(title: "缓存管理")
   - 顶部 Card：总缓存章节数（sum of all books' cached_chapters）
   - 顶部 "全局清空"按钮（FilledButton.tonal，红色文字）→ AlertDialog 确认 → 调 clear_all_cache → invalidate bookChaptersProvider
   - ListView 每条：(book_name, "已缓存 X / Y 章")，trailing IconButton (delete_outline) 单本清空 → AlertDialog → clear_book_cache → invalidate
5. **路由注册** `/cache-management` → CacheManagementPage
6. **入口**：bookshelf_page AppBar PopupMenu 加"缓存管理"项（在批次 14 的"阅读统计"后）

### 测试
- Rust ≥ 4 单测：
  1. `test_count_cached_chapters` — 5 章其中 3 章有 content → count=3
  2. `test_list_books_with_cache_stats` — 多本书的 stats 完整且按 cached DESC 排序
  3. `test_clear_book_cache` — 清空一本不影响其它本
  4. `test_clear_all_cache` — 全部 content 变 NULL
- Flutter ≥ 1 widget test — cache_management_page 渲染 + 点"全局清空"调 mock 一次

## Acceptance Criteria

- [ ] cargo test core-storage ≥ 61 (57 baseline + 4)
- [ ] cargo test bridge ≥ 16（不变）
- [ ] cargo build bridge 通过 + FRB regen
- [ ] flutter analyze 0 issue
- [ ] flutter test ≥ 355 (354 baseline + 1)
- [ ] **手工验证**：reader 读几章 → 设置 → 缓存管理 → 看到该书 N 章缓存 → 点单本清空 → reader 重开同章重新拉

## Definition of Done

- cargo + flutter test 全绿
- analyze 0 issue
- 不打 APK
- commit "feat: 第五十四批 — 缓存管理（按书统计/清空）(批次 15)" + archive

## Out of Scope

- 缓存大小（字节数）显示 — content 字段是 TEXT，CHAR_LENGTH SUM 可行但意义不大（bookshelf 主要关心章节数）
- 自动清理过期缓存（30 天 / LRU）— MVP 不做
- 后台清理任务（用户主动清，不需要异步）
- chapters 表 content_size 列（如果以后要精确字节统计再考虑加 schema）
