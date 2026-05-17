//! # 书源解析器模块
//!
//! 整合规则引擎和脚本引擎，提供完整的书源解析功能。
//! 对应原 Legado 的 WebBook 模块 (model/webBook/)。

use crate::rule_engine::RuleEngine;
use crate::types::{BookSource, TocRule};
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::Value as JsonValue;
use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Mutex;
use tracing::{info, warn};

/// Global per-source rate limiter registry.
/// Tracks request timing per source URL to enforce concurrentRate.
///
/// Memory hygiene: each `wait_for_rate_limit` call also opportunistically
/// drops stale entries (windows that expired more than [`RATE_STATE_TTL`]
/// ago) so a long-running api-server with thousands of imported sources
/// doesn't accumulate entries forever.
///
/// Locking: `std::sync::Mutex` is intentional. The critical section is
/// short (HashMap lookup + a few field writes), and we always release the
/// lock *before* `tokio::time::sleep` — so the async runtime never sees a
/// held mutex. `parking_lot::Mutex` would be marginally faster on
/// contention but pulls in a dependency for no measurable win at the
/// current concurrency level (single-digit concurrent searches).
static RATE_LIMITER: std::sync::LazyLock<Mutex<HashMap<String, RateLimitState>>> =
    std::sync::LazyLock::new(|| Mutex::new(HashMap::new()));

/// Maximum number of distinct rate-limit entries to keep in memory.
/// On overflow we evict the entry with the oldest `window_start`.
const RATE_LIMITER_MAX_ENTRIES: usize = 1024;
/// Stale entries (no traffic for this long) are evicted on next access.
const RATE_STATE_TTL: std::time::Duration = std::time::Duration::from_secs(300);
/// Minimum gap between full registry sweeps. Without this each
/// `wait_for_rate_limit` call would re-scan the whole map; under heavy
/// concurrent search bursts the per-call O(n) work is wasteful.
const RATE_LIMITER_SWEEP_INTERVAL: std::time::Duration =
    std::time::Duration::from_secs(30);

/// Last time `evict_stale_rate_states` did real work. Wrapped in `Mutex`
/// (rather than `AtomicU64`) so it shares the locking story with
/// `RATE_LIMITER` — both are cheap to acquire and nothing async crosses
/// the critical section.
static RATE_LIMITER_LAST_SWEEP: std::sync::LazyLock<Mutex<std::time::Instant>> =
    std::sync::LazyLock::new(|| Mutex::new(std::time::Instant::now()));

#[derive(Debug, Clone)]
struct RateLimitState {
    /// Start time of current window
    window_start: std::time::Instant,
    /// Number of requests in current window
    count: u32,
}

/// Parse concurrentRate string into (max_count, window_ms).
/// - "1000" → (1, 1000) — one request per 1000ms
/// - "5/1000" → (5, 1000) — 5 requests per 1000ms window
fn parse_concurrent_rate(rate: &str) -> Option<(u32, u64)> {
    let rate = rate.trim();
    if rate.is_empty() || rate == "0" {
        return None;
    }
    if let Some((count_str, ms_str)) = rate.split_once('/') {
        let count = count_str.trim().parse::<u32>().ok()?;
        let ms = ms_str.trim().parse::<u64>().ok()?;
        if count == 0 || ms == 0 {
            return None;
        }
        Some((count, ms))
    } else {
        let ms = rate.parse::<u64>().ok()?;
        if ms == 0 {
            return None;
        }
        Some((1, ms))
    }
}

/// Drop entries older than [`RATE_STATE_TTL`] and, if still over capacity,
/// evict the oldest until back under [`RATE_LIMITER_MAX_ENTRIES`].
/// Caller holds the registry lock.
///
/// R4: use `saturating_duration_since` to defend against any future case
///     where `state.window_start` is somehow in the future relative to
///     `now` (clock skew on a future port; can't happen with `Instant`
///     today but cheap insurance).
fn evict_stale_rate_states(registry: &mut HashMap<String, RateLimitState>) {
    let now = std::time::Instant::now();
    registry.retain(|_, state| now.saturating_duration_since(state.window_start) <= RATE_STATE_TTL);

    if registry.len() <= RATE_LIMITER_MAX_ENTRIES {
        return;
    }
    // O(n) eviction — acceptable since we only run when over the cap.
    let mut entries: Vec<(String, std::time::Instant)> = registry
        .iter()
        .map(|(k, v)| (k.clone(), v.window_start))
        .collect();
    entries.sort_by_key(|(_, ts)| *ts);
    let drop_count = registry.len() - RATE_LIMITER_MAX_ENTRIES;
    for (key, _) in entries.iter().take(drop_count) {
        registry.remove(key);
    }
}

/// R5: throttle `evict_stale_rate_states` so heavy concurrent search bursts
/// don't pay the O(n) sweep cost on every request. Returns true at most
/// once per [`RATE_LIMITER_SWEEP_INTERVAL`].
fn should_run_sweep_now() -> bool {
    let mut last = match RATE_LIMITER_LAST_SWEEP.lock() {
        Ok(g) => g,
        Err(_) => return false,
    };
    let now = std::time::Instant::now();
    if now.saturating_duration_since(*last) >= RATE_LIMITER_SWEEP_INTERVAL {
        *last = now;
        true
    } else {
        false
    }
}

/// Wait if needed to respect the source's concurrentRate.
async fn wait_for_rate_limit(source_key: &str, concurrent_rate: &str) {
    let Some((max_count, window_ms)) = parse_concurrent_rate(concurrent_rate) else {
        return;
    };

    let window_duration = std::time::Duration::from_millis(window_ms);

    loop {
        let wait_time = {
            let mut registry = RATE_LIMITER.lock().unwrap();
            // R5: only sweep periodically — a hot path with thousands of
            // concurrent searches per minute would otherwise pay O(n) on
            // every call. Sweep cadence is 30s; entries that overflow the
            // hard cap [`RATE_LIMITER_MAX_ENTRIES`] still get evicted
            // immediately because that path is gated separately by size.
            if should_run_sweep_now()
                || registry.len() > RATE_LIMITER_MAX_ENTRIES
            {
                evict_stale_rate_states(&mut registry);
            }
            let state = registry
                .entry(source_key.to_string())
                .or_insert_with(|| RateLimitState {
                    window_start: std::time::Instant::now(),
                    count: 0,
                });

            let elapsed = state.window_start.elapsed();
            if elapsed >= window_duration {
                // Window expired, reset
                state.window_start = std::time::Instant::now();
                state.count = 1;
                None
            } else if state.count < max_count {
                // Within window and under limit
                state.count += 1;
                None
            } else {
                // Over limit, need to wait for window to expire
                Some(window_duration - elapsed)
            }
        };

        match wait_time {
            None => break,
            Some(duration) => {
                tokio::time::sleep(duration).await;
            }
        }
    }
}

/// 搜索结果（对应原 Legado 的 SearchBook）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchResult {
    pub id: String,
    pub name: String,
    pub author: String,
    pub cover_url: Option<String>,
    pub intro: Option<String>,
    pub book_url: String,
    pub source_id: String,
    pub source_name: String,
}

/// P1-3: Build a stable ID for a SearchResult so the Dart side doesn't have
/// to reinvent the same hash ([_saveResultToBookshelf] in search_page.dart).
///
/// Inputs are joined with `|`, hashed with SHA256, then base64url-encoded
/// (no padding) — this matches the Dart side byte-for-byte. If the source
/// has no book_url (offline / explore), we fall back to `name|author|now`
/// so two distinct entries still get distinct IDs within the same second.
pub(crate) fn stable_search_result_id(
    source_id: &str,
    book_url: &str,
    name: &str,
    author: &str,
) -> String {
    use base64::Engine;
    use sha2::{Digest, Sha256};
    let parts = [source_id, book_url, name, author];
    let joined = parts
        .iter()
        .filter(|s| !s.is_empty())
        .copied()
        .collect::<Vec<_>>()
        .join("|");
    let input = if joined.is_empty() {
        format!(
            "unknown|{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0)
        )
    } else {
        joined
    };
    let digest = Sha256::digest(input.as_bytes());
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(digest)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExploreEntry {
    pub title: String,
    pub url: String,
}

/// 书籍详情
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookDetail {
    pub id: String,
    pub name: String,
    pub author: String,
    pub cover_url: Option<String>,
    pub intro: Option<String>,
    pub kind: Option<String>,
    pub word_count: Option<String>,
    pub book_url: String,
    pub source_id: String,
    pub chapters_url: Option<String>,
}

/// 章节信息
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChapterInfo {
    pub id: String,
    pub title: String,
    pub url: String,
    pub index: i32,
    #[serde(default)]
    pub is_vip: Option<bool>,
    #[serde(default)]
    pub is_volume: bool,
    #[serde(default)]
    pub is_pay: bool,
    /// 更新时间或其他附加信息 (corresponds to Legado's BookChapter.tag)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tag: Option<String>,
}

/// 章节内容
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChapterContent {
    pub chapter_id: String,
    pub content: String,
    pub next_chapter_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub platform_request: Option<PlatformRequest>,
    /// Image display style from source (DEFAULT, FULL, TEXT, SINGLE)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_style: Option<String>,
    /// JS for decrypting image bytes (receives `result` as bytes, `src` as URL)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_decode: Option<String>,
    /// JS or URL for purchasing paid chapters
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pay_action: Option<String>,
}

/// Request that must be handled by the host platform (Android/WebView layer).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum PlatformRequest {
    WebViewContent {
        url: String,
        content_rule: Option<String>,
        web_js: Option<String>,
        source_regex: Option<String>,
        headers: std::collections::HashMap<String, String>,
        user_agent: Option<String>,
    },
}

/// Internal struct for parsed chapter data from a single TOC page.
struct ParsedChaptersPage {
    names: Vec<String>,
    urls: Vec<String>,
    vips: Vec<Option<bool>>,
    is_volumes: Vec<bool>,
    is_pays: Vec<bool>,
    update_times: Vec<String>,
}

impl ParsedChaptersPage {
    fn empty() -> Self {
        Self {
            names: Vec::new(),
            urls: Vec::new(),
            vips: Vec::new(),
            is_volumes: Vec::new(),
            is_pays: Vec::new(),
            update_times: Vec::new(),
        }
    }

    fn len(&self) -> usize {
        self.names
            .len()
            .max(self.urls.len())
            .max(self.vips.len())
    }
}

/// 书源解析器
pub struct BookSourceParser {
    rule_engine: RuleEngine,
    http_client: crate::legado::LegadoHttpClient,
}

impl Default for BookSourceParser {
    fn default() -> Self {
        Self::new()
    }
}

impl BookSourceParser {
    /// 创建新的书源解析器
    pub fn new() -> Self {
        Self {
            rule_engine: RuleEngine::new(),
            http_client: crate::legado::LegadoHttpClient::new(),
        }
    }

    /// Execute a rule string, preferring the legado selector chain for Legado-style rules.
    fn run_rule(
        &self,
        rule: &str,
        html: &str,
        context: &crate::legado::RuleContext,
    ) -> Result<Vec<String>, String> {
        match crate::legado::execute_legado_rule(rule, html, context) {
            Ok(results) if !results.is_empty() => return Ok(results),
            Ok(results) if !can_fallback_to_legacy_rule_engine(rule) => return Ok(results),
            _ => {}
        }
        self.rule_engine
            .execute_rule(rule, html)
            .map_err(|e| e.to_string())
    }

    /// Execute a rule string and return the first result.
    fn run_rule_first(
        &self,
        rule: &str,
        html: &str,
        context: &crate::legado::RuleContext,
    ) -> Option<String> {
        self.run_rule(rule, html, context).ok()?.into_iter().next()
    }

    async fn fetch_url(
        &self,
        source: &BookSource,
        url: &str,
        keyword: &str,
        page: i32,
    ) -> Result<String, String> {
        // Apply rate limiting if configured
        if let Some(ref rate) = source.concurrent_rate {
            wait_for_rate_limit(&source.url, rate).await;
        }
        let legado_url = crate::legado::url::parse_legado_url(url);
        let full_url = resolve_source_url(source, &legado_url, keyword, page);
        let headers = parse_source_headers(source.header.as_deref());
        self.http_client
            .request_with_legado_url_and_headers(&full_url, &legado_url, keyword, page, &headers)
            .await
    }

