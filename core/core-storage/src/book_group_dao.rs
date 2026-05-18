//! # 书架分组 DAO (Data Access Object)
//!
//! 批次 7：书架分组功能。schema 在批次 6 (v11) 已就位 (`book_groups` 表 +
//! `Book.group_id`)，本模块提供 CRUD 操作。
//!
//! ## 约定
//!
//! - `id = 0` 代表"未分组"虚拟分组（不入库，由 `Book.group_id` 默认值
//!   `0` 体现）。`book_groups.id` AUTOINCREMENT 从 1 开始所以不会冲突。
//! - 删除分组时显式把组内书的 `group_id` 重置为 0（不靠外键 ON DELETE
//!   CASCADE — 见 PRD Notes）。重置 + 删除走同一个事务保证原子性。

use super::models::BookGroup;
use chrono::Utc;
use rusqlite::{params, Connection, Result as SqlResult};
use tracing::{debug, info};

/// `book_groups` 列读取顺序的单一来源。SELECT/INSERT 都基于此构建，
/// 列顺序与 [`book_group_from_row`] 内 `row.get(N)` 索引一致。
const BOOK_GROUP_COLUMNS: &str =
    "id, name, sort_order, cover, show, book_sort, created_at, updated_at";

/// 书架分组 DAO
pub struct BookGroupDao;

impl BookGroupDao {
    /// 列出所有分组（按 sort_order ASC，再按 id ASC）
    pub fn list_all(conn: &Connection) -> SqlResult<Vec<BookGroup>> {
        let sql = format!(
            "SELECT {} FROM book_groups ORDER BY sort_order ASC, id ASC",
            BOOK_GROUP_COLUMNS
        );
        let mut stmt = conn.prepare(&sql)?;
        let rows = stmt.query_map([], book_group_from_row)?;
        rows.collect()
    }

    /// 按 ID 获取分组
    pub fn get_by_id(conn: &Connection, id: i64) -> SqlResult<Option<BookGroup>> {
        let sql = format!(
            "SELECT {} FROM book_groups WHERE id = ?",
            BOOK_GROUP_COLUMNS
        );
        let mut stmt = conn.prepare(&sql)?;
        let mut rows = stmt.query(params![id])?;
        if let Some(row) = rows.next()? {
            Ok(Some(book_group_from_row(row)?))
        } else {
            Ok(None)
        }
    }

    /// 创建新分组（sort_order 由调用方指定；返回完整 row）
    pub fn create(conn: &Connection, name: &str, sort_order: i32) -> SqlResult<BookGroup> {
        debug!("创建书架分组: name={}, sort_order={}", name, sort_order);
        let now = Utc::now().timestamp();
        conn.execute(
            "INSERT INTO book_groups (name, sort_order, cover, show, book_sort, created_at, updated_at) \
             VALUES (?, ?, NULL, 1, 0, ?, ?)",
            params![name, sort_order, now, now],
        )?;
        let new_id = conn.last_insert_rowid();
        // 拿回完整 row（show / book_sort 用 schema 默认值）。
        Self::get_by_id(conn, new_id)?.ok_or_else(|| {
            rusqlite::Error::SqliteFailure(
                rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_INTERNAL),
                Some("created book_group not found".to_string()),
            )
        })
    }

    /// 更新分组的 name + sort_order（其它字段批次 7 暂不暴露给上层修改）
    pub fn update(conn: &Connection, id: i64, name: &str, sort_order: i32) -> SqlResult<()> {
        debug!("更新书架分组: id={}, name={}", id, name);
        let now = Utc::now().timestamp();
        conn.execute(
            "UPDATE book_groups SET name = ?, sort_order = ?, updated_at = ? WHERE id = ?",
            params![name, sort_order, now, id],
        )?;
        Ok(())
    }

    /// 删除分组：把组内书的 group_id 重置为 0（未分组），再删除分组本身。
    /// 走显式事务保证两步原子性 — 任何一步失败都不会留下"组没了但书还
    /// 指向 deleted id"的脏数据。
    pub fn delete(conn: &mut Connection, id: i64) -> SqlResult<()> {
        info!("删除书架分组: id={}", id);
        let tx = conn.transaction()?;
        tx.execute(
            "UPDATE books SET group_id = 0, updated_at = ? WHERE group_id = ?",
            params![Utc::now().timestamp(), id],
        )?;
        tx.execute("DELETE FROM book_groups WHERE id = ?", params![id])?;
        tx.commit()?;
        Ok(())
    }
}

