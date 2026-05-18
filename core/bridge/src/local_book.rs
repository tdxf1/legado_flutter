//! # 本地书导入辅助 (批次 13 / 05-19)
//!
//! 把原 Legado `import/local/ImportBookActivity.kt` 的核心 MVP 流程拆成
//! 三个可单测的小函数：
//!
//! - [`ensure_local_source`]：保证 `id="local"` / `name="本地书"` /
//!   `url="loc_book"` 的虚拟书源存在，所有本地书的 `Book.source_id`
//!   都指向它（与 `BookType.localTag = "loc_book"` 对齐）。
//! - [`parser_chapters_to_storage`]：把 `core_parser::types::Chapter` 列
//!   表适配成 `core_storage::models::Chapter`，生成 UUID id、回填
//!   `book_id` / `index_num` / 时间戳，章末字符 offset 当 `end`。
//! - [`copy_to_local_books_dir`]：把用户选中的源文件复制到
//!   `<documents_dir>/local_books/<book_id>_<basename>`，避免原文件
//!   被移动 / 删除后阅读断链；目录不存在时 mkdir。
//!
//! 三个函数都不直接依赖 FRB，只用 std + uuid + chrono + rusqlite，
//! 这样能在 `#[cfg(test)]` 里直接 in-process 单测，不必跑 Flutter
//! 端。`pub(crate)` 是因为它们只供同 crate 的 [`crate::api::import_local_book`]
//! 用，不希望泄漏到外部。

use chrono::Utc;
use rusqlite::{params, Connection};
use std::fs;
use std::path::{Path, PathBuf};

/// 虚拟本地书源在 books 表外键里使用的固定 ID（与 `BookType.localTag`
/// 字面量"loc_book"配对，但 source_id 列存"local"避免和 url 字段同名
/// 混淆）。
pub(crate) const LOCAL_SOURCE_ID: &str = "local";

/// 本地书 url scheme 前缀；`Book.book_url = "loc_book:<absolute_path>"`
/// 在 reader 侧据此判断"这是一本本地书"。
pub(crate) const LOCAL_BOOK_URL_KEY: &str = "loc_book";

/// 确保虚拟"本地书"书源存在。返回该书源 id（恒等于 [`LOCAL_SOURCE_ID`]）。
///
/// 实现细节：先 `SELECT id FROM book_sources WHERE url = 'loc_book'`，
/// 命中即返回；否则按默认值 INSERT 一行。这样对 batch 13 单元测试反复
/// 调两次只插入一行的语义。
///
/// 用 `INSERT OR IGNORE`（基于 PK + UNIQUE(url) 双重约束）也能达成同样
/// 效果，但显式 SELECT-then-INSERT 更便于读懂"我在 upsert 一条虚拟
/// source"的意图，跟 [`crate::api::import_local_book`] 报错路径里"找不
/// 到 source 该往哪写"也对得上。
pub(crate) fn ensure_local_source(conn: &mut Connection) -> Result<String, String> {
    if let Ok(id) = conn.query_row(
        "SELECT id FROM book_sources WHERE url = ?1",
        params![LOCAL_BOOK_URL_KEY],
        |row| row.get::<_, String>(0),
    ) {
        return Ok(id);
    }
    let now = Utc::now().timestamp();
    conn.execute(
        "INSERT INTO book_sources (
            id, name, url, source_type, enabled, custom_order, weight,
            enabled_explore, last_update_time, created_at, updated_at
        ) VALUES (?1, ?2, ?3, 0, 0, 0, 0, 0, 0, ?4, ?4)",
        params![LOCAL_SOURCE_ID, "本地书", LOCAL_BOOK_URL_KEY, now],
    )
    .map_err(|e| format!("插入本地书虚拟书源失败: {}", e))?;
    Ok(LOCAL_SOURCE_ID.to_string())
}

