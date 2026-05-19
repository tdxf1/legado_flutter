# RSS 拉取 + 文章列表 (批次 17)

## Goal

阶段 4 第二批：在 schema v12（批次 16）的基础上，实现 RSS 文章 **拉取（XML / 规则双路）+ 解析 + 列表 UI**。让用户从批次 16 已导入的 RSS 源点进去看到文章 Tab + 文章列表 + 已读标记。

阶段 4 全 3 批：
- 批次 16（done）：源管理 + schema v12（骨架）
- 批次 17（**本批**）：拉取 + 解析 + 文章列表（默认 layout）
- 批次 18：文章详情 WebView + 收藏

## What I already know

### Rust 端现状
- `core/core-source/Cargo.toml` 已含 `quick-xml = "0.37" (serialize)` — 未用过，本批次首启
- `scraper` + 自家 JSOUP-style 规则引擎已就绪（`legado/rule.rs` / `legado/selector.rs`） — RSS 规则路（按规则解析）可复用
- `BookSourceParser` 是异步 reqwest 风格（`parser.rs::search/explore/get_book_info/get_chapters/get_chapter_content`）— RSS 解析器沿袭这个风格新建 `RssParser`
- `core-net/client.rs` 提供共享 reqwest client（含 cookie / proxy / retry）— RSS 网络请求复用
- DB schema v12（批次 16）已有 4 张表：rss_sources / rss_articles / rss_stars / rss_read_records；所以本批次**不动 schema**

### 原 Legado 参考（`feature-gap-rss-manga-audio-misc.md` §1.7 / §1.3）
- `model/rss/Rss.kt`（102 行）入口：`getArticles(source, sortName, sortUrl, page) -> List<RssArticle>`
- `RssParserDefault.kt`（149 行）— 标准 RSS 2.0 / Atom XML 解析（XmlPullParser）
- `RssParserByRule.kt`（131 行）— 按规则解析（AnalyzeUrl + AnalyzeRule，与 BookSource 同一套）
- 通过 `singleUrl`（DB v12 已建字段）区分单 URL 模式 / 多分类模式
- RssArticle 字段（10）：origin / sort / title / pubDate(String) / link / image / description / variable / order / read_time / star — 与 v12 表对齐
- 默认 layout style=0 的文章列表：标题 + pubDate + 短描述 + 缩略图（128px）
- 已读 = `rssReadRecords.link == article.link AND read_time > 0`

### Flutter 端现状
- 批次 16 已有 `lib/features/rss/rss_source_manage_page.dart` — 源管理页
- 路由 `/rss-source-manage` 已注册
- 入口在 bookshelf AppBar PopupMenu

### FRB 现状
- bridge funcId 已用到 90（批次 16 RSS 源管理 9 个 fn）
- 本批次新增 funcId 91 起

## Decision

**MVP 范围 — 拉取 + 文章列表 + 已读，不含详情页 / 收藏 / 自定义 layout 1/2 / 分页 next_page**：

### Rust 端

1. **新增 `core/core-source/src/rss/mod.rs`**（含子模块 `parse_xml.rs` / `parse_rule.rs`）
   - `pub struct RssParser { client: reqwest::Client }`（沿袭 `BookSourceParser` 模式）
   - `pub async fn get_articles(&self, source: &RssSource, sort_name: &str, sort_url: &str, page: i32) -> Result<Vec<RssArticle>, ParserError>`
     - 路由：若 `source.rule_articles` 为空且 url 看起来像 RSS XML（`<rss>` / `<feed>` 开头）→ XML 路；否则规则路
     - 失败时降级 — XML 解析失败回退试规则路
   - `pub async fn fetch_article_content_full(&self, source: &RssSource, article: &RssArticle) -> Result<String, ParserError>` — 仅占位（批次 18 用）
   - **错误类型**：复用 `ParserError`（`core-source::lib.rs` 已定义 Network/Empty/Parse/RuleConfig）

