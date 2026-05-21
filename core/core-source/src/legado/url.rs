//! Legado URL 模板与选项解析
//!
//! 支持 Legado 的 URL 格式：
//! - 基础 URL：/search?q={{key}}
//! - 带选项 URL：/search?q={{key}}, {"method": "POST", "body": "...", "charset": "gbk"}
//! - GET/POST 请求
//! - charset 指定
//! - webView 标记
//! - 模板变量：{{key}}, {{keyword}}, {{page}}, {{encodeKey}}, {{encode_keyword}}
//! - JS 表达式：{{java.base64Encode(key)}}
//! - 相对 URL 处理和完整 URL 构建
//! - <,{{page}}> 语法：第一页无页码

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

use super::js_runtime::{DefaultJsRuntime, JsRuntime};
use super::value::LegadoValue;

/// Legado 解析后的 URL 结构
#[derive(Debug, Clone)]
pub struct LegadoUrl {
    /// URL 路径部分
    pub path: String,
    /// URL 选项
    pub options: UrlOption,
    /// 是否为相对 URL
    pub is_relative: bool,
}

/// Legado URL 选项
///
/// 对应 Legado 的 UrlOption data class：
/// ```kotlin
/// data class UrlOption(
///     val method: String?,
///     val charset: String?,
///     val webView: Any?,
///     val headers: Any?,
///     val body: Any?,
///     val type: String?,
///     val js: String?,
///     val retry: Int = 0
/// )
/// ```
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct UrlOption {
    /// HTTP 方法（GET/POST）
    #[serde(default)]
    pub method: Option<String>,
    /// 字符集（utf-8/gbk/gb2312/gb18030）
    #[serde(default)]
    pub charset: Option<String>,
    /// 是否使用 WebView 加载
    #[serde(default)]
    pub web_view: bool,
    /// 请求头（JSON 字符串或 Map）
    #[serde(default)]
    pub headers: Option<serde_json::Value>,
    /// POST 请求体
    #[serde(default)]
    pub body: Option<String>,
    /// JS 脚本（加载 URL 前执行）
    #[serde(default)]
    pub js: Option<String>,
    /// 重试次数
    #[serde(default)]
    pub retry: i32,
    /// 内容类型
    #[serde(rename = "type", default)]
    pub content_type: Option<String>,
}

/// 解析 Legado URL 字符串
///
/// 输入格式：`/search?q={{key}}` 或 `/search?q={{key}}, {"method": "POST", "charset": "gbk"}`
///
/// 使用从右到左扫描找到末尾的有效 JSON 选项块，避免 URL 中逗号导致的误分割。
pub fn parse_legado_url(url_str: &str) -> LegadoUrl {
    let trimmed = url_str.trim();
    let (path, options_json) = extract_json_option(trimmed);

    let options = options_json
        .and_then(|j| serde_json::from_str::<UrlOption>(&j).ok())
        .unwrap_or_default();

    let is_relative = !path.starts_with("http://") && !path.starts_with("https://");

    LegadoUrl {
        path: path.to_string(),
        options,
        is_relative,
    }
}

/// 从右向左扫描字符串，找到末尾有效 JSON `{...}` 块作为选项。
///
/// 从最右边的 `{` 开始尝试，找到匹配的 `}` 后尝试 JSON 解析。
/// 如果该块不在字符串末尾（忽略空白），则尝试前一个 `{`。
/// 如果没有任何有效 JSON 块在末尾，整个字符串作为 URL 路径。
fn extract_json_option(s: &str) -> (&str, Option<String>) {
    let bytes = s.as_bytes();
    let mut brace_positions: Vec<usize> = Vec::new();

    for (i, &b) in bytes.iter().enumerate() {
        if b == b'{' {
            brace_positions.push(i);
        }
    }

    for &start in brace_positions.iter().rev() {
        let mut depth: i32 = 0;
        let mut end: Option<usize> = None;

        for (j, &b) in bytes[start..].iter().enumerate() {
            match b {
                b'{' => depth += 1,
                b'}' => {
                    depth -= 1;
                    if depth == 0 {
                        end = Some(start + j + 1);
                        break;
                    }
                }
                _ => {}
            }
        }

        if let Some(end_pos) = end {
            let candidate = std::str::from_utf8(&bytes[start..end_pos]).unwrap_or("");
            if serde_json::from_str::<serde_json::Value>(candidate).is_ok() {
                let after_json = s[end_pos..].trim();
                if after_json.is_empty() {
                    let prefix = s[..start].trim().trim_end_matches(',').trim();
                    return (prefix, Some(candidate.to_string()));
                }
            }
        }
    }

    (s, None)
}