    /// 搜索书籍
    /// 对应原 Legado 的 searchBook 流程
    pub async fn search(&self, source: &BookSource, keyword: &str) -> Vec<SearchResult> {
        info!("搜索书籍: {} (书源: {})", keyword, source.name);

        // 1. 构建搜索 URL
        let search_url = match &source.rule_search {
            Some(search_rule) => match search_rule.search_url.as_ref() {
                Some(url) => url.clone(),
                None => {
                    warn!("书源 {} 未配置搜索 URL", source.name);
                    return vec![];
                }
            },
            None => {
                warn!("书源 {} 未配置搜索规则", source.name);
                return vec![];
            }
        };

        // 2. 构建请求 URL（用于结果中的 book_url）
        let request_url = resolve_source_url(
            source,
            &crate::legado::url::parse_legado_url(&search_url),
            keyword,
            1,
        );

        // 3. 发起 HTTP 请求
        let html = match self.fetch_url(source, &search_url, keyword, 1).await {
            Ok(text) => text,
            Err(e) => {
                warn!("搜索请求失败: {}", e);
                return vec![SearchResult {
                    id: uuid::Uuid::new_v4().to_string(),
                    name: format!("[ERR] {}", if e.len() > 200 { &e[..200] } else { &e }),
                    author: String::new(),
                    cover_url: None,
                    intro: Some(format!("url={}", search_url)),
                    book_url: String::new(),
                    source_id: source.id.clone(),
                    source_name: source.name.clone(),
                }];
            }
        };
        let request_context = rule_context_with_source_headers(
            rule_context_with_src(
                crate::legado::RuleContext::for_search(&search_url, keyword, 1),
                &html,
            ),
            source,
        );

        // 3. 使用规则解析搜索结果
        let rules = source.rule_search.as_ref().unwrap();

        // 4. 解析结果
        let mut results = Vec::new();

        let contexts = rules
            .book_list
            .as_ref()
            .and_then(|r| {
                self.run_rule(&list_context_rule(r), &html, &request_context)
                    .ok()
            })
            .filter(|items| !items.is_empty())
            .unwrap_or_else(|| vec![html.clone()]);

        let names = extract_from_contexts(self, rules.name.as_deref(), &contexts, &request_context);
        let authors =
            extract_from_contexts(self, rules.author.as_deref(), &contexts, &request_context);
        let covers = extract_from_contexts(
            self,
            rules.cover_url.as_deref(),
            &contexts,
            &request_context,
        );
        let book_urls =
            extract_from_contexts(self, rules.book_url.as_deref(), &contexts, &request_context);
        let intros =
            extract_from_contexts(self, rules.intro.as_deref(), &contexts, &request_context);

        let max_len = names
            .len()
            .max(authors.len())
            .max(covers.len())
            .max(book_urls.len())
            .max(intros.len());

        for i in 0..max_len {
            let name = names.get(i).cloned().unwrap_or_default();
            let author = authors.get(i).cloned().unwrap_or_default();
            let book_url_str = book_urls
                .get(i)
                .cloned()
                .map(|u| crate::utils::build_full_url(&request_url, &u))
                .unwrap_or_else(|| request_url.clone());
            results.push(SearchResult {
                id: stable_search_result_id(&source.id, &book_url_str, &name, &author),
                name,
                author,
                cover_url: covers
                    .get(i)
                    .cloned()
                    .map(|u| crate::utils::build_full_url(&request_url, &u)),
                intro: None,
                book_url: book_url_str,
                source_id: source.id.clone(),
                source_name: source.name.clone(),
            });
        }

        info!("搜索完成，找到 {} 个结果", results.len());
        results
    }

    /// 探索/发现书籍
    /// 对应原 Legado 的 explore 流程
    pub async fn explore(
        &self,
        source: &BookSource,
        explore_url: &str,
        page: i32,
    ) -> Vec<SearchResult> {
        info!(
            "探索: {} page={} (书源: {})",
            explore_url, page, source.name
        );

        let legado_url = crate::legado::url::parse_legado_url(explore_url);
        let full_url = crate::legado::url::resolve_url_template(&legado_url, "", page, &source.url);

        let html = match self.fetch_url(source, &full_url, "", page).await {
            Ok(text) => text,
            Err(e) => {
                warn!("探索请求失败: {}", e);
                return vec![];
            }
        };

        // Try JSON array format first: [{"title": "...", "url": "..."}]
        if let Ok(json_array) = serde_json::from_str::<Vec<JsonValue>>(&html) {
            let results: Vec<SearchResult> = json_array
                .iter()
                .filter_map(|item| {
                    let title = item
                        .get("title")
                        .or_else(|| item.get("name"))
                        .and_then(|v| v.as_str())
                        .unwrap_or("");
                    let url = item
                        .get("url")
                        .or_else(|| item.get("bookUrl"))
                        .and_then(|v| v.as_str())
                        .unwrap_or("");
                    if title.is_empty() || url.is_empty() {
                        return None;
                    }
                    let author = item
                        .get("author")
                        .and_then(|v| v.as_str())
                        .unwrap_or_default()
                        .to_string();
                    let book_url_str = crate::utils::build_full_url(&full_url, url);
                    Some(SearchResult {
                        id: stable_search_result_id(
                            &source.id,
                            &book_url_str,
                            title,
                            &author,
                        ),
                        name: title.to_string(),
                        author,
                        cover_url: item
                            .get("cover")
                            .or_else(|| item.get("coverUrl"))
                            .and_then(|v| v.as_str())
                            .map(|u| crate::utils::build_full_url(&full_url, u)),
                        intro: item
                            .get("intro")
                            .and_then(|v| v.as_str())
                            .map(|s| s.to_string()),
                        book_url: book_url_str,
                        source_id: source.id.clone(),
                        source_name: source.name.clone(),
                    })
                })
                .collect();
            info!("探索完成 (JSON)，找到 {} 个结果", results.len());
            return results;
        }

        // Try title::url text format
        if html.contains("::") {
            let results: Vec<SearchResult> = html
                .lines()
                .filter(|line| line.contains("::"))
                .filter_map(|line| {
                    let (title, url) = line.split_once("::")?;
                    let title = title.trim();
                    let url = url.trim();
                    if title.is_empty() || url.is_empty() {
                        return None;
                    }
                    let book_url_str = crate::utils::build_full_url(&full_url, url);
                    Some(SearchResult {
                        id: stable_search_result_id(&source.id, &book_url_str, title, ""),
                        name: title.to_string(),
                        author: String::new(),
                        cover_url: None,
                        intro: None,
                        book_url: book_url_str,
                        source_id: source.id.clone(),
                        source_name: source.name.clone(),
                    })
                })
                .collect();
            info!("探索完成 (文本)，找到 {} 个结果", results.len());
            return results;
        }

        // Use rule_explore (like search rules) to parse HTML
        if let Some(ref explore_rule) = source.rule_explore {
            let results = self.parse_explore_with_rule(&html, explore_rule, source, &full_url);
            info!("探索完成 (规则)，找到 {} 个结果", results.len());
            return results;
        }

        vec![]
    }

    fn parse_explore_with_rule(
        &self,
        html: &str,
        explore_rule: &crate::types::SearchRule,
        source: &BookSource,
        base_url: &str,
    ) -> Vec<SearchResult> {
        let context = crate::legado::RuleContext::for_search(base_url, "", 1);
        let request_context =
            rule_context_with_source_headers(rule_context_with_src(context, html), source);

        let contexts = explore_rule
            .book_list
            .as_ref()
            .and_then(|r| {
                self.run_rule(&list_context_rule(r), html, &request_context)
                    .ok()
            })
            .filter(|items| !items.is_empty())
            .unwrap_or_else(|| vec![html.to_string()]);

        let names = extract_from_contexts(
            self,
            explore_rule.name.as_deref(),
            &contexts,
            &request_context,
        );
        let authors = extract_from_contexts(
            self,
            explore_rule.author.as_deref(),
            &contexts,
            &request_context,
        );
        let covers = extract_from_contexts(
            self,
            explore_rule.cover_url.as_deref(),
            &contexts,
            &request_context,
        );
        let book_urls = extract_from_contexts(
            self,
            explore_rule.book_url.as_deref(),
            &contexts,
            &request_context,
        );

        let max_len = names
            .len()
            .max(authors.len())
            .max(covers.len())
            .max(book_urls.len());
        (0..max_len)
            .map(|i| {
                let name = names.get(i).cloned().unwrap_or_default();
                let author = authors.get(i).cloned().unwrap_or_default();
                let book_url_str = book_urls
                    .get(i)
                    .cloned()
                    .map(|u| crate::utils::build_full_url(base_url, &u))
                    .unwrap_or_else(|| base_url.to_string());
                SearchResult {
                    id: stable_search_result_id(&source.id, &book_url_str, &name, &author),
                    name,
                    author,
                    cover_url: covers
                        .get(i)
                        .cloned()
                        .map(|u| crate::utils::build_full_url(base_url, &u)),
                    intro: None,
                    book_url: book_url_str,
                    source_id: source.id.clone(),
                    source_name: source.name.clone(),
                }
            })
            .collect()
    }

    pub fn get_explore_entries(source: &BookSource) -> Vec<ExploreEntry> {
        let mut entries = Vec::new();
        if let Some(ref explore_url) = source.explore_url {
            for entry in explore_url.split("&&") {
                let entry = entry.trim();
                if let Some((title, url)) = entry.split_once("::") {
                    entries.push(ExploreEntry {
                        title: title.trim().to_string(),
                        url: url.trim().to_string(),
                    });
                }
            }
        }
        entries
    }

    /// 获取书籍详情
    /// 对应原 Legado 的 getBookInfo 流程
    pub async fn get_book_info(&self, source: &BookSource, book_url: &str) -> Option<BookDetail> {
        let book_url = crate::utils::build_full_url(&source.url, book_url);
        info!("获取书籍详情: {} (书源: {})", book_url, source.name);

        // 1. 请求书籍页面
        let html = match self.fetch_url(source, &book_url, "", 1).await {
            Ok(text) => text,
            Err(e) => {
                warn!("请求书籍页面失败: {}", e);
                return None;
            }
        };
        let context = rule_context_with_source_headers(
            crate::legado::RuleContext::for_book_info(&book_url, &html),
            source,
        );

        // 2. 使用规则解析
        let rules = source.rule_book_info.as_ref()?;

        // Phase 2a: book_info_init - execute init rule and use JSON result if available
        let (working_content, init_context, is_init_json) =
            execute_book_info_init(self, rules.book_info_init.as_deref(), &html, &context).await;

        let extract_field = |rule: Option<&String>| -> Option<String> {
            let rule_str = rule?;
            if rule_str.contains("{{") {
                let resolved = crate::legado::url::resolve_rule_template(
                    rule_str,
                    &working_content,
                    &init_context,
                );
                if resolved.is_empty() {
                    None
                } else {
                    Some(resolved)
                }
            } else {
                let effective_rule = if is_init_json && is_simple_field_name(rule_str) {
                    format!("$.{}", rule_str)
                } else {
                    rule_str.clone()
                };
                self.run_rule_first(&effective_rule, &working_content, &init_context)
            }
        };

        let detail_name = extract_field(rules.name.as_ref());
        let detail_author = extract_field(rules.author.as_ref());

        let can_rename_name = rules
            .can_rename
            .as_ref()
            .and_then(|rule| self.run_rule_first(rule, &working_content, &init_context))
            .map(|v| !v.is_empty() && v != "false" && v != "0");
        let can_rename_author = rules
            .can_rename
            .as_ref()
            .and_then(|rule| self.run_rule_first(rule, &working_content, &init_context))
            .map(|v| !v.is_empty() && v != "false" && v != "0");

        let name = match (can_rename_name, detail_name.as_ref()) {
            (Some(true), Some(dn)) if !dn.is_empty() => dn.clone(),
            (Some(false), _) => String::new(),
            _ => detail_name.clone().unwrap_or_default(),
        };

        let author = match (can_rename_author, detail_author.as_ref()) {
            (Some(true), Some(da)) if !da.is_empty() => Some(da.clone()),
            (Some(false), _) => None,
            _ => detail_author.clone(),
        };

        let intro = extract_field(rules.intro.as_ref());

        let cover_url = extract_field(rules.cover_url.as_ref());

        let kind = extract_field(rules.kind.as_ref());

        let word_count = extract_field(rules.word_count.as_ref());

        // Phase 2b: toc_url - parse directory page URL
        let chapters_url = match rules.toc_url.as_deref() {
            Some(toc_rule) if !toc_rule.trim().is_empty() => {
                let resolved = if toc_rule.contains("{{") {
                    crate::legado::url::resolve_rule_template(
                        toc_rule,
                        &working_content,
                        &init_context,
                    )
                } else {
                    let effective_toc_rule = if is_init_json && is_simple_field_name(toc_rule) {
                        format!("$.{}", toc_rule)
                    } else {
                        toc_rule.to_string()
                    };
                    self.run_rule_first(&effective_toc_rule, &working_content, &init_context)
                        .unwrap_or_default()
                };
                if resolved.is_empty() {
                    book_url.clone()
                } else {
                    crate::utils::build_full_url(&book_url, &resolved)
                }
            }
            _ => book_url.clone(),
        };

        Some(BookDetail {
            id: stable_search_result_id(
                &source.id,
                &book_url,
                &name,
                author.as_deref().unwrap_or(""),
            ),
            name,
            author: author.unwrap_or_default(),
            cover_url: cover_url.map(|u| crate::utils::build_full_url(&book_url, &u)),
            intro,
            kind,
            word_count,
            book_url: book_url.clone(),
            source_id: source.id.clone(),
            chapters_url: Some(chapters_url),
        })
    }

