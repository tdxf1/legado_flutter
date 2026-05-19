# RSS 源管理 + schema v12 (批次 16)

## Goal

在 Flutter+Rust 端补齐 RSS 订阅子系统的**第一层骨架**：建好 schema v12（rss_sources / rss_articles / rss_stars / rss_read_records 4 张表）+ RssSourceDao CRUD + RSS 源管理 UI（列表 / 启用切换 / 删除 / 单源导入）。

阶段 4 共 3 批：
- 批次 16（本批）：源管理 + schema v12（骨架）
- 批次 17：拉取与解析 + 文章列表
- 批次 18：文章详情 WebView + 收藏

## What I already know

- DB_VERSION 当前 = 11；schema v11 注释里写"故意不动 rss_*，等后续依赖批次实现对应功能时再加"
- 原 Legado RssSource 31 字段（feature-gap §1.1）：sourceUrl PK / sourceName / sourceIcon / sourceGroup / sourceComment / enabled / variableComment / jsLib / enabledCookieJar / concurrentRate / header / loginUrl / loginUi / loginCheckJs / coverDecodeJs / sortUrl / singleUrl / articleStyle / ruleArticles / ruleNextPage / ruleTitle / rulePubDate / ruleDescription / ruleImage / ruleLink / ruleContent / contentWhitelist / contentBlacklist / shouldOverrideUrlLoading / style / enableJs / loadWithBaseUrl / injectJs / lastUpdateTime / customOrder
- 原 RssArticle 字段约 11：origin / sort / title / pubDate / link / image / description / variable / order / readTime / star
- 原 RssStar 收藏字段 ~9：origin / sourceName / sort / title / pubDate / star / link / variable / image
- 原 RssReadRecord 字段 2：record_time / read_time（按 link 主键）
- backup zip §2.5 含 `rssSources.json` / §2.6 `rssStar.json`，但批次 10 仅做了 5 张表的 backup，rss_* 留待后续批次
- core/core-source 的 source_type=3 已预留给 RSS，但解析器 / DAO 全无
- 现有 BookSourceDao 模式：`import_from_json` upsert by url + 列表 / 启用切换 / 分组（参考批次 7+8）
- FRB bridge 现有 84 个 funcId（cache-management 占用 81-84）

## Decision

**MVP 范围 — 仅源管理骨架，不含拉取/解析/文章 UI**：

### Rust 端

1. **Schema v12 — 新增 `core/core-storage/src/database.rs::migrate_v12`**：
   - `rss_sources` 表（17 个 MVP 字段，剩余 14 个塞 `custom_info_json`）：
     - `source_url TEXT PK`
     - `source_name TEXT NOT NULL`
     - `source_icon TEXT`
     - `source_group TEXT`
     - `source_comment TEXT`
     - `enabled INTEGER DEFAULT 1`
     - `single_url INTEGER DEFAULT 0`  -- 0=多分类 1=单 URL
     - `sort_url TEXT`  -- 分类 sortName::sortUrl 对，多个用 \n 分隔
     - `article_style INTEGER DEFAULT 0`  -- 0/1/2 三种 layout
     - `rule_articles TEXT`
     - `rule_next_page TEXT`
     - `rule_title TEXT`
     - `rule_pub_date TEXT`
     - `rule_description TEXT`
     - `rule_image TEXT`
     - `rule_link TEXT`
     - `rule_content TEXT`
     - `last_update_time INTEGER DEFAULT 0`
     - `custom_order INTEGER DEFAULT 0`
     - `enable_js INTEGER DEFAULT 1`
     - `load_with_base_url INTEGER DEFAULT 1`
     - `header TEXT`
     - `custom_info_json TEXT`  -- 高级字段：jsLib/loginUrl/loginUi/loginCheckJs/coverDecodeJs/contentWhitelist/contentBlacklist/shouldOverrideUrlLoading/style/injectJs/concurrentRate/enabledCookieJar/variableComment
   - `rss_articles` 表（11 字段）：
     - 复合主键 `(origin, link)`
     - `origin TEXT NOT NULL`  -- 关联 rss_sources.source_url
     - `sort TEXT`  -- 分类 sortName
     - `title TEXT`
     - `pub_date TEXT`  -- 原 Legado 是 String，不是时间戳
     - `link TEXT NOT NULL`
     - `image TEXT`
     - `description TEXT`
     - `variable TEXT`
     - `order_num INTEGER DEFAULT 0`  -- 列表顺序
     - `read_time INTEGER DEFAULT 0`  -- 0=未读
     - `star INTEGER DEFAULT 0`  -- 0=未收藏
   - `rss_stars` 表（9 字段，独立于 rss_articles，因为收藏要跨源持久）：
     - 复合主键 `(origin, link)`
     - `origin / source_name / sort / title / pub_date / image / link / description / variable`
     - `star_time INTEGER NOT NULL`
   - `rss_read_records` 表（2 字段 + 复合主键）：
     - `record_time INTEGER`
     - `read_time INTEGER`
     - 主键 `link TEXT PK`
   - 索引：`rss_sources(source_group)` `rss_articles(origin, sort)` `rss_articles(read_time)` `rss_stars(star_time DESC)`
   - DB_VERSION = 12
   - migrate_v12 防御性：CREATE TABLE IF NOT EXISTS；不依赖任何旧表存在

