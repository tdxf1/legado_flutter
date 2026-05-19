# RSS 文章详情 WebView + 收藏 (批次 18)

## Goal

阶段 4 第三批（收尾）：在批次 16/17 的基础上，实现 RSS 文章 **详情页（WebView 渲染）+ 收藏（RssStar）**。

阶段 4 全 3 批：
- 批次 16（done）：源管理 + schema v12
- 批次 17（done）：拉取 + 文章列表 + 已读
- 批次 18（**本批**）：详情 WebView + 收藏

## What I already know

### 现状
- DB schema v12 已建好 `rss_stars` 表（批次 16）— 9 字段含 `(origin, link)` 复合主键 + star_time
- `core-storage::models::RssArticle` 已加（批次 17，11 字段含 `link/title/description`）— 收藏直接拿这个 + source_name
- `core-source::rss::RssParser::fetch_article_content_full` 是占位，本批次实装
- `pubspec.yaml` 已含 `webview_flutter: ^4.8.0`，已有 `core/platform_webview_executor.dart` 用例（headless 用法）— 详情页需要新写一份**用户级 WebView**
- bridge funcId 已用到 96，本批次新增 97 起
- core-source 已有 `BookSourceParser::get_chapter_content` 拉正文流程（reqwest + AnalyzeRule + replace_regex），可作 RSS 详情拉取参照

### 原 Legado 参考（`feature-gap-rss-manga-audio-misc.md` §1.4 / §1.5）
- `ui/rss/read/ReadRssActivity.kt` (1100+ 行) — WebView + JS Bridge + `injectJs` / `style` / `enableJs` / `loadWithBaseUrl` / `shouldOverrideUrlLoading`
- `data/entities/RssStar.kt` (49 行) + `data/dao/RssStarDao.kt`
- `ui/rss/favorites/RssFavoritesActivity.kt` 等 5 个文件 — 收藏列表 / 详情 / dialog
- 2 种渲染模式：
  1. `loadWithBaseUrl=true`（默认）→ 拉 HTML 字符串后 `loadDataWithBaseURL`，注入 article 描述
  2. `loadWithBaseUrl=false` → `loadUrl(article.link)` 直接打开原网页
- `injectJs` 在 `onPageFinished` 注入；`style` 用 `<style>` 包装放 head

### Flutter WebView 现状
- `webview_flutter: ^4.8.0` API：`WebViewController` + `loadHtmlString` / `loadRequest` / `runJavaScript` / `setNavigationDelegate`
- 无 cookie 共享配置（暂不做 — Cookie 表是后续批次）

## Decision

**MVP 范围 — 详情 WebView（单一渲染模式）+ 收藏 CRUD + 收藏页面，不含字体定制 / 链接拦截 / JS Bridge 高级 API**：

### Rust 端

1. **`core/core-source/src/rss/mod.rs::RssParser::fetch_article_content_full`** 实装：
   - 接收 `(source: &RssSource, article: &RssArticle)`，返回拉到的 HTML 字符串
   - 路由：
     - 若 `source.rule_content` 非空 → 走规则路（reqwest GET article.link → AnalyzeRule 抽 rule_content → 包成 `<html><head><style>...</style></head><body>...</body></html>`）
     - 否则 → 直接返回 article.description（XML 路通常 description 已是全文 HTML）+ 包同样的 wrapper
   - 错误：复用 `ParserError`
   - **不做** injectJs / loginCheckJs / coverDecodeJs / loadWithBaseUrl=false（链接直跳）— 这些留批次 19+

2. **新增 `core/core-storage/src/rss_star_dao.rs`** RssStarDao：
   - `add(article: &RssArticle, source_name: &str) -> usize` — 把 RssArticle 转成 RssStar 行入库（star_time = now）
   - `remove(origin: &str, link: &str) -> usize` — 按复合主键删
   - `is_starred(origin: &str, link: &str) -> bool`
   - `list_all(limit: i64, offset: i64) -> Vec<RssStar>` — 按 star_time DESC
   - `count() -> i64`
   - 4 单测：add+is_starred / 重复 add 不报错 / remove / list_all 排序

3. **`core/core-storage/src/models.rs` 加 `RssStar` struct**（9 字段）：
   - `origin / source_name / sort / title / pub_date / image / link / description / variable / star_time`
   - serde derive 全套

4. **bridge api 加 5 个 pub fn**（funcId 97-101，部分 async）：
   - `rss_fetch_article_content(db_path, source_url, link) -> JSON {html, base_url}` — async：读 source/article → 调 fetch_article_content_full → 返回拼装 HTML + base URL（base URL 用 `source.source_url` 或 `article.link` 让 WebView 解析相对路径）
   - `rss_star_add(db_path, article_json, source_name) -> i64` — sync
   - `rss_star_remove(db_path, origin, link) -> i64` — sync
   - `rss_star_is_starred(db_path, origin, link) -> bool` — sync
   - `rss_star_list(db_path, limit, offset) -> JSON Vec<RssStar>` — sync

### Flutter 端

