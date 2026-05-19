//! # RSS 规则路解析
//!
//! 当 RSS 源不是标准 XML（例如 HTML 列表页伪装 RSS）时，按 [`RssSource`]
//! 上的规则字段解析。规则语法与 BookSource 同（CSS / JSOUP 伪类 /
//! `@text` / `@html` / `@href` 等），直接复用
//! [`crate::legado::execute_legado_rule`]。
//!
//! ## 切分逻辑
//!
//! 1. `rule_articles` 切分文章块：用 selector 抽出 N 个 fragment（每段
//!    HTML），后续每段单独抽字段
//! 2. 每段内：rule_title / rule_link / rule_pub_date / rule_description /
//!    rule_image 各跑一遍 `execute_legado_rule_first`
//! 3. `rule_next_page`（MVP 仅记录到 RssArticle.variable，不实装翻页）
//!
//! 缺 `rule_articles` 直接返回空 Vec（没法切就放弃，留给上层走 XML 路）。

use crate::legado::{execute_legado_rule, RuleContext};
use core_storage::{RssArticle, RssSource};

/// 按规则解析 RSS 文章列表。
///
/// `sort` 用于填充每篇 [`RssArticle::sort`]，与 XML 路同语义。
pub fn parse_articles_by_rule(source: &RssSource, html: &str, sort: &str) -> Vec<RssArticle> {
    let articles_rule = match source.rule_articles.as_deref() {
        Some(r) if !r.trim().is_empty() => r,
        _ => return Vec::new(),
    };
    let context = RuleContext::new(&source.source_url, html);

    // 1. 切分文章块：list_context_rule 等价方式 — 走默认 selector +
    //    @html 输出。如果规则尾巴已经带了 @html / @all，原样跑；否则
    //    自动追加 @html。
    let list_rule = list_context_rule(articles_rule);
    let blocks = match execute_legado_rule(&list_rule, html, &context) {
        Ok(items) if !items.is_empty() => items,
        _ => return Vec::new(),
    };

    let mut articles = Vec::with_capacity(blocks.len());
    let next_page = source
        .rule_next_page
        .as_deref()
        .and_then(|r| {
            let r = r.trim();
            if r.is_empty() {
                None
            } else {
                execute_first(r, html, &context)
            }
        });

    for (i, block) in blocks.iter().enumerate() {
        let block_ctx = RuleContext::new(&source.source_url, block);
        let title = source
            .rule_title
            .as_deref()
            .and_then(|r| execute_first(r, block, &block_ctx))
            .unwrap_or_default();
        let link = source
            .rule_link
            .as_deref()
            .and_then(|r| execute_first(r, block, &block_ctx))
            .unwrap_or_default();
        let pub_date = source
            .rule_pub_date
            .as_deref()
            .and_then(|r| execute_first(r, block, &block_ctx))
            .unwrap_or_default();
        let description = source
            .rule_description
            .as_deref()
            .and_then(|r| execute_first(r, block, &block_ctx));
        let image = source
            .rule_image
            .as_deref()
            .and_then(|r| execute_first(r, block, &block_ctx));

        // MVP：把 next_page 落到第一个 article 的 variable，方便批次 18
        // 走翻页时取出来；没有 next_page 就 None。
        let variable = if i == 0 {
            next_page.clone().filter(|s| !s.is_empty())
        } else {
            None
        };

        if title.is_empty() && link.is_empty() {
            continue;
        }

        articles.push(RssArticle {
            origin: source.source_url.clone(),
            sort: sort.to_string(),
            title,
            pub_date,
            link,
            image,
            description,
            variable,
            order_num: articles.len() as i32,
            read_time: 0,
            star: 0,
        });
    }
    articles
}

fn execute_first(rule: &str, html: &str, ctx: &RuleContext) -> Option<String> {
    execute_legado_rule(rule, html, ctx)
        .ok()
        .and_then(|v| v.into_iter().find(|s| !s.trim().is_empty()))
}

/// 仿照 parser.rs 同名 helper —— 默认尾巴补 `@html` 让选择器返回每条
/// 文章块的 outer HTML（而非 textContent），后续才能继续抽子字段。
fn list_context_rule(rule: &str) -> String {
    let trimmed = rule.trim();
    if trimmed.is_empty()
        || trimmed.starts_with("@js:")
        || trimmed.starts_with("js:")
        || trimmed.starts_with("$.")
        || trimmed.starts_with("$[")
        || trimmed.contains("@html")
        || trimmed.contains("@all")
        || trimmed.contains("@text")
        || trimmed.contains("@href")
        || trimmed.contains("@src")
        || trimmed.contains("@content")
    {
        return trimmed.to_string();
    }
    format!("{trimmed}@html")
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;

    fn make_source(
        rule_articles: Option<&str>,
        rule_title: Option<&str>,
        rule_link: Option<&str>,
        rule_pub_date: Option<&str>,
        rule_description: Option<&str>,
        rule_image: Option<&str>,
    ) -> RssSource {
        RssSource {
            source_url: "https://feed/x".into(),
            source_name: "X".into(),
            source_icon: None,
            source_group: None,
            source_comment: None,
            enabled: true,
            single_url: true,
            sort_url: None,
            article_style: 0,
            rule_articles: rule_articles.map(|s| s.to_string()),
            rule_next_page: None,
            rule_title: rule_title.map(|s| s.to_string()),
            rule_pub_date: rule_pub_date.map(|s| s.to_string()),
            rule_description: rule_description.map(|s| s.to_string()),
            rule_image: rule_image.map(|s| s.to_string()),
            rule_link: rule_link.map(|s| s.to_string()),
            rule_content: None,
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

    #[test]
    fn test_full_rules_extract() {
        let html = r#"
<html><body>
<div class="article">
  <a class="link" href="/p/1">Article One</a>
  <span class="date">2024-01-01</span>
  <p class="summary">Summary 1</p>
  <img class="thumb" src="/img/1.jpg" />
</div>
<div class="article">
  <a class="link" href="/p/2">Article Two</a>
  <span class="date">2024-01-02</span>
  <p class="summary">Summary 2</p>
  <img class="thumb" src="/img/2.jpg" />
</div>
</body></html>
"#;
        let source = make_source(
            Some("div.article"),
            Some("a.link@text"),
            Some("a.link@href"),
            Some("span.date@text"),
            Some("p.summary@text"),
            Some("img.thumb@src"),
        );
        let articles = parse_articles_by_rule(&source, html, "tech");
        assert_eq!(articles.len(), 2);
        assert_eq!(articles[0].title, "Article One");
        assert_eq!(articles[0].link, "/p/1");
        assert_eq!(articles[0].pub_date, "2024-01-01");
        assert_eq!(articles[0].description.as_deref(), Some("Summary 1"));
        assert_eq!(articles[0].image.as_deref(), Some("/img/1.jpg"));
        assert_eq!(articles[0].sort, "tech");
        assert_eq!(articles[0].order_num, 0);
        assert_eq!(articles[1].title, "Article Two");
        assert_eq!(articles[1].order_num, 1);
    }

    #[test]
    fn test_missing_rule_articles_returns_empty() {
        let source = make_source(None, Some("a@text"), Some("a@href"), None, None, None);
        let articles = parse_articles_by_rule(&source, "<html><a>x</a></html>", "");
        assert!(articles.is_empty());

        let source2 = make_source(Some(""), None, None, None, None, None);
        let articles2 = parse_articles_by_rule(&source2, "<html></html>", "");
        assert!(articles2.is_empty());
    }
}