2. **新增 `core/core-storage/src/rss_source_dao.rs`** — RssSourceDao：
   - `list_all() -> Vec<RssSource>` (按 custom_order ASC, source_name ASC)
   - `list_enabled() -> Vec<RssSource>`
   - `list_by_group(group: &str) -> Vec<RssSource>`
   - `list_groups() -> Vec<String>` (DISTINCT source_group, 跳过空)
   - `get_by_url(url: &str) -> Option<RssSource>`
   - `upsert(source: &RssSource) -> i64`
   - `set_enabled(url: &str, enabled: bool) -> usize`
   - `delete_by_url(url: &str) -> usize`
   - `import_from_json(json: &str) -> ImportSummary{added, updated, skipped}`（复用 BookSource 风格）
   - `count() -> i64`

3. **新增 `core/core-storage/src/models.rs::RssSource` struct**（与 BookSource 同模块）：
   - 含上述 23 个 SQL 字段映射 + `custom_info_json: Option<String>` 收纳剩余 13 个高级字段
   - 实现 `from_legado_json(v: &Value) -> RssSource` 适配原 Legado JSON

4. **bridge api 加 9 个 pub fn**（同步，沿袭 BookSource 风格）：
   - `rss_source_list_all(db_path) -> JSON Vec<RssSource>`
   - `rss_source_list_enabled(db_path) -> JSON Vec<RssSource>`
   - `rss_source_list_by_group(db_path, group) -> JSON Vec<RssSource>`
   - `rss_source_list_groups(db_path) -> Vec<String>`
   - `rss_source_get(db_path, url) -> JSON Option<RssSource>`
   - `rss_source_upsert(db_path, json: String) -> i64`
   - `rss_source_set_enabled(db_path, url, enabled) -> usize`
   - `rss_source_delete(db_path, url) -> usize`
   - `rss_source_import_json(db_path, json) -> JSON ImportSummary`

### Flutter 端

5. **新建 `lib/features/rss/rss_source_manage_page.dart`** ConsumerStatefulWidget：
   - AppBar(title: "RSS 源管理")，actions = [导入 IconButton(file_download), 新建 IconButton(add)]
   - GroupBy 模式：按 source_group 分 Section（沿袭 BookSourceManagePage 风格，如已有）
   - 每条 ListTile：
     - leading: Switch(value=enabled, onChanged → set_enabled)
     - title: source_name
     - subtitle: source_url
     - trailing: PopupMenuButton(删除 / 编辑（占位 → 批次 17 实装）)
   - FAB 按"导入"打开 file_picker（批次 13 已加 file_picker）选 JSON 文件 → import_json → ImportSummary toast
   - 空态："暂无 RSS 源" + "导入" 按钮

6. **路由注册** `/rss-source-manage` → RssSourceManagePage

7. **入口**：bookshelf_page AppBar PopupMenu 加 "RSS 源管理" 项（在批次 15 "缓存管理"之后）

### 测试

- Rust ≥ 6 单测：
  1. `test_migrate_v12_creates_rss_tables` — fresh install + migration 都建好 4 张表
  2. `test_migrate_v12_idempotent` — 重跑不报错
  3. `test_rss_source_upsert_and_get` — upsert 后能读
  4. `test_rss_source_list_groups` — DISTINCT 分组
  5. `test_rss_source_set_enabled` — 切换 enabled
  6. `test_rss_source_import_from_legado_json` — 标准 Legado JSON 导入并保留 custom_info_json
- Flutter ≥ 1 widget test — rss_source_manage_page 渲染空态 + 渲染 mock 列表

## Acceptance Criteria

- [ ] cargo test core-storage ≥ 67 (61 baseline + 6)
- [ ] cargo test bridge ≥ 16（不变）
- [ ] cargo build bridge 通过 + FRB regen
- [ ] flutter analyze 0 issue
- [ ] flutter test ≥ 360 (359 baseline + 1)
- [ ] 手工验证：导入一份 rssSources.json (Legado 格式) → 列表显示 → 切 enabled → 重启 app 状态保留

## Definition of Done

- cargo + flutter test 全绿
- analyze 0 issue
- 不打 APK
- commit "feat: 第五十六批 — RSS 源管理 + schema v12 (批次 16)" + archive

## Out of Scope

- 拉取与解析 RSS — 批次 17
- 文章列表 / 详情 / 收藏 UI — 批次 17/18
- RSS 源编辑页（新建/编辑表单）— 批次 17 (含简易编辑) 或暂用 JSON 文本框
- 备份 zip 加 rssSources.json / rssStar.json — 批次 18 末尾或独立批次
- 高级字段（jsLib / loginUrl / loginUi 等）的 UI 暴露 — MVP 仅在 import_json 时保留到 custom_info_json，UI 不展示
- 调试页（debug stream）— 不做
- 分组管理 GroupManageDialog — 不做（用 distinct 列出来即可）

## Technical Notes

- 现有 `core/core-storage/src/source_dao.rs::BookSourceDao::import_from_json` 是参照模板，复用 ImportSummary
- 原 Legado RssSource 字段映射详见 `feature-gap-rss-manga-audio-misc.md` §1.1
- backup-format §2.5 / §2.6 RSS JSON 结构详见 `legado-backup-format.md`
- FRB build.rs 守护：每加一个 wire fn 都要更新 REQUIRED_WIRE_FN_FRAGMENTS / DISPATCHER_FRAGMENTS（参考批次 15 经验）
