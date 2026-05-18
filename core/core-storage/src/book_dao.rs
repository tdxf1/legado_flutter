//! # 书籍 DAO (Data Access Object)
//!
//! 提供书籍相关的数据库操作。
//! 对应原 Legado 的 Book 实体操作 (data/entities/Book.kt)
//!
//! 批次 6 (v11): SELECT/INSERT/UPDATE 列表新增 5 字段
//! `dur_chapter_index / dur_chapter_pos / dur_chapter_title /
//!  dur_chapter_time / group_id`，对齐 schema v11。
//! 列顺序固定常量 [`BOOK_COLUMNS`] 保证 SELECT/INSERT/UPDATE 同步。

use super::models::Book;
use chrono::Utc;
use rusqlite::{params, Connection, Result as SqlResult};
use tracing::{debug, info};
use uuid::Uuid;

/// books 表读取列顺序的单一来源。
/// SELECT/INSERT/UPDATE 都基于此常量构建，避免列错位。
/// 顺序与 [`book_from_row`] 内 `row.get(N)` 索引必须一致。
const BOOK_COLUMNS: &str = "id, source_id, source_name, name, author, cover_url, chapter_count, \
    latest_chapter_title, intro, kind, book_url, toc_url, last_check_time, last_check_count, \
    total_word_count, can_update, order_time, latest_chapter_time, \
    custom_cover_path, custom_info_json, \
    dur_chapter_index, dur_chapter_pos, dur_chapter_title, dur_chapter_time, group_id, \
    created_at, updated_at";

/// 书籍 DAO
pub struct BookDao<'a> {
    conn: &'a Connection,
}

impl<'a> BookDao<'a> {
    /// 创建新的 BookDao
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 插入或更新书籍
    pub fn upsert(&self, book: &Book) -> SqlResult<()> {
        debug!(
            "插入/更新书籍: {} - {}",
            book.name,
            book.author.as_deref().unwrap_or("")
        );

        // 27 列 → 27 个占位符。批次 6 (v11) 在 v10 基础上新增 5 个 dur_*/group_id 字段。
        self.conn.execute(
            "INSERT INTO books (
                id, source_id, source_name, name, author, cover_url, chapter_count,
                latest_chapter_title, intro, kind, book_url, toc_url, last_check_time, last_check_count,
                total_word_count, can_update, order_time, latest_chapter_time,
                custom_cover_path, custom_info_json,
                dur_chapter_index, dur_chapter_pos, dur_chapter_title, dur_chapter_time, group_id,
                created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                source_id = excluded.source_id,
                source_name = excluded.source_name,
                name = excluded.name,
                author = excluded.author,
                cover_url = excluded.cover_url,
                chapter_count = excluded.chapter_count,
                latest_chapter_title = excluded.latest_chapter_title,
                intro = excluded.intro,
                kind = excluded.kind,
                book_url = excluded.book_url,
                toc_url = excluded.toc_url,
                last_check_time = excluded.last_check_time,
                last_check_count = excluded.last_check_count,
                total_word_count = excluded.total_word_count,
                can_update = excluded.can_update,
                order_time = excluded.order_time,
                latest_chapter_time = excluded.latest_chapter_time,
                custom_cover_path = excluded.custom_cover_path,
                custom_info_json = excluded.custom_info_json,
                dur_chapter_index = excluded.dur_chapter_index,
                dur_chapter_pos = excluded.dur_chapter_pos,
                dur_chapter_title = excluded.dur_chapter_title,
                dur_chapter_time = excluded.dur_chapter_time,
                group_id = excluded.group_id,
                updated_at = excluded.updated_at",
            params![
                book.id,
                book.source_id,
                book.source_name,
                book.name,
                book.author,
                book.cover_url,
                book.chapter_count,
                book.latest_chapter_title,
                book.intro,
                book.kind,
                book.book_url,
                book.toc_url,
                book.last_check_time,
                book.last_check_count,
                book.total_word_count,
                book.can_update as i32,
                book.order_time,
                book.latest_chapter_time,
                book.custom_cover_path,
                book.custom_info_json,
                book.dur_chapter_index,
                book.dur_chapter_pos,
                book.dur_chapter_title,
                book.dur_chapter_time,
                book.group_id,
                book.created_at,
                book.updated_at,
            ],
        )?;

        Ok(())
    }

    /// 根据 ID 获取书籍
    pub fn get_by_id(&self, id: &str) -> SqlResult<Option<Book>> {
        let sql = format!("SELECT {} FROM books WHERE id = ?", BOOK_COLUMNS);
        let mut stmt = self.conn.prepare(&sql)?;

        let mut rows = stmt.query(params![id])?;

        if let Some(row) = rows.next()? {
            Ok(Some(book_from_row(row)?))
        } else {
            Ok(None)
        }
    }

