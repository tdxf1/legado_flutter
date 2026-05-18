//! # 数据模型定义
//!
//! 定义 core-storage 使用的核心数据结构。
//! 对应原 Legado 的 data/entities/ 中的数据实体。

use chrono::Utc;
use serde::{Deserialize, Serialize};

/// 书源结构体（对应原 Legado 的 BookSource 实体）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookSource {
    pub id: String,
    pub name: String,
    pub url: String,
    pub source_type: i32, // 0=小说, 1=音频, 2=图片, 3=RSS
    pub group_name: Option<String>,
    pub enabled: bool,
    pub custom_order: i32,
    pub weight: i32,

    // 规则（JSON 格式存储）
    pub rule_search: Option<String>,
    pub rule_book_info: Option<String>,
    pub rule_toc: Option<String>,
    pub rule_content: Option<String>,

    // 其他配置
    pub login_url: Option<String>,
    #[serde(default)]
    pub login_ui: Option<String>,
    #[serde(default)]
    pub login_check_js: Option<String>,
    pub header: Option<String>,
    pub js_lib: Option<String>,
    #[serde(default)]
    pub cover_decode_js: Option<String>,
    pub book_url_pattern: Option<String>,
    #[serde(default)]
    pub rule_explore: Option<String>,
    #[serde(default)]
    pub explore_url: Option<String>,
    #[serde(default)]
    pub enabled_explore: bool,
    #[serde(default)]
    pub last_update_time: i64,
    #[serde(default)]
    pub book_source_comment: Option<String>,
    #[serde(default)]
    pub concurrent_rate: Option<String>,
    #[serde(default)]
    pub variable_comment: Option<String>,
    #[serde(default)]
    pub explore_screen: Option<i32>,

    pub created_at: i64,
    pub updated_at: i64,
}

/// 书籍结构体（对应原 Legado 的 Book 实体）
///
/// **批次 6 (v11)**: 加 5 字段对齐原 Legado `Book.kt:96-102`：
/// - `dur_chapter_index` / `dur_chapter_pos` — 当前章节 + 章内字符 offset
///   （书架"上次阅读"显示 + 排序）。`book_progress` 表已经存有这些
///   信息，但原 Legado 是把"上次阅读"快照写在 books 表里方便
///   书架直接 SELECT；保留两份做兼容。
/// - `dur_chapter_title` — 上次阅读章节标题，书架卡片副标题用。
/// - `dur_chapter_time` — 上次阅读时间戳，书架按"最近读"排序用。
/// - `group_id` — 所属分组 id（0 = 未分组），FK 到 `book_groups.id`。
///
/// 全部带 `#[serde(default)]`，老 JSON 反序列化兼容（远端 / 备份恢复
/// 不会因新字段缺失而失败）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Book {
    pub id: String,
    pub source_id: String,
    pub source_name: Option<String>,
    pub name: String,
    pub author: Option<String>,
    pub cover_url: Option<String>,
    pub chapter_count: i32,
    pub latest_chapter_title: Option<String>,
    pub intro: Option<String>,
    pub kind: Option<String>,
    pub book_url: Option<String>,
    pub toc_url: Option<String>,
    pub last_check_time: Option<i64>,
    pub last_check_count: i32,
    pub total_word_count: i32,
    pub can_update: bool,
    pub order_time: i64,
    pub latest_chapter_time: Option<i64>,
    pub custom_cover_path: Option<String>,
    pub custom_info_json: Option<String>,
    /// 当前阅读章节索引（书架"上次读"显示用）。批次 6 新增。
    #[serde(default)]
    pub dur_chapter_index: i32,
    /// 当前阅读章节内字符 offset。批次 6 新增。
    #[serde(default)]
    pub dur_chapter_pos: i32,
    /// 当前阅读章节标题（书架卡片副标题）。批次 6 新增。
    #[serde(default)]
    pub dur_chapter_title: Option<String>,
    /// 上次阅读时间戳（秒），书架按"最近读"排序用。批次 6 新增。
    #[serde(default)]
    pub dur_chapter_time: i64,
    /// 所属分组 id；0 = 未分组，AUTOINCREMENT 从 1 开始。批次 6 新增。
    #[serde(default)]
    pub group_id: i64,
    pub created_at: i64,
    pub updated_at: i64,
}