5. **新建 `lib/features/rss/rss_article_detail_page.dart`** ConsumerStatefulWidget：
   - 路由参数：`?sourceUrl=...&link=...`
   - 进入时：
     - 调 `rss_mark_read` 标记已读（如未读）
     - 调 `rss_fetch_article_content` 拉 HTML
     - 调 `rss_star_is_starred` 判断收藏状态
   - AppBar(title: article.title)，actions = [
     - IconButton(star/star_outline) → toggle add/remove → 更新本地状态 + invalidate 列表页
     - IconButton(open_in_browser) → 留占位（批次 19+）
   - body: WebViewWidget（loading 时显 CircularProgressIndicator）
   - WebView 使用 `controller.loadHtmlString(html, baseUrl: url)`
   - 加测试钩子：`sourceOverride / articleOverride / fetchHtmlOverride / starStateOverride / starToggleOverride`

6. **新建 `lib/features/rss/rss_favorites_page.dart`** ConsumerStatefulWidget：
   - 路由 `/rss-favorites`
   - AppBar(title: "RSS 收藏")
   - ListView 渲染所有 `RssStar`：
     - leading 64×64 缩略图（image）
     - title: title
     - subtitle: source_name + " · " + pub_date
     - 长按 → 取消收藏（confirm dialog）
     - 点击 → push detail 页（同 `/rss-articles-detail?sourceUrl=...&link=...`）
   - 空态："暂无收藏"

7. **路由注册**：
   - `/rss-articles-detail` → RssArticleDetailPage（query: sourceUrl, link）
   - `/rss-favorites` → RssFavoritesPage

8. **改 `lib/features/rss/rss_article_list_page.dart`**：
   - 列表点击：从原本的"标记已读 + SnackBar 占位" 改成 `push '/rss-articles-detail?sourceUrl=...&link=...'`
   - 不再显示 SnackBar 提示
   - mark_read 在 detail 页 init 时做（避免双写）

9. **改 `lib/features/bookshelf/bookshelf_page.dart`**：
   - AppBar PopupMenu 加 "RSS 收藏" 项（在批次 16 "RSS 源管理" 之后）

### 测试

- Rust ≥ 6 单测：
  1. `rss_star_dao::test_add_and_is_starred` — add 后 is_starred=true
  2. `rss_star_dao::test_add_duplicate_replaces` — 重复 add 不报错（用 INSERT OR REPLACE）
  3. `rss_star_dao::test_remove` — remove 后 is_starred=false
  4. `rss_star_dao::test_list_all_orders_by_star_time_desc`
  5. `rss::mod::test_fetch_article_content_uses_description_fallback` — rule_content 为空时用 description
  6. `rss::mod::test_fetch_article_content_via_rule_content` — 配置 rule_content 走规则路
- Flutter ≥ 2 widget tests：
  1. detail 页渲染 — mock fetcher 返回 HTML，验证 WebView 出现
  2. favorites 页渲染空态 + mock 列表

## Acceptance Criteria

- [ ] cargo test core-source ≥ 182 (180 baseline + 2)
- [ ] cargo test core-storage ≥ 79 (75 baseline + 4)
- [ ] cargo test bridge 16 不变
- [ ] cargo build bridge 通过 + FRB regen + build.rs 守护更新（funcId 97-101）
- [ ] flutter analyze 0 issue
- [ ] flutter test ≥ 366 (364 baseline + 2)
- [ ] **手工**：批次 17 已导入的源 → 进文章列表 → 点 → 看到详情 WebView + 内容 → 点 ★ 加收藏 → 进收藏页看到 → 长按取消收藏

## Definition of Done

- cargo + flutter test 全绿
- analyze 0 issue
- 不打 APK
- commit "feat: 第五十八批 — RSS 文章详情 + 收藏 (批次 18)" + archive
- 阶段 4 收尾完成

## Out of Scope

- injectJs / coverDecodeJs / loginCheckJs / loadWithBaseUrl=false 链接直跳 — 批次 19+
- WebView Cookie 共享 / 自定义 UA — Cookie 表批次（未规划）
- 字体 / 字号自定义 — 批次 19+ 或单独
- 收藏分组 — 不做
- 收藏导出导入 — 后续 backup 批次
- 链接拦截（点 WebView 内的链接打开浏览器） — 批次 19+
- 阅读原文按钮（loadWithBaseUrl=false）— MVP 不实装，留 IconButton 占位

## Technical Notes

- WebViewController API：`loadHtmlString(html, baseUrl: source.source_url)` + `runJavaScript`（如未来要 inject）
- HTML wrapper（避免 WebView 显示纯文本）：
  ```html
  <!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>body{padding:16px;font-family:sans-serif;line-height:1.6;font-size:16px;color:#222}img{max-width:100%;height:auto}</style>
  </head><body>{content}</body></html>
  ```
- RssStar 写入复合主键 (origin, link)，重复 add 时用 `INSERT OR REPLACE` 保留 star_time（更新成最新 = 收藏时间向后挪）
- mark_read 在 detail 页 init 时调用一次 — 列表页 onTap 不再调，避免双写
- detail 页 fetch 失败 — 显示错误信息 + 重试按钮
- favorites 页本批次使用 `rss_star_list(limit=-1, offset=0)`（无分页 MVP；后续如收藏多了再加分页）