    /// 获取章节列表 (supports multi-page catalogs via nextTocUrl)
    pub async fn get_chapters(&self, source: &BookSource, book_url: &str) -> Vec<ChapterInfo> {
        let rules = match &source.rule_toc {
            Some(r) => r,
            None => {
                warn!("书源 {} 未配置章节列表规则", source.name);
                return vec![];
            }
        };

        // Execute preUpdateJs before fetching the TOC
        if let Some(pre_update_js) = rules.pre_update_js.as_deref() {
            if !pre_update_js.trim().is_empty() {
                let base_url = crate::utils::build_full_url(&source.url, book_url);
                let context = rule_context_with_source_headers(
                    crate::legado::RuleContext::for_toc(&base_url, ""),
                    source,
                );
                let script = pre_update_js.to_string();
                let cookie_jar = self.http_client.cookie_jar();
                let headers = parse_source_headers(source.header.as_deref());
                let _ = tokio::task::spawn_blocking(move || {
                    let vars = crate::legado::js_runtime::build_runtime_vars(&context, "");
                    crate::legado::js_runtime::eval_default_with_http_state(
                        &script,
                        &vars,
                        cookie_jar,
                        headers,
                    )
                })
                .await;
            }
        }

        let chapter_list_reverse = rules
            .chapter_list
            .as_deref()
            .map_or(false, |r| r.trim_start().starts_with('-'));
        let modified_rules: std::borrow::Cow<TocRule>;
        let effective_rules = if chapter_list_reverse {
            let mut m = rules.clone();
            m.chapter_list = m
                .chapter_list
                .map(|s| s.trim_start().trim_start_matches('-').trim().to_string());
            modified_rules = std::borrow::Cow::Owned(m);
            &*modified_rules
        } else {
            rules
        };

        let mut all_chapters: Vec<ChapterInfo> = Vec::new();
        let current_url = crate::utils::build_full_url(&source.url, book_url);
        let mut seen_urls: HashSet<String> = HashSet::new();
        let mut chapter_offset: i32 = 0;
        const MAX_TOC_PAGES: usize = 50;

        info!("开始获取章节列表: {} (书源: {})", current_url, source.name);

        let mut url_queue: VecDeque<String> = VecDeque::new();
        url_queue.push_back(current_url);

        while let Some(url) = url_queue.pop_front() {
            if seen_urls.contains(&url) {
                warn!("检测到目录页 URL 循环: {}", url);
                continue;
            }
            if seen_urls.len() >= MAX_TOC_PAGES {
                warn!("目录页数量达到上限: {}", MAX_TOC_PAGES);
                break;
            }
            seen_urls.insert(url.clone());

            let first_page = seen_urls.len() == 1;
            let html = match self.fetch_url(source, &url, "", 1).await {
                Ok(text) => text,
                Err(e) => {
                    if first_page {
                        warn!("请求章节列表失败 (首页): {}", e);
                        return vec![];
                    }
                    warn!("请求章节列表失败: {}", e);
                    continue;
                }
            };
            let context = rule_context_with_source_headers(
                crate::legado::RuleContext::for_toc(&url, &html),
                source,
            );

            let page = self
                .parse_chapters_from_page(source, effective_rules, &html, &context, &url)
                .await;

            let max_len = page.len();
            for i in 0..max_len {
                let title = page
                    .names
                    .get(i)
                    .cloned()
                    .unwrap_or_else(|| format!("第 {} 章", chapter_offset + i as i32 + 1));
                let chapter_url_val = page
                    .urls
                    .get(i)
                    .cloned()
                    .map(|u| crate::utils::build_full_url(&url, &u))
                    .unwrap_or_default();
                let is_vip = page.vips.get(i).copied().flatten();
                let is_volume = page.is_volumes.get(i).copied().unwrap_or(false);
                let is_pay = page.is_pays.get(i).copied().unwrap_or(false);
                let tag = page.update_times.get(i).cloned();
                // If isVolume and no URL, use title as placeholder (matching Legado behavior)
                let chapter_url_val = if is_volume && chapter_url_val.is_empty() {
                    format!("{}_{}", title, chapter_offset + i as i32)
                } else {
                    chapter_url_val
                };
                all_chapters.push(ChapterInfo {
                    id: stable_search_result_id(
                        &url,
                        &chapter_url_val,
                        &title,
                        &(chapter_offset + i as i32).to_string(),
                    ),
                    title,
                    url: chapter_url_val,
                    index: chapter_offset + i as i32,
                    is_vip,
                    is_volume,
                    is_pay,
                    tag,
                });
            }
            chapter_offset += max_len as i32;

            let next_urls: Vec<String> = match rules.next_toc_url.as_deref() {
                Some(next_rule) if !next_rule.trim().is_empty() => {
                    if next_rule.contains("{{") {
                        let resolved =
                            crate::legado::url::resolve_rule_template(next_rule, &html, &context);
                        if resolved.is_empty() {
                            Vec::new()
                        } else {
                            vec![resolved]
                        }
                    } else {
                        self.run_rule(next_rule, &html, &context)
                            .unwrap_or_default()
                    }
                }
                _ => Vec::new(),
            };
            for next in next_urls {
                if !next.trim().is_empty() {
                    let full_url = crate::utils::build_full_url(&url, &next);
                    if !full_url.is_empty() && !seen_urls.contains(&full_url) {
                        url_queue.push_back(full_url);
                    }
                }
            }
        }

        if chapter_list_reverse {
            all_chapters.reverse();
            for (i, ch) in all_chapters.iter_mut().enumerate() {
                ch.index = i as i32;
            }
        }

        // Apply formatJs: post-process chapter titles via JavaScript
        if let Some(format_js) = rules.format_js.as_deref() {
            if !format_js.trim().is_empty() {
                let format_js = format_js.to_string();
                let cookie_jar = self.http_client.cookie_jar();
                let source_headers = parse_source_headers(source.header.as_deref());
                let base_url = crate::utils::build_full_url(&source.url, book_url);
                let chapters_clone = all_chapters.clone();
                let result = tokio::task::spawn_blocking(move || {
                    apply_format_js(&format_js, chapters_clone, &base_url, cookie_jar, &source_headers)
                })
                .await;
                if let Ok(formatted) = result {
                    all_chapters = formatted;
                }
            }
        }

        info!(
            "章节列表获取完成，共 {} 章 ({} 页)",
            all_chapters.len(),
            seen_urls.len()
        );
        all_chapters
    }

    /// Parse chapters from a single catalog page
    async fn parse_chapters_from_page(
        &self,
        _source: &BookSource,
        rules: &TocRule,
        html: &str,
        context: &crate::legado::RuleContext,
        _book_url: &str,
    ) -> ParsedChaptersPage {
        let Some(chapter_list_rule) = rules.chapter_list.as_deref() else {
            return ParsedChaptersPage::empty();
        };

        if chapter_list_rule.trim_start().starts_with("@js:") {
            match execute_chapter_list_js_rule_blocking(
                chapter_list_rule,
                html,
                context,
                self.http_client.cookie_jar(),
            )
            .await
            {
                Some(items) => {
                    let len = items.len();
                    let names =
                        extract_json_field_from_contexts(rules.chapter_name.as_deref(), &items);
                    let urls =
                        extract_json_field_from_contexts(rules.chapter_url.as_deref(), &items);
                    let vips = rules
                        .is_vip
                        .as_deref()
                        .map(|rule| {
                            items
                                .iter()
                                .map(|item| item.get(rule).and_then(js_is_vip_to_bool))
                                .collect()
                        })
                        .unwrap_or_else(|| vec![None; len]);
                    let is_volumes = rules
                        .is_volume
                        .as_deref()
                        .map(|rule| {
                            items
                                .iter()
                                .map(|item| {
                                    item.get(rule)
                                        .and_then(js_is_vip_to_bool)
                                        .unwrap_or(false)
                                })
                                .collect()
                        })
                        .unwrap_or_else(|| vec![false; len]);
                    let is_pays = rules
                        .is_pay
                        .as_deref()
                        .map(|rule| {
                            items
                                .iter()
                                .map(|item| {
                                    item.get(rule)
                                        .and_then(js_is_vip_to_bool)
                                        .unwrap_or(false)
                                })
                                .collect()
                        })
                        .unwrap_or_else(|| vec![false; len]);
                    let update_times = rules
                        .update_time
                        .as_deref()
                        .map(|rule| {
                            items
                                .iter()
                                .filter_map(|item| {
                                    item.get(rule).and_then(json_scalar_to_string)
                                })
                                .collect()
                        })
                        .unwrap_or_default();
                    return ParsedChaptersPage {
                        names,
                        urls,
                        vips,
                        is_volumes,
                        is_pays,
                        update_times,
                    };
                }
                None => return ParsedChaptersPage::empty(),
            }
        }

        let item_contexts =
            match self.run_rule(&list_context_rule(chapter_list_rule), html, context) {
                Ok(items) if !items.is_empty() => items,
                _ => vec![html.to_string()],
            };
        let len = item_contexts.len();
        let names =
            extract_from_contexts(self, rules.chapter_name.as_deref(), &item_contexts, context);
        let urls =
            extract_from_contexts(self, rules.chapter_url.as_deref(), &item_contexts, context);
        let vips = rules
            .is_vip
            .as_deref()
            .map(|rule| {
                item_contexts
                    .iter()
                    .map(|item| {
                        let mut ctx = context.clone();
                        ctx.result = vec![crate::legado::LegadoValue::String(item.clone())];
                        self.run_rule_first(rule, item, &ctx)
                            .map(|v| !v.is_empty() && v != "false" && v != "0")
                    })
                    .collect()
            })
            .unwrap_or_else(|| vec![None; len]);
        let is_volumes = rules
            .is_volume
            .as_deref()
            .map(|rule| {
                item_contexts
                    .iter()
                    .map(|item| {
                        let mut ctx = context.clone();
                        ctx.result = vec![crate::legado::LegadoValue::String(item.clone())];
                        self.run_rule_first(rule, item, &ctx)
                            .map(|v| !v.is_empty() && v != "false" && v != "0")
                            .unwrap_or(false)
                    })
                    .collect()
            })
            .unwrap_or_else(|| vec![false; len]);
        let is_pays = rules
            .is_pay
            .as_deref()
            .map(|rule| {
                item_contexts
                    .iter()
                    .map(|item| {
                        let mut ctx = context.clone();
                        ctx.result = vec![crate::legado::LegadoValue::String(item.clone())];
                        self.run_rule_first(rule, item, &ctx)
                            .map(|v| !v.is_empty() && v != "false" && v != "0")
                            .unwrap_or(false)
                    })
                    .collect()
            })
            .unwrap_or_else(|| vec![false; len]);
        let update_times = rules
            .update_time
            .as_deref()
            .map(|rule| {
                item_contexts
                    .iter()
                    .filter_map(|item| {
                        let mut ctx = context.clone();
                        ctx.result = vec![crate::legado::LegadoValue::String(item.clone())];
                        self.run_rule_first(rule, item, &ctx)
                    })
                    .collect()
            })
            .unwrap_or_default();
        ParsedChaptersPage {
            names,
            urls,
            vips,
            is_volumes,
            is_pays,
            update_times,
        }
    }

