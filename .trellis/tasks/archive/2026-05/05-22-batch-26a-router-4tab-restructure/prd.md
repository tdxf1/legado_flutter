# BATCH-26a: router 4-tab 重构

**Stage**: P2
**Slug**: `batch-26a-router-4tab-restructure`
**Effort**: M (~300-400 行)
**Parent**: `05-22-align-ui-with-legado-android`
**对照原版**：`/root/data/workspaces/doro_FriendMessage_641981595/legado/`（不是 legado-with-MD3）

## 1. 范围

把 flutter_app 顶层底部导航从 5 tab（书架/搜索/书源/下载/设置）重构为 4 tab（书架/发现/订阅/我的），对齐 `legado/app/src/main/res/menu/main_bnv.xml`。所有原 tab 内容（搜索/书源/下载/设置）以及 RSS 入口按 PRD R2/R5 重新映射。本批不填充「我的」hub 的 14 项内容（留 26b），仅建骨架页 + AppBar。

## 2. 路由结构改动

### 改前 (`flutter_app/lib/core/router.dart:23-200`)

5 个 StatefulShellBranch：bookshelf / search / sources / downloads / settings

### 改后

4 个 StatefulShellBranch（NavigationDestination 顺序对齐 `main_bnv.xml` 0-3）：

| index | path | builder | label | icon | selectedIcon |
|---|---|---|---|---|---|
| 0 | /bookshelf | BookshelfPage | 书架 | library_books_outlined | library_books |
| 1 | /explore | ExplorePage（新建） | 发现 | explore_outlined | explore |
| 2 | /rss | RssTabPage（新建，沿用 rss_source_manage_page 视图） | 订阅 | rss_feed_outlined | rss_feed |
| 3 | /my | MyHubPage（新建，**26a 仅骨架**） | 我的 | person_outline | person |

`StatefulShellRoute.indexedStack` 保留；`initialLocation: '/bookshelf'` 不变。

### 顶级 GoRoute 调整

- `/search` 从 ShellBranch 移到顶级 `GoRoute`（不在底栏 tab）：`bookshelf AppBar` IconButton 入。
- `/sources` 从 ShellBranch 移到顶级 `GoRoute`（书源管理页）：`/my` hub 入。
- `/downloads` 从 ShellBranch 移到顶级 `GoRoute`：bookshelf PopupMenu「缓存/导出」入；title 文案改"缓存/导出"对齐 `main_bookshelf.xml:46 cache_export`。
- `/settings` 从 ShellBranch 移到顶级 `GoRoute`：`/my` hub「其他设置」入。
- 现有 18 条二级 GoRoute 全部保留：reader / replace-rules / book-info-edit / backup / webdav-config / read-stats / cache-management / rss-source-manage / rss-articles / rss-articles-detail / rss-favorites / rule-subs / qr-scan。

## 3. 影响文件

### 新建

- `flutter_app/lib/features/explore/explore_page.dart`：占位骨架。AppBar 标题"发现" + body Center(Column[Icon(explore, 96), Text('发现待实现 (Explore)', style: titleLarge)])。**不引入 ViewModel / Provider**。
- `flutter_app/lib/features/my/my_hub_page.dart`：占位骨架。AppBar 标题"我的" + body `ListView` 空（26b 填充）。可加一个 placeholder Text "我的 (待 26b 填充)"，避免空 ListView assertions。
- `flutter_app/lib/features/rss/rss_tab_page.dart`：作为订阅 tab 的容器页。**复用 rss_source_manage_page** 的 list 视图实现（如可），上面加 3 个 IconButton（收藏 / 分组 / 设置）对齐 `main_rss.xml`。如果 `rss_source_manage_page` 是带 Scaffold + AppBar 的，直接 `body: const RssSourceManagePage()` 包一层会重复 AppBar，需要改写为 widget 抽出（或干脆让 RssTabPage 直接把 rss_source_manage_page 作为内容嵌入并隐藏其 AppBar）。**评估**：如复用难度高，本批 RssTabPage 用 placeholder + 3 个 IconButton（push 到 `/rss-source-manage`/`/rss-favorites`/占位），列表展示留 26b 或后续。