/// 把 parser 输出的章节列表适配成 storage 层 schema。
///
/// 字段映射要点：
/// - `id`：每章生成新 UUID（storage 层主键不能复用 parser.index）。
/// - `book_id`：caller 传入。
/// - `index_num`：parser.index → i32（章节序号在书内的位置）。
/// - `url`：parser.href（仅 EPUB 有，其它 None → 留空字符串）。
/// - `content`：直接 `Some(parser.content)`，本地书一次性存全章正文。
/// - `is_volume = false / is_checked = true`：本地书相当于已下载状态。
/// - `start = 0`，`end = content.chars().count() as i32`：与 download
///   流程的章节进度计数对齐。
/// - `created_at = updated_at = now`：caller 传同一个 timestamp，避免
///   一次导入内时间戳漂移导致排序混乱。
pub(crate) fn parser_chapters_to_storage(
    parser_chapters: &[core_parser::types::Chapter],
    book_id: &str,
    now: i64,
) -> Vec<core_storage::models::Chapter> {
    parser_chapters
        .iter()
        .map(|c| core_storage::models::Chapter {
            id: uuid::Uuid::new_v4().to_string(),
            book_id: book_id.to_string(),
            index_num: c.index as i32,
            title: c.title.clone(),
            url: c.href.clone().unwrap_or_default(),
            content: Some(c.content.clone()),
            is_volume: false,
            is_checked: true,
            start: 0,
            end: c.content.chars().count() as i32,
            created_at: now,
            updated_at: now,
        })
        .collect()
}

