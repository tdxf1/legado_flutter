//! # 订阅源 DAO (批次 19 / 05-19)
//!
//! 对应原 Legado `RuleSubDao.kt`。schema 在批次 6 (v11) 已建好
//! `rule_subs` 表（id PK / name / url UNIQUE / sub_type / custom_order
//! / created_at / updated_at），本批次只补 DAO + bridge fn。
//!
//! ## 约定
//!
//! - 列表默认排序：`custom_order ASC, name ASC`（与 RssSource / BookSource
//!   一致，便于用户用 customOrder 字段调整置顶）
//! - 主键 = `id`（UUID 字符串）；`url` 列上有 UNIQUE 约束，由 schema 保证
//! - upsert 通过 `INSERT ... ON CONFLICT(id) DO UPDATE SET ...` 实现，
//!   仅刷新 name / url / sub_type / custom_order / updated_at；**不动**
//!   created_at（防丢失原创建时间）
//! - `delete_by_id` / `upsert` 返回受影响行数，方便上层做 toast 反馈
//!
//! 风格参考 `rss_source_dao.rs`（共享 SQL 常量 + 防 ON CONFLICT 列表漂移）。

use super::models::RuleSub;
use rusqlite::{params, Connection, Result as SqlResult};
use tracing::{debug, info};

/// `rule_subs` 列读取顺序的单一来源。SELECT/INSERT 都基于此构建，
/// 列顺序与 [`rule_sub_from_row`] 内 `row.get(N)` 索引严格一致。
const RULE_SUB_COLUMNS: &str =
    "id, name, url, sub_type, custom_order, created_at, updated_at";

/// 单条 SQL；upsert 共享，避免 ON CONFLICT 列表漂移。
/// 注意：`created_at` 故意不在 DO UPDATE 列里，旧记录的 created_at
/// 永远保留（参考 BookSource / RssSource 的相同处理）。
const RULE_SUB_UPSERT_SQL: &str = "INSERT INTO rule_subs (
    id, name, url, sub_type, custom_order, created_at, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
    name = excluded.name,
    url = excluded.url,
    sub_type = excluded.sub_type,
    custom_order = excluded.custom_order,
    updated_at = excluded.updated_at";

/// 订阅源 DAO
pub struct RuleSubDao<'a> {
    conn: &'a Connection,
}

