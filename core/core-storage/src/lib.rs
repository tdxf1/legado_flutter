//! # core-storage - 存储引擎模块
//!
//! 负责所有数据持久化操作，对应原Legado的`data/entities/`和`help/storage/`。
//! 使用SQLite + rusqlite实现轻量级本地数据库，chrono处理时间相关字段。

pub mod backup_dao;
pub mod book_dao;
pub mod book_group_dao;
pub mod cache_dao;
pub mod cache_stats_dao;
pub mod chapter_dao;
pub mod database;
pub mod download_dao;
pub mod legado_aes;
pub mod legado_field_map;
pub mod models;
pub mod progress_dao;
pub mod read_record_dao;
pub mod replace_rule_dao;
pub mod rss_article_dao;
pub mod rss_read_record_dao;
pub mod rss_source_dao;
pub mod rss_star_dao;
pub mod rule_sub_dao;
pub mod source_dao;

// 重新导出主要类型，方便上层调用
pub use book_dao::BookDao;
pub use book_group_dao::BookGroupDao;
pub use cache_dao::CacheDao;
pub use cache_stats_dao::{BookCacheStats, CacheStatsDao};
pub use chapter_dao::ChapterDao;
pub use download_dao::DownloadDao;
pub use models::{
    Book, BookGroup, BookProgress, BookSource, Bookmark, Chapter, Cookie, DownloadChapter,
    DownloadTask, ReadRecord, ReplaceRule, RssArticle, RssImportSummary, RssReadRecord,
    RssSource, RssStar, RuleSub,
};
pub use progress_dao::ProgressDao;
pub use read_record_dao::ReadRecordDao;
pub use replace_rule_dao::ReplaceRuleDao;
pub use rss_article_dao::RssArticleDao;
pub use rss_read_record_dao::RssReadRecordDao;
pub use rss_source_dao::RssSourceDao;
pub use rss_star_dao::RssStarDao;
pub use rule_sub_dao::RuleSubDao;
pub use source_dao::SourceDao;

// 历史 `pub struct StorageManager` / `pub struct DatabaseConfig` /
// `pub fn init_database` 顶层 wrapper / `#[cfg(test)] mod tests` 已在
// BATCH-08b（2026-05）整删 — 全仓零外部 caller，error type 用
// `Box<dyn std::error::Error>` 与全 crate `rusqlite::Error` 风格不一致；
// WAL 测试只在死代码路径上验证 production 不启用的开关。生产代码
// 一律走 `core_storage::database::init_database` + 各 DAO 直接构造
// 的方式（如 `BookDao::new(&conn)`）。
//
// 关于 production WAL：BATCH-08c（F-W1A-055）已在
// `database::init_database` 启用 `journal_mode = WAL` — 配合既有的
// `synchronous = NORMAL` + `wal_autocheckpoint = 1000` 形成 SQLite
// 官方推荐组合。详见 `database.rs::init_database` 内的 BATCH-08c 段
// 注释，及 `database.rs::tests` 内 `test_wal_enabled_on_fresh_init` /
// `test_wal_persists_across_reopens` 两条单测。
