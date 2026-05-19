//! # RSS 源 DAO (批次 16 / 05-19)
//!
//! 对应原 Legado `RssSourceDao.kt`。schema 在批次 16 (v12) 新增的
//! `rss_sources` 表（`database.rs::create_rss_tables`），本模块提供
//! CRUD + 分组 + 批量 JSON 导入。
//!
//! ## 约定
//!
//! - 主键 = `source_url`（与原 Legado RssSource 一致），upsert 通过
//!   `INSERT ... ON CONFLICT(source_url) DO UPDATE` 实现幂等
//! - 列表默认排序：`custom_order ASC, source_name ASC`（沿袭 BookSource
//!   行为，方便用户用 customOrder 字段调整置顶）
//! - `import_from_json` 走"内部 JSON / Legado JSON"双格式探测：先按
//!   端口内部 `Vec<RssSource>` 反序列化，失败则按原 Legado camelCase
//!   `Vec<Object>` 解析 + `RssSource::from_legado_json` 适配
//! - upsert 按 source_url 区分 added vs updated，统计计入
//!   [`RssImportSummary`]
//! - `set_enabled` / `delete_by_url` 返回受影响行数（usize），方便
//!   上层做 toast 反馈
//!
//! 风格参考 `source_dao.rs::BookSourceDao`（共享 SQL 常量 + 防 ON CONFLICT
//! 列表漂移）+ `cache_stats_dao.rs`（只读 + UPDATE 不分 mut/non-mut）。

use super::models::{RssImportSummary, RssSource};
use chrono::Utc;
use rusqlite::{params, Connection, Result as SqlResult};
use serde_json::Value;
use tracing::{debug, info};

/// `rss_sources` 列读取顺序的单一来源。SELECT/INSERT 都基于此构建，
/// 列顺序与 [`rss_source_from_row`] 内 `row.get(N)` 索引一致。
const RSS_SOURCE_COLUMNS: &str = "source_url, source_name, source_icon, source_group, \
     source_comment, enabled, single_url, sort_url, article_style, \
     rule_articles, rule_next_page, rule_title, rule_pub_date, \
     rule_description, rule_image, rule_link, rule_content, \
     last_update_time, custom_order, enable_js, load_with_base_url, \
     header, custom_info_json, created_at, updated_at";

/// 单条 SQL，[`RssSourceDao::upsert`] 与未来潜在的 `batch_insert` 共享，
/// 避免两份 ON CONFLICT 列表漂移（参考 `source_dao::SOURCE_UPSERT_SQL`
/// 的修复教训）。
const RSS_UPSERT_SQL: &str = "INSERT INTO rss_sources (
    source_url, source_name, source_icon, source_group, source_comment,
    enabled, single_url, sort_url, article_style,
    rule_articles, rule_next_page, rule_title, rule_pub_date,
    rule_description, rule_image, rule_link, rule_content,
    last_update_time, custom_order, enable_js, load_with_base_url,
    header, custom_info_json, created_at, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(source_url) DO UPDATE SET
    source_name = excluded.source_name,
    source_icon = excluded.source_icon,
    source_group = excluded.source_group,
    source_comment = excluded.source_comment,
    enabled = excluded.enabled,
    single_url = excluded.single_url,
    sort_url = excluded.sort_url,
    article_style = excluded.article_style,
    rule_articles = excluded.rule_articles,
    rule_next_page = excluded.rule_next_page,
    rule_title = excluded.rule_title,
    rule_pub_date = excluded.rule_pub_date,
    rule_description = excluded.rule_description,
    rule_image = excluded.rule_image,
    rule_link = excluded.rule_link,
    rule_content = excluded.rule_content,
    last_update_time = excluded.last_update_time,
    custom_order = excluded.custom_order,
    enable_js = excluded.enable_js,
    load_with_base_url = excluded.load_with_base_url,
    header = excluded.header,
    custom_info_json = excluded.custom_info_json,
    updated_at = excluded.updated_at";

/// RSS 源 DAO
pub struct RssSourceDao<'a> {
    conn: &'a Connection,
}

