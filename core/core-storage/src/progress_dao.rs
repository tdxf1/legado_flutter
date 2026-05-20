//! # 阅读进度 DAO (Data Access Object)
//!
//! 提供阅读进度相关的数据库操作。
//! 对应原 Legado 的 BookProgress 实体操作。

use super::models::{BookProgress, Bookmark};
use chrono::Utc;
use rusqlite::{params, Connection, Result as SqlResult};
use tracing::debug;

/// `bookmarks` 表 upsert 的 SQL 模板（11 列 INSERT + ON CONFLICT(id) DO UPDATE）。
///
/// 抽常量是因为 [`ProgressDao::add_bookmark`] 与
/// [`crate::backup_dao::upsert_bookmark`] 都要写同一行；之前主路径裸
/// `INSERT` 不带 `ON CONFLICT` 与 backup 路径的 upsert 风格分裂，对同
/// 一 id 二次添加表现不一致（主路径报 UNIQUE 违反、backup 路径覆盖）。
/// 批次 08 (BATCH-08 / F-W1A-010) 收口为单一 upsert SQL，让重复 id =
/// 二次添加 = idempotent 覆盖（caller 通常用 sha256 派生 id，重复 id 即
/// 同一 bookmark）。
///
/// 跨文件复用：`pub(crate)` 让 `backup_dao::upsert_bookmark` 直接复用。
pub(crate) const BOOKMARK_UPSERT_SQL: &str = "INSERT INTO bookmarks (
        id, book_id, chapter_index, paragraph_index, content,
        book_name, book_author, chapter_pos, chapter_name, book_text,
        created_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
        book_id = excluded.book_id,
        chapter_index = excluded.chapter_index,
        paragraph_index = excluded.paragraph_index,
        content = excluded.content,
        book_name = excluded.book_name,
        book_author = excluded.book_author,
        chapter_pos = excluded.chapter_pos,
        chapter_name = excluded.chapter_name,
        book_text = excluded.book_text";

/// 把一条 [`Bookmark`] 的 11 个字段按 [`BOOKMARK_UPSERT_SQL`] 占位符
/// 顺序绑定为 `params!(...)`。批次 08 (BATCH-08 / F-W1A-010)。
macro_rules! bookmark_upsert_params {
    ($bm:expr) => {
        rusqlite::params![
            $bm.id,
            $bm.book_id,
            $bm.chapter_index,
            $bm.paragraph_index,
            $bm.content,
            $bm.book_name,
            $bm.book_author,
            $bm.chapter_pos,
            $bm.chapter_name,
            $bm.book_text,
            $bm.created_at,
        ]
    };
}

// 跨文件复用：批次 08 (BATCH-08 / F-W1A-010)，让 backup_dao 复用本宏。
pub(crate) use bookmark_upsert_params;

/// 阅读进度 DAO
pub struct ProgressDao<'a> {
    conn: &'a Connection,
}

impl<'a> ProgressDao<'a> {
    /// 创建新的 ProgressDao
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 保存或更新阅读进度
    pub fn upsert(&self, progress: &BookProgress) -> SqlResult<()> {
        debug!(
            "保存阅读进度: book_id={}, chapter={}",
            progress.book_id, progress.chapter_index
        );

        self.conn.execute(
            "INSERT INTO book_progress (book_id, chapter_index, paragraph_index, offset, read_time, updated_at)
             VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(book_id) DO UPDATE SET
                chapter_index = excluded.chapter_index,
                paragraph_index = excluded.paragraph_index,
                offset = excluded.offset,
                read_time = excluded.read_time,
                updated_at = excluded.updated_at",
            params![
                progress.book_id,
                progress.chapter_index,
                progress.paragraph_index,
                progress.offset,
                progress.read_time,
                progress.updated_at,
            ],
        )?;

        Ok(())
    }