    /// 获取所有书籍（按排序时间倒序）
    pub fn get_all(&self) -> SqlResult<Vec<Book>> {
        let sql = format!("SELECT {} FROM books ORDER BY order_time DESC", BOOK_COLUMNS);
        let mut stmt = self.conn.prepare(&sql)?;

        let rows = stmt.query_map([], book_from_row)?;
        rows.collect()
    }

    /// 根据书源 ID 获取书籍
    pub fn get_by_source(&self, source_id: &str) -> SqlResult<Vec<Book>> {
        let sql = format!(
            "SELECT {} FROM books WHERE source_id = ? ORDER BY order_time DESC",
            BOOK_COLUMNS
        );
        let mut stmt = self.conn.prepare(&sql)?;

        let rows = stmt.query_map(params![source_id], book_from_row)?;
        rows.collect()
    }

    /// 删除书籍
    pub fn delete(&self, id: &str) -> SqlResult<()> {
        info!("删除书籍: {}", id);
        self.conn
            .execute("DELETE FROM books WHERE id = ?", params![id])?;
        // 章节会因外键级联删除
        Ok(())
    }

    /// 搜索书籍
    pub fn search(&self, keyword: &str) -> SqlResult<Vec<Book>> {
        let sql = format!(
            "SELECT {} FROM books \
             WHERE name LIKE ? OR author LIKE ? \
             ORDER BY order_time DESC",
            BOOK_COLUMNS
        );
        let mut stmt = self.conn.prepare(&sql)?;

        let pattern = format!("%{}%", keyword);
        let rows = stmt.query_map(params![pattern, pattern], book_from_row)?;
        rows.collect()
    }