    /// 获取章节内容
    pub async fn get_chapter_content(
        &self,
        source: &BookSource,
        chapter_url: &str,
    ) -> Option<ChapterContent> {
        const MAX_CONTENT_PAGES: usize = 50;

        let initial_url = crate::utils::build_full_url(&source.url, chapter_url);
        info!("获取章节内容: {} (书源: {})", initial_url, source.name);

        let current_url = initial_url.clone();
        let mut all_content = String::new();
        let mut seen_urls = HashSet::new();
        let mut final_next_chapter_url = None;

        let mut url_queue: VecDeque<String> = VecDeque::new();
        url_queue.push_back(current_url);

        while let Some(url) = url_queue.pop_front() {
            if !seen_urls.insert(url.clone()) {
                warn!("检测到重复内容页 URL, 跳过: {}", url);
                continue;
            }
            if seen_urls.len() > MAX_CONTENT_PAGES {
                warn!("内容页数量达到上限: {}", MAX_CONTENT_PAGES);
                break;
            }

            let first_page = seen_urls.len() == 1;
            let html = match self.fetch_url(source, &url, "", 1).await {
                Ok(text) => text,
                Err(e) => {
                    if first_page {
                        if e.starts_with("WEBVIEW_REQUIRED") {
                            let (web_js, source_regex, content_rule) = source
                                .rule_content
                                .as_ref()
                                .map(|r| {
                                    (r.web_js.clone(), r.source_regex.clone(), r.content.clone())
                                })
                                .unwrap_or((None, None, None));
                            return Some(ChapterContent {
                                chapter_id: uuid::Uuid::new_v4().to_string(),
                                content: String::new(),
                                next_chapter_url: None,
                                platform_request: Some(PlatformRequest::WebViewContent {
                                    url: url.clone(),
                                    content_rule,
                                    web_js,
                                    source_regex,
                                    headers: parse_source_headers(source.header.as_deref())
                                        .into_iter()
                                        .collect(),
                                    user_agent: source_user_agent(source.header.as_deref()),
                                }),
                                image_style: content_rule_field(source, |r| r.image_style.clone()),
                                image_decode: content_rule_field(source, |r| r.image_decode.clone()),
                                pay_action: content_rule_field(source, |r| r.pay_action.clone()),
                            });
                        }
                        warn!("请求章节内容失败: {}", e);
                        return None;
                    }
                    warn!("请求后续内容页失败: {}", e);
                    continue;
                }
            };

            let context = rule_context_with_source_headers(
                crate::legado::RuleContext::for_content(&url, &html),
                source,
            );
            let mut context = context;
            context.set_variable(
                "chapter",
                crate::legado::LegadoValue::Map(chapter_context_map(&url, chapter_url)),
            );

            if let Some(rule) = &source.rule_content {
                if rule.web_js.as_deref().is_some_and(|s| !s.trim().is_empty())
                    || rule
                        .source_regex
                        .as_deref()
                        .is_some_and(|s| !s.trim().is_empty())
                {
                    warn!("正文规则需要平台 WebView/sourceRegex 支持: {}", url);
                    return Some(ChapterContent {
                        chapter_id: uuid::Uuid::new_v4().to_string(),
                        content: String::new(),
                        next_chapter_url: None,
                        platform_request: Some(PlatformRequest::WebViewContent {
                            url: url.clone(),
                            content_rule: rule.content.clone(),
                            web_js: rule.web_js.clone(),
                            source_regex: rule.source_regex.clone(),
                            headers: parse_source_headers(source.header.as_deref())
                                .into_iter()
                                .collect(),
                            user_agent: source_user_agent(source.header.as_deref()),
                        }),
                        image_style: rule.image_style.clone(),
                        image_decode: rule.image_decode.clone(),
                        pay_action: rule.pay_action.clone(),
                    });
                }
            }

            let (page_content, next_urls) = match &source.rule_content {
                Some(rule) => {
                    let content_str = rule.content.as_deref().unwrap_or("");
                    let parsed = if content_str.contains("{{") {
                        crate::legado::url::resolve_rule_template(content_str, &html, &context)
                    } else if content_str.trim_start().starts_with("@js:") {
                        self
                            .run_rule_first_blocking(content_str, &html, &context)
                            .await
                            .unwrap_or_default()
                    } else {
                        self.run_rule_first(content_str, &html, &context)
                            .unwrap_or_default()
                    };
                    let nexts: Vec<String> = rule
                        .next_content_url
                        .as_deref()
                        .map(|r| {
                            if r.contains("{{") {
                                let resolved =
                                    crate::legado::url::resolve_rule_template(r, &html, &context);
                                if resolved.is_empty() {
                                    Vec::new()
                                } else {
                                    vec![resolved]
                                }
                            } else {
                                self.run_rule(r, &html, &context).unwrap_or_default()
                            }
                        })
                        .unwrap_or_default();
                    (parsed, nexts)
                }
                None => {
                    warn!("书源 {} 未配置内容规则", source.name);
                    (String::new(), Vec::new())
                }
            };

            let page_content = resolve_image_src_headers(&page_content, &url);
            if !first_page && !page_content.is_empty() {
                all_content.push('\n');
            }
            all_content.push_str(&page_content);

            if let Some(first_next) = next_urls.first() {
                let full_next = crate::utils::build_full_url(&url, first_next);
                final_next_chapter_url = Some(full_next);
            } else {
                final_next_chapter_url = None;
            }
            for next in next_urls {
                if !next.is_empty() {
                    let full_url = crate::utils::build_full_url(&url, &next);
                    if !full_url.is_empty() && !seen_urls.contains(&full_url) {
                        url_queue.push_back(full_url);
                    }
                }
            }
        }

        if all_content.is_empty() {
            return None;
        }

        // Apply replaceRegex (正文替换规则)
        let all_content = self.apply_replace_regex(source, &all_content, &initial_url);

        // Optional jsLib post-processing: feed the assembled content into the
        // book source's jsLib script and let it return the final body. P3-2
        // moved this off Rhai onto the QuickJS runtime so the script actually
        // sees Legado's `java.*` bridge and standard ECMAScript syntax.
        let content = if let Some(ref js_lib) = source.js_lib {
            use crate::legado::js_runtime::{
                build_runtime_vars, DefaultJsRuntime, JsRuntime,
            };
            use crate::legado::value::LegadoValue;
            let context = crate::legado::RuleContext::for_content(chapter_url, &all_content);
            let mut vars = build_runtime_vars(&context, &all_content);
            vars.insert(
                "result".into(),
                LegadoValue::String(all_content.clone()),
            );
            let runtime = DefaultJsRuntime::new();
            match runtime.eval(js_lib, &vars) {
                Ok(LegadoValue::String(s)) if !s.is_empty() => s,
                Ok(_) | Err(_) => all_content,
            }
        } else {
            all_content
        };

        Some(ChapterContent {
            chapter_id: uuid::Uuid::new_v4().to_string(),
            content,
            next_chapter_url: final_next_chapter_url,
            platform_request: None,
            image_style: content_rule_field(source, |r| r.image_style.clone()),
            image_decode: content_rule_field(source, |r| r.image_decode.clone()),
            pay_action: content_rule_field(source, |r| r.pay_action.clone()),
        })
    }

    async fn run_rule_first_blocking(
        &self,
        rule: &str,
        html: &str,
        context: &crate::legado::RuleContext,
    ) -> Option<String> {
        let rule = rule.to_string();
        let html = html.to_string();
        let context = context.clone();
        let cookie_jar = self.http_client.cookie_jar();
        let default_headers = context_default_headers(&context);
        tokio::task::spawn_blocking(move || {
            crate::legado::execute_legado_rule_with_http_state(
                &rule,
                &html,
                &context,
                cookie_jar,
                default_headers,
            )
            .ok()
            .and_then(|values| values.into_iter().next())
        })
        .await
        .ok()
        .flatten()
    }

    /// Apply replaceRegex rules to content text.
    /// In Legado, replaceRegex is a rule string executed via analyzeRule.getString(replaceRegex, content).
    /// The content becomes the source text, and the rule (with ##regex##replacement purification) is applied.
    fn apply_replace_regex(&self, source: &BookSource, content: &str, base_url: &str) -> String {
        let replace_regex = match source.rule_content.as_ref().and_then(|r| r.replace_regex.as_deref()) {
            Some(r) if !r.trim().is_empty() => r,
            _ => return content.to_string(),
        };

        // Legado's behavior: trim each line, apply rule, then re-indent
        let trimmed_content: String = content
            .lines()
            .map(|line| line.trim())
            .collect::<Vec<_>>()
            .join("\n");

        let context = crate::legado::RuleContext::for_content(base_url, &trimmed_content);

        // Execute the replaceRegex as a rule against the content
        let result = match self.run_rule(replace_regex, &trimmed_content, &context) {
            Ok(results) if !results.is_empty() => results.join("\n"),
            _ => trimmed_content.clone(),
        };

        // Re-indent paragraphs (Legado adds "　　" before each line)
        result
            .lines()
            .map(|line| {
                let trimmed = line.trim();
                if trimmed.is_empty() {
                    String::new()
                } else {
                    format!("\u{3000}\u{3000}{}", trimmed)
                }
            })
            .collect::<Vec<_>>()
            .join("\n")
    }
}

fn can_fallback_to_legacy_rule_engine(rule: &str) -> bool {
    let trimmed = rule.trim_start();
    !(trimmed.starts_with("@js:")
        || trimmed.starts_with("js:")
        || trimmed.contains("<js>")
        || trimmed.starts_with("@put:")
        || trimmed.starts_with("@get:")
        || trimmed.starts_with("@get."))
}

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

fn resolve_source_url(
    source: &BookSource,
    legado_url: &crate::legado::url::LegadoUrl,
    keyword: &str,
    page: i32,
) -> String {
    crate::legado::url::resolve_url_template(legado_url, keyword, page, &source.url)
}

fn rule_context_with_src(
    mut context: crate::legado::RuleContext,
    html: &str,
) -> crate::legado::RuleContext {
    context.src = html.to_string();
    context
}

fn rule_context_with_source_headers(
    mut context: crate::legado::RuleContext,
    source: &BookSource,
) -> crate::legado::RuleContext {
    let headers = parse_source_headers(source.header.as_deref());
    if !headers.is_empty() {
        let map = headers
            .into_iter()
            .map(|(key, value)| (key, crate::legado::LegadoValue::String(value)))
            .collect();
        context.variables.insert(
            "__source_header".into(),
            crate::legado::LegadoValue::Map(map),
        );
    }
    context
}

async fn execute_book_info_init(
    parser: &BookSourceParser,
    init_rule: Option<&str>,
    html: &str,
    context: &crate::legado::RuleContext,
) -> (String, crate::legado::RuleContext, bool) {
    let Some(init_rule) = init_rule.filter(|r| !r.trim().is_empty()) else {
        return (html.to_string(), context.clone(), false);
    };

    let rule = init_rule.to_string();
    let html_owned = html.to_string();
    let context_clone = context.clone();
    let cookie_jar = parser.http_client.cookie_jar();
    let default_headers = context_default_headers(&context_clone);

    let init_values = match tokio::task::spawn_blocking(move || {
        crate::legado::execute_legado_rule_values_with_http_state(
            &rule,
            &html_owned,
            &context_clone,
            cookie_jar,
            default_headers,
        )
    })
    .await
    {
        Ok(Ok(values)) => values,
        _ => return (html.to_string(), context.clone(), false),
    };

    if init_values.is_empty() {
        return (html.to_string(), context.clone(), false);
    }

    if init_values.len() == 1 {
        if let crate::legado::LegadoValue::Map(_) = &init_values[0] {
            let json_str = init_values[0].to_json_value().to_string();
            let init_context =
                crate::legado::RuleContext::for_book_info(&context.base_url, &json_str);
            return (json_str, init_context, true);
        }
    }

    let init_result = init_values[0].as_string_lossy();
    if init_result.trim().is_empty() {
        return (html.to_string(), context.clone(), false);
    }

    if let Ok(init_json) = serde_json::from_str::<JsonValue>(&init_result) {
        if init_json.is_object() {
            let init_context =
                crate::legado::RuleContext::for_book_info(&context.base_url, &init_result);
            return (init_result, init_context, true);
        }
    }

    (init_result, context.clone(), false)
}

fn is_simple_field_name(rule: &str) -> bool {
    let trimmed = rule.trim();
    !trimmed.is_empty()
        && !trimmed.starts_with('@')
        && !trimmed.starts_with("//")
        && !trimmed.starts_with("$.")
        && !trimmed.starts_with("$[")
        && !trimmed.starts_with('/')
        && !trimmed.starts_with(':')
        && !trimmed.starts_with("js:")
        && !trimmed.starts_with("regex:")
        && !trimmed.contains('@')
        && !trimmed.contains("class.")
        && !trimmed.contains("id.")
        && !trimmed.contains("tag.")
}