impl<'a> RuleSubDao<'a> {
    /// 创建新的 RuleSubDao
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 列出所有订阅源（custom_order ASC, name ASC）
    pub fn list_all(&self) -> SqlResult<Vec<RuleSub>> {
        let sql = format!(
            "SELECT {} FROM rule_subs ORDER BY custom_order ASC, name ASC",
            RULE_SUB_COLUMNS
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt.query_map([], rule_sub_from_row)?;
        rows.collect()
    }

    /// 按 id 取单条
    pub fn get_by_id(&self, id: &str) -> SqlResult<Option<RuleSub>> {
        let sql = format!(
            "SELECT {} FROM rule_subs WHERE id = ? LIMIT 1",
            RULE_SUB_COLUMNS
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let mut rows = stmt.query(params![id])?;
        match rows.next()? {
            Some(row) => Ok(Some(rule_sub_from_row(row)?)),
            None => Ok(None),
        }
    }

    /// 按 url 取单条（url 列 UNIQUE，最多 1 条）
    pub fn get_by_url(&self, url: &str) -> SqlResult<Option<RuleSub>> {
        let sql = format!(
            "SELECT {} FROM rule_subs WHERE url = ? LIMIT 1",
            RULE_SUB_COLUMNS
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let mut rows = stmt.query(params![url])?;
        match rows.next()? {
            Some(row) => Ok(Some(rule_sub_from_row(row)?)),
            None => Ok(None),
        }
    }

    /// upsert 单条 RuleSub，返回受影响行数（INSERT 或 UPDATE 都算 1）。
    pub fn upsert(&self, sub: &RuleSub) -> SqlResult<usize> {
        debug!("upsert rule_sub: {} ({})", sub.name, sub.url);
        self.conn.execute(
            RULE_SUB_UPSERT_SQL,
            params![
                sub.id,
                sub.name,
                sub.url,
                sub.sub_type,
                sub.custom_order,
                sub.created_at,
                sub.updated_at,
            ],
        )
    }

    /// 按 id 删除，返回受影响行数（0 = 不存在）。
    pub fn delete_by_id(&self, id: &str) -> SqlResult<usize> {
        info!("删除订阅源: {}", id);
        self.conn
            .execute("DELETE FROM rule_subs WHERE id = ?", params![id])
    }

    /// 总数（rule_subs 行数）。
    pub fn count(&self) -> SqlResult<i64> {
        self.conn
            .query_row("SELECT COUNT(*) FROM rule_subs", [], |row| row.get(0))
    }
}

/// 从数据库行 → RuleSub。列顺序严格对齐 [`RULE_SUB_COLUMNS`]。
fn rule_sub_from_row(row: &rusqlite::Row) -> SqlResult<RuleSub> {
    Ok(RuleSub {
        id: row.get(0)?,
        name: row.get(1)?,
        url: row.get(2)?,
        sub_type: row.get(3)?,
        custom_order: row.get(4)?,
        created_at: row.get(5)?,
        updated_at: row.get(6)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;
    use tempfile::TempDir;

    fn setup() -> (TempDir, Connection) {
        let dir = TempDir::new().unwrap();
        let db_path = dir.path().join("test.db");
        let conn = crate::database::init_database(db_path.to_str().unwrap()).unwrap();
        (dir, conn)
    }

    fn make_sub(id: &str, name: &str, url: &str, sub_type: i32) -> RuleSub {
        let now = Utc::now().timestamp();
        RuleSub {
            id: id.to_string(),
            name: name.to_string(),
            url: url.to_string(),
            sub_type,
            custom_order: 0,
            created_at: now,
            updated_at: now,
        }
    }

    /// upsert + get_by_id：基本写读 + 二次 upsert 走 UPDATE 路径。
    #[test]
    fn test_upsert_and_get_by_id() {
        let (_dir, conn) = setup();
        let dao = RuleSubDao::new(&conn);

        let s = make_sub("rs1", "示例订阅", "https://example.com/sub.json", 0);
        let n = dao.upsert(&s).unwrap();
        assert_eq!(n, 1);

        let got = dao.get_by_id("rs1").unwrap().unwrap();
        assert_eq!(got.name, "示例订阅");
        assert_eq!(got.url, "https://example.com/sub.json");
        assert_eq!(got.sub_type, 0);
        assert_eq!(got.custom_order, 0);

        // 二次 upsert 同 id —— UPDATE 路径，name 应被刷新，
        // created_at 必须保留（不被 excluded.created_at 顶掉）。
        let original_created = got.created_at;
        let mut s2 = s.clone();
        s2.name = "新名".to_string();
        s2.sub_type = 1;
        s2.custom_order = 5;
        s2.updated_at = original_created + 1000;
        dao.upsert(&s2).unwrap();
        let got2 = dao.get_by_id("rs1").unwrap().unwrap();
        assert_eq!(got2.name, "新名");
        assert_eq!(got2.sub_type, 1);
        assert_eq!(got2.custom_order, 5);
        assert_eq!(got2.created_at, original_created, "created_at 必须保留");
        assert_eq!(got2.updated_at, original_created + 1000);

        // 不存在 id → None
        let none = dao.get_by_id("nonexistent").unwrap();
        assert!(none.is_none());
    }

    /// get_by_url：URL 列 UNIQUE 约束已在 schema，DAO 提供查询入口。
    #[test]
    fn test_get_by_url() {
        let (_dir, conn) = setup();
        let dao = RuleSubDao::new(&conn);

        let s = make_sub("rs2", "RSS 订阅", "https://rss.example/sub.json", 1);
        dao.upsert(&s).unwrap();

        let got = dao
            .get_by_url("https://rss.example/sub.json")
            .unwrap()
            .unwrap();
        assert_eq!(got.id, "rs2");
        assert_eq!(got.sub_type, 1);

        // 不存在 url → None
        let none = dao.get_by_url("https://no.example").unwrap();
        assert!(none.is_none());
    }

    /// list_all：custom_order ASC, name ASC 双键排序。
    #[test]
    fn test_list_all_ordered() {
        let (_dir, conn) = setup();
        let dao = RuleSubDao::new(&conn);

        // 故意打乱插入顺序，测排序正确性
        let mut a = make_sub("rs-a", "alpha", "https://a.example", 0);
        a.custom_order = 5;
        let mut b = make_sub("rs-b", "bravo", "https://b.example", 0);
        b.custom_order = 1;
        let mut c = make_sub("rs-c", "charlie", "https://c.example", 0);
        c.custom_order = 1;
        dao.upsert(&a).unwrap();
        dao.upsert(&b).unwrap();
        dao.upsert(&c).unwrap();

        let list = dao.list_all().unwrap();
        assert_eq!(list.len(), 3);
        // custom_order=1 (bravo, charlie) → name ASC → bravo, charlie
        // 然后 custom_order=5 (alpha)
        assert_eq!(list[0].id, "rs-b");
        assert_eq!(list[1].id, "rs-c");
        assert_eq!(list[2].id, "rs-a");
    }

    /// delete_by_id：返回受影响行数；不存在 id 返回 0；不报错。
    #[test]
    fn test_delete_by_id() {
        let (_dir, conn) = setup();
        let dao = RuleSubDao::new(&conn);

        let s = make_sub("rs-d", "to delete", "https://d.example", 2);
        dao.upsert(&s).unwrap();
        assert_eq!(dao.count().unwrap(), 1);

        let n = dao.delete_by_id("rs-d").unwrap();
        assert_eq!(n, 1);
        assert_eq!(dao.count().unwrap(), 0);
        assert!(dao.get_by_id("rs-d").unwrap().is_none());

        // 重复删除 → 0，不报错
        let n2 = dao.delete_by_id("rs-d").unwrap();
        assert_eq!(n2, 0);

        // 不存在 id → 0
        let n3 = dao.delete_by_id("missing").unwrap();
        assert_eq!(n3, 0);
    }

    /// count：空 / 多条
    #[test]
    fn test_count() {
        let (_dir, conn) = setup();
        let dao = RuleSubDao::new(&conn);
        assert_eq!(dao.count().unwrap(), 0);

        for i in 0..5 {
            let s = make_sub(
                &format!("rs-{i}"),
                &format!("name-{i}"),
                &format!("https://e{i}.example"),
                (i % 3) as i32,
            );
            dao.upsert(&s).unwrap();
        }
        assert_eq!(dao.count().unwrap(), 5);

        dao.delete_by_id("rs-0").unwrap();
        dao.delete_by_id("rs-2").unwrap();
        assert_eq!(dao.count().unwrap(), 3);
    }
}