### 改写

- `flutter_app/lib/core/router.dart`（核心改动，约 50-80 行 diff）
  - StatefulShellRoute 4 branch
  - 4 个新顶级 GoRoute（search/sources/downloads/settings）
  - 新增 explore_page / my_hub_page / rss_tab_page 三个 import
- `flutter_app/lib/features/bookshelf/bookshelf_page.dart`
  - AppBar 加 IconButton(Icons.search) → `context.push('/search')`
  - PopupMenu 加「缓存/导出」项 → `context.push('/downloads')`
  - PopupMenu 删除 `/rss-source-manage` / `/rss-favorites` 两项（迁去 RSS tab）
  - PopupMenu 删除 `/settings` / `/sources` 项（如有）（迁去 /my hub）
- `flutter_app/lib/features/download/download_page.dart`
  - AppBar title 改「缓存/导出」（如可文案化）

### 不动

- 所有现有二级页面内部内容（reader / sources / settings / search / download 等）
- core/security / data 层

## 4. 测试策略

- `flutter analyze` 0 issue
- `flutter test` 跑 baseline 542：可能受影响：
  - 任何依赖具体 NavigationDestination 数量 / 顺序的 widget test
  - bookshelf PopupMenu menu items 的测试需要更新 expected items
  - tab 路由的 widget test（如有 `goBranch` 的）
  - 期望 0-5 个测试需要按新结构调整 expected
- 不引入新测试（occupy 26a 范围在结构改动；hub 内容的测试留 26b）

## 5. 验收

- [ ] 顶部 4 NavigationDestination 出现，选中切换正常
- [ ] /explore /my /rss 三个新页可进
- [ ] `/search` 可从书架 AppBar IconButton 进
- [ ] `/sources` `/settings` 仍可从其他入口（hub 暂未填，仍可通过直接 URL 访问验证）
- [ ] `/downloads` 可从书架 PopupMenu「缓存/导出」进，原 tab 已撤
- [ ] flutter analyze 0 / flutter test PASS（允许 ≤ 5 个测试调整）
- [ ] 不破坏 reader 路由 / 已实现的二级页面入口

## 6. 不在范围（明确）

- /my hub 14 项 ListTile + 分组（→ 26b）
- 「发现」tab 真业务（书源 explore 分类）
- RssTabPage 完整 list 视图（如复用 rss_source_manage_page 难度大，先 placeholder）
- bookshelf PopupMenu 剩余 9 项原版菜单（更新目录 / 添加远程 / 书架管理 / 书架布局 / 导出书架 / 导入书架 / 日志）—— 留 follow-up
- spec 「页面布局对齐」段更新（→ 26b 收尾时一起入）

## 7. 风险点

- **StatefulShellRoute branch 数量改动**：旧 5 → 新 4；branch 切换 indexedStack 状态。任何在 main session 之前持有 NavigationShell `branchIndex` 的代码会受影响。grep 验证无第三方持有。
- **search 从 tab 撤离**：原本 search 是 root-level tab，UX 上"持久"；改 push 后每次进入是新 stack。任何依赖"全局唯一 SearchPage 实例 + alive 状态"的逻辑需要核实（如有 `AutomaticKeepAliveClientMixin` 这个不影响，搜索结果 state 在 page 内）。
- **RssTabPage 复用 rss_source_manage_page**：如难度高，本批选保守 placeholder。在 sub-agent 实施时评估再决定，避免范围扩张。
- **bookshelf AppBar IconButton 数量**：原本可能已 3-4 个 icon，再加 search 可能拥挤。如需可把"添加"系动作折叠到 PopupMenu。
- **/downloads 文案改"缓存/导出"**：如 download_page 的 i18n 用了 string key，要调；如用硬编码字符串，直接改即可。
- **测试 baseline 542 → 可能 540-542**：允许微调，但不能下降到 < 540。如有 flaky 立刻修。
