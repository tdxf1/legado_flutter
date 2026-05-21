//! # RSS XML 解析（quick-xml）
//!
//! 解析标准 RSS 2.0（`<rss>/<channel>/<item>`）+ Atom 1.0（`<feed>/<entry>`）
//! 两种 feed 格式。流式状态机基于 [`quick_xml::Reader::read_event_into`]，
//! 部分解析失败不 panic — 已经从前面 item 抓到的字段照样返回，让调用方
//! 决定是否再走规则路降级。
//!
//! ## 字段映射
//!
//! ### RSS 2.0
//!
//! `<item>` 子元素 → [`RssArticle`]：
//! - `<title>` → title
//! - `<link>` → link（取首个非空）
//! - `<description>` → description
//! - `<pubDate>` → pub_date（保留原 String，不解析时间戳）
//! - `<enclosure url="..."/>` 或 `<media:thumbnail url="..."/>` → image
//!
//! ### Atom
//!
//! `<entry>` 子元素 → [`RssArticle`]：
//! - `<title>` → title
//! - `<link href="..."/>` → link（取 rel="alternate" 或第一个）
//! - `<summary>` 或 `<content>` → description
//! - `<published>` 或 `<updated>` → pub_date
//! - `<media:thumbnail url="..."/>` → image
//!
//! `read_time / star = 0`，`order_num` 用 enumerate index，`variable = None`。

use core_storage::RssArticle;
use quick_xml::events::Event;
use quick_xml::Reader;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RssFormat {
    Rss20,
    Atom,
    Unknown,
}

/// 取首个非注释的根标签判断格式。`<rss` 前缀（含可能的 version 属性）→
/// Rss20；`<feed` 前缀 → Atom；其它 → Unknown。
pub fn detect_format(xml: &str) -> RssFormat {
    let trimmed = skip_xml_prologue(xml);
    if trimmed.starts_with("<rss") {
        RssFormat::Rss20
    } else if trimmed.starts_with("<feed") {
        RssFormat::Atom
    } else {
        RssFormat::Unknown
    }
}

/// 跳过 BOM / XML 声明 / 空白 / 注释，返回首个真正的 element 起点。
///
/// `pub(crate)` 暴露给 `rss::mod`：`detect_format` 之外的入口（如
/// `RssParser::get_articles` 的"先 XML 后规则"分支判定）也需要剥掉
/// `<?xml ?>` 头才能正确判定，避免出现两套 BOM/prologue 剥离逻辑漂移。
/// 见 master findings F-W1B-039。
pub(crate) fn skip_xml_prologue(xml: &str) -> &str {
    let mut s = xml.trim_start_matches('\u{FEFF}').trim_start();
    loop {
        if let Some(rest) = s.strip_prefix("<?") {
            // XML 声明 / processing instruction，找到 `?>` 跳过
            if let Some(end) = rest.find("?>") {
                s = rest[end + 2..].trim_start();
                continue;
            }
            break;
        }
        if let Some(rest) = s.strip_prefix("<!--") {
            if let Some(end) = rest.find("-->") {
                s = rest[end + 3..].trim_start();
                continue;
            }
            break;
        }
        break;
    }
    s
}

