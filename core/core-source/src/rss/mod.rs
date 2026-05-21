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

use crate::legado::{execute_legado_rule, LegadoHttpClient, LegadoUrl, RuleContext};
use crate::parser::ParserError;
use core_storage::{RssArticle, RssSource};
use serde::{Deserialize, Serialize};
use tracing::{info, warn};

/// 详情拉取结果（批次 18 / 05-19）。
///
/// 上层（bridge / Flutter detail 页）拿到后：
/// - `html` 直接喂 WebViewController.loadHtmlString
/// - `base_url` 给 loadHtmlString 第二参数，让 WebView 解析相对 URL
///   （例如规则路返回的 `<img src="/foo.jpg">` 能正确补全成绝对 URL）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FetchedContent {
    pub html: String,
    pub base_url: String,
}

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
        // F-W1B-029 mitigation: clear the per-thread parsed-html cache up
        // front so that the (ptr, len) cache key inside `legado::rule`
        // cannot collide with stale state left by a previous call whose
        // html buffer happens to be re-allocated at the same address.
        crate::legado::clear_html_parse_cache();

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

        // BOM / `<?xml ?>` / 空白 / 注释剥离统一走 `parse_xml::skip_xml_prologue`，
        // 避免 mod.rs 简化版与 parse_xml 版漂移（master findings F-W1B-039）。
        let trimmed = parse_xml::skip_xml_prologue(&body);
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

    /// 拉取单篇 RSS 文章的完整正文 HTML（批次 18 / 05-19）。
    ///
    /// 路由：
    /// 1. `source.rule_content` 非空 → 规则路：reqwest GET `article.link`
    ///    → AnalyzeRule 抽 rule_content 结果 → 包成 wrapper HTML
    /// 2. 否则 → fallback：把 `article.description`（XML 路通常已是
    ///    全文）作为正文，包同一个 wrapper
    ///
    /// 返回 [`FetchedContent`]：含完整 wrapper HTML（带 viewport / 默认
    /// 样式 / 响应式图片）+ base URL（用 `source.source_url`，让 WebView
    /// 解析相对链接）。
    ///
    /// 错误：[`ParserError::Network`]（HTTP 失败）/
    /// [`ParserError::Empty`](规则路抽到空 + description 也空) /
    /// [`ParserError::Parse`](规则解析失败但 fetch 成功)。
    pub async fn fetch_article_content_full(
        &self,
        source: &RssSource,
        article: &RssArticle,
    ) -> Result<FetchedContent, ParserError> {
        // F-W1B-029 mitigation: clear the per-thread parsed-html cache up
        // front (see `RssParser::get_articles` for rationale).
        crate::legado::clear_html_parse_cache();

        info!(
            "拉取 RSS 文章详情: source={} link={}",
            source.source_name, article.link
        );

        let rule = source
            .rule_content
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty());

        let body_text = match rule {
            Some(rule_str) => {
                // 规则路：fetch HTML 再抽
                let body = self
                    .fetch(source, &article.link, 1)
                    .await
                    .map_err(ParserError::Network)?;
                let context = RuleContext::for_content(&article.link, &body);
                let result = execute_legado_rule(rule_str, &body, &context)
                    .map_err(ParserError::Parse)?;
                let extracted = result.into_iter().collect::<Vec<_>>().join("\n");
                if extracted.trim().is_empty() {
                    // 规则没抽到 → 退化用 description 兜底（不当 Parse 错）
                    article.description.clone().unwrap_or_default()
                } else {
                    extracted
                }
            }
            None => article.description.clone().unwrap_or_default(),
        };

        if body_text.trim().is_empty() {
            return Err(ParserError::Empty);
        }

        let html = wrap_article_html(&body_text);
        // base_url 优先用 source 根 URL；fallback article.link 所在域。
        // WebView 用 base_url 解析 wrapper 内相对链接（图片 / a href）。
        let base_url = if !source.source_url.trim().is_empty() {
            source.source_url.clone()
        } else {
            article.link.clone()
        };
        Ok(FetchedContent { html, base_url })
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

