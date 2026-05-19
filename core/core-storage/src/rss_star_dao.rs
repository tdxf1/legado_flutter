//! # RSS 收藏 DAO (批次 18 / 05-19)
//!
//! 对应原 Legado `RssStarDao.kt`。schema v12 (批次 16) 已建好
//! `rss_stars` 表（9 字段 + 复合主键 `(origin, link)` + idx star_time DESC）；
//! 本批次只补 DAO + bridge 暴露。
//!
//! ## 关键约定
//!
//! - **add 走 `INSERT OR REPLACE`**：重复收藏同一篇文章时 star_time
//!   刷成最新（"再次收藏" 行为相当于把卡片置顶）。
//! - **跨源持久**：[`RssArticleDao::delete_by_origin`] 不动 rss_stars；
//!   即使源删了，收藏依旧保留 — 用户体验更稳。
//! - **list_all 排序**：`ORDER BY star_time DESC`，最新收藏在前；
//!   `limit < 0` 表示无分页（取全量），UI 端 MVP 不分页。
//! - 字段从 [`RssArticle`] 拷贝 + `source_name` 单独传入（RssArticle
//!   本身不带源名，需要 caller 从 RssSource 取过来）。

use super::models::{RssArticle, RssStar};
use chrono::Utc;
use rusqlite::{params, Connection, Result as SqlResult};
use tracing::{debug, info};

/// 列读取顺序的单一来源（与 [`rss_star_from_row`] 索引严格对齐）。
const RSS_STAR_COLUMNS: &str = "origin, source_name, sort, title, pub_date, \
     image, link, description, variable, star_time";

/// upsert SQL — `INSERT OR REPLACE` 语义：重复 (origin, link) 把 star_time
/// 刷成最新；不会失败。
const RSS_STAR_INSERT_SQL: &str = "INSERT OR REPLACE INTO rss_stars (
    origin, source_name, sort, title, pub_date, image, link,
    description, variable, star_time
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";

pub struct RssStarDao<'a> {
    conn: &'a Connection,
}

impl<'a> RssStarDao<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 把 RssArticle + source_name 转成 RssStar 行入库。重复 add
    /// 走 `INSERT OR REPLACE`，star_time 自动刷为当前时间戳。
    pub fn add(&self, article: &RssArticle, source_name: &str) -> SqlResult<usize> {
        let now = Utc::now().timestamp();
        debug!(
            "add rss_star: origin={} link={} source_name={}",
            article.origin, article.link, source_name
        );
        self.conn.execute(
            RSS_STAR_INSERT_SQL,
            params![
                article.origin,
                source_name,
                article.sort,
                article.title,
                article.pub_date,
                article.image,
                article.link,
                article.description,
                article.variable,
                now,
            ],
        )
    }

    /// 按 (origin, link) 删除。返回受影响行数（0 表示不存在）。
    pub fn remove(&self, origin: &str, link: &str) -> SqlResult<usize> {
        info!("remove rss_star: origin={} link={}", origin, link);
        self.conn.execute(
            "DELETE FROM rss_stars WHERE origin = ? AND link = ?",
            params![origin, link],
        )
    }

    /// 是否已收藏。
    pub fn is_starred(&self, origin: &str, link: &str) -> SqlResult<bool> {
        let n: i64 = self
            .conn
            .query_row(
                "SELECT COUNT(*) FROM rss_stars WHERE origin = ? AND link = ?",
                params![origin, link],
                |row| row.get(0),
            )
            .unwrap_or(0);
        Ok(n > 0)
    }

    /// 列出所有收藏（按 star_time DESC）。
    /// `limit < 0` 表示无限制；offset < 0 视作 0。
    pub fn list_all(&self, limit: i64, offset: i64) -> SqlResult<Vec<RssStar>> {
        let limit_clause = if limit < 0 {
            String::new()
        } else {
            format!(" LIMIT {} OFFSET {}", limit, offset.max(0))
        };
        let sql = format!(
            "SELECT {} FROM rss_stars ORDER BY star_time DESC{}",
            RSS_STAR_COLUMNS, limit_clause
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt.query_map([], rss_star_from_row)?;
        rows.collect()
    }

    /// 收藏总数。
    pub fn count(&self) -> SqlResult<i64> {
        self.conn
            .query_row("SELECT COUNT(*) FROM rss_stars", [], |row| row.get(0))
    }
}