/// 解析 RSS 2.0。
pub fn parse_rss20(xml: &str, origin: &str, sort: &str) -> Vec<RssArticle> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);
    let mut buf = Vec::new();
    let mut articles: Vec<RssArticle> = Vec::new();
    let mut current: Option<RssArticle> = None;
    // path 状态机：仅认 `<item>` 内层。
    let mut current_tag: Option<String> = None;

    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(e)) => {
                let name = e.name().as_ref().to_vec();
                let name_str = String::from_utf8_lossy(&name).to_string();
                let local = local_name(&name_str);
                if local == "item" {
                    current = Some(empty_article(origin, sort, articles.len() as i32));
                } else if current.is_some() {
                    // enclosure / media:thumbnail 可能是 self-closing，
                    // 但 image 也可能由 Start+End 包出来 — 取属性优先。
                    if local == "enclosure" || local == "thumbnail" {
                        if let Some(url) = first_attr_value(e.attributes(), b"url") {
                            if let Some(a) = current.as_mut() {
                                if a.image.is_none() {
                                    a.image = Some(url);
                                }
                            }
                        }
                    }
                    current_tag = Some(local.to_string());
                }
            }
            Ok(Event::Empty(e)) => {
                let name = e.name().as_ref().to_vec();
                let name_str = String::from_utf8_lossy(&name).to_string();
                let local = local_name(&name_str);
                if current.is_some() && (local == "enclosure" || local == "thumbnail") {
                    if let Some(url) = first_attr_value(e.attributes(), b"url") {
                        if let Some(a) = current.as_mut() {
                            if a.image.is_none() {
                                a.image = Some(url);
                            }
                        }
                    }
                }
            }
            Ok(Event::Text(e)) => {
                if let (Some(article), Some(tag)) = (current.as_mut(), current_tag.as_deref()) {
                    let text = e.unescape().map(|c| c.into_owned()).unwrap_or_default();
                    apply_rss20_text_field(article, tag, &text);
                }
            }
            Ok(Event::CData(e)) => {
                if let (Some(article), Some(tag)) = (current.as_mut(), current_tag.as_deref()) {
                    let text = String::from_utf8_lossy(&e).to_string();
                    apply_rss20_text_field(article, tag, &text);
                }
            }
            Ok(Event::End(e)) => {
                let name = e.name().as_ref().to_vec();
                let name_str = String::from_utf8_lossy(&name).to_string();
                let local = local_name(&name_str);
                if local == "item" {
                    if let Some(a) = current.take() {
                        if !a.link.is_empty() || !a.title.is_empty() {
                            articles.push(a);
                        }
                    }
                    current_tag = None;
                } else if current_tag.as_deref() == Some(local) {
                    current_tag = None;
                }
            }
            Ok(Event::Eof) => break,
            // 残缺 XML：不 panic，已抓到的 item 照常返回。
            Err(_) => break,
            _ => {}
        }
        buf.clear();
    }
    articles
}

fn apply_rss20_text_field(article: &mut RssArticle, tag: &str, text: &str) {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return;
    }
    match tag {
        "title" => {
            if article.title.is_empty() {
                article.title = trimmed.to_string();
            }
        }
        "link" => {
            if article.link.is_empty() {
                article.link = trimmed.to_string();
            }
        }
        "description" => {
            if article.description.is_none() {
                article.description = Some(trimmed.to_string());
            }
        }
        "pubDate" => {
            if article.pub_date.is_empty() {
                article.pub_date = trimmed.to_string();
            }
        }
        _ => {}
    }
}

