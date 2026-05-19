//! # RSS 文章 DAO (批次 17 / 05-19)
//!
//! 对应原 Legado `RssArticleDao.kt`。schema 在批次 16 (v12) 已建好
//! `rss_articles` 表（复合主键 (origin, link)）+ `idx_rss_articles_origin_sort`
//! / `idx_rss_articles_unread` 索引；本批次只补 DAO。
//!
//! ## 关键约定
//!
//! - **upsert_batch 保留 read_time / star**：拉取后再写入时，DB 已有的
//!   行不能把已读 / 收藏状态被新拉的 0 覆盖掉。SQL 用
//!   `ON CONFLICT(origin, link) DO UPDATE SET ...` 仅更新 sort / title
//!   / pub_date / image / description / variable / order_num，不动
//!   read_time 与 star。
//! - **mark_read 双写**：UPDATE rss_articles 同时 UPSERT rss_read_records，
//!   后者按 link 主键全局去重，便于跨源已读探测。
//! - **list_by_origin_sort 排序**：`ORDER BY order_num ASC, pub_date DESC`，
//!   pub_date 是原始 String（"Mon, 01 Jan 2024 ..." / "2024-01-01T..."），
//!   字典序倒序对常见格式都近似日期顺序（MVP 不解析日期）。
//! - **delete_by_origin**：删源时清这一源下的全部文章；不动 rss_stars
//!   收藏（独立表，跨源持久）。

use super::models::RssArticle;
use chrono::Utc;
use rusqlite::{params, Connection, Result as SqlResult};
use tracing::{debug, info};

/// 列读取顺序的单一来源（与 [`rss_article_from_row`] 索引严格对齐）。
const RSS_ARTICLE_COLUMNS: &str =
    "origin, sort, title, pub_date, link, image, description, variable, \
     order_num, read_time, star";

/// upsert SQL 单一来源；ON CONFLICT 仅刷新可拉取字段，**不**改 read_time
/// / star。
const RSS_ARTICLE_UPSERT_SQL: &str = "INSERT INTO rss_articles (
    origin, sort, title, pub_date, link, image, description,
    variable, order_num, read_time, star
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(origin, link) DO UPDATE SET
    sort = excluded.sort,
    title = excluded.title,
    pub_date = excluded.pub_date,
    image = excluded.image,
    description = excluded.description,
    variable = excluded.variable,
    order_num = excluded.order_num";

pub struct RssArticleDao<'a> {
    conn: &'a Connection,
}

