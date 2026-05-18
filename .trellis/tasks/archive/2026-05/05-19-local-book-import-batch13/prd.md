# 本地书导入 MVP (批次 13)

## Goal

让用户能从书架顶栏添加本地 TXT / EPUB / UMD 文件，导入流程：选文件 → Rust 解析章节 → 复制到 `<documentsDir>/local_books/` → upsert 到 books 表（origin = "loc_book"）+ chapters 表 → 跳到书籍详情页。对齐原 Legado `import/local/ImportBookActivity.kt` MVP 行为。

## What I already know

- **Rust 解析器全部已就绪**（research feature-gap §1.8）：
  - `core/core-parser/src/txt.rs::parse_txt_file(path) -> Result<Vec<Chapter>>`
  - `core/core-parser/src/epub.rs::parse_epub_file(path) -> Result<(BookMetadata, Vec<Chapter>)>`
  - `core/core-parser/src/umd.rs::parse_umd_file(path) -> Result<Vec<Chapter>>`
- `core/bridge/Cargo.toml` 已 `core-parser = { path = "../core-parser" }` — 不需要新增依赖
- `core-parser::types::Chapter { title, content, index, href }` 与 storage::Chapter 字段不一致：
  - storage `Chapter { id, book_id, index_num, title, url, content, is_volume, is_checked, start, end, created_at, updated_at }`
  - 需要适配层把 parser 输出 → storage::Chapter（生成 UUID id / 给 book_id / index → index_num / url 留空 / is_volume false / 时间戳）
- `models::Book.book_url` 是 Option<String> — 本地书约定 `book_url = "loc_book:<absolute_path>"`（与原 Legado `BookType.localTag = "loc_book"` 一致）
- `models::Book.source_id` 必填，本地书需要一个虚拟 source。原 Legado 用 `origin = "loc_book"` 字面量；本工程 `source_id` 是 UUID 外键，需要先确保有一条 `id="local"` / `name="本地书"` / `url="loc_book"` 的虚拟书源（不存在则导入时插入）
- `pubspec.yaml` 已有 `file_picker: ^11.0.2`，可用于选 .txt/.epub/.umd 文件
- 批次 9 `book_info_edit_page.dart` 用过 `<documentsDir>/covers/` 目录，导入也走类似 `<documentsDir>/local_books/<bookId>_<basename>` 复制路径
- 批次 10 `backup_dao` 复用 `BookDao::upsert` + `ChapterDao::replace_by_book` 同款 DAO 入口

## Decision

**MVP 范围**：

### Rust 端
1. **新增 `core/bridge/src/api.rs::import_local_book(db_path, file_path, documents_dir) -> Result<String, String>`**
   - 返回新书的 book_id（JSON 字符串 `{"book_id": "..."}`）
   - 实现：
     1. 按文件后缀分发 `.txt` / `.epub` / `.umd` 调对应 parser
     2. **复制源文件**到 `<documents_dir>/local_books/<bookId>_<basename>` 防原文件移动断链
     3. 确保虚拟 source 存在（`SELECT id FROM book_sources WHERE url = 'loc_book'`，无则 insert `BookSource { id="local", name="本地书", url="loc_book", source_type=0, ... }`）
     4. 构造 `Book` 记录（`book_url = "loc_book:<copied_path>"` / `source_id = "local"` / `name = epub metadata.title || basename(without ext)` / `author = epub metadata.author || None` / `kind = None` / `chapter_count = chapters.len()` / `total_word_count = sum(content.chars().count())` / `cover_url = None` / `latest_chapter_title` = 最后章节 title）
     5. 把 parser 章节 → `storage::Chapter[]` 适配 → `ChapterDao::replace_by_book`
     6. `BookDao::upsert(&book)`
2. **新增 helper `core/bridge/src/local_book.rs`** 内部模块，封装：
   - `pub fn ensure_local_source(conn: &mut Connection) -> SqlResult<String>` — 返回 source_id="local"
   - `pub fn parser_chapters_to_storage(parser_chapters: &[parser::Chapter], book_id: &str) -> Vec<storage::Chapter>`
   - `pub fn copy_to_local_books_dir(src: &Path, dest_dir: &Path, book_id: &str) -> Result<PathBuf, String>`
3. **FRB regen** 同步 funcId 73：frb_generated.rs / api.dart / frb_generated.dart + build.rs

### Flutter 端
4. **改 `flutter_app/lib/features/bookshelf/bookshelf_page.dart`** AppBar PopupMenu 加"导入本地书"项（在"备份/恢复"后）：
   - 选中 → file_picker.pickFiles(type: custom, allowedExtensions: ['txt', 'epub', 'umd'])
   - 调 `rust_api.importLocalBook(dbPath, filePath, documentsDir)`
   - 解析返回 `book_id` → invalidate allBooksProvider + booksByGroupProvider → SnackBar "导入成功" + 自动跳到 reader（`context.push('/reader?bookId=$bookId')`）
5. **测试钩子**：在 bookshelf_page 加 `pickFileOverride` / `importBookOverride` 同模式

### 测试
- Rust ≥ 4 单测（在 bridge crate 内 `local_book.rs::tests`）：
  1. `test_ensure_local_source_creates_once` — 调两次只插入一条
  2. `test_parser_chapters_to_storage_maps_fields` — index → index_num / 时间戳填入 / book_id 一致
  3. `test_copy_to_local_books_dir_creates_dir_and_copies` — 不存在时 mkdir / copy 后文件大小一致
  4. `test_import_local_book_txt_roundtrip` — 用 tempfile 写一个简短 TXT (3 章节) → import → DB 里能查到 1 本书 + 3 章节
- Flutter ≥ 1 widget test — bookshelf_page 顶栏 PopupMenu 含 "导入本地书" 项 + 触发后调用 importBookOverride 一次

## Acceptance Criteria

- [ ] cargo test core-storage 仍 53 通过
- [ ] cargo test bridge ≥ baseline + 4
- [ ] cargo build bridge 通过
- [ ] flutter analyze 0 issue
- [ ] flutter test ≥ 351 (350 baseline + 1)
- [ ] **手工验证**：导入一个 .txt 文件 → 书架显示 → 点开能正常分页阅读

## Definition of Done

- cargo + flutter test 全绿
- analyze 0 issue
- 不打 APK
- commit "feat: 第五十二批 — 本地书导入 MVP (批次 13)" + archive

## Out of Scope

- mobi / pdf / cbz 格式（Rust 解析器还没写，留批次 17+）
- TxtTocRule 用户可配章节切分规则（feature-gap §1.10，留批次 14+）
- charset 自动检测扩展到 Big5 / Shift-JIS（feature-gap §1.9，留进阶）
- 多文件批量导入 / 文件夹扫描（MVP 单文件即可）
- 本地书 cover 提取（EPUB metadata cover 暂不导出图片，留进阶）
- 删除本地书时清理 `<documentsDir>/local_books/` 里的源文件（暂用 DownloadDao 同款"轻删"，文件留作 GC）