/// 把抽到的正文（可能是 HTML 片段也可能是纯文本）包成完整 HTML 文档。
/// 加 `<meta viewport>` 让 WebView 在手机端按宽度自适应；style 里
/// 设置 padding / line-height / 响应式图片避免横滚。
///
/// 不做内容白名单 / black list（PRD 明确 out-of-scope）；不注入 JS
/// （injectJs 留批次 19+）。批次 18 的 wrapper 与 PRD Technical Notes
/// 章节给的样板一致。
fn wrap_article_html(body: &str) -> String {
    format!(
        "<!DOCTYPE html><html><head><meta charset=\"UTF-8\">\
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\
<style>body{{padding:16px;font-family:sans-serif;line-height:1.6;font-size:16px;color:#222}}\
img{{max-width:100%;height:auto}}</style></head><body>{body}</body></html>",
        body = body
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;
    use httpmock::prelude::*;

    fn make_source(rule_content: Option<&str>, base: &str) -> RssSource {
        RssSource {
            source_url: base.to_string(),
            source_name: "X Feed".into(),
            source_icon: None,
            source_group: None,
            source_comment: None,
            enabled: true,
            single_url: true,
            sort_url: None,
            article_style: 0,
            rule_articles: None,
            rule_next_page: None,
            rule_title: None,
            rule_pub_date: None,
            rule_description: None,
            rule_image: None,
            rule_link: None,
            rule_content: rule_content.map(|s| s.to_string()),
            last_update_time: 0,
            custom_order: 0,
            enable_js: false,
            load_with_base_url: true,
            header: None,
            custom_info_json: None,
            created_at: Utc::now().timestamp(),
            updated_at: Utc::now().timestamp(),
        }
    }

    fn make_article(origin: &str, link: &str, description: Option<&str>) -> RssArticle {
        RssArticle {
            origin: origin.to_string(),
            sort: String::new(),
            title: "Title".into(),
            pub_date: "2024-05-19".into(),
            link: link.to_string(),
            image: None,
            description: description.map(|s| s.to_string()),
            variable: None,
            order_num: 0,
            read_time: 0,
            star: 0,
        }
    }

    /// rule_content 为 None → 用 article.description fallback，
    /// 包成 wrapper HTML 返回。
    #[tokio::test]
    async fn test_fetch_article_content_uses_description_fallback() {
        let parser = RssParser::new();
        let source = make_source(None, "https://example.com");
        let article = make_article(
            "https://example.com",
            "https://example.com/article/1",
            Some("<p>Hello from description</p>"),
        );
        let result = parser
            .fetch_article_content_full(&source, &article)
            .await
            .expect("fetch ok");
        assert!(result.html.contains("Hello from description"));
        assert!(result.html.contains("<style>"));
        assert!(result.html.contains("<meta name=\"viewport\""));
        assert_eq!(result.base_url, "https://example.com");
    }

    /// 配置了 rule_content → 走规则路：fetch URL → 抽 rule_content
    /// → wrapper HTML。
    #[tokio::test]
    async fn test_fetch_article_content_via_rule_content() {
        let server = MockServer::start();
        let html_body = r#"<html><body>
<header>nav stuff</header>
<div id="article-body"><p>Real article body here.</p><img src="/pic.jpg"></div>
<footer>foot</footer>
</body></html>"#;
        let mock = server.mock(|when, then| {
            when.method(GET).path("/article/2");
            then.status(200)
                .header("Content-Type", "text/html; charset=utf-8")
                .body(html_body);
        });

        let parser = RssParser::new();
        let source = make_source(Some("#article-body@html"), &server.base_url());
        let article = make_article(
            &server.base_url(),
            &format!("{}/article/2", server.base_url()),
            Some("description should NOT be used"),
        );
        let result = parser
            .fetch_article_content_full(&source, &article)
            .await
            .expect("fetch ok");
        // 抽出的内容里有正文段落
        assert!(result.html.contains("Real article body here."));
        // 不应回落到 description
        assert!(!result.html.contains("description should NOT be used"));
        // wrapper 在
        assert!(result.html.contains("<meta name=\"viewport\""));
        assert_eq!(result.base_url, server.base_url());
        mock.assert();
    }

    /// 规则为空 + description 也空 → ParserError::Empty
    #[tokio::test]
    async fn test_fetch_article_content_empty_returns_empty_error() {
        let parser = RssParser::new();
        let source = make_source(None, "https://example.com");
        let article = make_article(
            "https://example.com",
            "https://example.com/article/empty",
            None,
        );
        let result = parser.fetch_article_content_full(&source, &article).await;
        assert!(matches!(result, Err(ParserError::Empty)));
    }

    /// F-W1B-039 回归：feed 顶部含 `<?xml version="1.0"?>` prologue 时，
    /// `get_articles` 应当复用 `parse_xml::skip_xml_prologue` 正确判定为
    /// XML feed 并走 XML 解析路径，而非降级到规则路径。
    #[tokio::test]
    async fn test_get_articles_handles_xml_prologue() {
        let server = MockServer::start();
        let xml_body = r#"<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0">
<channel>
<title>Sample Feed</title>
<item>
<title>Hello</title>
<link>https://example.com/post/1</link>
<description>desc</description>
</item>
</channel>
</rss>"#;
        let mock = server.mock(|when, then| {
            when.method(GET).path("/feed");
            then.status(200)
                .header("Content-Type", "application/rss+xml; charset=utf-8")
                .body(xml_body);
        });

        let parser = RssParser::new();
        let mut source = make_source(None, &format!("{}/feed", server.base_url()));
        // rule_articles 留 None 强制走 XML 优先路径
        source.rule_articles = None;
        let articles = parser
            .get_articles(&source, "", "tech", 1)
            .await
            .expect("xml feed parsed");
        assert_eq!(articles.len(), 1);
        assert_eq!(articles[0].title, "Hello");
        mock.assert();
    }
}