/// 章节结构体（对应原 Legado 的 Chapter 实体）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Chapter {
    pub id: String,
    pub book_id: String,
    pub index_num: i32,
    pub title: String,
    pub url: String,
    pub content: Option<String>,
    pub is_volume: bool,
    pub is_checked: bool,
    pub start: i32,
    pub end: i32,
    pub created_at: i64,
    pub updated_at: i64,
}

/// 阅读进度结构体
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookProgress {
    pub book_id: String,
    pub chapter_index: i32,
    pub paragraph_index: i32,
    pub offset: i32,
    pub read_time: i64, // 累计阅读时长（毫秒）
    pub updated_at: i64,
}

/// 书签结构体
///
/// **批次 6 (v11)**: 加 5 字段对齐原 Legado `Bookmark.kt`：
/// - `book_name` / `book_author` — 跨书全书签清单页要显示书名作者，
///   书删了书签仍保留这些冗余信息。
/// - `chapter_pos` — 章内字符级 offset（不是段落 index，不是字符串）。
/// - `chapter_name` — 章节标题，全书签清单页副标题用。
/// - `book_text` — 书签所在位置的文本片段（上下文预览）。
///
/// 全部带 `#[serde(default)]`，老 JSON 兼容。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Bookmark {
    pub id: String,
    pub book_id: String,
    pub chapter_index: i32,
    pub paragraph_index: i32,
    pub content: Option<String>,
    /// 冗余存的书名（跨书全书签清单页用）。批次 6 新增。
    #[serde(default)]
    pub book_name: Option<String>,
    /// 冗余存的作者。批次 6 新增。
    #[serde(default)]
    pub book_author: Option<String>,
    /// 章内字符级 offset。批次 6 新增。
    #[serde(default)]
    pub chapter_pos: i32,
    /// 章节标题（清单页副标题）。批次 6 新增。
    #[serde(default)]
    pub chapter_name: Option<String>,
    /// 书签上下文文本片段。批次 6 新增。
    #[serde(default)]
    pub book_text: Option<String>,
    pub created_at: i64,
}

/// 替换规则结构体
///
/// **R24**: schema 对齐原 Legado 设计 (`app/data/entities/ReplaceRule.kt`)。
/// 之前用 `scope: i32` enum (0=全局, 1=书源, 2=书籍) 但 schema 没有
/// 配套的 target 字段，导致所有 enabled 规则不分作用范围一律生效。
/// v10 schema 把 `scope` 改成 `Option<String>`，子串包含 `book.name`
/// 或 `book.origin` 即匹配；并补齐 scope_title / scope_content /
/// exclude_scope 等原项目里就有的辅助字段。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReplaceRule {
    pub id: String,
    pub name: String,
    pub pattern: String,
    pub replacement: String,
    pub enabled: bool,
    /// 作用范围。`None` 或空字符串表示全局；否则按子串包含
    /// `book.name` 或 `book.origin` (书源 URL) 来匹配。
    pub scope: Option<String>,
    /// 是否作用于章节标题。原 Legado 默认 false。
    pub scope_title: bool,
    /// 是否作用于正文。原 Legado 默认 true。
    pub scope_content: bool,
    /// 排除范围。子串语义同 [`scope`]，命中即跳过该规则。
    pub exclude_scope: Option<String>,
    pub sort_number: i32,
    pub created_at: i64,
    pub updated_at: i64,
}