/// 解析 Atom 1.0。
pub fn parse_atom(xml: &str, origin: &str, sort: &str) -> Vec<RssArticle> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);
    let mut buf = Vec::new();
    let mut articles: Vec<RssArticle> = Vec::new();
    let mut current: Option<RssArticle> = None;
    let mut current_tag: Option<String> = None;

    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(e)) => {
                let name = e.name().as_ref().to_vec();
                let name_str = String::from_utf8_lossy(&name).to_string();
                let local = local_name(&name_str);
                if local == "entry" {
                    current = Some(empty_article(origin, sort, articles.len() as i32));
                } else if current.is_some() {
                    if local == "link" {
                        let rel = first_attr_value(e.attributes(), b"rel");
                        let href = first_attr_value(e.attributes(), b"href");
                        if let Some(a) = current.as_mut() {
                            if a.link.is_empty() {
                                if let Some(href) = href {
                                    if rel.as_deref().map_or(true, |r| r == "alternate") {
                                        a.link = href;
                                    }
                                }
                            }
                        }
                    } else if local == "thumbnail" {
                        if let Some(url) = first_attr_value(e.attributes(), b"url") {
                            if let Some(a) = current.as_mut() {
                                if a.image.is_none() {
                                    a.image = Some(url);
                                }
                            }
                        }
                    }
                    current_tag = Some(local.to_string());
                }
            }
            Ok(Event::Empty(e)) => {
                // Atom 的 `<link>` 通常是 self-closing，走这里。
                let name = e.name().as_ref().to_vec();
                let name_str = String::from_utf8_lossy(&name).to_string();
                let local = local_name(&name_str);
                if current.is_some() && local == "link" {
                    let rel = first_attr_value(e.attributes(), b"rel");
                    let href = first_attr_value(e.attributes(), b"href");
                    if let Some(a) = current.as_mut() {
                        if a.link.is_empty() {
                            if let Some(href) = href {
                                if rel.as_deref().map_or(true, |r| r == "alternate") {
                                    a.link = href;
                                }
                            }
                        }
                    }
                } else if current.is_some() && local == "thumbnail" {
                    if let Some(url) = first_attr_value(e.attributes(), b"url") {
                        if let Some(a) = current.as_mut() {
                            if a.image.is_none() {
                                a.image = Some(url);
                            }
                        }
                    }
                }
            }
            Ok(Event::Text(e)) => {
                if let (Some(article), Some(tag)) = (current.as_mut(), current_tag.as_deref()) {
                    let text = e.unescape().map(|c| c.into_owned()).unwrap_or_default();
                    apply_atom_text_field(article, tag, &text);
                }
            }
            Ok(Event::CData(e)) => {
                if let (Some(article), Some(tag)) = (current.as_mut(), current_tag.as_deref()) {
                    let text = String::from_utf8_lossy(&e).to_string();
                    apply_atom_text_field(article, tag, &text);
                }
            }
            Ok(Event::End(e)) => {
                let name = e.name().as_ref().to_vec();
                let name_str = String::from_utf8_lossy(&name).to_string();
                let local = local_name(&name_str);
                if local == "entry" {
                    if let Some(a) = current.take() {
                        if !a.link.is_empty() || !a.title.is_empty() {
                            articles.push(a);
                        }
                    }
                    current_tag = None;
                } else if current_tag.as_deref() == Some(local) {
                    current_tag = None;
                }
            }
            Ok(Event::Eof) => break,
            Err(_) => break,
            _ => {}
        }
        buf.clear();
    }
    articles
}

fn apply_atom_text_field(article: &mut RssArticle, tag: &str, text: &str) {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return;
    }
    match tag {
        "title" => {
            if article.title.is_empty() {
                article.title = trimmed.to_string();
            }
        }
        "summary" | "content" => {
            if article.description.is_none() {
                article.description = Some(trimmed.to_string());
            }
        }
        "published" => {
            // published 优先级最高
            article.pub_date = trimmed.to_string();
        }
        "updated" => {
            // updated 仅在 published 缺失时填充
            if article.pub_date.is_empty() {
                article.pub_date = trimmed.to_string();
            }
        }
        _ => {}
    }
}

fn empty_article(origin: &str, sort: &str, order_num: i32) -> RssArticle {
    RssArticle {
        origin: origin.to_string(),
        sort: sort.to_string(),
        title: String::new(),
        pub_date: String::new(),
        link: String::new(),
        image: None,
        description: None,
        variable: None,
        order_num,
        read_time: 0,
        star: 0,
    }
}

/// 把 `prefix:local` 形式的标签名取末段（NS 前缀通常无关紧要）。
fn local_name(name: &str) -> &str {
    if let Some(idx) = name.rfind(':') {
        &name[idx + 1..]
    } else {
        name
    }
}