2. **`core/core-source/src/rss/parse_xml.rs`** — quick-xml 解析 RSS 2.0 + Atom：
   - `parse_rss20(xml: &str, origin: &str, sort: &str) -> Vec<RssArticle>`
     - `<channel>/<item>` 列表；每 item 提取 `<title>/<link>/<description>/<pubDate>/<enclosure url=>(image)`
   - `parse_atom(xml: &str, origin: &str, sort: &str) -> Vec<RssArticle>`
     - `<feed>/<entry>` 列表；提取 `<title>/<link href=>/<summary>/<published or updated>/<media:thumbnail>` 等
   - `detect_format(xml: &str) -> Format::{Rss20, Atom, Unknown}` — 取首个非空白 token / `<rss>` vs `<feed>` 判断
   - 4 单测：标准 RSS 2.0 / Atom / 缺字段降级 / 非法 XML 不 panic

3. **`core/core-source/src/rss/parse_rule.rs`** — 走 AnalyzeRule（沿袭 BookSourceParser）：
   - `parse_articles_by_rule(source: &RssSource, html: &str, sort: &str) -> Vec<RssArticle>`
   - 用 `source.rule_articles`（CSS / JSOUP-style）切分文章块
   - 每块用 `rule_title` / `rule_link` / `rule_pub_date` / `rule_description` / `rule_image` 抽字段
   - `rule_next_page`（如有）抽下一页 URL — **MVP 仅记录到 RssArticle.variable，不实装翻页**
   - 2 单测：完整规则成功 / 缺 rule_articles 返回空

4. **新增 `core/core-storage/src/rss_article_dao.rs`** — RssArticleDao：
   - `upsert_batch(articles: &[RssArticle]) -> usize` — 复合 PK (origin, link)，事务 + INSERT OR REPLACE 保留 read_time/star（不覆盖）
   - `list_by_origin_sort(origin: &str, sort: Option<&str>, limit: i64, offset: i64) -> Vec<RssArticle>` — 按 order_num ASC, pub_date DESC 排
   - `list_unread_by_origin(origin: &str) -> Vec<RssArticle>` — read_time = 0
   - `mark_read(link: &str, ts: i64) -> usize` — 同时 UPDATE rss_articles.read_time + UPSERT rss_read_records
   - `count_unread_by_origin(origin: &str) -> i64`
   - `delete_by_origin(origin: &str) -> usize` — 删源时清文章
   - 5 单测

5. **新增 `core/core-storage/src/rss_read_record_dao.rs`** — RssReadRecordDao 极小：
   - `upsert(link: &str, ts: i64) -> usize`
   - `is_read(link: &str) -> bool`
   - 2 单测
   - **注**：与 rss_articles.read_time 双写，便于跨源已读探测（同一篇文章被多个源收录）

6. **bridge api 加 6 个 pub fn**（funcId 91-96，部分 async）：
   - `rss_get_articles(db_path, source_url, sort_name, sort_url, page) -> JSON Vec<RssArticle>` — async：拉取 + 解析 + upsert 入库 + 返回**入库后排序的列表**
   - `rss_list_articles(db_path, source_url, sort) -> JSON Vec<RssArticle>` — sync：直接读 DB，UI 切 sort tab 用
   - `rss_mark_read(db_path, link, ts) -> i64` — sync
   - `rss_count_unread(db_path, source_url) -> i64` — sync
   - `rss_delete_articles_by_source(db_path, source_url) -> i64` — sync（删源时清文章）
   - `rss_get_sort_tabs(db_path, source_url) -> JSON Vec<{name, url}>` — sync：从 source.sort_url 字段（"name::url\n..."）切出来给 UI Tab 用

### Flutter 端

7. **新建 `lib/features/rss/rss_article_list_page.dart`** ConsumerStatefulWidget：
   - 路由参数：`?sourceUrl=...`
   - AppBar(title: source.name)，actions = [Refresh IconButton(rotate when loading)]
   - **Tab 行**（DefaultTabController）：
     - 单 URL 模式（`single_url=1` 或 sort_url 为空）：不显 TabBar
     - 多分类：Tab = source.sort_url 切出来的 (name, url) 列表
   - 每 Tab body：
     - 顶部 ListView.builder
     - 进入 Tab 自动调 rss_get_articles 拉一次 → 后续 pull-to-refresh 触发同接口
     - 列表点击 → 标题前的"未读 dot"消失 + 调 rss_mark_read（**不进详情页 — 批次 18 才实装**），现仅 SnackBar 提示"批次 18 实装详情"
   - 每 ListTile：
     - leading 64×64 缩略图（cached_network_image，缺图 placeholder Icon.article）
     - title: article.title（已读时 onSurface.opacity 0.6）
     - subtitle: pubDate + "·" + description 前 50 字符（一行，溢出 ellipsis）
     - 已读 dot：title 前蓝点（unread 时显示）
   - 加 hooks 注入 mock 数据用于 widget test（参考 cache_management_page）
   - 空态："暂无文章，下拉刷新"