/// 解析 URL 模板，替换占位符
///
/// 支持的占位符：
/// - `{{key}}` / `{{keyword}}` → 搜索关键词
/// - `{{encodeKey}}` / `{{encode_keyword}}` → URL 编码后的关键词
/// - `{{page}}` → 页码
/// - `{{(page-1)*20}}` → 页面计算表达式
/// - `<,{{page}}>` → 第一页忽略页码
///
/// 返回最终的 URL 路径和 option（如果有 POST body 中的占位符也应在此替换）
pub fn resolve_url_template(
    legado_url: &LegadoUrl,
    keyword: &str,
    page: i32,
    base_url: &str,
) -> String {
    let mut path = legado_url.path.clone();

    // 处理 <,{{page}}> 语法：第一页去除前面的部分
    path = resolve_conditional_page(&path, page);
    path = resolve_template_expressions(&path, keyword, page);

    // 处理 <,xxx> 语法中剩余的占位符
    path = resolve_conditional_placeholder(&path, page);

    // 如果是相对 URL，拼接 base_url
    if legado_url.is_relative {
        build_full_url(base_url, &path)
    } else {
        path
    }
}

/// 构建 POST body，替换其中的占位符
pub fn resolve_post_body(body: &str, keyword: &str, page: i32) -> String {
    resolve_template_expressions(body, keyword, page)
}

static TEMPLATE_RE: std::sync::LazyLock<regex::Regex> =
    std::sync::LazyLock::new(|| regex::Regex::new(r"\{\{([\s\S]*?)\}\}").unwrap());

/// Whitelisted template variable names that take a fast-path direct
/// `vars` lookup, bypassing the JS evaluator entirely.
///
/// F-W1B-008 (BATCH-10): keeping this list explicit (rather than only
/// implicit in [`build_template_vars`]) makes the safe-by-construction
/// path obvious to auditors. Names listed here cannot trigger JS
/// evaluation, so URL/body templates that only use these vars carry
/// zero JS-injection surface.
const TEMPLATE_VAR_WHITELIST: &[&str] = &[
    "key",
    "keyword",
    "page",
    "encodeKey",
    "encode_keyword",
];

/// Resolve `{{...}}` template expressions in URL paths or POST bodies.
///
/// Two paths:
/// 1. **Whitelist fast-path**: when the trimmed expression is one of
///    [`TEMPLATE_VAR_WHITELIST`], read directly from the `vars` map. No
///    JS engine spin-up, no injection surface.
/// 2. **JS eval fallback**: anything else (e.g. `(page-1)*20`,
///    `java.base64Encode(key)`, ternaries) goes through `runtime.eval`.
///    These templates are author-controlled in the book-source JSON,
///    which is itself trusted at the source-import audit step (the user
///    chooses which sources to install). The JS sandbox boundary
///    (BATCH-04) still applies inside the eval.
fn resolve_template_expressions(input: &str, keyword: &str, page: i32) -> String {
    let vars = build_template_vars(keyword, page);
    let runtime = DefaultJsRuntime::new();
    let mut result = String::with_capacity(input.len());
    let mut last = 0;

    for caps in TEMPLATE_RE.captures_iter(input) {
        let Some(full_match) = caps.get(0) else {
            continue;
        };
        result.push_str(&input[last..full_match.start()]);
        let expr = caps.get(1).map(|m| m.as_str()).unwrap_or_default().trim();
        let replacement = if TEMPLATE_VAR_WHITELIST.contains(&expr) {
            // Whitelist fast-path: direct vars lookup, never touches JS.
            vars.get(expr)
                .map(|value| value.as_string_lossy())
                .unwrap_or_default()
        } else {
            // Fallback: still consult `vars` first in case future builds
            // extend the var map with non-whitelisted aliases, then fall
            // through to JS eval for legitimate expressions like
            // `(page-1)*20`.
            vars.get(expr)
                .map(|value| value.as_string_lossy())
                .or_else(|| {
                    runtime
                        .eval(expr, &vars)
                        .ok()
                        .map(|value| value.as_string_lossy())
                })
                .unwrap_or_default()
        };
        result.push_str(&replacement);
        last = full_match.end();
    }

    result.push_str(&input[last..]);
    result
}

