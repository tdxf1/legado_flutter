//! # 缓存统计 DAO (批次 15 / 05-19)
//!
//! 对应原 Legado `CacheActivity.kt` 的"按书显示已缓存章节数 + 清空"功能。
//! "已缓存章节" 定义：`chapters.content IS NOT NULL AND chapters.content != ''`。
//!
//! ## 约定
//!
//! - 只读 + 批量 UPDATE，不动 chapters 行的存在性 / index / url。这点
//!   和"整本删章节"区分：删书时 SQLite FK CASCADE 自动清理章节
//!   （`chapters.book_id` 外键 ON DELETE CASCADE）；用户只想"释放空间
//!   但保留章节列表（标题 + url）以便重新拉"时走
//!   [`CacheStatsDao::clear_book_cache`]。
//! - 全部走 `&Connection`（不需要 `&mut`），可与其它只读 DAO 同实例
//!   并存。
//! - `clear_*` 返回受影响 chapters 行数（i64），方便上层 SnackBar
//!   反馈"清空了 N 章"。

use chrono::Utc;
use rusqlite::{params, Connection, Result as SqlResult};
use serde::{Deserialize, Serialize};
use tracing::{debug, info};

/// 单本书的缓存统计快照。Flutter 侧 `cache_management_page` 会把
/// 这个结构反序列化展示。`book_name` 来自 books.name 冗余以避免 UI
/// 端再 round-trip 一次。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookCacheStats {
    pub book_id: String,
    pub book_name: String,
    pub total_chapters: i64,
    pub cached_chapters: i64,
}

/// 缓存统计 DAO
pub struct CacheStatsDao<'a> {
    conn: &'a Connection,
}

impl<'a> CacheStatsDao<'a> {
    /// 创建新的 CacheStatsDao
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 单本已缓存章节数。
    ///
    /// SQL 上"已缓存"的判定与 [`list_books_with_cache_stats`] 严格一致：
    /// `content IS NOT NULL AND content != ''`。空串和 NULL 都视为"未
    /// 缓存"，避免 reader 写入空内容时误算。
    pub fn count_cached_chapters_for_book(&self, book_id: &str) -> SqlResult<i64> {
        self.conn.query_row(
            "SELECT COUNT(*) FROM chapters \
             WHERE book_id = ? AND content IS NOT NULL AND content != ''",
            params![book_id],
            |row| row.get(0),
        )
    }

