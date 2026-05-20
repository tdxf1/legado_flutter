use chrono::Utc;
use rusqlite::{params, Connection, Result as SqlResult};

pub struct CacheDao<'a> {
    conn: &'a Connection,
}

impl<'a> CacheDao<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    pub fn get(&self, key: &str) -> SqlResult<Option<String>> {
        let mut stmt = self
            .conn
            .prepare("SELECT value FROM legacy_cache WHERE key = ?")?;
        let mut rows = stmt.query(params![key])?;
        // 批次 08 (BATCH-08 / F-W1A-015)：不再 `unwrap_or_default()` 静默
        // 吞 SQL 错误（如列类型不匹配 / NULL 解码失败），让 caller 看到
        // `Err(rusqlite::Error)` 而不是误把"读取失败"当成空串。
        // `Option<Result<T,E>>` → `Result<Option<T>,E>` 用 `transpose`。
        rows.next()?
            .map(|row| row.get::<_, String>(0))
            .transpose()
    }

    pub fn put(&self, key: &str, value: &str) -> SqlResult<()> {
        let now = Utc::now().timestamp();
        self.conn.execute(
            "INSERT INTO legacy_cache (key, value, updated_at) VALUES (?1, ?2, ?3)
             ON CONFLICT(key) DO UPDATE SET value = ?2, updated_at = ?3",
            params![key, value, now],
        )?;
        Ok(())
    }

    pub fn delete(&self, key: &str) -> SqlResult<()> {
        self.conn
            .execute("DELETE FROM legacy_cache WHERE key = ?", params![key])?;
        Ok(())
    }
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
    fn get_returns_none_for_missing_key() {
        let (_dir, conn) = setup();
        let dao = CacheDao::new(&conn);
        assert!(dao.get("missing").unwrap().is_none());
    }

    #[test]
    fn get_returns_value_for_existing_key() {
        let (_dir, conn) = setup();
        let dao = CacheDao::new(&conn);
        dao.put("k", "v").unwrap();
        assert_eq!(dao.get("k").unwrap(), Some("v".to_string()));
    }

    /// 批次 08 (BATCH-08 / F-W1A-015): 之前 `unwrap_or_default()` 把列类型
    /// 不匹配的 SQL 错误吞成 `Ok(Some(""))`；改用 `transpose` 后应返回
    /// `Err(rusqlite::Error)`，让 caller 区分 "key 不存在" vs "value 列读
    /// 取失败"。
    #[test]
    fn get_propagates_column_type_error_instead_of_swallowing() {
        let (_dir, conn) = setup();
        // 用 raw SQL 直接塞一个 BLOB 进 value 列；SQLite 类型亲和性允许
        // 此操作（TEXT 列也能存 BLOB）。`row.get::<_, String>(0)` 读 BLOB
        // 时会返回 `InvalidColumnType` 错误。
        conn.execute(
            "INSERT INTO legacy_cache (key, value, updated_at) VALUES ('blob_key', X'01020304', 1)",
            [],
        )
        .unwrap();
        let dao = CacheDao::new(&conn);
        let result = dao.get("blob_key");
        assert!(
            result.is_err(),
            "BLOB value should produce Err, not silently default to empty string. Got: {:?}",
            result
        );
    }
}