fn build_template_vars(keyword: &str, page: i32) -> HashMap<String, LegadoValue> {
    let mut vars = HashMap::new();
    vars.insert("key".into(), LegadoValue::String(keyword.to_string()));
    vars.insert("keyword".into(), LegadoValue::String(keyword.to_string()));
    vars.insert("page".into(), LegadoValue::Int(page as i64));
    vars.insert(
        "encodeKey".into(),
        LegadoValue::String(urlencoding::encode(keyword).to_string()),
    );
    vars.insert(
        "encode_keyword".into(),
        LegadoValue::String(urlencoding::encode(keyword).to_string()),
    );
    vars
}

/// 处理 `<,{{page}}>` 语法
///
/// 语法 `prefix,{{page}}`:
/// - 如果 page == 1，去除 `prefix,` 部分，返回空字符串
/// - 如果 page > 1，保留 `,{{page}}`，去除 `<` 和 `>`
///
/// **契约**：仅识别 URL 中第一处 `<...>` 段（用 `find('<')` + `find('>')`
/// 单次扫描）。多段 `<...>` 同时出现时，第二段及之后保留原样不展开。这
/// 是对 Legado 原版语法的保守复刻——`sy/*.json` 真实书源未见多段用法，
/// 不扩展支持以避免引入歧义（master findings F-W1B-036）。
fn resolve_conditional_page(url: &str, page: i32) -> String {
    if let Some(start) = url.find('<') {
        if let Some(end) = url[start..].find('>') {
            let inner = &url[start + 1..start + end];
            if let Some((prefix, rest)) = inner.split_once(',') {
                let _prefix = prefix.trim();
                let rest = rest.trim();
                if page == 1 {
                    // 第一页：去除 prefix
                    format!("{}{}", &url[..start], &url[start + end + 1..])
                } else {
                    // 非第一页：保留 rest 部分（去掉 < >）
                    let replaced = format!("{}{}{}", &url[..start], rest, &url[start + end + 1..]);
                    replaced
                }
            } else {
                url.to_string()
            }
        } else {
            url.to_string()
        }
    } else {
        url.to_string()
    }
}

/// 处理 `<,xxx>` 中非页码部分
fn resolve_conditional_placeholder(url: &str, _page: i32) -> String {
    // 清理由 `<,{{page}}>` 处理后的残余占位符
    url.trim_start_matches('<')
        .trim_end_matches('>')
        .to_string()
}

/// 构建完整 URL（处理相对路径）
pub fn build_full_url(base_url: &str, relative_url: &str) -> String {
    if let Ok(base) = url::Url::parse(base_url) {
        if let Ok(full) = base.join(relative_url) {
            return full.to_string();
        }
    }
    // fallback: 直接拼接
    let base = base_url.trim_end_matches('/');
    let relative = relative_url.trim_start_matches('/');
    format!("{}/{}", base, relative)
}

/// 从 URL option 中获取 charset
pub fn get_charset_from_option(option: &UrlOption) -> Option<&str> {
    option.charset.as_deref()
}