/// 下载任务结构体
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadTask {
    pub id: String,
    pub book_id: String,
    pub book_name: String,
    pub cover_url: Option<String>,
    pub total_chapters: i32,
    pub downloaded_chapters: i32,
    pub status: i32, // 0=等待, 1=下载中, 2=暂停, 3=完成, 4=失败
    pub total_size: i64,
    pub downloaded_size: i64,
    pub error_message: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
}

/// 下载章节记录结构体
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadChapter {
    pub id: String,
    pub task_id: String,
    pub chapter_id: String,
    pub chapter_index: i32,
    pub chapter_title: String,
    pub status: i32, // 0=等待, 1=下载中, 2=完成, 3=失败
    pub file_path: Option<String>,
    pub file_size: i64,
    pub error_message: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
}

/// 生成新的 UUID
pub fn new_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

/// 获取当前时间戳（秒）
pub fn now_timestamp() -> i64 {
    Utc::now().timestamp()
}

// ============================================================
// 批次 6 (v11) 新增 schema：仅 struct 定义，DAO 留依赖批次再加
// ============================================================

/// 书籍分组（书架分组功能用）
///
/// 对应原 Legado `BookGroup.kt`，但简化掉了原版的 bitmask 设计 ——
/// 改成自增 ID 普通表，`Book.group_id` 直接存外键。
/// `id = 0` 约定表示"未分组"，AUTOINCREMENT 从 1 开始所以不会冲突。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookGroup {
    pub id: i64,
    pub name: String,
    /// 分组在书架顶栏 Tab 上的显示顺序。
    pub sort_order: i32,
    /// 分组封面图（本地路径或 URL，nullable）。
    pub cover: Option<String>,
    /// 是否在书架上显示（false = 隐藏分组）。
    pub show: bool,
    /// 分组内的排序模式（0=默认 / 1=名称 / 2=作者 / 3=最近读 ...）。
    /// 具体取值定义留后续批次实现 sort UI 时再约束。
    pub book_sort: i32,
    pub created_at: i64,
    pub updated_at: i64,
}

/// 阅读时长记录
///
/// 对应原 Legado `ReadRecord.kt`。原版用 `(deviceId, bookName)` 做联合主键，
/// 这里改成自增 UUID + book_id 外键 + 冗余 book_name。
/// `book_name` 冗余存便于"书删了仍能跨书统计阅读时长"。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReadRecord {
    pub id: String,
    pub book_id: String,
    /// 冗余存书名，便于跨书统计 / 书删后仍可查询历史阅读。
    pub book_name: String,
    /// 累计阅读时长（秒）。
    pub read_time: i64,
    /// 上次阅读时间戳（秒）。
    pub last_read_at: i64,
    pub created_at: i64,
    pub updated_at: i64,
}

/// 持久化 Cookie
///
/// 对应原 Legado `Cookie.kt`，用于书源登录态保活。
/// `(domain, key, path)` 三元组唯一（schema 上加 UNIQUE 约束）。
/// 当前 `core-net/cookie.rs` 是内存版本，本批次只先加 schema +
/// struct，DAO 实现留批次 7+ 做"书源登录"时再补。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Cookie {
    pub id: i64,
    pub domain: String,
    pub key: String,
    pub value: String,
    pub path: Option<String>,
    /// 过期时间戳（秒）；session cookie 为 None。
    pub expires_at: Option<i64>,
    pub created_at: i64,
    pub updated_at: i64,
}

/// 订阅源（书源 / RSS / 替换规则的远端订阅源）
///
/// 对应原 Legado `RuleSub.kt`。一个 URL 周期性拉取最新规则 JSON 列表
/// 合并入库。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuleSub {
    pub id: String,
    pub name: String,
    pub url: String,
    /// 0 = 书源订阅，1 = RSS 源订阅，2 = 替换规则订阅。
    pub sub_type: i32,
    pub custom_order: i32,
    pub created_at: i64,
    pub updated_at: i64,
}
