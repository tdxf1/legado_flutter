//! # 阅读时长记录 DAO (批次 14)
//!
//! 对应原 Legado `ReadRecord.kt`。schema 在批次 6 (v11) 已就绪
//! (`read_records` 表 + `idx_read_records_book_id` 索引)，本模块
//! 提供 upsert / 查询 / 聚合操作。
//!
//! ## 约定
//!
//! - 主键 = UUID（`String`），原 Legado 用 `(deviceId, bookName)`
//!   联合主键，端口里弃掉 deviceId 改成 book_id 外键 + 冗余 book_name。
//! - `read_time` 单位为**秒**。注意与 `book_progress.read_time`（毫秒，
//!   且批次 14 暂不使用）刻意不同步，避免单位混淆。
//! - `last_read_at` 单位为秒（`chrono::Utc::now().timestamp()`）。
//! - `add_time` 走 SELECT-then-UPDATE/INSERT，而不是 SQL 端 ON CONFLICT，
//!   主要因为 `book_id` 不是 UNIQUE 列（schema 上是普通索引，原 Legado
//!   是允许跨设备多行的）。MVP 单设备语义下我们按 book_id 聚合。

use super::models::{new_id, ReadRecord};
use chrono::Utc;
use rusqlite::{params, Connection, OptionalExtension, Result as SqlResult};
use tracing::debug;

/// `read_records` 列读取顺序的单一来源。SELECT/INSERT 都基于此构建，
/// 列顺序与 [`read_record_from_row`] 内 `row.get(N)` 索引一致。
const READ_RECORD_COLUMNS: &str =
    "id, book_id, book_name, read_time, last_read_at, created_at, updated_at";

/// 阅读时长 DAO
pub struct ReadRecordDao<'a> {
    conn: &'a Connection,
}

impl<'a> ReadRecordDao<'a> {
    /// 创建新的 ReadRecordDao
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 累加阅读时长（秒）。
    ///
    /// - 若该 `book_id` 已有 row → `read_time += delta_seconds` +
    ///   `last_read_at = now` + `updated_at = now`。
    /// - 否则插入新行：id=UUID, read_time=delta_seconds, last_read_at=now,
    ///   created_at=updated_at=now。
    ///
    /// 注：这里走两步（SELECT id → UPDATE/INSERT）而不是 SQL 端
    /// `ON CONFLICT(book_id) DO UPDATE`，原因是 schema 上 `book_id`
    /// 只有索引，没 UNIQUE 约束（参见 `database.rs::create_tables`
    /// 中 `read_records` 表的 DDL）。给同一 book_id 加 UNIQUE 又会限制
    /// 未来跨设备多行的扩展空间，所以本批次保留两步实现。
    pub fn add_time(
        &self,
        book_id: &str,
        book_name: &str,
        delta_seconds: i64,
    ) -> SqlResult<()> {
        debug!(
            "add_read_time: book_id={}, delta={}s",
            book_id, delta_seconds
        );
        let now = Utc::now().timestamp();
        let existing: Option<String> = self
            .conn
            .query_row(
                "SELECT id FROM read_records WHERE book_id = ?",
                params![book_id],
                |row| row.get(0),
            )
            .optional()?;
        if let Some(_id) = existing {
            self.conn.execute(
                "UPDATE read_records
                 SET read_time = read_time + ?,
                     last_read_at = ?,
                     book_name = ?,
                     updated_at = ?
                 WHERE book_id = ?",
                params![delta_seconds, now, book_name, now, book_id],
            )?;
        } else {
            let id = new_id();
            self.conn.execute(
                "INSERT INTO read_records
                    (id, book_id, book_name, read_time, last_read_at,
                     created_at, updated_at)
                 VALUES (?, ?, ?, ?, ?, ?, ?)",
                params![id, book_id, book_name, delta_seconds, now, now, now],
            )?;
        }
        Ok(())
    }

