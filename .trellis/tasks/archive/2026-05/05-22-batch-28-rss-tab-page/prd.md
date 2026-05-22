# BATCH-28: RssTabPage 订阅源 tab 页

## Goal

将 RSS 底栏 tab 的占位页 (`RssTabPage`) 从 instruction placeholder 改造为真实订阅源网格，对齐 legado `RssFragment` (RssAdapter 4 列网格 + 分组筛选)。让「订阅」tab 成为可用的每日浏览起点。

## Requirements

### R1. 源网格 GridView

- `RssTabPage`: StatelessWidget → ConsumerStatefulWidget + `dbPathOverride` 注入。
- initState `_loadSources()` 调 `rssSourceListEnabled(dbPath)` 返回 JSON array → parse → setState `_sources`。
- body: `RefreshIndicator` 包 `GridView.builder`。
- `SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4)` — 固定 4 列对齐 legado RssFragment。
- item: Card (clipBehavior.antiAlias + 圆角) + Column 居中：
  - Stack: `CachedNetworkImage` (50dp 圆角方形 source icon, fallback Icon(Icons.rss_feed)) + 右上角 Positioned 数字 badge
  - `Text(source_name, maxLines: 2, textAlign: center)`
- 未读数 badge：`rssCountUnread(dbPath, sourceUrl)` → 数字 >0 时显示红色圆形 badge，0 时不显示。
- 空态：`_sources.isEmpty` → centered Text「暂无订阅源」+ FilledButton「去添加」→ push `/rss-source-manage`。
- 点 source → push `/rss-articles?sourceUrl=...`（已有路由）。

### R2. 全局 pull-to-refresh

- RefreshIndicator 下拉 → `rssGetArticles(dbPath, sourceUrl: s.url, ...)` 逐源拉最新文章 → SnackBar 总结。
- 不逐源显示进度（简单总结即可，与 import_bookshelf 同款策略）。

### R3. 分组筛选 chips

- AppBar bottom 加 horizontal `SingleChildScrollView` + ChoiceChip：「全部」+ 各 `group` 名（调 `rssSourceListGroups` 获取）。
- 单选：点 chip 切换 `_filterGroup: String?`（null=全部，非 null=匹配 source_group 包含该组的源）。
- **不持久化**（与 27d-followup group chips 同款：每次进页 = 全部）。
- 「分组」AppBar action 图标从 disabled 改 enabled — 点选替代方式（若 chips 可见时 action 可省略，但保留与原 legado 心智对齐）。

### R4. AppBar actions

保留 3 个 action（与现有占位页相同，改「分组」enabled）：
- `star_outline` → push `/rss-favorites`
- `folder_outlined` → enabled（分组切换，fallback: 可点选芯片同代码 / 未来可补充 `_showGroupPickerDialog`）
- `settings_outlined` → push `/rss-source-manage`

## Acceptance Criteria

- [ ] RssTabPage 不再显示 placeholder 文字
- [ ] GridView 4 列显示 enabled RSS sources（icon + name）
- [ ] 每 source 右上角红色圆形 badge 显示未读数 >0
- [ ] 下拉刷新全源文章
- [ ] 顶部 chips：默认「全部」选中、选组后 GridView 仅显示该组源
- [ ] 点 source → push `/rss-articles?sourceUrl=...`
- [ ] 「分组」action enabled
- [ ] 空态显示「暂无订阅源」+「去添加」button
- [ ] flutter analyze 0 / flutter test all green
- [ ] ≥4 testWidgets：grid 渲染 / 点 source push / 分组 chips 选组过滤 / 空态 + CTA

## Definition of Done

- spec 加 BATCH-28 RssTabPage 段（源网格契约 + group filter + Forbidden 反向 ≥3 条）
- 27a 表更新：无新 PopupMenu 项，但 RssTabPage 心智对齐说明
- 测试新建 `rss_tab_page_test.dart`

## Decision (ADR-lite)

**Context**: RssTabPage 当前是占位页，需改为真实源网格，对齐 legado RssFragment。

**Decision**:

- GridView 4 列（Q1，对齐 legado）
- Card + 圆角方形 icon + name（Q2，对齐 legado item_rss.xml）
- 横向 ChoiceChip 分组筛选（Q3，与 27d-followup 同款）
- 数字 badge（Q4，显示具体数）
- 全局 pull-to-refresh 逐源拉最新文章（Q5）

**Consequences**:

- MVP 不加搜索 / 长按菜单 / 规则订阅 header — 当前入口全通过已有页面完成（源管理 / 文章列表 / 收藏）。后续 BATCH-28-followup 加。
- 与 legado 差异：legado 有「规则订阅」头部 item，Flutter 端暂无 RuleSub 管理页 → 留 BATCH-29。搜索 SearchView 留 followup。

## Out of Scope

- 搜索 SearchView → BATCH-28-followup
- 长按菜单（置顶/编辑/禁用/删除）→ BATCH-28-followup
- 「规则订阅」header item → BATCH-29+（需 RuleSub 管理页）
- 分组管理 CRUD → 已有 RssSourceManagePage
- Responsive 列数 → BATCH-28-followup
- 源 logo 加载失败 fallback 策略 → CachedNetworkImage errorBuilder 预设

## Technical Notes

### Flutter 端改动文件

- `flutter_app/lib/features/rss/rss_tab_page.dart`：重写 ~75 行 → ~250 行
- `flutter_app/lib/core/router.dart`：路由不动（`/rss` ShellBranch 已存在）

### 关键 API

- `rssSourceListEnabled(dbPath)` → `String` (JSON array) — 获取启用源列表
- `rssSourceListGroups(dbPath)` → `String` (JSON strings) — 分组名列表
- `rssCountUnread(dbPath, sourceUrl)` → `PlatformInt64` — 未读数
- `rssGetArticles(dbPath, sourceUrl, sortName, sortUrl, page)` → `String` — 拉取文章

### 测试策略

- 新建 `flutter_app/test/rss_tab_page_test.dart` ≥ 4 testWidgets
- 注入 `dbPathOverride + sourcesOverride + groupsOverride + unreadOverride + getArticlesOverride` 测试钩子
- `buildPage` helper 走 `ConsumerStatefulWidget` 同 `rss_source_manage_page_test.dart` 范本

### 锚源

- `legado/.../ui/main/rss/RssFragment.kt` — grid + group + search
- `legado/.../ui/main/rss/RssAdapter.kt` — 4-col source item
- `legado/.../res/layout/fragment_rss.xml` — layout
- `legado/.../res/layout/item_rss.xml` — item icon + name