    /// 获取书籍的阅读进度
    pub fn get_by_book(&self, book_id: &str) -> SqlResult<Option<BookProgress>> {
        let mut stmt = self.conn.prepare(
            "SELECT book_id, chapter_index, paragraph_index, offset, read_time, updated_at
             FROM book_progress WHERE book_id = ?",
        )?;

        let mut rows = stmt.query(params![book_id])?;

        if let Some(row) = rows.next()? {
            Ok(Some(progress_from_row(row)?))
        } else {
            Ok(None)
        }
    }

    /// 更新阅读进度（便捷函数）
    pub fn update_progress(
        &self,
        book_id: &str,
        chapter_index: i32,
        paragraph_index: i32,
        offset: i32,
    ) -> SqlResult<()> {
        let now = Utc::now().timestamp();

        // 获取现有进度以累加阅读时长
        let existing = self.get_by_book(book_id)?;
        let read_time = existing.map(|p| p.read_time).unwrap_or(0);

        let progress = BookProgress {
            book_id: book_id.to_string(),
            chapter_index,
            paragraph_index,
            offset,
            read_time,
            updated_at: now,
        };

        self.upsert(&progress)
    }

    /// 增加阅读时长
    pub fn add_read_time(&self, book_id: &str, additional_ms: i64) -> SqlResult<()> {
        self.conn.execute(
            "UPDATE book_progress SET read_time = read_time + ?, updated_at = ? WHERE book_id = ?",
            params![additional_ms, Utc::now().timestamp(), book_id],
        )?;
        Ok(())
    }

    // 历史上的 `pub fn delete(&self, book_id: &str)` 全表
    // `DELETE WHERE book_id = ?` 已在批次 08 (BATCH-08 / F-W1A-018) 删除：
    // `book_progress.book_id` 是 `books.id` 的外键且 schema 设了 `ON DELETE
    // CASCADE`，删书时数据库自动清理；该 fn 0 caller 属死代码。如果未来
    // 重新需要按 book_id 清 progress，请优先用 SQLite FK CASCADE，再考虑
    // 显式 DAO。

    /// 添加书签。
    ///
    /// 批次 6 (v11): 写入新增字段 book_name / book_author /
    /// chapter_pos / chapter_name / book_text。这些字段对老 caller
    /// 的 `create_bookmark` 便捷函数为默认值（None / 0）；新 caller
    /// 直接构造 Bookmark struct 时可填。
    ///
    /// 批次 08 (BATCH-08 / F-W1A-010): 改 upsert（`INSERT ... ON CONFLICT(id)
    /// DO UPDATE`），与 [`crate::backup_dao::upsert_bookmark`] 风格统一。
    /// 重复 id 不再报 UNIQUE 违反 → 静默覆盖（caller 通常用 sha256(book_id|
    /// chapter_index|paragraph_index) 派生 id，重复 = 同一 bookmark 二次
    /// 添加，应 idempotent）。
    pub fn add_bookmark(&self, bookmark: &Bookmark) -> SqlResult<()> {
        debug!(
            "添加书签: book_id={}, chapter={}",
            bookmark.book_id, bookmark.chapter_index
        );

        self.conn
            .execute(BOOKMARK_UPSERT_SQL, bookmark_upsert_params!(bookmark))?;

        Ok(())
    }

    /// 删除书签
    pub fn delete_bookmark(&self, bookmark_id: &str) -> SqlResult<()> {
        self.conn
            .execute("DELETE FROM bookmarks WHERE id = ?", params![bookmark_id])?;
        Ok(())
    }