/// 把源文件复制到 `<dest_dir>/local_books/<book_id>_<basename>`，返回
/// 拷贝后的绝对路径。
///
/// 复制而不是引用原路径的原因：原 Legado `ImportBookActivity` 也走
/// 同款 copy（`localBookDir/<bookId>_<filename>`），避免用户从相册 / U
/// 盘选完文件后挪走 / 删除导致 reader 打不开。`local_books` 目录不
/// 存在时 mkdir_p。
///
/// 目标文件名拼 `<book_id>_<basename>` 而不是直接 basename：同名书
/// 重复导入时不会互相覆盖，且日后清理时按前缀匹配 book_id 即可。
pub(crate) fn copy_to_local_books_dir(
    src: &Path,
    dest_dir: &Path,
    book_id: &str,
) -> Result<PathBuf, String> {
    let local_dir = dest_dir.join("local_books");
    fs::create_dir_all(&local_dir)
        .map_err(|e| format!("创建 local_books 目录失败: {}", e))?;
    let basename = src
        .file_name()
        .ok_or_else(|| "源文件名无效".to_string())?
        .to_string_lossy()
        .to_string();
    let dest_path = local_dir.join(format!("{}_{}", book_id, basename));
    fs::copy(src, &dest_path).map_err(|e| format!("复制文件失败: {}", e))?;
    Ok(dest_path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use core_storage::database::init_database;
    use std::io::Write;
    use tempfile::TempDir;

    fn open_test_db() -> (TempDir, Connection) {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("test.db");
        let conn = init_database(path.to_str().unwrap()).unwrap();
        (dir, conn)
    }

    #[test]
    fn test_ensure_local_source_creates_once() {
        let (_dir, mut conn) = open_test_db();
        let id1 = ensure_local_source(&mut conn).unwrap();
        let id2 = ensure_local_source(&mut conn).unwrap();
        assert_eq!(id1, LOCAL_SOURCE_ID);
        assert_eq!(id2, LOCAL_SOURCE_ID);
        // 仅插入一行
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM book_sources WHERE url = ?1",
                params![LOCAL_BOOK_URL_KEY],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 1);
    }

    #[test]
    fn test_parser_chapters_to_storage_maps_fields() {
        let parser_chapters = vec![
            core_parser::types::Chapter {
                title: "第一章".to_string(),
                content: "abcde".to_string(), // 5 chars
                index: 0,
                href: None,
            },
            core_parser::types::Chapter {
                title: "第二章".to_string(),
                content: "中文测试啊".to_string(), // 5 chars
                index: 1,
                href: Some("OEBPS/ch2.xhtml".to_string()),
            },
            core_parser::types::Chapter {
                title: "第三章".to_string(),
                content: "x".to_string(), // 1 char
                index: 2,
                href: None,
            },
        ];
        let now = 1_700_000_000;
        let storage = parser_chapters_to_storage(&parser_chapters, "book-xyz", now);
        assert_eq!(storage.len(), 3);
        for (i, ch) in storage.iter().enumerate() {
            assert_eq!(ch.index_num, i as i32);
            assert_eq!(ch.book_id, "book-xyz");
            assert_eq!(ch.created_at, now);
            assert_eq!(ch.updated_at, now);
            assert!(ch.is_checked);
            assert!(!ch.is_volume);
            assert_eq!(ch.start, 0);
            // ID 应为合法 UUID（36 字符）
            assert_eq!(ch.id.len(), 36);
            assert!(ch.content.is_some());
        }
        assert_eq!(storage[0].title, "第一章");
        assert_eq!(storage[0].url, ""); // href=None 留空
        assert_eq!(storage[0].end, 5);
        assert_eq!(storage[1].url, "OEBPS/ch2.xhtml"); // href 透传
        assert_eq!(storage[1].end, 5); // 中文 5 个字符
        assert_eq!(storage[2].end, 1);
        // UUID 互不相同
        assert_ne!(storage[0].id, storage[1].id);
        assert_ne!(storage[1].id, storage[2].id);
    }

    #[test]
    fn test_copy_to_local_books_dir_creates_dir_and_copies() {
        let dir = TempDir::new().unwrap();
        let docs = dir.path();
        // 准备一个源文件
        let src = dir.path().join("source.txt");
        let payload = b"hello world local book";
        let mut f = fs::File::create(&src).unwrap();
        f.write_all(payload).unwrap();
        drop(f);

        let book_id = "book-1234";
        let dest = copy_to_local_books_dir(&src, docs, book_id).unwrap();
        assert!(dest.exists(), "目标文件应存在");
        assert!(dest.starts_with(docs.join("local_books")));
        let dest_name = dest.file_name().unwrap().to_string_lossy().to_string();
        assert!(
            dest_name.starts_with(&format!("{}_", book_id)),
            "目标文件名应以 book_id 前缀开头: {}",
            dest_name
        );
        assert!(dest_name.ends_with("source.txt"));
        let copied = fs::read(&dest).unwrap();
        assert_eq!(copied.as_slice(), payload);
        // local_books 目录应被 mkdir_p
        assert!(docs.join("local_books").is_dir());
    }

    #[test]
    fn test_import_local_book_txt_roundtrip() {
        // 整链路 e2e：写一个 3 章节的 TXT → 调 import_local_book →
        // 解析返回 JSON → 在 DB 里能查到 1 本书 + 3 章节。
        let dir = TempDir::new().unwrap();
        let db_path = dir.path().join("test.db");
        // 先 init 一次 schema
        let _ = init_database(db_path.to_str().unwrap()).unwrap();
        let docs_dir = dir.path().to_path_buf();
        let txt_path = dir.path().join("我的本地书.txt");
        let content = "前言\n这是前言部分。\n\n第一章 起源\n这是第一章正文。\n\n\
第二章 发展\n这是第二章正文。\n";
        fs::write(&txt_path, content).unwrap();

        let json = crate::api::import_local_book(
            db_path.to_string_lossy().to_string(),
            txt_path.to_string_lossy().to_string(),
            docs_dir.to_string_lossy().to_string(),
        )
        .expect("import_local_book 应成功");
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        let book_id = v.get("book_id").and_then(|x| x.as_str()).unwrap();
        assert_eq!(book_id.len(), 36);

        // 验 DB
        let conn =
            core_storage::database::get_connection(db_path.to_str().unwrap()).unwrap();
        // 1 本书
        let books = core_storage::book_dao::BookDao::new(&conn).get_all().unwrap();
        assert_eq!(books.len(), 1);
        let book = &books[0];
        assert_eq!(book.id, book_id);
        assert_eq!(book.source_id, LOCAL_SOURCE_ID);
        assert!(book.book_url.as_deref().unwrap().starts_with("loc_book:"));
        // name fallback 到 basename(无扩展)
        assert_eq!(book.name, "我的本地书");
        // 3 章 = 前言 + 第一章 + 第二章
        assert_eq!(book.chapter_count, 3);
        let mut conn2 =
            core_storage::database::get_connection(db_path.to_str().unwrap()).unwrap();
        let chapters = core_storage::chapter_dao::ChapterDao::new(&mut conn2)
            .get_by_book(book_id)
            .unwrap();
        assert_eq!(chapters.len(), 3);
        // index 0..2 升序
        for (i, c) in chapters.iter().enumerate() {
            assert_eq!(c.index_num, i as i32);
            assert_eq!(c.book_id, book_id);
        }
        // local_books 目录内有复制后的源文件
        let copied_files: Vec<_> = fs::read_dir(docs_dir.join("local_books"))
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().to_string())
            .collect();
        assert_eq!(copied_files.len(), 1);
        assert!(copied_files[0].starts_with(&format!("{}_", book_id)));
    }
}