fn parse_source_headers(header: Option<&str>) -> Vec<(String, String)> {
    let Some(header) = header.map(str::trim).filter(|s| !s.is_empty()) else {
        return Vec::new();
    };

    if let Ok(value) = serde_json::from_str::<JsonValue>(header) {
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

fn source_user_agent(header: Option<&str>) -> Option<String> {
    parse_source_headers(header)
        .into_iter()
        .find(|(key, _)| key.eq_ignore_ascii_case("user-agent"))
        .map(|(_, value)| value)
}

/// Extract a field from the source's ContentRule.
fn content_rule_field(source: &BookSource, f: impl FnOnce(&crate::types::ContentRule) -> Option<String>) -> Option<String> {
    source.rule_content.as_ref().and_then(f).filter(|s| !s.trim().is_empty())
}

/// Apply formatJs to chapter titles.
/// In Legado, formatJs runs once per chapter with bindings:
///   - `index`: 1-based chapter index
///   - `title`: current chapter title
///   - `gInt`: shared integer variable (starts at 0, persists across iterations)
/// The return value replaces the chapter title.
fn apply_format_js(
    format_js: &str,
    mut chapters: Vec<ChapterInfo>,
    base_url: &str,
    _cookie_jar: std::sync::Arc<reqwest::cookie::Jar>,
    _default_headers: &[(String, String)],
) -> Vec<ChapterInfo> {
    use crate::legado::js_runtime::{DefaultJsRuntime, JsRuntime};
    use crate::legado::value::LegadoValue;
    use std::collections::HashMap;

    let runtime = DefaultJsRuntime::new();

    // Build a wrapper script that provides gInt persistence across calls.
    // We execute the formatJs for each chapter individually, passing index/title/gInt.
    let mut g_int: i64 = 0;

    for (idx, chapter) in chapters.iter_mut().enumerate() {
        let mut vars: HashMap<String, LegadoValue> = HashMap::new();
        vars.insert("index".into(), LegadoValue::Int((idx + 1) as i64));
        vars.insert(
            "title".into(),
            LegadoValue::String(chapter.title.clone()),
        );
        vars.insert("gInt".into(), LegadoValue::Int(g_int));
        vars.insert("baseUrl".into(), LegadoValue::String(base_url.to_string()));
        vars.insert("src".into(), LegadoValue::String(String::new()));
        vars.insert("result".into(), LegadoValue::String(chapter.title.clone()));

        // Wrap the script to return the result and allow gInt mutation
        let wrapped_script = format!(
            "var gInt = {};\n{}\n",
            g_int, format_js
        );

        match runtime.eval(&wrapped_script, &vars) {
            Ok(result) => {
                let new_title = result.as_string_lossy();
                if !new_title.is_empty() {
                    chapter.title = new_title;
                }
            }
            Err(e) => {
                warn!("formatJs 执行失败 (chapter {}): {}", idx + 1, e);
            }
        }

        // Try to extract updated gInt from the script result
        // In Legado, gInt is a mutable binding. We approximate by checking if the script
        // explicitly sets gInt. Since QuickJS doesn't easily expose mutated vars back,
        // we use a convention: if the script contains "gInt" assignments, we run a
        // secondary eval to get the updated value.
        let g_int_script = format!(
            "var gInt = {};\n{};\ngInt",
            g_int, format_js
        );
        if let Ok(val) = runtime.eval(&g_int_script, &vars) {
            if let LegadoValue::Int(v) = val {
                g_int = v;
            } else if let Ok(v) = val.as_string_lossy().parse::<i64>() {
                g_int = v;
            }
        }
    }

    chapters
}

fn execute_chapter_list_js_rule(
    rule: &str,
    html: &str,
    context: &crate::legado::RuleContext,
    cookie_jar: std::sync::Arc<reqwest::cookie::Jar>,
) -> Option<Vec<JsonValue>> {
    let values = crate::legado::execute_legado_rule_values_with_http_state(
        rule,
        html,
        context,
        cookie_jar,
        context_default_headers(context),
    )
    .ok()?;
    let items: Vec<JsonValue> = values
        .into_iter()
        .map(|value| value.to_json_value())
        .filter(|value| !value.is_null())
        .collect();
    if items.is_empty() {
        None
    } else {
        Some(items)
    }
}

fn context_default_headers(context: &crate::legado::RuleContext) -> Vec<(String, String)> {
    context
        .variables
        .get("__source_header")
        .and_then(|value| value.as_map())
        .map(|map| {
            map.iter()
                .map(|(key, value)| (key.clone(), value.as_string_lossy()))
                .collect()
        })
        .unwrap_or_default()
}

fn chapter_context_map(
    current_url: &str,
    original_url: &str,
) -> std::collections::HashMap<String, crate::legado::LegadoValue> {
    let mut map = std::collections::HashMap::new();
    map.insert(
        "url".into(),
        crate::legado::LegadoValue::String(current_url.to_string()),
    );
    map.insert(
        "baseUrl".into(),
        crate::legado::LegadoValue::String(current_url.to_string()),
    );
    map.insert(
        "bookUrl".into(),
        crate::legado::LegadoValue::String(original_url.to_string()),
    );
    map.insert(
        "title".into(),
        crate::legado::LegadoValue::String(String::new()),
    );
    map.insert("index".into(), crate::legado::LegadoValue::Int(0));
    map.insert(
        "resourceUrl".into(),
        crate::legado::LegadoValue::String(String::new()),
    );
    map.insert(
        "tag".into(),
        crate::legado::LegadoValue::String(String::new()),
    );
    map.insert("start".into(), crate::legado::LegadoValue::Int(0));
    map.insert("end".into(), crate::legado::LegadoValue::Int(0));
    map.insert(
        "variable".into(),
        crate::legado::LegadoValue::Map(std::collections::HashMap::new()),
    );
    map.insert("isVip".into(), crate::legado::LegadoValue::Bool(false));
    map.insert("is_vip".into(), crate::legado::LegadoValue::Bool(false));
    map
}

fn resolve_image_src_headers(content: &str, base_url: &str) -> String {
    let img_re = regex::Regex::new(r#"<img\s+[^>]*src="([^"]*)"[^>]*>"#).unwrap();
    img_re
        .replace_all(content, |caps: &regex::Captures| -> String {
            let full_match = caps.get(0).map(|m| m.as_str()).unwrap_or("");
            let src = caps.get(1).map(|m| m.as_str()).unwrap_or("");
            if let Some(comma_idx) = src.find(",{") {
                let url = &src[..comma_idx];
                let resolved = if !url.starts_with("http://")
                    && !url.starts_with("https://")
                    && !url.starts_with("data:")
                {
                    crate::utils::build_full_url(base_url, url)
                } else {
                    url.to_string()
                };
                full_match.replace(src, &resolved)
            } else {
                let resolved = if !src.starts_with("http://")
                    && !src.starts_with("https://")
                    && !src.starts_with("data:")
                {
                    crate::utils::build_full_url(base_url, src)
                } else {
                    src.to_string()
                };
                full_match.replace(src, &resolved)
            }
        })
        .to_string()
}

async fn execute_chapter_list_js_rule_blocking(
    rule: &str,
    html: &str,
    context: &crate::legado::RuleContext,
    cookie_jar: std::sync::Arc<reqwest::cookie::Jar>,
) -> Option<Vec<JsonValue>> {
    let rule = rule.to_string();
    let html = html.to_string();
    let context = context.clone();
    tokio::task::spawn_blocking(move || {
        execute_chapter_list_js_rule(&rule, &html, &context, cookie_jar)
    })
    .await
    .ok()
    .flatten()
}

fn extract_from_contexts(
    parser: &BookSourceParser,
    rule: Option<&str>,
    contexts: &[String],
    base_context: &crate::legado::RuleContext,
) -> Vec<String> {
    let Some(rule) = rule else {
        return Vec::new();
    };
    contexts
        .iter()
        .filter_map(|item| {
            let mut context = base_context.clone();
            context.result = vec![crate::legado::LegadoValue::String(item.clone())];
            if rule.contains("{{") {
                let resolved = crate::legado::url::resolve_rule_template(rule, item, &context);
                if resolved.is_empty() {
                    None
                } else {
                    Some(resolved)
                }
            } else {
                parser.run_rule_first(rule, item, &context)
            }
        })
        .collect()
}

fn extract_json_field_from_contexts(rule: Option<&str>, contexts: &[JsonValue]) -> Vec<String> {
    let Some(rule) = rule else {
        return Vec::new();
    };
    contexts
        .iter()
        .filter_map(|item| item.get(rule).and_then(json_scalar_to_string))
        .collect()
}

pub fn source_matches_url(source: &BookSource, url: &str) -> bool {
    let Some(ref pattern) = source.book_url_pattern else {
        return true;
    };
    if pattern.trim().is_empty() {
        return true;
    }
    Regex::new(pattern).is_ok_and(|re| re.is_match(url))
}

fn json_scalar_to_string(value: &JsonValue) -> Option<String> {
    if let Some(s) = value.as_str() {
        Some(s.to_string())
    } else if value.is_number() || value.is_boolean() {
        Some(value.to_string())
    } else {
        None
    }
}

fn js_is_vip_to_bool(value: &JsonValue) -> Option<bool> {
    if let Some(s) = value.as_str() {
        Some(!s.is_empty() && s != "false" && s != "0")
    } else if let Some(b) = value.as_bool() {
        Some(b)
    } else if let Some(n) = value.as_i64() {
        Some(n != 0)
    } else if let Some(n) = value.as_f64() {
        Some(n != 0.0)
    } else {
        None
    }
}

/// 便捷函数：快速搜索（使用默认解析器）
pub async fn search_book(source: &BookSource, keyword: &str) -> Vec<SearchResult> {
    let parser = BookSourceParser::new();
    parser.search(source, keyword).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{BookInfoRule, BookSource, ContentRule, SearchRule};

    // P1-3: stable_search_result_id contract — same inputs produce the same
    // output, different inputs differ, byte-for-byte matches the Dart
    // _saveResultToBookshelf hash so a Search SR.id can land in storage
    // without re-hashing.
    #[test]
    fn test_stable_search_result_id_is_deterministic() {
        let a = stable_search_result_id("src1", "https://x/book/1", "三体", "刘慈欣");
        let b = stable_search_result_id("src1", "https://x/book/1", "三体", "刘慈欣");
        assert_eq!(a, b);
        // Differs on any field change
        assert_ne!(
            a,
            stable_search_result_id("src2", "https://x/book/1", "三体", "刘慈欣")
        );
        assert_ne!(
            a,
            stable_search_result_id("src1", "https://x/book/2", "三体", "刘慈欣")
        );
        assert_ne!(
            a,
            stable_search_result_id("src1", "https://x/book/1", "三体II", "刘慈欣")
        );
    }

    #[test]
    fn test_stable_search_result_id_skips_empty_components() {
        // Order matters: ["a", "b"] must hash differently from ["", "a", "b"]
        // since the Dart side filters out empties before joining with '|'.
        let with_empty = stable_search_result_id("", "u", "n", "a");
        let manual = stable_search_result_id("u", "n", "a", "");
        // Both should reduce to joining "u|n|a" — same hash.
        assert_eq!(with_empty, manual);
    }

    #[test]
    fn test_stable_search_result_id_falls_back_when_all_empty() {
        // No information at all: still emits a non-empty hash (timestamp-based).
        let id = stable_search_result_id("", "", "", "");
        assert!(!id.is_empty());
        // 256-bit sha → base64url (no pad) is 43 chars.
        assert_eq!(id.len(), 43);
    }

    #[test]
    fn test_evict_stale_rate_states_drops_old_and_caps_size() {
        let mut registry: HashMap<String, RateLimitState> = HashMap::new();
        // A clearly-stale entry (window_start far in the past).
        registry.insert(
            "stale".into(),
            RateLimitState {
                window_start: std::time::Instant::now()
                    - RATE_STATE_TTL
                    - std::time::Duration::from_secs(1),
                count: 0,
            },
        );
        // A fresh entry that should survive eviction.
        registry.insert(
            "fresh".into(),
            RateLimitState {
                window_start: std::time::Instant::now(),
                count: 0,
            },
        );
        evict_stale_rate_states(&mut registry);
        assert!(!registry.contains_key("stale"));
        assert!(registry.contains_key("fresh"));
    }

    #[test]
    fn test_evict_stale_rate_states_caps_max_entries() {
        let mut registry: HashMap<String, RateLimitState> = HashMap::new();
        // Insert RATE_LIMITER_MAX_ENTRIES + 32 entries with monotonically
        // increasing window_start so we can verify oldest eviction order.
        let base = std::time::Instant::now();
        for i in 0..(RATE_LIMITER_MAX_ENTRIES + 32) {
            registry.insert(
                format!("k{i}"),
                RateLimitState {
                    window_start: base + std::time::Duration::from_micros(i as u64),
                    count: 0,
                },
            );
        }
        evict_stale_rate_states(&mut registry);
        assert!(registry.len() <= RATE_LIMITER_MAX_ENTRIES);
        // The oldest 32 keys ("k0".."k31") should be gone.
        for i in 0..32 {
            assert!(!registry.contains_key(&format!("k{i}")));
        }
    }

    #[tokio::test]
    async fn test_search_books() {
        let source = BookSource {
            id: "test".into(),
            name: "Test".into(),
            url: "https://example.com".into(),
            source_type: 0,
            enabled: true,
            group_name: None,
            custom_order: 0,
            weight: 0,
            rule_search: None,
            rule_book_info: None,
            rule_toc: None,
            rule_content: None,
            rule_review: None,
            login_url: None,
            login_ui: None,
            login_check_js: None,
            header: None,
            js_lib: None,
            cover_decode_js: None,
            explore_url: None,
            rule_explore: None,
            book_url_pattern: None,
            enabled_explore: false,
            last_update_time: 0,
            book_source_comment: None,
            concurrent_rate: None,
            variable_comment: None,
            explore_screen: None,
            created_at: 0,
            updated_at: 0,
        };
        let parser = BookSourceParser::new();
        let results = parser.search(&source, "test").await;
        assert!(results.is_empty());
    }

    #[tokio::test]
    async fn test_search_no_search_url() {
        let source = BookSource {
            id: "test2".into(),
            name: "Test2".into(),
            url: "https://example.com".into(),
            rule_search: Some(SearchRule {
                search_url: None,
                book_list: Some(".book".into()),
                name: Some(".title".into()),
                author: Some(".author".into()),
                book_url: Some("a@href".into()),
                cover_url: None,
                kind: None,
                last_chapter: None,
                ..Default::default()
            }),
            rule_book_info: None,
            rule_toc: None,
            rule_content: None,
            rule_review: None,
            login_url: None,
            login_ui: None,
            login_check_js: None,
            header: None,
            js_lib: None,
            cover_decode_js: None,
            explore_url: None,
            rule_explore: None,
            book_url_pattern: None,
            enabled_explore: false,
            last_update_time: 0,
            book_source_comment: None,
            concurrent_rate: None,
            variable_comment: None,
            explore_screen: None,
            created_at: 0,
            updated_at: 0,
            source_type: 0,
            enabled: true,
            group_name: None,
            custom_order: 0,
            weight: 0,
        };
        let parser = BookSourceParser::new();
        let results = parser.search(&source, "test").await;
        assert!(results.is_empty());
    }

    #[test]
    fn test_chapter_content_with_next_url() {
        let content = ChapterContent {
            chapter_id: "ch1".into(),
            content: "test content".into(),
            next_chapter_url: Some("https://next.example.com/ch2".into()),
            platform_request: None,
            image_style: None,
            image_decode: None,
            pay_action: None,
        };
        assert_eq!(content.content, "test content");
        assert_eq!(
            content.next_chapter_url,
            Some("https://next.example.com/ch2".into())
        );
    }

    #[tokio::test]
    async fn test_get_chapter_content_with_mock_server() {
        use httpmock::prelude::*;

        let server = MockServer::start();
        let html = r#"<html><body><div class="content">Chapter text here</div><a class="next" href="/ch2.html">Next</a></body></html>"#;

        let mock = server.mock(|when, then| {
            when.method(GET).path("/ch1.html");
            then.status(200)
                .header("Content-Type", "text/html; charset=utf-8")
                .body(html);
        });

        let source = BookSource {
            id: "test".into(),
            name: "Test Source".into(),
            url: server.base_url(),
            rule_content: Some(ContentRule {
                content: Some("div.content@text".into()),
                next_content_url: Some("a.next@href".into()),
                ..Default::default()
            }),
            source_type: 0,
            enabled: true,
            group_name: None,
            custom_order: 0,
            weight: 0,
            rule_search: None,
            rule_book_info: None,
            rule_toc: None,
            rule_review: None,
            login_url: None,
            login_ui: None,
            login_check_js: None,
            header: None,
            js_lib: None,
            cover_decode_js: None,
            explore_url: None,
            rule_explore: None,
            book_url_pattern: None,
            enabled_explore: false,
            last_update_time: 0,
            book_source_comment: None,
            concurrent_rate: None,
            variable_comment: None,
            explore_screen: None,
            created_at: 0,
            updated_at: 0,
        };

        let parser = BookSourceParser::new();
        let result = parser.get_chapter_content(&source, "/ch1.html").await;
        assert!(result.is_some(), "expected chapter content, got None");
        let chapter = result.unwrap();
        assert!(chapter.content.contains("Chapter text here"));
        assert!(chapter.next_chapter_url.is_some());
        assert_eq!(
            chapter.next_chapter_url.unwrap(),
            server.url("/ch2.html"),
            "next_chapter_url must be the fully normalized URL"
        );

        mock.assert();
    }

    #[tokio::test]
    async fn test_search_with_mock_server() {
        use httpmock::prelude::*;

        let server = MockServer::start();
        let html = r#"<html><body>
            <div class="book-item">
                <span class="book-title">Test Book</span>
                <span class="book-author">Test Author</span>
                <a href="/book/123">Read</a>
                <img class="book-cover" src="/covers/123.jpg" />
            </div>
            <div class="book-item">
                <span class="book-title">Second Book</span>
                <span class="book-author">Second Author</span>
                <a href="/book/456">Read</a>
                <img class="book-cover" src="/covers/456.jpg" />
            </div>
        </body></html>"#;

        let mock = server.mock(|when, then| {
            when.method(GET).path("/search");
            then.status(200)
                .header("Content-Type", "text/html; charset=utf-8")
                .body(html);
        });

        let source = BookSource {
            id: "test".into(),
            name: "Test Source".into(),
            url: server.base_url(),
            rule_search: Some(SearchRule {
                search_url: Some("/search?keyword={{keyword}}".into()),
                book_list: Some(".book-item".into()),
                name: Some(".book-title".into()),
                author: Some(".book-author".into()),
                book_url: Some("a@href".into()),
                cover_url: Some(".book-cover@src".into()),
                kind: None,
                last_chapter: None,
                ..Default::default()
            }),
            source_type: 0,
            enabled: true,
            group_name: None,
            custom_order: 0,
            weight: 0,
            rule_book_info: None,
            rule_toc: None,
            rule_content: None,
            rule_review: None,
            login_url: None,
            login_ui: None,
            login_check_js: None,
            header: None,
            js_lib: None,
            cover_decode_js: None,
            explore_url: None,
            rule_explore: None,
            book_url_pattern: None,
            enabled_explore: false,
            last_update_time: 0,
            book_source_comment: None,
            concurrent_rate: None,
            variable_comment: None,
            explore_screen: None,
            created_at: 0,
            updated_at: 0,
        };

        let parser = BookSourceParser::new();
        let results = parser.search(&source, "test").await;

        assert_eq!(
            results.len(),
            2,
            "expected 2 results, got {}",
            results.len()
        );
        assert_eq!(results[0].name, "Test Book");
        assert_eq!(results[0].author, "Test Author");
        assert_eq!(results[0].book_url, server.url("/book/123"));
        assert_eq!(results[0].cover_url, Some(server.url("/covers/123.jpg")));

        assert_eq!(results[1].name, "Second Book");
        assert_eq!(results[1].author, "Second Author");
        assert_eq!(results[1].book_url, server.url("/book/456"));
        assert_eq!(results[1].cover_url, Some(server.url("/covers/456.jpg")));

        mock.assert();
    }

    #[tokio::test]
    async fn test_search_field_url_template_is_resolved_without_selector_parse() {
        use httpmock::prelude::*;

        let server = MockServer::start();
        let mock = server.mock(|when, then| {
            when.method(GET).path("/api/search");
            then.status(200)
                .header("Content-Type", "application/json; charset=utf-8")
                .body(r#"{"data":[{"id":42,"name":"Template Book","thumb":"/covers/42.jpg"}]}"#);
        });

        let source = BookSource {
            id: "test".into(),
            name: "Test Source".into(),
            url: server.base_url(),
            rule_search: Some(SearchRule {
                search_url: Some("/api/search?q={{keyword}}".into()),
                book_list: Some("$.data[*]".into()),
                name: Some("$.name".into()),
                author: None,
                book_url: Some("https://example.test/book/{{$.id}}".into()),
                cover_url: Some("https://img.example.test{{$.thumb}}".into()),
                kind: None,
                last_chapter: None,
                ..Default::default()
            }),
            source_type: 0,
            enabled: true,
            group_name: None,
            custom_order: 0,
            weight: 0,
            rule_book_info: None,
            rule_toc: None,
            rule_content: None,
            rule_review: None,
            login_url: None,
            login_ui: None,
            login_check_js: None,
            header: None,
            js_lib: None,
            cover_decode_js: None,
            explore_url: None,
            rule_explore: None,
            book_url_pattern: None,
            enabled_explore: false,
            last_update_time: 0,
            book_source_comment: None,
            concurrent_rate: None,
            variable_comment: None,
            explore_screen: None,
            created_at: 0,
            updated_at: 0,
        };

        let parser = BookSourceParser::new();
        let results = parser.search(&source, "test").await;

        assert_eq!(results.len(), 1);
        assert_eq!(results[0].name, "Template Book");
        assert_eq!(results[0].book_url, "https://example.test/book/42");
        assert_eq!(
            results[0].cover_url,
            Some("https://img.example.test/covers/42.jpg".into())
        );
        mock.assert();
    }

    #[tokio::test]
    async fn test_search_jsonpath_array_context_is_expanded() {
        use httpmock::prelude::*;

        let server = MockServer::start();
        let mock = server.mock(|when, then| {
            when.method(GET).path("/api/search");
            then.status(200)
                .header("Content-Type", "application/json; charset=utf-8")
                .body(r#"{"data":{"items":[{"name":"One","id":1},{"name":"Two","id":2}]}}"#);
        });

        let source = BookSource {
            id: "test".into(),
            name: "Test Source".into(),
            url: server.base_url(),
            rule_search: Some(SearchRule {
                search_url: Some("/api/search?q={{keyword}}".into()),
                book_list: Some("$.data.items".into()),
                name: Some("$.name".into()),
                author: None,
                book_url: Some("https://example.test/book/{{$.id}}".into()),
                cover_url: None,
                kind: None,
                last_chapter: None,
                ..Default::default()
            }),
            source_type: 0,
            enabled: true,
            group_name: None,
            custom_order: 0,
            weight: 0,
            rule_book_info: None,
            rule_toc: None,
            rule_content: None,
            rule_review: None,
            login_url: None,
            login_ui: None,
            login_check_js: None,
            header: None,
            js_lib: None,
            cover_decode_js: None,
            explore_url: None,
            rule_explore: None,
            book_url_pattern: None,
            enabled_explore: false,
            last_update_time: 0,
            book_source_comment: None,
            concurrent_rate: None,
            variable_comment: None,
            explore_screen: None,
            created_at: 0,
            updated_at: 0,
        };

        let parser = BookSourceParser::new();
        let results = parser.search(&source, "test").await;

        assert_eq!(results.len(), 2);
        assert_eq!(results[0].name, "One");
        assert_eq!(results[0].book_url, "https://example.test/book/1");
        assert_eq!(results[1].name, "Two");
        assert_eq!(results[1].book_url, "https://example.test/book/2");
        mock.assert();
    }

    #[tokio::test]
    async fn test_get_book_info_with_kind_and_word_count() {
        use httpmock::prelude::*;

        let server = MockServer::start();
        let html = r#"<html><body>
            <h1 class="book-name">Test Novel</h1>
            <span class="book-author">Test Author</span>
            <span class="book-kind">都市</span>
            <span class="book-word-count">100万字</span>
        </body></html>"#;

        let mock = server.mock(|when, then| {
            when.method(GET).path("/book/789");
            then.status(200)
                .header("Content-Type", "text/html; charset=utf-8")
                .body(html);
        });

        let source = BookSource {
            id: "test".into(),
            name: "Test Source".into(),
            url: server.base_url(),
            rule_book_info: Some(BookInfoRule {
                name: Some(".book-name@text".into()),
                author: Some(".book-author@text".into()),
                kind: Some(".book-kind@text".into()),
                word_count: Some(".book-word-count@text".into()),
                intro: None,
                cover_url: None,
                last_chapter: None,
                ..Default::default()
            }),
            source_type: 0,
            enabled: true,
            group_name: None,
            custom_order: 0,
            weight: 0,
            rule_search: None,
            rule_toc: None,
            rule_content: None,
            rule_review: None,
            login_url: None,
            login_ui: None,
            login_check_js: None,
            header: None,
            js_lib: None,
            cover_decode_js: None,
            explore_url: None,
            rule_explore: None,
            book_url_pattern: None,
            enabled_explore: false,
            last_update_time: 0,
            book_source_comment: None,
            concurrent_rate: None,
            variable_comment: None,
            explore_screen: None,
            created_at: 0,
            updated_at: 0,
        };

        let parser = BookSourceParser::new();
        let result = parser.get_book_info(&source, "/book/789").await;
        assert!(result.is_some(), "expected book detail, got None");
        let detail = result.unwrap();
        assert_eq!(detail.name, "Test Novel");
        assert_eq!(detail.author, "Test Author");
        assert_eq!(detail.kind.as_deref(), Some("都市"));
        assert_eq!(detail.word_count.as_deref(), Some("100万字"));

        mock.assert();
    }

    #[tokio::test]
    async fn test_search_uses_legado_url_option_js_and_source_header() {
        use httpmock::prelude::*;

        let server = MockServer::start();
        let html = r#"<html><body>
            <div class="book-item"><span class="book-title">Changed Book</span><a href="/book/changed">Read</a></div>
        </body></html>"#;

        let mock = server.mock(|when, then| {
            when.method(GET)
                .path("/changed")
                .header("X-Source", "source-ok")
                .header("X-Option", "option-ok");
            then.status(200)
                .header("Content-Type", "text/html; charset=utf-8")
                .body(html);
        });

        let source = BookSource {
            id: "test".into(),
            name: "Test Source".into(),
            url: server.base_url(),
            rule_search: Some(SearchRule {
                search_url: Some(format!(
                    "/original, {{\"js\": \"java.url = '{}'; java.headerMap.put('X-Option', 'option-ok')\"}}",
                    server.url("/changed")
                )),
                book_list: Some(".book-item".into()),
                name: Some(".book-title@text".into()),
                author: None,
                book_url: Some("a@href".into()),
                cover_url: None,
                kind: None,
                last_chapter: None,
                ..Default::default()
            }),
            source_type: 0,
            enabled: true,
            group_name: None,
            custom_order: 0,
            weight: 0,
            rule_book_info: None,
            rule_toc: None,
            rule_content: None,
            rule_review: None,
            login_url: None,
            login_ui: None,
            login_check_js: None,
            header: Some(r#"{"X-Source":"source-ok"}"#.into()),
            js_lib: None,
            cover_decode_js: None,
            explore_url: None,
            rule_explore: None,
            book_url_pattern: None,
            enabled_explore: false,
            last_update_time: 0,
            book_source_comment: None,
            concurrent_rate: None,
            variable_comment: None,
            explore_screen: None,
            created_at: 0,
            updated_at: 0,
        };

        let parser = BookSourceParser::new();
        let results = parser.search(&source, "test").await;

        assert_eq!(results.len(), 1);
        assert_eq!(results[0].name, "Changed Book");
        assert_eq!(results[0].book_url, server.url("/book/changed"));
        mock.assert();
    }

    #[tokio::test]
    async fn test_get_chapters_uses_generic_js_rule_result() {
        use crate::types::TocRule;
        use httpmock::prelude::*;

        let server = MockServer::start();
        let mock = server.mock(|when, then| {
            when.method(GET).path("/book/1");
            then.status(200)
                .header("Content-Type", "text/html; charset=utf-8")
                .body("<html></html>");
        });

        let source = BookSource {
            id: "test".into(),
            name: "Test Source".into(),
            url: server.base_url(),
            rule_toc: Some(TocRule {
                chapter_list: Some(
                    r#"@js:
                    var chapters = [
                        {"title":"Chapter A","url":"/a.html"},
                        {"title":"Chapter B","url":"/b.html"}
                    ];
                    chapters;
                "#
                    .into(),
                ),
                chapter_name: Some("title".into()),
                chapter_url: Some("url".into()),
                ..Default::default()
            }),
            source_type: 0,
            enabled: true,
            group_name: None,
            custom_order: 0,
            weight: 0,
            rule_search: None,
            rule_book_info: None,
            rule_content: None,
            rule_review: None,
            login_url: None,
            login_ui: None,
            login_check_js: None,
            header: None,
            js_lib: None,
            cover_decode_js: None,
            explore_url: None,
            rule_explore: None,
            book_url_pattern: None,
            enabled_explore: false,
            last_update_time: 0,
            book_source_comment: None,
            concurrent_rate: None,
            variable_comment: None,
            explore_screen: None,
            created_at: 0,
            updated_at: 0,
        };

        let parser = BookSourceParser::new();
        let chapters = parser.get_chapters(&source, "/book/1").await;

        assert_eq!(chapters.len(), 2);
        assert_eq!(chapters[0].title, "Chapter A");
        assert_eq!(chapters[0].url, server.url("/a.html"));
        assert_eq!(chapters[1].title, "Chapter B");
        assert_eq!(chapters[1].url, server.url("/b.html"));
        mock.assert();
    }

    #[tokio::test]
    async fn test_get_content_uses_generic_js_rule() {
        use httpmock::prelude::*;

        let server = MockServer::start();
        let mock = server.mock(|when, then| {
            when.method(GET).path("/chapter/1");
            then.status(200)
                .header("Content-Type", "text/html; charset=utf-8")
                .body("<html><body><p>Raw</p></body></html>");
        });

        let source = BookSource {
            id: "test".into(),
            name: "Test Source".into(),
            url: server.base_url(),
            rule_content: Some(ContentRule {
                content: Some("@js:\nvar text = 'Generic JS Content';\ntext;".into()),
                next_content_url: None,
                ..Default::default()
            }),
            source_type: 0,
            enabled: true,
            group_name: None,
            custom_order: 0,
            weight: 0,
            rule_search: None,
            rule_book_info: None,
            rule_toc: None,
            rule_review: None,
            login_url: None,
            login_ui: None,
            login_check_js: None,
            header: None,
            js_lib: None,
            cover_decode_js: None,
            explore_url: None,
            rule_explore: None,
            book_url_pattern: None,
            enabled_explore: false,
            last_update_time: 0,
            book_source_comment: None,
            concurrent_rate: None,
            variable_comment: None,
            explore_screen: None,
            created_at: 0,
            updated_at: 0,
        };

        let parser = BookSourceParser::new();
        let content = parser
            .get_chapter_content(&source, "/chapter/1")
            .await
            .unwrap();

        assert_eq!(content.content, "Generic JS Content");
        mock.assert();
    }

    #[tokio::test]
    async fn test_get_chapters_generic_js_rule_can_use_java_post() {
        use crate::types::TocRule;
        use httpmock::prelude::*;

        let server = MockServer::start();
        let page_mock = server.mock(|when, then| {
            when.method(GET).path("/read/123/");
            then.status(200).body("<html></html>");
        });
        let api_mock = server.mock(|when, then| {
            when.method(POST).path("/novel/clist/").body("bid=123");
            then.status(200)
                .header("Content-Type", "application/json")
                .body(r#"{"data":[{"title":"Remote A","url":"/ra.html"},{"title":"Remote B","url":"/rb.html"}]}"#);
        });

        let source = BookSource {
            id: "test".into(),
            name: "Test Source".into(),
            url: server.base_url(),
            rule_toc: Some(TocRule {
                chapter_list: Some(
                    r#"@js:
                    var bid = baseUrl.match(/read\/(\d+)/)[1];
                    var resp = java.post(source.getKey() + "/novel/clist/", "bid=" + bid, {});
                    JSON.parse(resp.body()).data;
                "#
                    .into(),
                ),
                chapter_name: Some("title".into()),
                chapter_url: Some("url".into()),
                ..Default::default()
            }),
            source_type: 0,
            enabled: true,
            group_name: None,
            custom_order: 0,
            weight: 0,
            rule_search: None,
            rule_book_info: None,
            rule_content: None,
            rule_review: None,
            login_url: None,
            login_ui: None,
            login_check_js: None,
            header: None,
            js_lib: None,
            cover_decode_js: None,
            explore_url: None,
            rule_explore: None,
            book_url_pattern: None,
            enabled_explore: false,
            last_update_time: 0,
            book_source_comment: None,
            concurrent_rate: None,
            variable_comment: None,
            explore_screen: None,
            created_at: 0,
            updated_at: 0,
        };

        let parser = BookSourceParser::new();
        let chapters = parser.get_chapters(&source, "/read/123/").await;

        assert_eq!(chapters.len(), 2);
        assert_eq!(chapters[0].title, "Remote A");
        assert_eq!(chapters[0].url, server.url("/ra.html"));
        assert_eq!(chapters[1].title, "Remote B");
        assert_eq!(chapters[1].url, server.url("/rb.html"));
        page_mock.assert();
        api_mock.assert();
    }

    #[tokio::test]
    async fn test_get_content_generic_js_rule_can_use_java_ajax() {
        use httpmock::prelude::*;

        let server = MockServer::start();
        let page_mock = server.mock(|when, then| {
            when.method(GET).path("/chapter/2");
            then.status(200)
                .header("Content-Type", "text/html; charset=utf-8")
                .body("<html><script>var token = \"abc\";</script></html>");
        });
        let ajax_mock = server.mock(|when, then| {
            when.method(GET)
                .path("/ajax")
                .query_param("challenge", "abc");
            then.status(200)
                .header("Content-Type", "text/html; charset=utf-8")
                .body("<section><p>Ajax Content</p></section>");
        });

        let source = BookSource {
            id: "test".into(),
            name: "Test Source".into(),
            url: server.base_url(),
            rule_content: Some(ContentRule {
                content: Some(r#"@js:
                    var token = src.match(/token\s*=\s*"([^"]+)"/)[1];
                    var text = java.ajax(source.getKey() + "/ajax?challenge=" + encodeURIComponent(token));
                    text.match(/<p>(.*?)<\/p>/)[1];
                "#.into()),
                next_content_url: None,
                ..Default::default()
            }),
            source_type: 0,
            enabled: true,
            group_name: None,
            custom_order: 0,
            weight: 0,
            rule_search: None,
            rule_book_info: None,
            rule_toc: None,
            rule_review: None,
            login_url: None,
            login_ui: None,
            login_check_js: None,
            header: None,
            js_lib: None,
            cover_decode_js: None,
            explore_url: None,
            rule_explore: None,
            book_url_pattern: None,
            enabled_explore: false,
            last_update_time: 0,
            book_source_comment: None,
            concurrent_rate: None,
            variable_comment: None,
            explore_screen: None,
            created_at: 0,
            updated_at: 0,
        };

        let parser = BookSourceParser::new();
        let content = parser
            .get_chapter_content(&source, "/chapter/2")
            .await
            .unwrap();

        assert_eq!(content.content, "Ajax Content");
        page_mock.assert();
        ajax_mock.assert();
    }

    #[tokio::test]
    #[ignore = "FIXME: get_chapter_content returns None when @js content rule \
                calls java.getCookie before any prior request populated the \
                cookie jar; needs investigation. Tracked in CURRENT_STATUS."]
    async fn test_generic_js_rule_shares_parser_cookie_jar() {
        use httpmock::prelude::*;

        let server = MockServer::start();
        let page_mock = server.mock(|when, then| {
            when.method(GET).path("/chapter/cookie");
            then.status(200)
                .header("Content-Type", "text/html; charset=utf-8")
                .header("Set-Cookie", "sid=parser-cookie; Path=/")
                .body("<html></html>");
        });

        let source = BookSource {
            id: "test".into(),
            name: "Test Source".into(),
            url: server.base_url(),
            rule_content: Some(ContentRule {
                content: Some("@js: java.getCookie(baseUrl, 'sid');".into()),
                next_content_url: None,
                ..Default::default()
            }),
            source_type: 0,
            enabled: true,
            group_name: None,
            custom_order: 0,
            weight: 0,
            rule_search: None,
            rule_book_info: None,
            rule_toc: None,
            rule_review: None,
            login_url: None,
            login_ui: None,
            login_check_js: None,
            header: None,
            js_lib: None,
            cover_decode_js: None,
            explore_url: None,
            rule_explore: None,
            book_url_pattern: None,
            enabled_explore: false,
            last_update_time: 0,
            book_source_comment: None,
            concurrent_rate: None,
            variable_comment: None,
            explore_screen: None,
            created_at: 0,
            updated_at: 0,
        };

        let parser = BookSourceParser::new();
        let content = parser
            .get_chapter_content(&source, "/chapter/cookie")
            .await
            .unwrap();

        assert_eq!(content.content, "parser-cookie");
        page_mock.assert();
    }

    #[tokio::test]
    async fn test_generic_js_ajax_inherits_source_header() {
        use httpmock::prelude::*;

        let server = MockServer::start();
        let page_mock = server.mock(|when, then| {
            when.method(GET).path("/chapter/header");
            then.status(200).body("<html></html>");
        });
        let ajax_mock = server.mock(|when, then| {
            when.method(GET)
                .path("/needs-header")
                .header("X-Source", "source-ok");
            then.status(200).body("header-ok");
        });

        let source = BookSource {
            id: "test".into(),
            name: "Test Source".into(),
            url: server.base_url(),
            rule_content: Some(ContentRule {
                content: Some("@js: java.ajax(source.getKey() + '/needs-header');".into()),
                next_content_url: None,
                ..Default::default()
            }),
            source_type: 0,
            enabled: true,
            group_name: None,
            custom_order: 0,
            weight: 0,
            rule_search: None,
            rule_book_info: None,
            rule_toc: None,
            rule_review: None,
            login_url: None,
            login_ui: None,
            login_check_js: None,
            header: Some(r#"{"X-Source":"source-ok"}"#.into()),
            js_lib: None,
            cover_decode_js: None,
            explore_url: None,
            rule_explore: None,
            book_url_pattern: None,
            enabled_explore: false,
            last_update_time: 0,
            book_source_comment: None,
            concurrent_rate: None,
            variable_comment: None,
            explore_screen: None,
            created_at: 0,
            updated_at: 0,
        };

        let parser = BookSourceParser::new();
        let content = parser
            .get_chapter_content(&source, "/chapter/header")
            .await
            .unwrap();

        assert_eq!(content.content, "header-ok");
        page_mock.assert();
        ajax_mock.assert();
    }

    #[tokio::test]
    async fn test_generic_js_explicit_header_overrides_source_header() {
        use httpmock::prelude::*;

        let server = MockServer::start();
        let page_mock = server.mock(|when, then| {
            when.method(GET).path("/chapter/override");
            then.status(200).body("<html></html>");
        });
        let ajax_mock = server.mock(|when, then| {
            when.method(GET)
                .path("/override-header")
                .header("X-Source", "explicit-ok");
            then.status(200).body("override-ok");
        });

        let source = BookSource {
            id: "test".into(),
            name: "Test Source".into(),
            url: server.base_url(),
            rule_content: Some(ContentRule {
                content: Some("@js: java.get(source.getKey() + '/override-header', {'X-Source':'explicit-ok'}).body();".into()),
                next_content_url: None,
                ..Default::default()
            }),
            source_type: 0,
            enabled: true,
            group_name: None,
            custom_order: 0,
            weight: 0,
            rule_search: None,
            rule_book_info: None,
            rule_toc: None,
            rule_review: None,
            login_url: None,
            login_ui: None,
            login_check_js: None,
            header: Some(r#"{"X-Source":"source-default"}"#.into()),
            js_lib: None,
            cover_decode_js: None,
            explore_url: None,
            rule_explore: None,
            book_url_pattern: None,
            enabled_explore: false,
            last_update_time: 0,
            book_source_comment: None,
            concurrent_rate: None,
            variable_comment: None,
            explore_screen: None,
            created_at: 0,
            updated_at: 0,
        };

        let parser = BookSourceParser::new();
        let content = parser
            .get_chapter_content(&source, "/chapter/override")
            .await
            .unwrap();

        assert_eq!(content.content, "override-ok");
        page_mock.assert();
        ajax_mock.assert();
    }

    #[tokio::test]
    async fn test_book_info_init_js_returns_object() {
        use crate::types::BookInfoRule;
        use httpmock::prelude::*;

        let server = MockServer::start();
        let mock = server.mock(|when, then| {
            when.method(GET).path("/book/init");
            then.status(200)
                .header("Content-Type", "text/html; charset=utf-8")
                .body("<html></html>");
        });

        let source = BookSource {
            id: "test".into(),
            name: "Test Source".into(),
            url: server.base_url(),
            rule_book_info: Some(BookInfoRule {
                book_info_init: Some(
                    "@js:\nreturn {a:'Init Name',b:'Init Author',h:'/toc/list.html'}".into(),
                ),
                name: Some("a".into()),
                author: Some("b".into()),
                toc_url: Some("h".into()),
                ..Default::default()
            }),
            source_type: 0,
            enabled: true,
            group_name: None,
            custom_order: 0,
            weight: 0,
            rule_search: None,
            rule_toc: None,
            rule_content: None,
            rule_review: None,
            login_url: None,
            login_ui: None,
            login_check_js: None,
            header: None,
            js_lib: None,
            cover_decode_js: None,
            explore_url: None,
            rule_explore: None,
            book_url_pattern: None,
            enabled_explore: false,
            last_update_time: 0,
            book_source_comment: None,
            concurrent_rate: None,
            variable_comment: None,
            explore_screen: None,
            created_at: 0,
            updated_at: 0,
        };

        let parser = BookSourceParser::new();
        let detail = parser.get_book_info(&source, "/book/init").await.unwrap();

        assert_eq!(detail.name, "Init Name");
        assert_eq!(detail.author, "Init Author");
        assert_eq!(detail.chapters_url, Some(server.url("/toc/list.html")));
        mock.assert();
    }

    #[tokio::test]
    async fn test_book_info_toc_url_selector() {
        use crate::types::BookInfoRule;
        use httpmock::prelude::*;

        let server = MockServer::start();
        let mock = server.mock(|when, then| {
            when.method(GET).path("/book/toc");
            then.status(200)
                .header("Content-Type", "text/html; charset=utf-8")
                .body(r#"<html><a class="read" href="/read/list">Read</a></html>"#);
        });

        let source = BookSource {
            id: "test".into(),
            name: "Test Source".into(),
            url: server.base_url(),
            rule_book_info: Some(BookInfoRule {
                name: Some("tag.h1@text".into()),
                author: Some("tag.h2@text".into()),
                toc_url: Some("a.read@href".into()),
                ..Default::default()
            }),
            source_type: 0,
            enabled: true,
            group_name: None,
            custom_order: 0,
            weight: 0,
            rule_search: None,
            rule_toc: None,
            rule_content: None,
            rule_review: None,
            login_url: None,
            login_ui: None,
            login_check_js: None,
            header: None,
            js_lib: None,
            cover_decode_js: None,
            explore_url: None,
            rule_explore: None,
            book_url_pattern: None,
            enabled_explore: false,
            last_update_time: 0,
            book_source_comment: None,
            concurrent_rate: None,
            variable_comment: None,
            explore_screen: None,
            created_at: 0,
            updated_at: 0,
        };

        let parser = BookSourceParser::new();
        let detail = parser.get_book_info(&source, "/book/toc").await.unwrap();

        assert_eq!(detail.chapters_url, Some(server.url("/read/list")));
        mock.assert();
    }

    #[tokio::test]
    async fn test_book_info_init_all_in_one_regex() {
        use crate::types::BookInfoRule;
        use httpmock::prelude::*;

        let server = MockServer::start();
        let mock = server.mock(|when, then| {
            when.method(GET).path("/book/regex");
            then.status(200)
                .header("Content-Type", "text/html; charset=utf-8")
                .body(r#"<html><meta property="name" content="Regex Name"><meta property="author" content="Regex Author"></html>"#);
        });

        let source = BookSource {
            id: "test".into(),
            name: "Test Source".into(),
            url: server.base_url(),
            rule_book_info: Some(BookInfoRule {
                book_info_init: Some(
                    r#"@js:
    return {a:'Regex Name',b:'Regex Author'}
"#
                    .into(),
                ),
                name: Some("a".into()),
                author: Some("b".into()),
                ..Default::default()
            }),
            source_type: 0,
            enabled: true,
            group_name: None,
            custom_order: 0,
            weight: 0,
            rule_search: None,
            rule_toc: None,
            rule_content: None,
            rule_review: None,
            login_url: None,
            login_ui: None,
            login_check_js: None,
            header: None,
            js_lib: None,
            cover_decode_js: None,
            explore_url: None,
            rule_explore: None,
            book_url_pattern: None,
            enabled_explore: false,
            last_update_time: 0,
            book_source_comment: None,
            concurrent_rate: None,
            variable_comment: None,
            explore_screen: None,
            created_at: 0,
            updated_at: 0,
        };

        let parser = BookSourceParser::new();
        let detail = parser.get_book_info(&source, "/book/regex").await.unwrap();

        assert_eq!(detail.name, "Regex Name");
        assert_eq!(detail.author, "Regex Author");
        mock.assert();
    }

    #[tokio::test]
    async fn test_get_chapters_multi_page_via_next_toc_url() {
        use crate::types::TocRule;
        use httpmock::prelude::*;

        let server = MockServer::start();
        let page1_mock = server.mock(|when, then| {
            when.method(GET).path("/toc/page1");
            then.status(200)
                .header("Content-Type", "text/html; charset=utf-8")
                .body(r#"<html><ul class="chapters"><li><a href="/ch1">Ch1</a></li><li><a href="/ch2">Ch2</a></li></ul><a class="next" href="/toc/page2">Next</a></html>"#);
        });
        let page2_mock = server.mock(|when, then| {
            when.method(GET).path("/toc/page2");
            then.status(200)
                .header("Content-Type", "text/html; charset=utf-8")
                .body(r#"<html><ul class="chapters"><li><a href="/ch3">Ch3</a></li><li><a href="/ch4">Ch4</a></li></ul></html>"#);
        });

        let source = BookSource {
            id: "test".into(),
            name: "Test Source".into(),
            url: server.base_url(),
            rule_toc: Some(TocRule {
                chapter_list: Some("ul.chapters@li".into()),
                chapter_name: Some("a@text".into()),
                chapter_url: Some("a@href".into()),
                next_toc_url: Some("a.next@href".into()),
                ..Default::default()
            }),
            source_type: 0,
            enabled: true,
            group_name: None,
            custom_order: 0,
            weight: 0,
            rule_search: None,
            rule_book_info: None,
            rule_content: None,
            rule_review: None,
            login_url: None,
            login_ui: None,
            login_check_js: None,
            header: None,
            js_lib: None,
            cover_decode_js: None,
            explore_url: None,
            rule_explore: None,
            book_url_pattern: None,
            enabled_explore: false,
            last_update_time: 0,
            book_source_comment: None,
            concurrent_rate: None,
            variable_comment: None,
            explore_screen: None,
            created_at: 0,
            updated_at: 0,
        };

        let parser = BookSourceParser::new();
        let chapters = parser.get_chapters(&source, "/toc/page1").await;

        assert_eq!(chapters.len(), 4, "expected 4 chapters across 2 pages");
        assert_eq!(chapters[0].title, "Ch1");
        assert_eq!(chapters[0].url, server.url("/ch1"));
        assert_eq!(chapters[1].title, "Ch2");
        assert_eq!(chapters[1].url, server.url("/ch2"));
        assert_eq!(chapters[2].title, "Ch3");
        assert_eq!(chapters[2].url, server.url("/ch3"));
        assert_eq!(chapters[3].title, "Ch4");
        assert_eq!(chapters[3].url, server.url("/ch4"));
        page1_mock.assert();
        page2_mock.assert();
    }

    #[tokio::test]
    async fn test_content_pagination_multi_page() {
        use crate::types::ContentRule;
        use httpmock::prelude::*;

        let server = MockServer::start();
        let page1_mock = server.mock(|when, then| {
            when.method(GET).path("/ch/page1");
            then.status(200)
                .header("Content-Type", "text/html; charset=utf-8")
                .body(r#"<html><div class="content">Page 1 content</div><a class="next-page" href="/ch/page2">Next</a></html>"#);
        });
        let page2_mock = server.mock(|when, then| {
            when.method(GET).path("/ch/page2");
            then.status(200)
                .header("Content-Type", "text/html; charset=utf-8")
                .body(r#"<html><div class="content">Page 2 content</div></html>"#);
        });

        let source = BookSource {
            id: "test".into(),
            name: "Test Source".into(),
            url: server.base_url(),
            rule_content: Some(ContentRule {
                content: Some("div.content@text".into()),
                next_content_url: Some("a.next-page@href".into()),
                ..Default::default()
            }),
            source_type: 0,
            enabled: true,
            group_name: None,
            custom_order: 0,
            weight: 0,
            rule_search: None,
            rule_book_info: None,
            rule_toc: None,
            rule_review: None,
            login_url: None,
            login_ui: None,
            login_check_js: None,
            header: None,
            js_lib: None,
            cover_decode_js: None,
            explore_url: None,
            rule_explore: None,
            book_url_pattern: None,
            enabled_explore: false,
            last_update_time: 0,
            book_source_comment: None,
            concurrent_rate: None,
            variable_comment: None,
            explore_screen: None,
            created_at: 0,
            updated_at: 0,
        };

        let parser = BookSourceParser::new();
        let result = parser.get_chapter_content(&source, "/ch/page1").await;
        assert!(result.is_some(), "expected chapter content, got None");
        let chapter = result.unwrap();
        assert!(
            chapter.content.contains("Page 1 content"),
            "should contain page 1"
        );
        assert!(
            chapter.content.contains("Page 2 content"),
            "should contain page 2"
        );
        assert!(
            chapter.content.contains("\n"),
            "pages should be separated by newline"
        );
        assert!(
            chapter.next_chapter_url.is_none(),
            "no next chapter when pagination ends"
        );
        page1_mock.assert();
        page2_mock.assert();
    }

    #[tokio::test]
    async fn test_book_info_toc_url_template_resolution() {
        use crate::types::BookInfoRule;
        use httpmock::prelude::*;

        let server = MockServer::start();
        let mock = server.mock(|when, then| {
            when.method(GET).path("/book/template");
            then.status(200)
                .header("Content-Type", "text/html; charset=utf-8")
                .body(r#"<html><a class="toc-link" href="/read/list">目录</a><div class="title">Test Book</div><span class="author">Author Name</span></html>"#);
        });

        let source = BookSource {
            id: "test".into(),
            name: "Test Source".into(),
            url: server.base_url(),
            rule_book_info: Some(BookInfoRule {
                name: Some("@css:.title@text".into()),
                author: Some("@css:.author@text".into()),
                toc_url: Some("{{@css:a.toc-link@href}}".into()),
                ..Default::default()
            }),
            source_type: 0,
            enabled: true,
            group_name: None,
            custom_order: 0,
            weight: 0,
            rule_search: None,
            rule_toc: None,
            rule_content: None,
            rule_review: None,
            login_url: None,
            login_ui: None,
            login_check_js: None,
            header: None,
            js_lib: None,
            cover_decode_js: None,
            explore_url: None,
            rule_explore: None,
            book_url_pattern: None,
            enabled_explore: false,
            last_update_time: 0,
            book_source_comment: None,
            concurrent_rate: None,
            variable_comment: None,
            explore_screen: None,
            created_at: 0,
            updated_at: 0,
        };

        let parser = BookSourceParser::new();
        let detail = parser
            .get_book_info(&source, "/book/template")
            .await
            .unwrap();

        assert_eq!(detail.name, "Test Book");
        assert_eq!(detail.author, "Author Name");
        assert_eq!(detail.chapters_url, Some(server.url("/read/list")));
        mock.assert();
    }

    #[tokio::test]
    async fn test_explore_json_array_format() {
        use httpmock::prelude::*;

        let server = MockServer::start();
        let mock = server.mock(|when, then| {
            when.method(GET).path("/explore/json");
            then.status(200)
                .header("Content-Type", "application/json")
                .body(r#"[{"title":"Book 1","url":"/book/1","author":"A1"},{"title":"Book 2","url":"/book/2","cover":"/img/2.jpg"}]"#);
        });

        let source = BookSource {
            id: "test".into(),
            name: "Test Source".into(),
            url: server.base_url(),
            source_type: 0,
            enabled: true,
            group_name: None,
            custom_order: 0,
            weight: 0,
            rule_search: None,
            rule_book_info: None,
            rule_toc: None,
            rule_content: None,
            rule_review: None,
            login_url: None,
            login_ui: None,
            login_check_js: None,
            header: None,
            js_lib: None,
            cover_decode_js: None,
            explore_url: None,
            rule_explore: None,
            book_url_pattern: None,
            enabled_explore: false,
            last_update_time: 0,
            book_source_comment: None,
            concurrent_rate: None,
            variable_comment: None,
            explore_screen: None,
            created_at: 0,
            updated_at: 0,
        };

        let parser = BookSourceParser::new();
        let results = parser.explore(&source, "/explore/json", 1).await;

        assert_eq!(results.len(), 2);
        assert_eq!(results[0].name, "Book 1");
        assert_eq!(results[0].book_url, server.url("/book/1"));
        assert_eq!(results[0].author, "A1");
        assert_eq!(results[1].name, "Book 2");
        assert_eq!(results[1].book_url, server.url("/book/2"));
        assert_eq!(results[1].cover_url, Some(server.url("/img/2.jpg")));
        mock.assert();
    }

    #[tokio::test]
    async fn test_explore_title_url_text_format() {
        use httpmock::prelude::*;

        let server = MockServer::start();
        let mock = server.mock(|when, then| {
            when.method(GET).path("/explore/text");
            then.status(200)
                .header("Content-Type", "text/plain")
                .body("Category A::/cat/a\nCategory B::/cat/b");
        });

        let source = BookSource {
            id: "test".into(),
            name: "Test Source".into(),
            url: server.base_url(),
            source_type: 0,
            enabled: true,
            group_name: None,
            custom_order: 0,
            weight: 0,
            rule_search: None,
            rule_book_info: None,
            rule_toc: None,
            rule_content: None,
            rule_review: None,
            login_url: None,
            login_ui: None,
            login_check_js: None,
            header: None,
            js_lib: None,
            cover_decode_js: None,
            explore_url: None,
            rule_explore: None,
            book_url_pattern: None,
            enabled_explore: false,
            last_update_time: 0,
            book_source_comment: None,
            concurrent_rate: None,
            variable_comment: None,
            explore_screen: None,
            created_at: 0,
            updated_at: 0,
        };

        let parser = BookSourceParser::new();
        let results = parser.explore(&source, "/explore/text", 1).await;

        assert_eq!(results.len(), 2);
        assert_eq!(results[0].name, "Category A");
        assert_eq!(results[0].book_url, server.url("/cat/a"));
        assert_eq!(results[1].name, "Category B");
        assert_eq!(results[1].book_url, server.url("/cat/b"));
        mock.assert();
    }

    #[tokio::test]
    async fn test_explore_with_rule_explore() {
        use crate::types::SearchRule;
        use httpmock::prelude::*;

        let server = MockServer::start();
        let mock = server.mock(|when, then| {
            when.method(GET).path("/explore/rule");
            then.status(200)
                .header("Content-Type", "text/html; charset=utf-8")
                .body(r#"<html><ul><li class="item"><a href="/book/r1">Rule Book 1</a></li><li class="item"><a href="/book/r2">Rule Book 2</a></li></ul></html>"#);
        });

        let source = BookSource {
            id: "test".into(),
            name: "Test Source".into(),
            url: server.base_url(),
            source_type: 0,
            enabled: true,
            group_name: None,
            custom_order: 0,
            weight: 0,
            rule_search: None,
            rule_book_info: None,
            rule_toc: None,
            rule_content: None,
            rule_review: None,
            login_url: None,
            login_ui: None,
            login_check_js: None,
            header: None,
            js_lib: None,
            cover_decode_js: None,
            explore_url: None,
            rule_explore: Some(SearchRule {
                book_list: Some("li.item".into()),
                name: Some("a@text".into()),
                book_url: Some("a@href".into()),
                ..Default::default()
            }),
            book_url_pattern: None,
            enabled_explore: false,
            last_update_time: 0,
            book_source_comment: None,
            concurrent_rate: None,
            variable_comment: None,
            explore_screen: None,
            created_at: 0,
            updated_at: 0,
        };

        let parser = BookSourceParser::new();
        let results = parser.explore(&source, "/explore/rule", 1).await;

        assert_eq!(results.len(), 2);
        assert_eq!(results[0].name, "Rule Book 1");
        assert_eq!(results[0].book_url, server.url("/book/r1"));
        assert_eq!(results[1].name, "Rule Book 2");
        assert_eq!(results[1].book_url, server.url("/book/r2"));
        mock.assert();
    }
}