    /// 列所有书的缓存统计。
    ///
    /// 排序：cached_chapters DESC，再按 name ASC（避免 cached=0 时
    /// 出现不稳定顺序）。`total_chapters` 用 books.chapter_count
    /// 冗余字段而不是 `SELECT COUNT(*) FROM chapters WHERE book_id = b.id`，
    /// 因为：
    /// 1. books.chapter_count 是写入 books 行时同步更新的（见
    ///    [`crate::BookDao::upsert`]），与目录表数对齐。
    /// 2. 真正的 chapters 行数若与 chapter_count 不一致，那是 chapters
    ///    表的内部一致性问题，不该归 cache stats 报。本 DAO 只关心
    ///    "几章已缓存"。
    pub fn list_books_with_cache_stats(&self) -> SqlResult<Vec<BookCacheStats>> {
        let mut stmt = self.conn.prepare(
            "SELECT b.id, b.name, b.chapter_count, \
                (SELECT COUNT(*) FROM chapters c \
                 WHERE c.book_id = b.id \
                   AND c.content IS NOT NULL \
                   AND c.content != '') AS cached \
             FROM books b \
             ORDER BY cached DESC, b.name ASC",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok(BookCacheStats {
                book_id: row.get(0)?,
                book_name: row.get(1)?,
                total_chapters: row.get::<_, i64>(2)?,
                cached_chapters: row.get::<_, i64>(3)?,
            })
        })?;
        rows.collect()
    }

    /// 单本清空：把该书所有 chapters.content 置为 NULL。
    /// 返回受影响的 chapters 行数（即原本有/没有 content 都会被 UPDATE 一次，
    /// 这里是 SQLite execute 的语义 — 上层若想得"清空了多少有内容的章"
    /// 应先调 [`count_cached_chapters_for_book`]）。
    ///
    /// 不动 chapters 行的 index / url / title，保证下次 reader 打开时
    /// 章节列表还在，只是 content 重新拉。
    pub fn clear_book_cache(&self, book_id: &str) -> SqlResult<i64> {
        info!("清空书籍缓存: book_id={}", book_id);
        let now = Utc::now().timestamp();
        let n = self.conn.execute(
            "UPDATE chapters SET content = NULL, updated_at = ? WHERE book_id = ?",
            params![now, book_id],
        )?;
        debug!("清空书籍 {} 缓存：受影响行数 {}", book_id, n);
        Ok(n as i64)
    }

    /// 全局清空：所有书的 chapters.content 全置 NULL。
    /// 返回受影响行数（= 当前 chapters 表总行数）。
    pub fn clear_all_cache(&self) -> SqlResult<i64> {
        info!("全局清空所有书籍缓存");
        let now = Utc::now().timestamp();
        let n = self.conn.execute(
            "UPDATE chapters SET content = NULL, updated_at = ?",
            params![now],
        )?;
        debug!("全局清空缓存：受影响行数 {}", n);
        Ok(n as i64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    /// 建一个临时 DB + 一个 book_source。Book/Chapter 由各 test 自行插。
    fn setup() -> (TempDir, Connection) {
        let dir = TempDir::new().unwrap();
        let db_path = dir.path().join("test.db");
        let conn = crate::database::init_database(db_path.to_str().unwrap()).unwrap();
        conn.execute(
            "INSERT INTO book_sources (id, name, url, created_at, updated_at) \
             VALUES ('source1', 'Source', 'https://example.com', 1, 1)",
            [],
        )
        .unwrap();
        (dir, conn)
    }

    fn insert_book(conn: &Connection, id: &str, name: &str, chapter_count: i32) {
        conn.execute(
            "INSERT INTO books (id, source_id, source_name, name, chapter_count, \
                                order_time, created_at, updated_at) \
             VALUES (?, 'source1', 'Source', ?, ?, 1, 1, 1)",
            params![id, name, chapter_count],
        )
        .unwrap();
    }

    /// 插一行 chapter（content 可选）。chapter id 同时作为 chapter URL
    /// 字段以避免唯一性冲突。
    fn insert_chapter(
        conn: &Connection,
        chapter_id: &str,
        book_id: &str,
        index: i32,
        content: Option<&str>,
    ) {
        conn.execute(
            "INSERT INTO chapters (id, book_id, index_num, title, url, content, \
                                   created_at, updated_at) \
             VALUES (?, ?, ?, ?, ?, ?, 1, 1)",
            params![
                chapter_id,
                book_id,
                index,
                format!("Chapter {index}"),
                format!("/{}/{}", book_id, chapter_id),
                content,
            ],
        )
        .unwrap();
    }

    #[test]
    fn test_count_cached_chapters() {
        let (_dir, conn) = setup();
        insert_book(&conn, "book1", "Book1", 5);
        // 5 章：3 章有 content，1 章空串（视为未缓存），1 章 NULL。
        insert_chapter(&conn, "c1", "book1", 0, Some("正文1"));
        insert_chapter(&conn, "c2", "book1", 1, Some("正文2"));
        insert_chapter(&conn, "c3", "book1", 2, Some("正文3"));
        insert_chapter(&conn, "c4", "book1", 3, Some(""));
        insert_chapter(&conn, "c5", "book1", 4, None);

        let dao = CacheStatsDao::new(&conn);
        let count = dao.count_cached_chapters_for_book("book1").unwrap();
        assert_eq!(count, 3, "只统计 content 非 NULL 且非空串的章节");

        // 不存在的 book → 0
        assert_eq!(
            dao.count_cached_chapters_for_book("nonexistent").unwrap(),
            0
        );
    }

    #[test]
    fn test_list_books_with_cache_stats() {
        let (_dir, conn) = setup();
        // book1: 3 章总 / 2 缓存
        insert_book(&conn, "book1", "三体", 3);
        insert_chapter(&conn, "c1a", "book1", 0, Some("a"));
        insert_chapter(&conn, "c1b", "book1", 1, Some("b"));
        insert_chapter(&conn, "c1c", "book1", 2, None);
        // book2: 5 章总 / 5 缓存（最高）
        insert_book(&conn, "book2", "球状闪电", 5);
        for i in 0..5 {
            insert_chapter(&conn, &format!("c2_{i}"), "book2", i, Some("x"));
        }
        // book3: 4 章总 / 0 缓存
        insert_book(&conn, "book3", "黑暗森林", 4);
        for i in 0..4 {
            insert_chapter(&conn, &format!("c3_{i}"), "book3", i, None);
        }

        let dao = CacheStatsDao::new(&conn);
        let stats = dao.list_books_with_cache_stats().unwrap();
        assert_eq!(stats.len(), 3);

        // 按 cached_chapters DESC 排序：book2(5) → book1(2) → book3(0)
        assert_eq!(stats[0].book_id, "book2");
        assert_eq!(stats[0].book_name, "球状闪电");
        assert_eq!(stats[0].total_chapters, 5);
        assert_eq!(stats[0].cached_chapters, 5);

        assert_eq!(stats[1].book_id, "book1");
        assert_eq!(stats[1].book_name, "三体");
        assert_eq!(stats[1].total_chapters, 3);
        assert_eq!(stats[1].cached_chapters, 2);

        assert_eq!(stats[2].book_id, "book3");
        assert_eq!(stats[2].cached_chapters, 0);
    }

    #[test]
    fn test_clear_book_cache_only_clears_target() {
        let (_dir, conn) = setup();
        insert_book(&conn, "bookA", "A", 2);
        insert_chapter(&conn, "ca1", "bookA", 0, Some("aa"));
        insert_chapter(&conn, "ca2", "bookA", 1, Some("bb"));
        insert_book(&conn, "bookB", "B", 2);
        insert_chapter(&conn, "cb1", "bookB", 0, Some("xx"));
        insert_chapter(&conn, "cb2", "bookB", 1, Some("yy"));

        let dao = CacheStatsDao::new(&conn);
        // 清 A
        let affected = dao.clear_book_cache("bookA").unwrap();
        assert_eq!(affected, 2);

        // A 全部 0 缓存，B 不变
        assert_eq!(dao.count_cached_chapters_for_book("bookA").unwrap(), 0);
        assert_eq!(dao.count_cached_chapters_for_book("bookB").unwrap(), 2);

        // 章节行还在（不是 delete）
        let n: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM chapters WHERE book_id = 'bookA'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(n, 2);
    }

    #[test]
    fn test_clear_all_cache() {
        let (_dir, conn) = setup();
        insert_book(&conn, "b1", "One", 2);
        insert_chapter(&conn, "x1", "b1", 0, Some("a"));
        insert_chapter(&conn, "x2", "b1", 1, Some("b"));
        insert_book(&conn, "b2", "Two", 2);
        insert_chapter(&conn, "x3", "b2", 0, Some("c"));
        insert_chapter(&conn, "x4", "b2", 1, Some("d"));

        let dao = CacheStatsDao::new(&conn);
        let affected = dao.clear_all_cache().unwrap();
        assert_eq!(affected, 4);

        // 两本书都 0 缓存
        assert_eq!(dao.count_cached_chapters_for_book("b1").unwrap(), 0);
        assert_eq!(dao.count_cached_chapters_for_book("b2").unwrap(), 0);

        // 但章节行依然存在
        let n: i64 = conn
            .query_row("SELECT COUNT(*) FROM chapters", [], |row| row.get(0))
            .unwrap();
        assert_eq!(n, 4);
    }
}