    /// 获取书籍的所有书签
    pub fn get_bookmarks(&self, book_id: &str) -> SqlResult<Vec<Bookmark>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, book_id, chapter_index, paragraph_index, content,
                    book_name, book_author, chapter_pos, chapter_name, book_text,
                    created_at
             FROM bookmarks WHERE book_id = ? ORDER BY chapter_index ASC, paragraph_index ASC",
        )?;

        let rows = stmt.query_map(params![book_id], bookmark_from_row)?;
        rows.collect()
    }

    /// 创建书签（便捷函数）
    pub fn create_bookmark(
        &self,
        book_id: &str,
        chapter_index: i32,
        paragraph_index: i32,
        content: Option<&str>,
    ) -> SqlResult<Bookmark> {
        let now = Utc::now().timestamp();
        let bookmark = Bookmark {
            id: uuid::Uuid::new_v4().to_string(),
            book_id: book_id.to_string(),
            chapter_index,
            paragraph_index,
            content: content.map(|s| s.to_string()),
            book_name: None,
            book_author: None,
            chapter_pos: 0,
            chapter_name: None,
            book_text: None,
            created_at: now,
        };

        self.add_bookmark(&bookmark)?;
        Ok(bookmark)
    }
}

/// 从数据库行转换到 BookProgress 结构体
fn progress_from_row(row: &rusqlite::Row) -> SqlResult<BookProgress> {
    Ok(BookProgress {
        book_id: row.get(0)?,
        chapter_index: row.get(1)?,
        paragraph_index: row.get(2)?,
        offset: row.get(3)?,
        read_time: row.get(4)?,
        updated_at: row.get(5)?,
    })
}

/// 从数据库行转换到 Bookmark 结构体。
/// 列顺序与 [`ProgressDao::get_bookmarks`] 的 SELECT 严格对齐。
fn bookmark_from_row(row: &rusqlite::Row) -> SqlResult<Bookmark> {
    Ok(Bookmark {
        id: row.get(0)?,
        book_id: row.get(1)?,
        chapter_index: row.get(2)?,
        paragraph_index: row.get(3)?,
        content: row.get(4)?,
        book_name: row.get(5)?,
        book_author: row.get(6)?,
        chapter_pos: row.get(7)?,
        chapter_name: row.get(8)?,
        book_text: row.get(9)?,
        created_at: row.get(10)?,
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
        conn.execute(
            "INSERT INTO books (id, source_id, source_name, name, order_time, created_at, updated_at) \
             VALUES ('book1', 's1', 'Source', 'Book', 1, 1, 1)",
            [],
        )
        .unwrap();
        (dir, conn)
    }

    fn make_bookmark(id: &str, chapter_index: i32, content: Option<&str>) -> Bookmark {
        Bookmark {
            id: id.to_string(),
            book_id: "book1".into(),
            chapter_index,
            paragraph_index: 0,
            content: content.map(|s| s.to_string()),
            book_name: None,
            book_author: None,
            chapter_pos: 0,
            chapter_name: None,
            book_text: None,
            created_at: 1,
        }
    }

    /// 批次 08 (BATCH-08 / F-W1A-010): `add_bookmark` 改 upsert 后，重复
    /// id 不再触发 UNIQUE 违反。第二次调用 = 同一 bookmark 的 idempotent
    /// 二次添加，新字段值覆盖旧值。
    #[test]
    fn add_bookmark_repeat_id_upserts_idempotently() {
        let (_dir, conn) = setup();
        let dao = ProgressDao::new(&conn);

        let bm1 = make_bookmark("bm-dup", 3, Some("first"));
        dao.add_bookmark(&bm1).expect("first add");

        // 第二次同 id：之前会报 UNIQUE violation；现在应静默覆盖
        let bm2 = make_bookmark("bm-dup", 3, Some("second"));
        dao.add_bookmark(&bm2).expect("second add (upsert)");

        // 表里应只有 1 行，content 是 second
        let all = dao.get_bookmarks("book1").unwrap();
        let dup: Vec<_> = all.iter().filter(|b| b.id == "bm-dup").collect();
        assert_eq!(dup.len(), 1, "duplicate id should not produce two rows");
        assert_eq!(dup[0].content.as_deref(), Some("second"));
    }
}