/// 从响应头中推测 charset
pub fn guess_charset_from_response(headers: &HashMap<String, String>, body_bytes: &[u8]) -> String {
    // 1. 检查 Content-Type header
    if let Some(content_type) = headers.get("content-type") {
        if let Some(charset) = content_type
            .split(';')
            .find(|s| s.trim().to_lowercase().starts_with("charset"))
        {
            let charset = charset
                .split('=')
                .nth(1)
                .map(|s| s.trim())
                .unwrap_or("utf-8");
            return match charset.to_lowercase().as_str() {
                "gbk" | "gb2312" | "gb18030" => charset.to_string(),
                _ => "utf-8".to_string(),
            };
        }
    }

    // 2. 检查 HTML meta charset
    let html = String::from_utf8_lossy(&body_bytes[..body_bytes.len().min(1024)]);
    let html_lower = html.to_lowercase();
    if let Some(pos) = html_lower.find("charset=") {
        let rest = &html_lower[pos + 8..];
        let charset = rest
            .split(|c: char| !c.is_alphanumeric() && c != '-')
            .next()
            .unwrap_or("utf-8");
        return match charset {
            "gbk" | "gb2312" | "gb18030" => charset.to_string(),
            _ => "utf-8".to_string(),
        };
    }

    "utf-8".to_string()
}

pub(crate) fn decode_response_bytes(bytes: &[u8], charset: &str) -> (String, bool) {
    let encoding = match charset.to_lowercase().as_str() {
        "gbk" | "gb2312" | "gb18030" => {
            encoding_rs::Encoding::for_label(b"gbk").unwrap_or(encoding_rs::UTF_8)
        }
        "big5" => encoding_rs::Encoding::for_label(b"big5").unwrap_or(encoding_rs::UTF_8),
        "shift_jis" | "shift-jis" => {
            encoding_rs::Encoding::for_label(b"shift_jis").unwrap_or(encoding_rs::UTF_8)
        }
        "euc-kr" => encoding_rs::Encoding::for_label(b"euc-kr").unwrap_or(encoding_rs::UTF_8),
        _ => encoding_rs::UTF_8,
    };
    let (decoded, _, had_errors) = encoding.decode(bytes);
    (decoded.into_owned(), had_errors)
}

/// 解析请求头，从 JSON 字符串或 Map 中提取
pub fn parse_headers(headers_value: &Option<serde_json::Value>) -> Vec<(String, String)> {
    let Some(headers) = headers_value else {
        return Vec::new();
    };

    match headers {
        serde_json::Value::Object(map) => map
            .iter()
            .filter_map(|(k, v)| {
                // 跳过 Legado 特有的 proxy 头
                if k == "proxy" {
                    return None;
                }
                v.as_str()
                    .map(|s| (k.clone(), s.to_string()))
                    .or_else(|| Some((k.clone(), v.to_string())))
            })
            .collect(),
        serde_json::Value::String(s) => {
            // 尝试解析为 JSON
            if let Ok(map) = serde_json::from_str::<HashMap<String, String>>(s) {
                map.into_iter().collect()
            } else {
                Vec::new()
            }
        }
        _ => Vec::new(),
    }
}

/// Parse proxy string from Legado headers JSON.
///
/// Supports formats:
/// - `socks5://host:port`
/// - `http://host:port`
/// - `socks5://host:port@username@password`
pub fn parse_proxy(headers: &Option<serde_json::Value>) -> Option<String> {
    let headers = headers.as_ref()?;
    match headers {
        serde_json::Value::Object(map) => map.get("proxy")?.as_str().map(|s| s.to_string()),
        serde_json::Value::String(s) => {
            let map: HashMap<String, String> = serde_json::from_str(s).ok()?;
            map.get("proxy").cloned()
        }
        _ => None,
    }
}

