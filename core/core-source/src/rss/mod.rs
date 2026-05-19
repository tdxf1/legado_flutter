//! # RSS 解析子系统（批次 17 / 05-19）
//!
//! 对应原 Legado `model/rss/Rss.kt` + `RssParserDefault.kt` +
//! `RssParserByRule.kt`。沿袭 [`crate::parser::BookSourceParser`] 的
//! "async + LegadoHttpClient + ParserError" 风格，新建独立的
//! [`RssParser`]，避免和 BookSource 解析器互相耦合。
//!
//! ## 路由
//!
//! 1. 单 URL 模式（`source.single_url == true` 或 `sort_url` 空）→ 用
//!    `source.source_url` 拉取
//! 2. 多分类模式 → 用传入的 `sort_url`
//! 3. 拉到 body 后判断格式：
//!    - `<rss` / `<feed` 开头 → XML 路（`parse_xml`）
//!    - 其它 → 规则路（`parse_rule`）
//!    - XML 路解析后 `Vec` 为空且 `rule_articles` 非空 → 降级试规则路
//!
//! 错误用 [`ParserError::Network/Empty/Parse/RuleConfig`]（已在
//! `crate::parser` 定义，沿用）。

pub mod parse_rule;
pub mod parse_xml;

use crate::legado::{LegadoHttpClient, LegadoUrl};
use crate::parser::ParserError;
use core_storage::{RssArticle, RssSource};
use tracing::{info, warn};

/// RSS 解析器。沿袭 [`crate::parser::BookSourceParser`] 风格 — 持有
/// 共享的 HTTP 客户端，负责拉取 + 路由 + 解析。
pub struct RssParser {
    http_client: LegadoHttpClient,
}

impl Default for RssParser {
    fn default() -> Self {
        Self::new()
    }
}

impl RssParser {
    pub fn new() -> Self {
        Self {
            http_client: LegadoHttpClient::new(),
        }
    }

    /// 拉取并解析 RSS 文章。
    ///
    /// - `sort_name` / `sort_url` 在多分类模式下用；单 URL 模式都可空
    /// - `page` MVP 不实装翻页（只取第 1 页），保留参数为批次 18 备用
    pub async fn get_articles(
        &self,
        source: &RssSource,
        sort_name: &str,
        sort_url: &str,
        page: i32,
    ) -> Result<Vec<RssArticle>, ParserError> {
        let target_url = if source.single_url || sort_url.trim().is_empty() {
            source.source_url.as_str()
        } else {
            sort_url
        };
        info!(
            "拉取 RSS: source={} url={} sort={} page={}",
            source.source_name, target_url, sort_name, page
        );

        let body = self
            .fetch(source, target_url, page)
            .await
            .map_err(ParserError::Network)?;

        let trimmed = body.trim_start_matches('\u{FEFF}').trim_start();
        let try_xml_first = trimmed.starts_with("<rss") || trimmed.starts_with("<feed");

        if try_xml_first {
            let articles = parse_xml_dispatch(&body, &source.source_url, sort_name);
            if !articles.is_empty() {
                return Ok(articles);
            }
            // XML 解析为空：若书源配了 rule_articles，降级试规则路
            if source
                .rule_articles
                .as_deref()
                .map(|s| !s.trim().is_empty())
                .unwrap_or(false)
            {
                warn!("RSS XML 解析为空，降级试规则路");
                let rule_articles =
                    parse_rule::parse_articles_by_rule(source, &body, sort_name);
                if !rule_articles.is_empty() {
                    return Ok(rule_articles);
                }
            }
            return Err(ParserError::Empty);
        }

        // 规则路
        let articles = parse_rule::parse_articles_by_rule(source, &body, sort_name);
        if articles.is_empty() {
            // 规则路也空：若内容看起来仍可能是 XML（带 < 但不以 rss/feed
            // 开头），最后兜底试一下两种 XML 解析（非常宽容）
            let detected = parse_xml::detect_format(&body);
            let articles_xml = match detected {
                parse_xml::RssFormat::Rss20 => {
                    parse_xml::parse_rss20(&body, &source.source_url, sort_name)
                }
                parse_xml::RssFormat::Atom => {
                    parse_xml::parse_atom(&body, &source.source_url, sort_name)
                }
                parse_xml::RssFormat::Unknown => Vec::new(),
            };
            if articles_xml.is_empty() {
                return Err(ParserError::Empty);
            }
            return Ok(articles_xml);
        }
        Ok(articles)
    }

    /// **占位**：批次 18 的"文章详情"才真正实装。现在仅返回
    /// `article.description`（XML 路通常已是全文）。
    pub async fn fetch_article_content_full(
        &self,
        _source: &RssSource,
        article: &RssArticle,
    ) -> Result<String, ParserError> {
        Ok(article.description.clone().unwrap_or_default())
    }

    async fn fetch(
        &self,
        source: &RssSource,
        url: &str,
        page: i32,
    ) -> Result<String, String> {
        let legado_url = crate::legado::url::parse_legado_url(url);
        let full_url = crate::legado::url::resolve_url_template(
            &legado_url,
            "",
            page,
            &source.source_url,
        );
        let extra_headers = parse_source_headers(source.header.as_deref());
        self.http_client
            .request_with_legado_url_and_headers(
                &full_url,
                &legado_url,
                "",
                page,
                &extra_headers,
            )
            .await
    }
}

fn parse_xml_dispatch(body: &str, origin: &str, sort: &str) -> Vec<RssArticle> {
    match parse_xml::detect_format(body) {
        parse_xml::RssFormat::Rss20 => parse_xml::parse_rss20(body, origin, sort),
        parse_xml::RssFormat::Atom => parse_xml::parse_atom(body, origin, sort),
        parse_xml::RssFormat::Unknown => Vec::new(),
    }
}

/// 解析 source.header（JSON object 或 `Key: Value\n` 行）→
/// `[(name, value)]`。复刻 parser.rs 同名函数，避免新加 pub。
fn parse_source_headers(header: Option<&str>) -> Vec<(String, String)> {
    let Some(header) = header.map(str::trim).filter(|s| !s.is_empty()) else {
        return Vec::new();
    };
    if let Ok(value) = serde_json::from_str::<serde_json::Value>(header) {
        return crate::legado::url::parse_headers(&Some(value));
    }
    header
        .lines()
        .filter_map(|line| {
            let (key, value) = line.split_once(':')?;
            let key = key.trim();
            if key.is_empty() {
                None
            } else {
                Some((key.to_string(), value.trim().to_string()))
            }
        })
        .collect()
}

// LegadoUrl re-export hint for downstream tests — keeps the import
// graph from being noisy if a future test wants to construct one.
#[allow(dead_code)]
fn _legado_url_visible(url: &str) -> LegadoUrl {
    crate::legado::url::parse_legado_url(url)
}