8. **改 `lib/features/rss/rss_source_manage_page.dart`** — 每条 ListTile 整体可点击：
   - 整个 Card 可点 → 进 `/rss-articles?sourceUrl=...`
   - 现有 Switch / 删除 trailing 不变（Switch 通过 GestureDetector 阻止冒泡）

9. **路由注册** `/rss-articles` → RssArticleListPage（与 `/reader` 同模式带 query）

### 测试

- Rust ≥ 8 单测：
  1. `parse_xml::test_rss20_standard` — 标准 RSS 2.0 解析 ≥ 3 item
  2. `parse_xml::test_atom_standard` — 标准 Atom 解析
  3. `parse_xml::test_format_detection` — `<rss>` / `<feed>` / 其它
  4. `parse_xml::test_malformed_xml_no_panic` — 残缺 XML 不崩
  5. `parse_rule::test_full_rules_extract` — mock html + 完整规则
  6. `parse_rule::test_missing_rule_articles_returns_empty`
  7. `rss_article_dao::test_upsert_batch_preserves_read_star` — read_time/star 不被覆盖
  8. `rss_article_dao::test_mark_read_updates_both_tables`
- Flutter ≥ 2 widget tests：
  1. 列表渲染（mock 5 article，已读/未读混合）
  2. 下拉刷新触发 mock fetcher 一次

## Acceptance Criteria

- [ ] cargo test core-source ≥ baseline + 6（XML 4 + 规则 2）
- [ ] cargo test core-storage ≥ 70 (68 baseline + 7：article 5 + read_record 2)
- [ ] cargo test bridge 16 不变
- [ ] cargo build bridge 通过 + FRB regen + build.rs 守护更新
- [ ] flutter analyze 0 issue
- [ ] flutter test ≥ 364 (362 baseline + 2)
- [ ] **手工**：导入一个真实 RSS 源 → 进文章列表 → 拉取成功 → 点条目标记已读 → 杀进程重启已读保留

## Definition of Done

- cargo + flutter test 全绿
- analyze 0 issue
- 不打 APK
- commit "feat: 第五十七批 — RSS 拉取 + 文章列表 (批次 17)" + archive

## Out of Scope

- 文章详情页（WebView 渲染） — 批次 18
- 文章收藏（rss_stars 表已建但 DAO + UI 留批次 18）
- layout 1/2 自定义样式（articleStyle=1/2）— MVP 仅默认 layout
- 分页（rule_next_page）— MVP 仅一页（XML 通常一次返回全部；规则路也只取第 1 页）
- 拉取并发限流（concurrent_rate）— 单源单次拉取，无并发问题
- JS 注入 / coverDecodeJs / loginCheckJs 高级字段 — 仅在 custom_info_json 保留
- WebSocket 实时更新 / push 通知 — 不做
- 全文搜索 — 不做
- 分组管理（按 source_group 显示文章）— 批次 18 后期或单独批次

## Technical Notes

- quick-xml 0.37 的 reader API：用 `Reader::from_str(xml).read_event_into(&mut buf)` 流式 + `Event::Start/Text/End` 状态机
- AnalyzeRule 规则字符串与 BookSource 的 `rule_search` 字段同语义（CSS + JSOUP 伪类 + `@text/@html/@href` 等后缀）— 直接复用 `legado/selector.rs::analyze_rule_string`
- RssArticle.pub_date 保留**原 String 格式**（不解析时间戳，避免格式分歧）；若需排序按字符串字典序倒序近似日期顺序
- 批次 18 加文章详情时，需用 source.rule_content 拉全文（XML 路通常 description 已全文）
- FRB 异步 fn 沿袭批次 11 webdav 风格（async pub fn → frb wire 自动 spawn）