impl<'a> RssSourceDao<'a> {
    /// 创建新的 RssSourceDao
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 列出所有 RSS 源（custom_order ASC, source_name ASC）
    pub fn list_all(&self) -> SqlResult<Vec<RssSource>> {
        let sql = format!(
            "SELECT {} FROM rss_sources ORDER BY custom_order ASC, source_name ASC",
            RSS_SOURCE_COLUMNS
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt.query_map([], rss_source_from_row)?;
        rows.collect()
    }

    /// 列出已启用的 RSS 源
    pub fn list_enabled(&self) -> SqlResult<Vec<RssSource>> {
        let sql = format!(
            "SELECT {} FROM rss_sources WHERE enabled = 1 \
             ORDER BY custom_order ASC, source_name ASC",
            RSS_SOURCE_COLUMNS
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt.query_map([], rss_source_from_row)?;
        rows.collect()
    }

    /// 列出指定分组下的 RSS 源。空字符串 / "未分组" 由调用方传 ""，
    /// 这里按 `source_group = ?` 严格匹配。
    pub fn list_by_group(&self, group: &str) -> SqlResult<Vec<RssSource>> {
        let sql = format!(
            "SELECT {} FROM rss_sources WHERE source_group = ? \
             ORDER BY custom_order ASC, source_name ASC",
            RSS_SOURCE_COLUMNS
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt.query_map(params![group], rss_source_from_row)?;
        rows.collect()
    }

    /// DISTINCT 分组列表（跳过 NULL / 空串）。返回顺序按分组名升序。
    pub fn list_groups(&self) -> SqlResult<Vec<String>> {
        let mut stmt = self.conn.prepare(
            "SELECT DISTINCT source_group FROM rss_sources \
             WHERE source_group IS NOT NULL AND source_group != '' \
             ORDER BY source_group ASC",
        )?;
        let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
        rows.collect()
    }

    /// 按 source_url 取单条
    pub fn get_by_url(&self, url: &str) -> SqlResult<Option<RssSource>> {
        let sql = format!(
            "SELECT {} FROM rss_sources WHERE source_url = ?",
            RSS_SOURCE_COLUMNS
        );
        let mut stmt = self.conn.prepare(&sql)?;
        let mut rows = stmt.query(params![url])?;
        if let Some(row) = rows.next()? {
            Ok(Some(rss_source_from_row(row)?))
        } else {
            Ok(None)
        }
    }

    /// upsert：返回 `1` 表示有写入（INSERT 或 UPDATE 命中），`0` 在
    /// SQLite ON CONFLICT 路径下基本不会出现（INSERT/UPDATE 都算 1）。
    pub fn upsert(&self, source: &RssSource) -> SqlResult<usize> {
        debug!(
            "upsert RSS source: {} ({})",
            source.source_name, source.source_url
        );
        self.conn.execute(
            RSS_UPSERT_SQL,
            params![
                source.source_url,
                source.source_name,
                source.source_icon,
                source.source_group,
                source.source_comment,
                source.enabled as i32,
                source.single_url as i32,
                source.sort_url,
                source.article_style,
                source.rule_articles,
                source.rule_next_page,
                source.rule_title,
                source.rule_pub_date,
                source.rule_description,
                source.rule_image,
                source.rule_link,
                source.rule_content,
                source.last_update_time,
                source.custom_order,
                source.enable_js as i32,
                source.load_with_base_url as i32,
                source.header,
                source.custom_info_json,
                source.created_at,
                source.updated_at,
            ],
        )
    }

    /// 切换 enabled，返回受影响行数。
    pub fn set_enabled(&self, url: &str, enabled: bool) -> SqlResult<usize> {
        let now = Utc::now().timestamp();
        self.conn.execute(
            "UPDATE rss_sources SET enabled = ?, updated_at = ? WHERE source_url = ?",
            params![enabled as i32, now, url],
        )
    }

    /// 按 source_url 删除单条，返回受影响行数。
    pub fn delete_by_url(&self, url: &str) -> SqlResult<usize> {
        info!("删除 RSS 源: {}", url);
        self.conn
            .execute("DELETE FROM rss_sources WHERE source_url = ?", params![url])
    }

    /// JSON 批量导入。复用 BookSource 风格双格式探测：
    /// 1. 内部存储格式 `Vec<RssSource>`（端口自己导出的 JSON）
    /// 2. 原 Legado 导出格式 `Vec<Object>` (camelCase + 31 字段)
    ///
    /// upsert 之前查 `source_url` 是否已存在，区分 added vs updated；
    /// 缺 sourceUrl / sourceName 的 entry 跳过并 +1 skipped。
    pub fn import_from_json(&self, json: &str) -> Result<RssImportSummary, String> {
        let mut summary = RssImportSummary::default();

        // 先按内部格式
        if let Ok(items) = serde_json::from_str::<Vec<RssSource>>(json) {
            for s in items {
                if s.source_url.is_empty() || s.source_name.is_empty() {
                    summary.skipped += 1;
                    continue;
                }
                let existed = self
                    .get_by_url(&s.source_url)
                    .map_err(|e| format!("查询 RSS 源失败: {}", e))?
                    .is_some();
                self.upsert(&s)
                    .map_err(|e| format!("写入 RSS 源失败: {}", e))?;
                if existed {
                    summary.updated += 1;
                } else {
                    summary.added += 1;
                }
            }
            return Ok(summary);
        }

        // 走原 Legado 格式
        let array: Vec<Value> =
            serde_json::from_str(json).map_err(|e| format!("解析 RSS 源 JSON 失败: {}", e))?;
        for v in array {
            let s = RssSource::from_legado_json(&v);
            if s.source_url.is_empty() || s.source_name.is_empty() {
                summary.skipped += 1;
                continue;
            }
            let existed = self
                .get_by_url(&s.source_url)
                .map_err(|e| format!("查询 RSS 源失败: {}", e))?
                .is_some();
            self.upsert(&s)
                .map_err(|e| format!("写入 RSS 源失败: {}", e))?;
            if existed {
                summary.updated += 1;
            } else {
                summary.added += 1;
            }
        }
        Ok(summary)
    }

    /// 总数（rss_sources 行数）。
    pub fn count(&self) -> SqlResult<i64> {
        self.conn
            .query_row("SELECT COUNT(*) FROM rss_sources", [], |row| row.get(0))
    }
}

/// 从数据库行 → `RssSource`。列顺序严格对齐 [`RSS_SOURCE_COLUMNS`]。
fn rss_source_from_row(row: &rusqlite::Row) -> SqlResult<RssSource> {
    Ok(RssSource {
        source_url: row.get(0)?,
        source_name: row.get(1)?,
        source_icon: row.get(2)?,
        source_group: row.get(3)?,
        source_comment: row.get(4)?,
        enabled: row.get::<_, i32>(5)? != 0,
        single_url: row.get::<_, i32>(6)? != 0,
        sort_url: row.get(7)?,
        article_style: row.get(8)?,
        rule_articles: row.get(9)?,
        rule_next_page: row.get(10)?,
        rule_title: row.get(11)?,
        rule_pub_date: row.get(12)?,
        rule_description: row.get(13)?,
        rule_image: row.get(14)?,
        rule_link: row.get(15)?,
        rule_content: row.get(16)?,
        last_update_time: row.get(17)?,
        custom_order: row.get(18)?,
        enable_js: row.get::<_, i32>(19)? != 0,
        load_with_base_url: row.get::<_, i32>(20)? != 0,
        header: row.get(21)?,
        custom_info_json: row.get(22)?,
        created_at: row.get(23)?,
        updated_at: row.get(24)?,
    })
}

// `OptionalExtension` 引用保住 — 当前实现走 `query` + `next` 模式，没
// 直接调 `.optional()`；未来 `get_by_url` 切到 `query_row(...).optional()`
// 时再加 import。

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

    fn make_source(url: &str, name: &str, group: Option<&str>) -> RssSource {
        let now = Utc::now().timestamp();
        RssSource {
            source_url: url.to_string(),
            source_name: name.to_string(),
            source_icon: None,
            source_group: group.map(|g| g.to_string()),
            source_comment: None,
            enabled: true,
            single_url: false,
            sort_url: None,
            article_style: 0,
            rule_articles: None,
            rule_next_page: None,
            rule_title: None,
            rule_pub_date: None,
            rule_description: None,
            rule_image: None,
            rule_link: None,
            rule_content: None,
            last_update_time: 0,
            custom_order: 0,
            enable_js: true,
            load_with_base_url: true,
            header: None,
            custom_info_json: None,
            created_at: now,
            updated_at: now,
        }
    }

    #[test]
    fn test_rss_source_upsert_and_get() {
        let (_dir, conn) = setup();
        let dao = RssSourceDao::new(&conn);

        let s1 = make_source("https://r1.example/feed", "Source 1", Some("Tech"));
        dao.upsert(&s1).unwrap();
        assert_eq!(dao.count().unwrap(), 1);

        let got = dao.get_by_url("https://r1.example/feed").unwrap().unwrap();
        assert_eq!(got.source_name, "Source 1");
        assert_eq!(got.source_group.as_deref(), Some("Tech"));
        assert!(got.enabled);

        // 再 upsert 同 URL 应该是 update 而不是 insert
        let mut s1_updated = s1.clone();
        s1_updated.source_name = "Source 1 (updated)".into();
        s1_updated.article_style = 2;
        dao.upsert(&s1_updated).unwrap();
        assert_eq!(dao.count().unwrap(), 1);
        let got2 = dao.get_by_url("https://r1.example/feed").unwrap().unwrap();
        assert_eq!(got2.source_name, "Source 1 (updated)");
        assert_eq!(got2.article_style, 2);
    }

    #[test]
    fn test_rss_source_list_groups() {
        let (_dir, conn) = setup();
        let dao = RssSourceDao::new(&conn);

        dao.upsert(&make_source(
            "https://r1.example",
            "S1",
            Some("Tech"),
        ))
        .unwrap();
        dao.upsert(&make_source(
            "https://r2.example",
            "S2",
            Some("Tech"),
        ))
        .unwrap();
        dao.upsert(&make_source(
            "https://r3.example",
            "S3",
            Some("News"),
        ))
        .unwrap();
        // 空分组（None）+ 空字符串 — 应被 list_groups 跳过
        dao.upsert(&make_source("https://r4.example", "S4", None))
            .unwrap();
        dao.upsert(&make_source("https://r5.example", "S5", Some("")))
            .unwrap();

        let groups = dao.list_groups().unwrap();
        assert_eq!(groups, vec!["News".to_string(), "Tech".to_string()]);

        let by_tech = dao.list_by_group("Tech").unwrap();
        assert_eq!(by_tech.len(), 2);
        let names: Vec<&str> = by_tech.iter().map(|s| s.source_name.as_str()).collect();
        assert!(names.contains(&"S1"));
        assert!(names.contains(&"S2"));
    }

    #[test]
    fn test_rss_source_set_enabled() {
        let (_dir, conn) = setup();
        let dao = RssSourceDao::new(&conn);

        let s = make_source("https://r1.example", "S", Some("G"));
        dao.upsert(&s).unwrap();
        assert!(dao.get_by_url("https://r1.example").unwrap().unwrap().enabled);

        let n = dao.set_enabled("https://r1.example", false).unwrap();
        assert_eq!(n, 1);
        assert!(!dao.get_by_url("https://r1.example").unwrap().unwrap().enabled);

        // list_enabled 不再返回它
        assert_eq!(dao.list_enabled().unwrap().len(), 0);
        assert_eq!(dao.list_all().unwrap().len(), 1);

        // 切回 true
        let n = dao.set_enabled("https://r1.example", true).unwrap();
        assert_eq!(n, 1);
        assert_eq!(dao.list_enabled().unwrap().len(), 1);

        // 不存在的 URL → 0
        let n = dao.set_enabled("https://nonexistent.example", true).unwrap();
        assert_eq!(n, 0);
    }

    #[test]
    fn test_rss_source_delete() {
        let (_dir, conn) = setup();
        let dao = RssSourceDao::new(&conn);
        dao.upsert(&make_source("https://r1.example", "S", None))
            .unwrap();
        let n = dao.delete_by_url("https://r1.example").unwrap();
        assert_eq!(n, 1);
        assert_eq!(dao.count().unwrap(), 0);
        // 重复删除 → 0
        let n2 = dao.delete_by_url("https://r1.example").unwrap();
        assert_eq!(n2, 0);
    }

    #[test]
    fn test_rss_source_import_from_legado_json() {
        let (_dir, conn) = setup();
        let dao = RssSourceDao::new(&conn);

        // 标准 Legado RssSource JSON（部分核心字段 + 部分高级字段）
        let json = r#"[
            {
                "sourceUrl": "https://feed.example/atom.xml",
                "sourceName": "示例 RSS",
                "sourceGroup": "科技",
                "sourceIcon": "https://feed.example/icon.png",
                "enabled": true,
                "singleUrl": false,
                "articleStyle": 1,
                "ruleArticles": "//entry",
                "ruleTitle": "title",
                "ruleLink": "link/@href",
                "rulePubDate": "updated",
                "ruleDescription": "summary",
                "ruleContent": "content",
                "lastUpdateTime": 1700000000000,
                "customOrder": 5,
                "enableJs": true,
                "loadWithBaseUrl": false,
                "header": "{\"User-Agent\":\"Mozilla\"}",
                "jsLib": "// helper",
                "loginUrl": "https://feed.example/login",
                "loginUi": "[]",
                "loginCheckJs": "true",
                "concurrentRate": "1000",
                "enabledCookieJar": true,
                "variableComment": "var v",
                "style": ".item { color:red }",
                "injectJs": "console.log(1)",
                "shouldOverrideUrlLoading": "true",
                "contentWhitelist": "main",
                "contentBlacklist": "ad",
                "coverDecodeJs": ""
            },
            {
                "sourceUrl": "https://feed2.example/rss",
                "sourceName": "RSS 2",
                "enabled": false
            },
            {
                "sourceUrl": "",
                "sourceName": "缺 URL"
            }
        ]"#;

        let summary = dao.import_from_json(json).unwrap();
        assert_eq!(summary.added, 2);
        assert_eq!(summary.updated, 0);
        assert_eq!(summary.skipped, 1, "缺 URL 应跳过");
        assert_eq!(dao.count().unwrap(), 2);

        let s1 = dao
            .get_by_url("https://feed.example/atom.xml")
            .unwrap()
            .unwrap();
        assert_eq!(s1.source_name, "示例 RSS");
        assert_eq!(s1.source_group.as_deref(), Some("科技"));
        assert_eq!(s1.article_style, 1);
        assert!(s1.enabled);
        assert!(!s1.single_url);
        assert_eq!(s1.rule_articles.as_deref(), Some("//entry"));
        assert_eq!(s1.last_update_time, 1700000000000);
        assert_eq!(s1.custom_order, 5);
        assert!(s1.enable_js);
        assert!(!s1.load_with_base_url);
        assert!(s1.header.is_some());

        // custom_info_json 必须保住 13 个高级字段（jsLib / loginUrl /
        // loginUi / loginCheckJs / coverDecodeJs / contentWhitelist /
        // contentBlacklist / shouldOverrideUrlLoading / style / injectJs /
        // concurrentRate / enabledCookieJar / variableComment）。
        let extras_json = s1
            .custom_info_json
            .as_deref()
            .expect("custom_info_json should not be empty");
        let extras: Value = serde_json::from_str(extras_json).unwrap();
        assert_eq!(extras.get("jsLib").and_then(|v| v.as_str()), Some("// helper"));
        assert_eq!(
            extras.get("loginUrl").and_then(|v| v.as_str()),
            Some("https://feed.example/login")
        );
        assert_eq!(extras.get("loginUi").and_then(|v| v.as_str()), Some("[]"));
        assert_eq!(extras.get("loginCheckJs").and_then(|v| v.as_str()), Some("true"));
        assert_eq!(
            extras.get("concurrentRate").and_then(|v| v.as_str()),
            Some("1000")
        );
        assert_eq!(
            extras.get("enabledCookieJar").and_then(|v| v.as_bool()),
            Some(true)
        );
        assert_eq!(
            extras.get("variableComment").and_then(|v| v.as_str()),
            Some("var v")
        );
        assert_eq!(
            extras.get("style").and_then(|v| v.as_str()),
            Some(".item { color:red }")
        );
        assert_eq!(
            extras.get("injectJs").and_then(|v| v.as_str()),
            Some("console.log(1)")
        );
        assert_eq!(
            extras.get("shouldOverrideUrlLoading").and_then(|v| v.as_str()),
            Some("true")
        );
        assert_eq!(
            extras.get("contentWhitelist").and_then(|v| v.as_str()),
            Some("main")
        );
        assert_eq!(
            extras.get("contentBlacklist").and_then(|v| v.as_str()),
            Some("ad")
        );

        // 第二次导入同一份 → 全部 updated
        let summary2 = dao.import_from_json(json).unwrap();
        assert_eq!(summary2.added, 0);
        assert_eq!(summary2.updated, 2);
        assert_eq!(summary2.skipped, 1);

        // 另一条
        let s2 = dao
            .get_by_url("https://feed2.example/rss")
            .unwrap()
            .unwrap();
        assert_eq!(s2.source_name, "RSS 2");
        assert!(!s2.enabled);
    }
}