    /// 取单本书的阅读记录，没有则返回 None。
    pub fn get_by_book(&self, book_id: &str) -> SqlResult<Option<ReadRecord>> {
        let sql = format!(
            "SELECT {} FROM read_records WHERE book_id = ?",
            READ_RECORD_COLUMNS
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let mut rows = stmt.query(params![book_id])?;
        if let Some(row) = rows.next()? {
            Ok(Some(read_record_from_row(row)?))
        } else {
            Ok(None)
        }
    }

    /// 列出所有阅读记录，按 last_read_at DESC 排序。
    /// 设置页"阅读统计"用。
    pub fn list_all(&self) -> SqlResult<Vec<ReadRecord>> {
        let sql = format!(
            "SELECT {} FROM read_records ORDER BY last_read_at DESC, id ASC",
            READ_RECORD_COLUMNS
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt.query_map([], read_record_from_row)?;
        rows.collect()
    }

    /// 全局总阅读时长（秒）。`COALESCE` 处理空表情况返回 0 而不是 NULL。
    pub fn total_read_time(&self) -> SqlResult<i64> {
        self.conn.query_row(
            "SELECT COALESCE(SUM(read_time), 0) FROM read_records",
            [],
            |row| row.get(0),
        )
    }
}

/// 从数据库行转换到 ReadRecord 结构体。列顺序与 [`READ_RECORD_COLUMNS`]
/// 严格对齐 — 改一处必须同步另一处。
fn read_record_from_row(row: &rusqlite::Row) -> SqlResult<ReadRecord> {
    Ok(ReadRecord {
        id: row.get(0)?,
        book_id: row.get(1)?,
        book_name: row.get(2)?,
        read_time: row.get(3)?,
        last_read_at: row.get(4)?,
        created_at: row.get(5)?,
        updated_at: row.get(6)?,
    })
}

// 让 `now_timestamp` 用法不至于因为只在 tests 用而触发 dead_code lint
// （目前 add_time 路径用的是 chrono::Utc::now().timestamp()，与
// `models::now_timestamp` 等价）。这里以模块级 _ 引用稳住 import。
// 已删除：直接用 chrono::Utc::now().timestamp()。

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
    fn test_add_time_creates_new_record() {
        let (_dir, conn) = setup();
        let dao = ReadRecordDao::new(&conn);
        dao.add_time("book-A", "三体", 60).unwrap();

        let r = dao.get_by_book("book-A").unwrap().unwrap();
        assert_eq!(r.book_id, "book-A");
        assert_eq!(r.book_name, "三体");
        assert_eq!(r.read_time, 60);
        assert!(r.last_read_at > 0);
        assert!(r.created_at > 0);
        assert!(r.updated_at > 0);
    }

    #[test]
    fn test_add_time_accumulates() {
        let (_dir, conn) = setup();
        let dao = ReadRecordDao::new(&conn);
        dao.add_time("book-A", "三体", 60).unwrap();
        dao.add_time("book-A", "三体", 90).unwrap();

        let r = dao.get_by_book("book-A").unwrap().unwrap();
        assert_eq!(r.read_time, 150);
        // 列表只有一行 — 第二次 add_time 是 UPDATE 不是 INSERT
        let all = dao.list_all().unwrap();
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].book_id, "book-A");
    }

    #[test]
    fn test_total_read_time_sums() {
        let (_dir, conn) = setup();
        let dao = ReadRecordDao::new(&conn);
        // 空表 → 0
        assert_eq!(dao.total_read_time().unwrap(), 0);

        dao.add_time("b1", "n1", 60).unwrap();
        dao.add_time("b2", "n2", 60).unwrap();
        dao.add_time("b3", "n3", 60).unwrap();
        assert_eq!(dao.total_read_time().unwrap(), 180);

        // 同一本书继续累加，total 也跟着加
        dao.add_time("b1", "n1", 30).unwrap();
        assert_eq!(dao.total_read_time().unwrap(), 210);
    }

    #[test]
    fn test_list_all_orders_by_last_read_desc() {
        let (_dir, conn) = setup();
        let dao = ReadRecordDao::new(&conn);
        // 按时间倒序插入，让 last_read_at 不同
        dao.add_time("b1", "n1", 60).unwrap();
        // 手动把 b1 的 last_read_at 改老，让 b2 / b3 更新
        conn.execute(
            "UPDATE read_records SET last_read_at = ? WHERE book_id = 'b1'",
            params![1_000_000_000_i64],
        )
        .unwrap();
        dao.add_time("b2", "n2", 60).unwrap();
        conn.execute(
            "UPDATE read_records SET last_read_at = ? WHERE book_id = 'b2'",
            params![1_500_000_000_i64],
        )
        .unwrap();
        dao.add_time("b3", "n3", 60).unwrap();
        // b3 用 now（最新），无须改

        let all = dao.list_all().unwrap();
        assert_eq!(all.len(), 3);
        // 顺序：b3（now）→ b2（1.5e9）→ b1（1e9）
        assert_eq!(all[0].book_id, "b3");
        assert_eq!(all[1].book_id, "b2");
        assert_eq!(all[2].book_id, "b1");
    }
}