impl<'a> RssArticleDao<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 批量 upsert：保留每条 (origin, link) 现有 read_time / star。
    ///
    /// 用 IMMEDIATE 事务包裹整批，单个 INSERT 失败不会影响其它行
    /// 的回滚语义 — 但实际上 ON CONFLICT 兜底，单条成功率应 100%。
    pub fn upsert_batch(&self, articles: &[RssArticle]) -> SqlResult<usize> {
        if articles.is_empty() {
            return Ok(0);
        }
        let tx = self.conn.unchecked_transaction()?;
        let mut written = 0usize;
        for a in articles {
            let n = tx.execute(
                RSS_ARTICLE_UPSERT_SQL,
                params![
                    a.origin,
                    a.sort,
                    a.title,
                    a.pub_date,
                    a.link,
                    a.image,
                    a.description,
                    a.variable,
                    a.order_num,
                    a.read_time,
                    a.star,
                ],
            )?;
            written += n;
        }
        tx.commit()?;
        debug!("upsert {} 篇 RSS 文章", written);
        Ok(written)
    }

    /// 列出某源 / 某 sort 下的文章。
    ///
    /// - `sort = None` → 不过滤 sort 列（用于"全部"）
    /// - `limit < 0` → 不分页（取全量）
    /// - 排序：`order_num ASC, pub_date DESC`
    pub fn list_by_origin_sort(
        &self,
        origin: &str,
        sort: Option<&str>,
        limit: i64,
        offset: i64,
    ) -> SqlResult<Vec<RssArticle>> {
        let limit_clause = if limit < 0 {
            String::new()
        } else {
            format!(" LIMIT {} OFFSET {}", limit, offset.max(0))
        };
        let articles = match sort {
            Some(s) => {
                let sql = format!(
                    "SELECT {} FROM rss_articles WHERE origin = ? AND sort = ? \
                     ORDER BY order_num ASC, pub_date DESC{}",
                    RSS_ARTICLE_COLUMNS, limit_clause
                );
                let mut stmt = self.conn.prepare(&sql)?;
                let rows = stmt.query_map(params![origin, s], rss_article_from_row)?;
                rows.collect::<SqlResult<Vec<_>>>()?
            }
            None => {
                let sql = format!(
                    "SELECT {} FROM rss_articles WHERE origin = ? \
                     ORDER BY order_num ASC, pub_date DESC{}",
                    RSS_ARTICLE_COLUMNS, limit_clause
                );
                let mut stmt = self.conn.prepare(&sql)?;
                let rows = stmt.query_map(params![origin], rss_article_from_row)?;
                rows.collect::<SqlResult<Vec<_>>>()?
            }
        };
        Ok(articles)
    }

    /// 列出某源未读文章（read_time = 0）。
    pub fn list_unread_by_origin(&self, origin: &str) -> SqlResult<Vec<RssArticle>> {
        let sql = format!(
            "SELECT {} FROM rss_articles WHERE origin = ? AND read_time = 0 \
             ORDER BY order_num ASC, pub_date DESC",
            RSS_ARTICLE_COLUMNS
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt.query_map(params![origin], rss_article_from_row)?;
        rows.collect()
    }

    /// 按 (origin, link) 复合主键直接取单条文章；不存在返回 None。
    /// 批次 18 (05-19) 新增 — 详情页 / 收藏 add 流程要根据 (origin, link)
    /// 拿完整 RssArticle，避免在 dart 端再 list-then-find。
    pub fn get_by_origin_link(
        &self,
        origin: &str,
        link: &str,
    ) -> SqlResult<Option<RssArticle>> {
        let sql = format!(
            "SELECT {} FROM rss_articles WHERE origin = ? AND link = ? LIMIT 1",
            RSS_ARTICLE_COLUMNS
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let mut rows = stmt.query_map(params![origin, link], rss_article_from_row)?;
        match rows.next() {
            Some(row) => Ok(Some(row?)),
            None => Ok(None),
        }
    }

    /// 标记已读：双写 rss_articles.read_time + rss_read_records。
    /// 返回 rss_articles 受影响的行数（按 link 跨 origin 全部更新；
    /// 同一篇文章被多个源收录的话会一起标已读，与原 Legado 行为一致）。
    pub fn mark_read(&self, link: &str, ts: i64) -> SqlResult<usize> {
        let tx = self.conn.unchecked_transaction()?;
        let n = tx.execute(
            "UPDATE rss_articles SET read_time = ? WHERE link = ?",
            params![ts, link],
        )?;
        // UPSERT rss_read_records — record_time 与 read_time 同值。
        tx.execute(
            "INSERT INTO rss_read_records (link, record_time, read_time) \
             VALUES (?, ?, ?) \
             ON CONFLICT(link) DO UPDATE SET \
                record_time = excluded.record_time, \
                read_time = excluded.read_time",
            params![link, ts, ts],
        )?;
        tx.commit()?;
        Ok(n)
    }

    /// 某源未读文章数量。
    pub fn count_unread_by_origin(&self, origin: &str) -> SqlResult<i64> {
        self.conn.query_row(
            "SELECT COUNT(*) FROM rss_articles WHERE origin = ? AND read_time = 0",
            params![origin],
            |row| row.get(0),
        )
    }

    /// 删除某源下的全部文章（删源时清理）。
    /// 不动 rss_stars / rss_read_records。
    pub fn delete_by_origin(&self, origin: &str) -> SqlResult<usize> {
        info!("删除 RSS 源文章: origin={}", origin);
        self.conn.execute(
            "DELETE FROM rss_articles WHERE origin = ?",
            params![origin],
        )
    }
}

fn rss_article_from_row(row: &rusqlite::Row) -> SqlResult<RssArticle> {
    Ok(RssArticle {
        origin: row.get(0)?,
        sort: row.get::<_, Option<String>>(1)?.unwrap_or_default(),
        title: row.get::<_, Option<String>>(2)?.unwrap_or_default(),
        pub_date: row.get::<_, Option<String>>(3)?.unwrap_or_default(),
        link: row.get(4)?,
        image: row.get(5)?,
        description: row.get(6)?,
        variable: row.get(7)?,
        order_num: row.get::<_, Option<i32>>(8)?.unwrap_or(0),
        read_time: row.get::<_, Option<i64>>(9)?.unwrap_or(0),
        star: row.get::<_, Option<i32>>(10)?.unwrap_or(0),
    })
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

    fn make_article(origin: &str, sort: &str, link: &str, order_num: i32) -> RssArticle {
        RssArticle {
            origin: origin.to_string(),
            sort: sort.to_string(),
            title: format!("title-{}", link),
            pub_date: format!("2024-01-{:02}", order_num + 1),
            link: link.to_string(),
            image: Some(format!("img-{}", link)),
            description: Some(format!("desc-{}", link)),
            variable: None,
            order_num,
            read_time: 0,
            star: 0,
        }
    }

    #[test]
    fn test_upsert_batch_preserves_read_star() {
        let (_dir, conn) = setup();
        let dao = RssArticleDao::new(&conn);

        // 第一次 upsert：5 篇，全部未读未收藏。
        let mut articles: Vec<RssArticle> = (0..5)
            .map(|i| make_article("https://feed/x", "", &format!("link-{i}"), i))
            .collect();
        let n = dao.upsert_batch(&articles).unwrap();
        assert_eq!(n, 5);

        // 标记 link-0 / link-1 为已读 + 设置 star=1（直接写 DB 模拟批次 18）。
        let mark_n = dao.mark_read("link-0", 1700000000).unwrap();
        assert_eq!(mark_n, 1);
        conn.execute(
            "UPDATE rss_articles SET read_time = 1700000001 WHERE link = 'link-1'",
            [],
        )
        .unwrap();
        conn.execute(
            "UPDATE rss_articles SET star = 1 WHERE link = 'link-1'",
            [],
        )
        .unwrap();

        // 第二次 upsert：把 title 都改了 + read_time/star 都传 0（模拟新拉取）。
        for a in &mut articles {
            a.title = format!("new-title-{}", a.link);
            a.read_time = 0;
            a.star = 0;
        }
        dao.upsert_batch(&articles).unwrap();

        let listed = dao
            .list_by_origin_sort("https://feed/x", Some(""), -1, 0)
            .unwrap();
        assert_eq!(listed.len(), 5);
        let by_link: std::collections::HashMap<_, _> =
            listed.iter().map(|a| (a.link.clone(), a)).collect();

        // title 应被刷新
        assert_eq!(by_link["link-0"].title, "new-title-link-0");
        // 但 read_time / star 必须保留
        assert_eq!(by_link["link-0"].read_time, 1700000000);
        assert_eq!(by_link["link-1"].read_time, 1700000001);
        assert_eq!(by_link["link-1"].star, 1);
        // 其它行依旧未读
        assert_eq!(by_link["link-2"].read_time, 0);
        assert_eq!(by_link["link-2"].star, 0);
    }

    #[test]
    fn test_list_by_origin_sort_orders_and_filters() {
        let (_dir, conn) = setup();
        let dao = RssArticleDao::new(&conn);

        let mut all = Vec::new();
        for i in 0..3 {
            let mut a = make_article("https://feed/x", "tech", &format!("t-{i}"), i);
            a.pub_date = format!("2024-03-{:02}", i + 1);
            all.push(a);
        }
        for i in 0..2 {
            let mut a = make_article("https://feed/x", "news", &format!("n-{i}"), i);
            a.pub_date = format!("2024-02-{:02}", i + 1);
            all.push(a);
        }
        dao.upsert_batch(&all).unwrap();

        let tech = dao
            .list_by_origin_sort("https://feed/x", Some("tech"), -1, 0)
            .unwrap();
        assert_eq!(tech.len(), 3);
        // ORDER BY order_num ASC, pub_date DESC — tech-{0,1,2} 顺序为 0,1,2
        assert_eq!(tech[0].link, "t-0");
        assert_eq!(tech[2].link, "t-2");

        let news = dao
            .list_by_origin_sort("https://feed/x", Some("news"), -1, 0)
            .unwrap();
        assert_eq!(news.len(), 2);

        // sort=None → 全部
        let all_sorted = dao
            .list_by_origin_sort("https://feed/x", None, -1, 0)
            .unwrap();
        assert_eq!(all_sorted.len(), 5);

        // 分页 limit / offset
        let page = dao
            .list_by_origin_sort("https://feed/x", Some("tech"), 2, 1)
            .unwrap();
        assert_eq!(page.len(), 2);
        assert_eq!(page[0].link, "t-1");
    }

    #[test]
    fn test_mark_read_updates_both_tables() {
        let (_dir, conn) = setup();
        let dao = RssArticleDao::new(&conn);

        let articles = vec![
            make_article("https://feed/a", "", "shared-link", 0),
            make_article("https://feed/b", "", "shared-link", 0),
            make_article("https://feed/a", "", "lonely-link", 1),
        ];
        dao.upsert_batch(&articles).unwrap();

        let n = dao.mark_read("shared-link", 1700001234).unwrap();
        // shared-link 在两个 origin 下各一行，UPDATE 都会命中
        assert_eq!(n, 2);

        // rss_articles.read_time 双 origin 都更新
        let read_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM rss_articles \
                 WHERE link = 'shared-link' AND read_time = 1700001234",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(read_count, 2);

        // rss_read_records 写入一条
        let rec_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM rss_read_records WHERE link = 'shared-link' \
                 AND read_time = 1700001234",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(rec_count, 1);

        // 其它链接不受影响
        let lonely_read: i64 = conn
            .query_row(
                "SELECT read_time FROM rss_articles WHERE link = 'lonely-link'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(lonely_read, 0);
    }

    #[test]
    fn test_count_unread_and_list_unread() {
        let (_dir, conn) = setup();
        let dao = RssArticleDao::new(&conn);

        let articles: Vec<RssArticle> = (0..5)
            .map(|i| make_article("https://feed/x", "", &format!("u-{i}"), i))
            .collect();
        dao.upsert_batch(&articles).unwrap();

        assert_eq!(dao.count_unread_by_origin("https://feed/x").unwrap(), 5);

        // 标 2 篇已读
        dao.mark_read("u-0", 1700000000).unwrap();
        dao.mark_read("u-2", 1700000010).unwrap();

        assert_eq!(dao.count_unread_by_origin("https://feed/x").unwrap(), 3);
        let unread = dao.list_unread_by_origin("https://feed/x").unwrap();
        assert_eq!(unread.len(), 3);
        let unread_links: Vec<&str> = unread.iter().map(|a| a.link.as_str()).collect();
        assert!(!unread_links.contains(&"u-0"));
        assert!(!unread_links.contains(&"u-2"));
        assert!(unread_links.contains(&"u-1"));
    }

    #[test]
    fn test_delete_by_origin() {
        let (_dir, conn) = setup();
        let dao = RssArticleDao::new(&conn);

        let mut all = Vec::new();
        for i in 0..3 {
            all.push(make_article("https://feed/x", "", &format!("x-{i}"), i));
        }
        for i in 0..2 {
            all.push(make_article("https://feed/y", "", &format!("y-{i}"), i));
        }
        dao.upsert_batch(&all).unwrap();
        assert_eq!(
            dao.list_by_origin_sort("https://feed/x", None, -1, 0)
                .unwrap()
                .len(),
            3
        );

        let n = dao.delete_by_origin("https://feed/x").unwrap();
        assert_eq!(n, 3);

        assert_eq!(
            dao.list_by_origin_sort("https://feed/x", None, -1, 0)
                .unwrap()
                .len(),
            0
        );
        assert_eq!(
            dao.list_by_origin_sort("https://feed/y", None, -1, 0)
                .unwrap()
                .len(),
            2
        );
    }

    #[test]
    fn test_get_by_origin_link() {
        let (_dir, conn) = setup();
        let dao = RssArticleDao::new(&conn);
        let mut a = make_article("https://feed/x", "tech", "link-1", 0);
        a.title = "Hello".into();
        a.description = Some("body".into());
        dao.upsert_batch(&[a]).unwrap();

        let got = dao
            .get_by_origin_link("https://feed/x", "link-1")
            .unwrap();
        assert!(got.is_some());
        let got = got.unwrap();
        assert_eq!(got.title, "Hello");
        assert_eq!(got.description.as_deref(), Some("body"));

        // 不存在 → None
        let none = dao
            .get_by_origin_link("https://feed/x", "missing")
            .unwrap();
        assert!(none.is_none());

        // 不同 origin 也分隔
        let none2 = dao
            .get_by_origin_link("https://feed/other", "link-1")
            .unwrap();
        assert!(none2.is_none());
    }
}