fn first_attr_value(
    attrs: quick_xml::events::attributes::Attributes,
    target: &[u8],
) -> Option<String> {
    for attr in attrs.flatten() {
        if attr.key.as_ref() == target {
            let value = attr
                .unescape_value()
                .map(|c| c.into_owned())
                .unwrap_or_default();
            return Some(value);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_format_detection() {
        assert_eq!(
            detect_format("<?xml version=\"1.0\"?>\n<rss version=\"2.0\"><channel></channel></rss>"),
            RssFormat::Rss20
        );
        assert_eq!(
            detect_format("\u{FEFF}<feed xmlns=\"http://www.w3.org/2005/Atom\"></feed>"),
            RssFormat::Atom
        );
        assert_eq!(
            detect_format("<html><body>oops</body></html>"),
            RssFormat::Unknown
        );
        assert_eq!(detect_format(""), RssFormat::Unknown);
        // 注释 + 空白
        assert_eq!(
            detect_format("<!-- comment -->\n<rss><channel></channel></rss>"),
            RssFormat::Rss20
        );
    }

    #[test]
    fn test_rss20_standard() {
        let xml = r#"<?xml version="1.0"?>
<rss version="2.0">
<channel>
<title>Example Feed</title>
<item>
<title>Article One</title>
<link>https://example.com/a</link>
<description>desc one</description>
<pubDate>Mon, 01 Jan 2024 12:00:00 +0000</pubDate>
<enclosure url="https://example.com/a.jpg" type="image/jpeg"/>
</item>
<item>
<title>Article Two</title>
<link>https://example.com/b</link>
<description><![CDATA[Some <b>HTML</b> body]]></description>
<pubDate>Tue, 02 Jan 2024 12:00:00 +0000</pubDate>
</item>
<item>
<title>Article Three</title>
<link>https://example.com/c</link>
</item>
</channel>
</rss>"#;
        let articles = parse_rss20(xml, "https://feed.example", "tech");
        assert_eq!(articles.len(), 3);

        assert_eq!(articles[0].title, "Article One");
        assert_eq!(articles[0].link, "https://example.com/a");
        assert_eq!(articles[0].description.as_deref(), Some("desc one"));
        assert_eq!(
            articles[0].pub_date,
            "Mon, 01 Jan 2024 12:00:00 +0000"
        );
        assert_eq!(
            articles[0].image.as_deref(),
            Some("https://example.com/a.jpg")
        );
        assert_eq!(articles[0].order_num, 0);
        assert_eq!(articles[0].read_time, 0);
        assert_eq!(articles[0].star, 0);
        assert_eq!(articles[0].origin, "https://feed.example");
        assert_eq!(articles[0].sort, "tech");

        assert_eq!(articles[1].title, "Article Two");
        assert_eq!(
            articles[1].description.as_deref(),
            Some("Some <b>HTML</b> body"),
            "CDATA 应原样保留"
        );

        // 缺字段不崩
        assert_eq!(articles[2].title, "Article Three");
        assert_eq!(articles[2].description, None);
        assert!(articles[2].pub_date.is_empty());
    }

    #[test]
    fn test_atom_standard() {
        let xml = r#"<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:media="http://search.yahoo.com/mrss/">
<title>Atom Feed</title>
<entry>
<title>Atom Article 1</title>
<link rel="alternate" href="https://example.com/atom1"/>
<summary>Summary 1</summary>
<published>2024-01-01T12:00:00Z</published>
</entry>
<entry>
<title>Atom Article 2</title>
<link href="https://example.com/atom2"/>
<content>Content 2</content>
<updated>2024-01-02T12:00:00Z</updated>
<media:thumbnail url="https://example.com/atom2.jpg"/>
</entry>
</feed>"#;
        let articles = parse_atom(xml, "https://feed.example", "");
        assert_eq!(articles.len(), 2);

        assert_eq!(articles[0].title, "Atom Article 1");
        assert_eq!(articles[0].link, "https://example.com/atom1");
        assert_eq!(articles[0].description.as_deref(), Some("Summary 1"));
        assert_eq!(articles[0].pub_date, "2024-01-01T12:00:00Z");

        assert_eq!(articles[1].title, "Atom Article 2");
        assert_eq!(articles[1].link, "https://example.com/atom2");
        assert_eq!(articles[1].description.as_deref(), Some("Content 2"));
        assert_eq!(articles[1].pub_date, "2024-01-02T12:00:00Z");
        assert_eq!(
            articles[1].image.as_deref(),
            Some("https://example.com/atom2.jpg")
        );
    }

    #[test]
    fn test_malformed_xml_no_panic() {
        // 残缺 XML：未关闭的 item / 截断
        let xml = r#"<rss><channel><item><title>Ok</title><link>https://example.com/ok</link></item><item><title>Broken"#;
        let articles = parse_rss20(xml, "o", "");
        // 第一条应该完整解析出来；第二条不完整可能丢
        assert!(!articles.is_empty());
        assert_eq!(articles[0].title, "Ok");

        // 完全乱码 — 不 panic 即可
        let xml2 = "<<<<not xml at all >>>>";
        let _ = parse_rss20(xml2, "o", "");
        let _ = parse_atom(xml2, "o", "");
    }
}