/// Resolve non-search {{rule}} templates in a string value.
///
/// In Legado, non-search URLs and field values can contain `{{...}}` blocks
/// that mix rule expressions (CSS, XPath, JSONPath, Default, JS) with literal
/// text. Unlike search URL templates where `{{}}` is always JavaScript, this
/// function detects the rule type inside each block and executes accordingly.
///
/// Rule detection inside `{{...}}`:
/// - `@@tag.a@href` → Default selector rule (strips `@@` prefix)
/// - `@css:a@href`   → CSS selector rule
/// - `@json:$.id`    → JSONPath rule
/// - `@xpath://a`    → XPath rule
/// - `@js:expr`      → JavaScript rule
/// - `js:expr`       → JavaScript (explicit)
/// - `//a/@href`     → XPath (pattern)
/// - `$.id`, `$[0]`  → JSONPath (pattern)
/// - anything else   → JavaScript expression (with rule context vars)
///
/// If input does not contain `{{`, returns the original string unchanged.
pub fn resolve_rule_template(
    input: &str,
    html: &str,
    context: &super::context::RuleContext,
) -> String {
    if !input.contains("{{") {
        return input.to_string();
    }

    let mut result = String::with_capacity(input.len());
    let mut last = 0;

    for caps in TEMPLATE_RE.captures_iter(input) {
        let Some(full_match) = caps.get(0) else {
            continue;
        };
        result.push_str(&input[last..full_match.start()]);

        let inner = caps.get(1).map(|m| m.as_str()).unwrap_or_default().trim();
        let replacement = if inner.is_empty() {
            String::new()
        } else {
            resolve_single_template_rule(inner, html, context)
        };
        result.push_str(&replacement);
        last = full_match.end();
    }

    result.push_str(&input[last..]);

    // Also resolve single-brace JSONPath shorthand: {$.key} or {$[0].key}
    resolve_single_brace_jsonpath(&result, html)
}

/// Regex for single-brace JSONPath: `{$...}`. The "not `{{...}}`" gate is
/// applied manually below since Rust's `regex` crate does not support
/// look-around. We accept any `\{$...\}` and discard matches whose immediate
/// neighbours are `{` / `}` (i.e. part of a `{{ ... }}` template).
static SINGLE_BRACE_JSONPATH_RE: std::sync::LazyLock<regex::Regex> =
    std::sync::LazyLock::new(|| {
        regex::Regex::new(r"\{(\$[\.\[][^}]*)\}").unwrap()
    });

/// Resolve `{$.key}` single-brace JSONPath shorthand against JSON content.
///
/// **契约（master findings F-W1B-042）**：
/// - 仅替换形如 `{$.path}` 或 `{$[0].path}` 的**单**花括号片段。
/// - 本函数在 `resolve_rule_template` 处理完 `{{...}}` 模板**之后**对
///   剩余字符串做一次后处理；外层调用 `resolve_rule_template` 在 input
///   不含 `{{` 时**早返回**（不进入本函数），所以独立的 `{$.x}` 模板
///   想要被识别，必须存在至少一处 `{{...}}`（哨兵）。
/// - 双花括号 `{{ ... }}` 模板由 `resolve_rule_template` 分派给
///   `resolve_single_template_rule` 处理（mustache 优先）；本函数内部用
///   手写 lookbehind/lookahead 跳过紧邻 `{` / `}` 的匹配，避免对
///   `{{ {$.x} }}` 这种嵌套二次替换 mustache 块内残余字面量。
/// - Rust `regex` crate 不支持真正的 lookbehind；当前手动跳过策略已经
///   被 `test_resolve_jsonpath_inside_double_braces` /
///   `test_resolve_single_brace_jsonpath_only` 测试固化，引入 lookbehind
///   regex 库或重写 tokenizer 不在当前批次范围。
fn resolve_single_brace_jsonpath(input: &str, json_content: &str) -> String {
    if !SINGLE_BRACE_JSONPATH_RE.is_match(input) {
        return input.to_string();
    }

    // Try to parse content as JSON
    let json_val: serde_json::Value = match serde_json::from_str(json_content) {
        Ok(v) => v,
        Err(_) => return input.to_string(),
    };

    let bytes = input.as_bytes();
    let mut result = String::with_capacity(input.len());
    let mut last = 0;

    for caps in SINGLE_BRACE_JSONPATH_RE.captures_iter(input) {
        let Some(full_match) = caps.get(0) else {
            continue;
        };
        let start = full_match.start();
        let end = full_match.end();

        // Manual lookbehind: skip if the byte immediately before is `{`.
        if start > 0 && bytes[start - 1] == b'{' {
            continue;
        }
        // Manual lookahead: skip if the byte immediately after is `}`.
        if end < bytes.len() && bytes[end] == b'}' {
            continue;
        }

        result.push_str(&input[last..start]);

        let jsonpath_expr = caps.get(1).map(|m| m.as_str()).unwrap_or_default();
        let replacement = evaluate_jsonpath_inline(jsonpath_expr, &json_val);
        result.push_str(&replacement);
        last = end;
    }

    result.push_str(&input[last..]);
    result
}

