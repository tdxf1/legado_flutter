# 订阅源 RuleSub MVP (批次 19)

## Goal

阶段 5 第一批：实现 RuleSub 订阅源 — 用户配 1 个 URL，**一键拉取最新规则 JSON 列表合并入库**（书源 / RSS 源 / 替换规则）。原 Legado 圈子里"配置一份订阅 = 同步上百个书源"的标准做法。

阶段 5 全 3 批：
- 批次 19（**本批**）：RuleSub 订阅源 (S)
- 批次 20：QR 扫码导入 (S)
- 批次 21：书源验证增强 (S)

## What I already know

### 现状
- DB schema v11 (批次 6) 已建好 `rule_subs` 表 — `id (uuid TEXT PK) / name / url UNIQUE / sub_type (0=书源 / 1=RSS / 2=替换规则) / custom_order / created_at / updated_at` (7 字段)
- 批次 16 已有 `RssSourceDao::import_from_json`（双格式探测）
- 批次 7 之前已有 `BookSourceDao::import_from_json`（双格式探测：内部 / Legado camelCase）
- `ReplaceRuleDao` 没有 import_from_json（暂不实装本批，仅 sub_type=0/1 实装真正 import；sub_type=2 留 TODO 占位）
- `core-net::client` 提供 reqwest async client (cookie + retry + proxy) — 拉取订阅源 URL 用
- bridge funcId 已用到 101，本批次 102 起

### 原 Legado 参考（`feature-gap-rss-manga-audio-misc.md` §5）
- `data/entities/RuleSub.kt` (16 行) — 极简 5 字段 + auto_update + last_update
- `data/dao/RuleSubDao.kt`
- `ui/rss/subscription/RuleSubActivity.kt` + `RuleSubAdapter.kt` — CRUD UI
- 触发"刷新订阅"时拉 URL → 按 sub_type 分发到 ImportBookSourceDialog / ImportRssSourceDialog / ImportReplaceRuleDialog

### Flutter 端现状
- 没有 `lib/features/rule_sub/`
- bookshelf PopupMenu 已有 RSS 源管理 / RSS 收藏 / 缓存管理 / 阅读统计 / 备份 / 管理分组等入口

## Decision

**MVP 范围 — RuleSub CRUD + 拉取触发 import + UI 入口**：

### Rust 端

1. **新增 `core/core-storage/src/rule_sub_dao.rs`** — RuleSubDao：
   - `list_all() -> Vec<RuleSub>` (按 custom_order ASC, name ASC)
   - `get_by_id(id) -> Option<RuleSub>`
   - `get_by_url(url) -> Option<RuleSub>`
   - `upsert(sub: &RuleSub) -> usize` — INSERT OR REPLACE by id
   - `delete_by_id(id) -> usize`
   - `count() -> i64`
   - 5 单测

2. **`core/core-storage/src/models.rs::RuleSub`** struct 已存在（批次 6 的 Cookie/RuleSub 都是空 struct + schema），本批次只补 DAO 即可。**注意 schema 与 struct 字段对齐**：批次 6 schema 是 7 字段 (id+name+url+sub_type+custom_order+created_at+updated_at)，本批次复用此 schema 不动。

3. **bridge api 加 7 个 pub fn**（funcId 102-108）：
   - 102 `rule_sub_list_all(db_path) -> JSON Vec<RuleSub>` — sync
   - 103 `rule_sub_create(db_path, name, url, sub_type) -> JSON RuleSub` — sync
   - 104 `rule_sub_update(db_path, id, name, url, sub_type) -> i64` — sync
   - 105 `rule_sub_delete(db_path, id) -> i64` — sync
   - 106 `rule_sub_refresh(db_path, id) -> JSON {sub_type, summary}` — async
     - 拉 sub.url（reqwest GET）
     - sub_type=0 → BookSourceDao::import_from_json，返回 `{sub_type:0, count:N}`
     - sub_type=1 → RssSourceDao::import_from_json，返回 `{sub_type:1, summary: RssImportSummary}`
     - sub_type=2 → 暂返回 `{sub_type:2, error: "替换规则订阅暂未实装"}`（占位，留批次 21+）
   - 107 `rule_sub_refresh_all(db_path) -> JSON Vec<{id, sub_type, ok, message}>` — async：遍历所有订阅刷新，每个失败不打断其它
   - **注意**：`RuleSub` 简单到不需要 from_legado_json — 用户手动建条目 + URL 即可

### Flutter 端

4. **新建 `lib/features/rule_sub/rule_sub_page.dart`** ConsumerStatefulWidget：
   - 路由 `/rule-subs`
   - AppBar(title: "订阅源")，actions = [Refresh All IconButton + Add IconButton]
   - ListView 渲染所有 RuleSub：
     - leading icon：sub_type 0=Icons.source, 1=Icons.rss_feed, 2=Icons.find_replace
     - title: name
     - subtitle: url + " · " + sub_type 标签 (书源 / RSS / 替换规则)
     - 长按 → 编辑 / 删除
     - 点击 → 单条刷新 → SnackBar 提示成功 (added X / updated Y)
   - 添加：弹 dialog 输 name + url + sub_type radio (3 选)
   - 刷新全部：滚动 + SnackBar 汇总
   - 测试钩子注入

5. **路由注册 `/rule-subs`**

6. **入口** `bookshelf_page.dart` AppBar PopupMenu 加 "订阅源" 项（在 "RSS 收藏"之后）

### 测试

- Rust ≥ 5 单测：rule_sub_dao 的 5 个 fn（已涵盖 CRUD + count）
- Flutter ≥ 1 widget test — rule_sub_page 渲染（mock 列表 + 空态）

## Acceptance Criteria

- [ ] cargo test core-storage ≥ 85 (80 baseline + 5)
- [ ] cargo test bridge 16 不变
- [ ] cargo build bridge 通过 + FRB regen + build.rs 守护更新（funcId 102-108）
- [ ] flutter analyze 0 issue
- [ ] flutter test ≥ 370 (369 baseline + 1)
- [ ] **手工**：建一个订阅 URL（如某 GitHub raw 的书源 JSON）→ 点单条刷新 → 看到 SnackBar "已导入 N 个书源" → 进 /sources 页确认

## Definition of Done

- cargo + flutter test 全绿
- analyze 0 issue
- 不打 APK
- commit "feat: 第五十九批 — 订阅源 RuleSub MVP (批次 19)" + archive

## Out of Scope

- 替换规则订阅（sub_type=2）— 占位返回 "暂未实装"，批次 20+ 或后续
- 自动定时刷新（auto_update + 后台 service）— 不做
- 导入冲突 UI（已存在的源是覆盖还是跳过）— 沿用 BookSource/RssSource 的 upsert 语义（按 url 去重 + 更新）
- QR 扫码导入订阅源 URL — 批次 20

## Technical Notes

- `rule_subs.url` UNIQUE 约束已在 schema (v11)；upsert 按 id 主键
- refresh 的 GET 用 `core-net::client::shared_client()` 或新建 reqwest::Client::new()
- HTTP 错误（4xx/5xx/timeout）走 ParserError::Network → bridge 转 String error
- sub_type=2 的占位返回结构：`{"sub_type":2, "error":"替换规则订阅暂未实装"}`（仍属成功响应，仅 error 字段提示）
- `rule_sub_create` 需新生成 UUID + now() timestamps