/// 从数据库行转换到 BookGroup 结构体。列顺序与 [`BOOK_GROUP_COLUMNS`]
/// 严格对齐 — 改一处必须同步另一处。
fn book_group_from_row(row: &rusqlite::Row) -> SqlResult<BookGroup> {
    Ok(BookGroup {
        id: row.get(0)?,
        name: row.get(1)?,
        sort_order: row.get(2)?,
        cover: row.get(3)?,
        show: row.get::<_, i32>(4)? != 0,
        book_sort: row.get(5)?,
        created_at: row.get(6)?,
        updated_at: row.get(7)?,
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
        (dir, conn)
    }

    #[test]
    fn test_create_and_list() {
        let (_dir, conn) = setup();
        let g1 = BookGroupDao::create(&conn, "玄幻", 1).unwrap();
        let g2 = BookGroupDao::create(&conn, "科幻", 0).unwrap();
        let g3 = BookGroupDao::create(&conn, "都市", 2).unwrap();

        assert!(g1.id >= 1);
        assert_eq!(g1.name, "玄幻");
        assert!(g1.show);
        assert_eq!(g1.book_sort, 0);

        let groups = BookGroupDao::list_all(&conn).unwrap();
        assert_eq!(groups.len(), 3);
        // 排序：sort_order ASC 后再 id ASC
        assert_eq!(groups[0].name, "科幻"); // sort_order=0
        assert_eq!(groups[1].name, "玄幻"); // sort_order=1
        assert_eq!(groups[2].name, "都市"); // sort_order=2

        // 按 id 取
        let by_id = BookGroupDao::get_by_id(&conn, g2.id).unwrap();
        assert!(by_id.is_some());
        assert_eq!(by_id.unwrap().name, "科幻");

        let missing = BookGroupDao::get_by_id(&conn, 99999).unwrap();
        assert!(missing.is_none());

        // 触发 _ 用一下避免 unused 警告
        let _ = g3.id;
    }

    #[test]
    fn test_update() {
        let (_dir, conn) = setup();
        let g = BookGroupDao::create(&conn, "原名", 0).unwrap();
        BookGroupDao::update(&conn, g.id, "新名字", 5).unwrap();

        let updated = BookGroupDao::get_by_id(&conn, g.id).unwrap().unwrap();
        assert_eq!(updated.name, "新名字");
        assert_eq!(updated.sort_order, 5);
        // updated_at 应该被刷新（>= created_at）
        assert!(updated.updated_at >= g.created_at);
    }

    #[test]
    fn test_delete_resets_book_group_id() {
        let (_dir, mut conn) = setup();
        // 建一个 source + 一个分组 + 一本归到分组里的书
        conn.execute(
            "INSERT INTO book_sources (id, name, url, created_at, updated_at) \
             VALUES ('src1', 'S', 'https://e', 1, 1)",
            [],
        )
        .unwrap();
        let g = BookGroupDao::create(&conn, "网文", 0).unwrap();
        conn.execute(
            "INSERT INTO books (id, source_id, source_name, name, group_id, order_time, created_at, updated_at) \
             VALUES ('b1', 'src1', 'S', 'Book', ?, 1, 1, 1)",
            params![g.id],
        )
        .unwrap();

        // 校验书确实归在分组内
        let group_id_before: i64 = conn
            .query_row("SELECT group_id FROM books WHERE id = 'b1'", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(group_id_before, g.id);

        // 删分组
        BookGroupDao::delete(&mut conn, g.id).unwrap();

        // 分组消失
        assert!(BookGroupDao::get_by_id(&conn, g.id).unwrap().is_none());
        // 书还在，但 group_id 被重置为 0
        let group_id_after: i64 = conn
            .query_row("SELECT group_id FROM books WHERE id = 'b1'", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(group_id_after, 0);
    }
}