/// Evaluate a JSONPath expression against a JSON value and return the first scalar result.
fn evaluate_jsonpath_inline(expr: &str, json_val: &serde_json::Value) -> String {
    match jsonpath_lib::select(json_val, expr) {
        Ok(results) => {
            results.into_iter().next().map(|v| match v {
                serde_json::Value::String(s) => s.clone(),
                other => other.to_string(),
            }).unwrap_or_default()
        }
        Err(_) => String::new(),
    }
}

/// Execute the inner content of a single `{{...}}` template block.
fn resolve_single_template_rule(
    inner: &str,
    html: &str,
    context: &super::context::RuleContext,
) -> String {
    use super::js_runtime::{build_runtime_vars, DefaultJsRuntime, JsRuntime};
    use super::rule::execute_legado_rule;

    let inner = inner.trim();

    // @@ prefix: Default selector rule — strip both @, execute as CSS selector
    if inner.starts_with("@@") {
        let rule = &inner[2..];
        return execute_legado_rule(rule, html, context)
            .ok()
            .and_then(|v| v.into_iter().next())
            .unwrap_or_default();
    }

    // @-prefixed rules and known patterns go through execute_legado_rule
    if inner.starts_with('@')
        || inner.starts_with("//")
        || inner.starts_with("$.")
        || inner.starts_with("$[")
    {
        return execute_legado_rule(inner, html, context)
            .ok()
            .and_then(|v| v.into_iter().next())
            .unwrap_or_default();
    }

    // Explicit JS
    if inner.starts_with("js:") {
        let script = &inner[3..];
        let vars = build_runtime_vars(context, html);
        let runtime = DefaultJsRuntime::new();
        return runtime
            .eval(script, &vars)
            .map(|v| v.as_string_lossy())
            .unwrap_or_default();
    }

    // Default: JavaScript expression
    let vars = build_runtime_vars(context, html);
    let runtime = DefaultJsRuntime::new();
    runtime
        .eval(inner, &vars)
        .map(|v| v.as_string_lossy())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_simple_url() {
        let url = parse_legado_url("/search?q={{key}}");
        assert_eq!(url.path, "/search?q={{key}}");
        assert!(url.is_relative);
        assert_eq!(url.options.method, None);
    }

    #[test]
    fn test_parse_url_with_options() {
        let url = parse_legado_url(
            "/search?q={{key}}, {\"method\": \"POST\", \"charset\": \"gbk\", \"body\": \"key={{key}}&page={{page}}\"}",
        );
        assert_eq!(url.path, "/search?q={{key}}");
        assert_eq!(url.options.method.as_deref(), Some("POST"));
        assert_eq!(url.options.charset.as_deref(), Some("gbk"));
        assert_eq!(
            url.options.body.as_deref(),
            Some("key={{key}}&page={{page}}")
        );
    }

    #[test]
    fn test_resolve_url_keyword() {
        let url = parse_legado_url("/search?q={{key}}");
        let resolved = resolve_url_template(&url, "我的", 1, "https://example.com");
        assert!(resolved.contains("https://example.com/search?q=%E6%88%91%E7%9A%84"));
    }

    #[test]
    fn test_resolve_url_page() {
        let url = parse_legado_url("/search?q=test&page={{page}}");
        let resolved = resolve_url_template(&url, "test", 3, "https://example.com");
        assert!(resolved.contains("page=3"));
    }

    #[test]
    fn test_conditional_page_first() {
        let url = parse_legado_url("/list-<,{{page}}>.html");
        let resolved = resolve_url_template(&url, "", 1, "https://example.com");
        assert_eq!(resolved, "https://example.com/list-.html");
    }

    #[test]
    fn test_conditional_page_second() {
        let url = parse_legado_url("/list-<,{{page}}>.html");
        let resolved = resolve_url_template(&url, "", 2, "https://example.com");
        assert_eq!(resolved, "https://example.com/list-2.html");
    }

    #[test]
    fn test_page_expression() {
        let url = parse_legado_url("/list?start={{(page-1)*20}}&limit=20");
        let resolved = resolve_url_template(&url, "", 3, "https://example.com");
        assert!(resolved.contains("start=40"));
    }

    #[test]
    fn test_js_base64_expression() {
        let url = parse_legado_url("/search?q={{java.base64Encode(key)}}");
        let resolved = resolve_url_template(&url, "test", 1, "https://example.com");
        assert_eq!(resolved, "https://example.com/search?q=dGVzdA==");
    }

    #[test]
    fn test_js_ternary_expression() {
        let url = parse_legado_url("/list{{page - 1 == 0 ? '' : page}}.html");
        let first = resolve_url_template(&url, "", 1, "https://example.com");
        let second = resolve_url_template(&url, "", 2, "https://example.com");
        assert_eq!(first, "https://example.com/list.html");
        assert_eq!(second, "https://example.com/list2.html");
    }

    #[test]
    fn test_post_body_js_expression() {
        let body = resolve_post_body("key={{java.md5Encode(key)}}&page={{(page-1)*20}}", "123", 2);
        assert_eq!(body, "key=202cb962ac59075b964b07152d234b70&page=20");
    }

    #[test]
    fn test_resolve_rule_template_css() {
        let html = r#"<html><a href="/book/1">Link</a></html>"#;
        let ctx = crate::legado::context::RuleContext::for_book_info("https://example.com", html);
        let template = "{{@css:a@href}}";
        let result = resolve_rule_template(template, html, &ctx);
        assert_eq!(result, "/book/1");
    }

    #[test]
    fn test_resolve_rule_template_css_text() {
        let html = r#"<html><a href="/book/2">Link</a></html>"#;
        let ctx = crate::legado::context::RuleContext::for_book_info("https://example.com", html);
        let template = "{{@css:a}}";
        let result = resolve_rule_template(template, html, &ctx);
        assert_eq!(result, "Link");
    }

    #[test]
    fn test_resolve_rule_template_jsonpath() {
        let json = r#"{"id": "book-123", "name": "Test"}"#;
        let ctx = crate::legado::context::RuleContext::for_book_info("https://example.com", json);
        let template = "{{$.id}}";
        let result = resolve_rule_template(template, json, &ctx);
        assert_eq!(result, "book-123");
    }

    #[test]
    fn test_resolve_rule_template_default() {
        let html = r#"<html><a href="/book/3">Link</a></html>"#;
        let ctx = crate::legado::context::RuleContext::for_book_info("https://example.com", html);
        let template = "{{@@a}}";
        let result = resolve_rule_template(template, html, &ctx);
        assert_eq!(result, "Link");
    }

    #[test]
    fn test_resolve_rule_template_js_fallback() {
        let html = r#"<html></html>"#;
        let ctx = crate::legado::context::RuleContext::for_book_info("https://example.com", html);
        let template = "{{1 + 2}}";
        let result = resolve_rule_template(template, html, &ctx);
        assert_eq!(result, "3");
    }

    #[test]
    fn test_resolve_rule_template_no_template() {
        let html = r#"<html></html>"#;
        let ctx = crate::legado::context::RuleContext::for_book_info("https://example.com", html);
        let input = "plain text without template";
        let result = resolve_rule_template(input, html, &ctx);
        assert_eq!(result, input);
    }

    #[test]
    fn test_resolve_rule_template_mixed() {
        let html = r#"<html><a href="/ch/1">Chapter 1</a></html>"#;
        let ctx = crate::legado::context::RuleContext::for_book_info("https://example.com", html);
        let template = "/toc/{{@css:a@href}}?page=1";
        let result = resolve_rule_template(template, html, &ctx);
        assert_eq!(result, "/toc//ch/1?page=1");
    }

    /// F-W1B-036 契约固化：`resolve_conditional_page` 仅识别 URL 中
    /// 第一处 `<...>` 段；第二段保留原样（仅末尾 `>` 因
    /// `resolve_conditional_placeholder` 的 `trim_end_matches('>')` 被剥）。
    /// 用绝对 URL 绕开 `build_full_url` 的百分号编码，便于断言结构。
    #[test]
    fn test_resolve_conditional_page_only_first_segment() {
        let url = parse_legado_url("http://example.com/list-<,{{page}}>?sort=<,asc>");
        // page=1：第一段 `<,{{page}}>` 整体被剥；第二段保留 `<,asc`，末尾
        // `>` 被 `resolve_conditional_placeholder` 的 trim_end_matches 一并剥掉。
        let first = resolve_url_template(&url, "", 1, "https://unused.example/");
        assert_eq!(first, "http://example.com/list-?sort=<,asc");
        // page=2：第一段拆 prefix=""、rest="{{page}}"（逗号本身被
        // `split_once(',')` 吃掉），rest 展开为 "2"；第二段同上保留
        // `<,asc`，末尾 `>` 被 trim。第二段未被识别，证明"仅识别第一处"。
        let second = resolve_url_template(&url, "", 2, "https://unused.example/");
        assert_eq!(second, "http://example.com/list-2?sort=<,asc");
    }

    /// F-W1B-042 契约固化：`{{ {$.x} }}` 双花括号包单花括号 JSONPath 时，
    /// 外层 mustache 由 `resolve_rule_template` 优先吃掉两层花括号，inner
    /// 内容为 `{$.id}`，落到 `resolve_single_template_rule` 的"Default:
    /// JavaScript expression"分支被当成 JS 表达式 eval；`{$.id}` 不是合法
    /// JS 表达式，返回空串。**这固化了 contract：用户应当用 `{{$.id}}`
    /// （无内层花括号）拿 JSONPath，而非 `{{ {$.id} }}`**。手动 lookbehind
    /// 在 `resolve_single_brace_jsonpath` 跳过紧邻 `{` / `}` 的匹配确保不
    /// 再二次替换 mustache 块内残余的单花括号。
    #[test]
    fn test_resolve_jsonpath_inside_double_braces() {
        let json = r#"{"id": "book-123", "name": "Test"}"#;
        let ctx = crate::legado::context::RuleContext::for_book_info("https://example.com", json);
        let template = "{{ {$.id} }}";
        let result = resolve_rule_template(template, json, &ctx);
        assert_eq!(
            result, "",
            "外层 mustache 优先；inner `{{$.id}}` 走 JS eval 失败返回空"
        );
    }

    /// F-W1B-042 契约固化：单花括号 `{$.x}` 在 input 含至少一处
    /// `{{...}}` 时（哨兵）才会被 `resolve_single_brace_jsonpath` 后处理
    /// 替换。无 `{{` 的纯文本走 `resolve_rule_template` 早返回。
    #[test]
    fn test_resolve_single_brace_jsonpath_only() {
        let json = r#"{"url": "https://api.example/v2", "name": "X"}"#;
        let ctx = crate::legado::context::RuleContext::for_book_info("https://example.com", json);
        // 用空 mustache 块 `{{}}` 触发主路径，让单花括号 JSONPath 后处理走起来。
        let template = "prefix {{}}{$.url} suffix";
        let result = resolve_rule_template(template, json, &ctx);
        assert_eq!(result, "prefix https://api.example/v2 suffix");
    }
}