    /// 按分组列出书籍。
    ///
    /// 批次 7 (2026-05): 配合书架顶栏 TabBar 切换分组。
    /// - `group_id == -1` → 列出所有书（"全部" Tab，等价 [`get_all`]）
    /// - `group_id == 0`  → "未分组" Tab，列出 `WHERE group_id = 0`
    /// - `group_id >= 1`  → 具体某个用户分组，列出 `WHERE group_id = ?`
    ///
    /// 排序与 [`get_all`] 保持一致（`order_time DESC`），UI 端不需要为
    /// 不同 Tab 单独维护排序状态。
    pub fn list_by_group(&self, group_id: i64) -> SqlResult<Vec<Book>> {
        if group_id == -1 {
            return self.get_all();
        }
        let sql = format!(
            "SELECT {} FROM books WHERE group_id = ? ORDER BY order_time DESC",
            BOOK_COLUMNS
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt.query_map(params![group_id], book_from_row)?;
        rows.collect()
    }

    /// 把一本书移到指定分组（`group_id = 0` 表示移回"未分组"）。
    /// 同时刷新 `updated_at`，让书架排序能感知到"刚移过来"。
    pub fn set_group(&self, book_id: &str, group_id: i64) -> SqlResult<()> {
        info!("移动书籍到分组: book_id={}, group_id={}", book_id, group_id);
        let now = Utc::now().timestamp();
        self.conn.execute(
            "UPDATE books SET group_id = ?, updated_at = ? WHERE id = ?",
            params![group_id, now, book_id],
        )?;
        Ok(())
    }

    /// 创建新书籍（便捷函数）
    pub fn create(
        &self,
        source_id: &str,
        source_name: Option<&str>,
        name: &str,
        author: Option<&str>,
    ) -> SqlResult<Book> {
        let now = Utc::now().timestamp();
        let book = Book {
            id: Uuid::new_v4().to_string(),
            source_id: source_id.to_string(),
            source_name: source_name.map(|s| s.to_string()),
            name: name.to_string(),
            author: author.map(|s| s.to_string()),
            cover_url: None,
            chapter_count: 0,
            latest_chapter_title: None,
            intro: None,
            kind: None,
            book_url: None,
            toc_url: None,
            last_check_time: None,
            last_check_count: 0,
            total_word_count: 0,
            can_update: true,
            order_time: now,
            latest_chapter_time: None,
            custom_cover_path: None,
            custom_info_json: None,
            dur_chapter_index: 0,
            dur_chapter_pos: 0,
            dur_chapter_title: None,
            dur_chapter_time: 0,
            group_id: 0,
            created_at: now,
            updated_at: now,
        };

        self.upsert(&book)?;
        Ok(book)
    }
}

/// 从数据库行转换到 Book 结构体。
/// 列顺序与 [`BOOK_COLUMNS`] 严格对齐 — 改一处必须同步另一处。
fn book_from_row(row: &rusqlite::Row) -> SqlResult<Book> {
    Ok(Book {
        id: row.get(0)?,
        source_id: row.get(1)?,
        source_name: row.get(2)?,
        name: row.get(3)?,
        author: row.get(4)?,
        cover_url: row.get(5)?,
        chapter_count: row.get(6)?,
        latest_chapter_title: row.get(7)?,
        intro: row.get(8)?,
        kind: row.get(9)?,
        book_url: row.get(10)?,
        toc_url: row.get(11)?,
        last_check_time: row.get(12)?,
        last_check_count: row.get(13)?,
        total_word_count: row.get(14)?,
        can_update: row.get::<_, i32>(15)? != 0,
        order_time: row.get(16)?,
        latest_chapter_time: row.get(17)?,
        custom_cover_path: row.get(18)?,
        custom_info_json: row.get(19)?,
        dur_chapter_index: row.get(20)?,
        dur_chapter_pos: row.get(21)?,
        dur_chapter_title: row.get(22)?,
        dur_chapter_time: row.get(23)?,
        group_id: row.get(24)?,
        created_at: row.get(25)?,
        updated_at: row.get(26)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn setup() -> (TempDir, Connection) {
        let dir = TempDir::new().unwrap();
        let db_path = dir.path().join("test.db");
        let conn = crate::database::init_database(db_path.to_str().unwrap()).unwrap();
        conn.execute(
            "INSERT INTO book_sources (id, name, url, created_at, updated_at) \
             VALUES ('s1', 'Source', 'https://e', 1, 1)",
            [],
        )
        .unwrap();
        (dir, conn)
    }

    fn book_with_group(id: &str, group_id: i64, order_time: i64) -> Book {
        Book {
            id: id.to_string(),
            source_id: "s1".to_string(),
            source_name: Some("Source".to_string()),
            name: format!("Book {id}"),
            author: None,
            cover_url: None,
            chapter_count: 0,
            latest_chapter_title: None,
            intro: None,
            kind: None,
            book_url: None,
            toc_url: None,
            last_check_time: None,
            last_check_count: 0,
            total_word_count: 0,
            can_update: true,
            order_time,
            latest_chapter_time: None,
            custom_cover_path: None,
            custom_info_json: None,
            dur_chapter_index: 0,
            dur_chapter_pos: 0,
            dur_chapter_title: None,
            dur_chapter_time: 0,
            group_id,
            created_at: 1,
            updated_at: 1,
        }
    }

    #[test]
    fn test_list_by_group_filters_correctly() {
        let (_dir, conn) = setup();
        let dao = BookDao::new(&conn);
        // 3 本未分组 + 2 本到分组 1 + 1 本到分组 2
        dao.upsert(&book_with_group("u1", 0, 1)).unwrap();
        dao.upsert(&book_with_group("u2", 0, 2)).unwrap();
        dao.upsert(&book_with_group("u3", 0, 3)).unwrap();
        dao.upsert(&book_with_group("g1a", 1, 4)).unwrap();
        dao.upsert(&book_with_group("g1b", 1, 5)).unwrap();
        dao.upsert(&book_with_group("g2a", 2, 6)).unwrap();

        // group_id == -1：全部，order_time DESC
        let all = dao.list_by_group(-1).unwrap();
        assert_eq!(all.len(), 6);
        assert_eq!(all[0].id, "g2a"); // order_time=6 最新

        // group_id == 0：未分组
        let ungrouped = dao.list_by_group(0).unwrap();
        assert_eq!(ungrouped.len(), 3);
        assert!(ungrouped.iter().all(|b| b.group_id == 0));

        // group_id == 1：分组 1
        let g1 = dao.list_by_group(1).unwrap();
        assert_eq!(g1.len(), 2);
        assert!(g1.iter().all(|b| b.group_id == 1));

        // group_id == 99：空分组
        let empty = dao.list_by_group(99).unwrap();
        assert!(empty.is_empty());
    }

    #[test]
    fn test_set_group_moves_book() {
        let (_dir, conn) = setup();
        let dao = BookDao::new(&conn);
        dao.upsert(&book_with_group("b1", 0, 1)).unwrap();

        dao.set_group("b1", 5).unwrap();
        let b = dao.get_by_id("b1").unwrap().unwrap();
        assert_eq!(b.group_id, 5);

        // 再移回未分组
        dao.set_group("b1", 0).unwrap();
        let b2 = dao.get_by_id("b1").unwrap().unwrap();
        assert_eq!(b2.group_id, 0);
    }
}
