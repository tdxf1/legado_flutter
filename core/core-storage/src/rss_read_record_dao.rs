//! # RSS 已读记录 DAO (批次 17 / 05-19)
//!
//! 对应原 Legado `RssReadRecordDao.kt`。表 `rss_read_records` 主键 `link`
//! 全局去重，便于跨源已读探测：同一篇文章被多个 RSS 源收录时，标过一次
//! 已读后所有源都视作已读。
//!
//! 与 `RssArticleDao::mark_read` 双写：mark_read 已经把 record 写入这个
//! 表，独立 dao 仅在以下场景用：
//! - 拉取 RSS 文章后判定每条是否曾读过（跨源）
//! - 单测 / 后续批次扩展

use chrono::Utc;
use rusqlite::{params, Connection, Result as SqlResult};
use tracing::debug;

pub struct RssReadRecordDao<'a> {
    conn: &'a Connection,
}

impl<'a> RssReadRecordDao<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// upsert 已读记录：同时写 record_time 与 read_time（两者同值）。
    /// 返回受影响行数（INSERT 或 UPDATE 都算 1）。
    pub fn upsert(&self, link: &str, ts: i64) -> SqlResult<usize> {
        debug!("upsert rss_read_record: link={} ts={}", link, ts);
        self.conn.execute(
            "INSERT INTO rss_read_records (link, record_time, read_time) \
             VALUES (?, ?, ?) \
             ON CONFLICT(link) DO UPDATE SET \
                record_time = excluded.record_time, \
                read_time = excluded.read_time",
            params![link, ts, ts],
        )
    }

    /// 查 link 是否已读（read_time > 0）。
    pub fn is_read(&self, link: &str) -> SqlResult<bool> {
        let n: i64 = self
            .conn
            .query_row(
                "SELECT COUNT(*) FROM rss_read_records WHERE link = ? AND read_time > 0",
                params![link],
                |row| row.get(0),
            )
            .unwrap_or(0);
        Ok(n > 0)
    }
}

#[allow(dead_code)]
fn now_ts() -> i64 {
    Utc::now().timestamp()
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
    fn test_upsert_and_is_read() {
        let (_dir, conn) = setup();
        let dao = RssReadRecordDao::new(&conn);

        assert!(!dao.is_read("link-1").unwrap());
        let n = dao.upsert("link-1", 1700000000).unwrap();
        assert_eq!(n, 1);
        assert!(dao.is_read("link-1").unwrap());

        // 再次 upsert 同 link → UPDATE 路径
        let n2 = dao.upsert("link-1", 1700000099).unwrap();
        assert_eq!(n2, 1);
        let read_time: i64 = conn
            .query_row(
                "SELECT read_time FROM rss_read_records WHERE link = 'link-1'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(read_time, 1700000099);
    }

    #[test]
    fn test_is_read_zero_treated_as_unread() {
        let (_dir, conn) = setup();
        let dao = RssReadRecordDao::new(&conn);
        // 直接插一行 read_time = 0（早期错误数据 / 占位）
        conn.execute(
            "INSERT INTO rss_read_records (link, record_time, read_time) \
             VALUES (?, ?, ?)",
            params!["zero-link", 1700000000, 0],
        )
        .unwrap();
        assert!(!dao.is_read("zero-link").unwrap(), "read_time=0 视作未读");
    }
}