fn rss_star_from_row(row: &rusqlite::Row) -> SqlResult<RssStar> {
    Ok(RssStar {
        origin: row.get(0)?,
        source_name: row.get::<_, Option<String>>(1)?.unwrap_or_default(),
        sort: row.get::<_, Option<String>>(2)?.unwrap_or_default(),
        title: row.get::<_, Option<String>>(3)?.unwrap_or_default(),
        pub_date: row.get::<_, Option<String>>(4)?.unwrap_or_default(),
        image: row.get(5)?,
        link: row.get(6)?,
        description: row.get(7)?,
        variable: row.get(8)?,
        star_time: row.get(9)?,
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

    fn make_article(origin: &str, link: &str, title: &str) -> RssArticle {
        RssArticle {
            origin: origin.to_string(),
            sort: "tech".to_string(),
            title: title.to_string(),
            pub_date: "2024-05-19".to_string(),
            link: link.to_string(),
            image: Some("https://example.com/img.jpg".to_string()),
            description: Some("desc".to_string()),
            variable: None,
            order_num: 0,
            read_time: 0,
            star: 0,
        }
    }

    #[test]
    fn test_add_and_is_starred() {
        let (_dir, conn) = setup();
        let dao = RssStarDao::new(&conn);
        let article = make_article("https://feed/x", "link-1", "Article 1");

        assert!(!dao.is_starred("https://feed/x", "link-1").unwrap());
        let n = dao.add(&article, "X Feed").unwrap();
        assert_eq!(n, 1);
        assert!(dao.is_starred("https://feed/x", "link-1").unwrap());
        assert_eq!(dao.count().unwrap(), 1);

        // 验证 source_name 写入正确
        let stored: String = conn
            .query_row(
                "SELECT source_name FROM rss_stars WHERE origin = ? AND link = ?",
                params!["https://feed/x", "link-1"],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(stored, "X Feed");
    }

    #[test]
    fn test_add_duplicate_replaces() {
        let (_dir, conn) = setup();
        let dao = RssStarDao::new(&conn);
        let article = make_article("https://feed/x", "link-dup", "First Title");

        dao.add(&article, "X Feed").unwrap();
        let first_time: i64 = conn
            .query_row(
                "SELECT star_time FROM rss_stars WHERE link = 'link-dup'",
                [],
                |row| row.get(0),
            )
            .unwrap();

        // 等一秒（确保 star_time 单调递增可观察）
        std::thread::sleep(std::time::Duration::from_secs(1));

        // 改 title 再 add — 不应报错；记录被 REPLACE
        let mut updated = article.clone();
        updated.title = "Second Title".into();
        let n = dao.add(&updated, "X Feed Renamed").unwrap();
        assert_eq!(n, 1);
        // 仍然只有一条
        assert_eq!(dao.count().unwrap(), 1);

        // title / source_name 被刷新
        let (title, source_name): (String, String) = conn
            .query_row(
                "SELECT title, source_name FROM rss_stars WHERE link = 'link-dup'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(title, "Second Title");
        assert_eq!(source_name, "X Feed Renamed");

        // star_time 应至少 >= 第一次（INSERT OR REPLACE 走新 ts）
        let second_time: i64 = conn
            .query_row(
                "SELECT star_time FROM rss_stars WHERE link = 'link-dup'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(second_time >= first_time);
    }

    #[test]
    fn test_remove() {
        let (_dir, conn) = setup();
        let dao = RssStarDao::new(&conn);
        let article = make_article("https://feed/x", "link-rm", "title");

        dao.add(&article, "X").unwrap();
        assert!(dao.is_starred("https://feed/x", "link-rm").unwrap());

        let n = dao.remove("https://feed/x", "link-rm").unwrap();
        assert_eq!(n, 1);
        assert!(!dao.is_starred("https://feed/x", "link-rm").unwrap());
        assert_eq!(dao.count().unwrap(), 0);

        // 重复 remove 返回 0，不报错
        let n2 = dao.remove("https://feed/x", "link-rm").unwrap();
        assert_eq!(n2, 0);
    }

    #[test]
    fn test_list_all_orders_by_star_time_desc() {
        let (_dir, conn) = setup();
        let dao = RssStarDao::new(&conn);

        // 三条不同 link，分三次 add（间隔 1s 让 star_time 严格递增）
        for i in 0..3 {
            let article = make_article("https://feed/x", &format!("l-{i}"), &format!("t-{i}"));
            dao.add(&article, "X").unwrap();
            std::thread::sleep(std::time::Duration::from_secs(1));
        }

        let list = dao.list_all(-1, 0).unwrap();
        assert_eq!(list.len(), 3);
        // 最后 add 的 (l-2) 在前
        assert_eq!(list[0].link, "l-2");
        assert_eq!(list[1].link, "l-1");
        assert_eq!(list[2].link, "l-0");

        // 分页
        let page = dao.list_all(2, 1).unwrap();
        assert_eq!(page.len(), 2);
        assert_eq!(page[0].link, "l-1");
        assert_eq!(page[1].link, "l-0");
    }
}
