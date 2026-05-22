# BATCH-26c: 发现/订阅 tab 显隐 toggle（对齐原 legado pref_config_other.xml）

**Stage**: P2
**Slug**: `batch-26c-show-discovery-rss-toggles`
**Effort**: M (~150-200 行)
**Depends on**: BATCH-26a ✅ / BATCH-26b ✅
**对照原版**：`/root/data/workspaces/doro_FriendMessage_641981595/legado/app/src/main/res/xml/pref_config_other.xml` 中 `showDiscovery` / `showRss` SwitchPreference

## 1. 范围

在 `/settings`（即 hub「其他设置」）里加 2 个 SwitchListTile，控制底栏「发现」/「订阅」两个 tab 的显隐。对齐原 legado `MainActivity.kt:364-371` 行为：toggle 关闭后底栏对应 NavigationDestination 不显示，但路由仍可直接 URL 访问（不删 ShellBranch，不破坏 26a 路由结构）。

## 2. 原版行为（legado/）

- `pref_config_other.xml:33-44` 两个 `SwitchPreference`，default true
- `AppConfig.kt:219-222` `showDiscovery` / `showRSS` getter 走 SharedPreferences
- `MainActivity.kt:364-381` 重建 BottomNavigationView：
  - 始终 inflate `R.menu.main_bnv` 4 项
  - `findItem(menu_discovery).isVisible = showDiscovery`
  - 同理 `menu_rss`
  - 计算 `bottomMenuCount = index + 1`（最后一个可见 tab + 1）
- `OtherConfigFragment.kt:200` toggle 后 `postEvent(NOTIFY_MAIN)` 触发 MainActivity 重建底栏
- 关闭 tab 不删 Fragment，底栏隐藏即可

## 3. 影响文件

### 改写

- `flutter_app/lib/core/providers.dart` 加 2 个 StateProvider + load/save：
  ```dart
  final showDiscoveryProvider = StateProvider<bool>((_) => true);
  final showRssProvider = StateProvider<bool>((_) => true);
  Future<bool> loadShowDiscoveryFromDisk({String? directory}) => ...
  Future<void> saveShowDiscoveryToDisk(bool v, {String? directory}) => ...
  // 同理 RSS
  ```
  走现有 `readJsonKey<bool>('showDiscovery', ..., true, ...)` / `writeJsonKey('showDiscovery', v)` 模式，与 `searchPrecision` 同结构。

- `flutter_app/lib/main.dart`（如有 startup 加载链）→ 启动时 load 两个 toggle 值并写入 provider。如无显式 startup load，可以在 router `_AppShell` 用 `FutureProvider` 兜底初值。**先评估现有启动流程**：搜 `loadThemeModeFromDisk` / `loadReaderSettingsFromDisk` 看怎么 wire 进 provider。

- `flutter_app/lib/core/router.dart` 改写 `_AppShell`：
  - `ConsumerWidget` 替代 `StatelessWidget`（已 import flutter_riverpod 链路 OK）
  - `ref.watch(showDiscoveryProvider)` + `ref.watch(showRssProvider)`
  - 计算 `visibleBranchIndices`（书架 0 / 我的 3 永远；探索 1 / 订阅 2 按 toggle）
  - NavigationBar destinations 用 collection-if 按 toggle 决定是否含「发现」/「订阅」
  - `selectedIndex` 做 view-index ↔ branch-index 映射：`visibleBranchIndices.indexOf(navigationShell.currentIndex)`，找不到（当前在被隐藏 tab）→ clamp 到 0
  - `onDestinationSelected` 用 view index 反查 branch index 调 `goBranch(...)`
  - `ref.listen` 监听两个 toggle 的变化：如关闭后当前 branch 落在被隐藏的 tab → 自动 `goBranch(0)` 切回书架（避免视觉错位）
  - 4 个 ShellBranch / 路由 / `initialLocation` 完全不动 — 用户仍可直接 URL `/explore` / `/rss` 访问（即便底栏不显示）

- `flutter_app/lib/features/settings/settings_page.dart` 加新分组「主页」：
  - `_SectionHeader(title: '主页')`
  - `SwitchListTile(value: showDiscovery, onChanged: (v) { provider.state = v; saveShowDiscoveryToDisk(v); })` 标题「显示「发现」」
  - 同理 `SwitchListTile` 标题「显示「订阅」」
  - 插入位置在「显示」（字号/主题）之后、「工具」之前

### 不动

- 26b /my hub 14 项（hub 本身不变）
- router 的 4 ShellBranch / 18 顶级 GoRoute
- 26a 已建的 explore_page / rss_tab_page
- settings_page 工具段 6 项（双入口保留，后续 26d/follow-up 收敛）

### 新增（spec）

- `quality-and-anti-patterns.md`「页面布局对齐 (BATCH-26)」段加一小节「底栏 tab 显隐 toggle (BATCH-26c)」：
  - 原版锚（pref_config_other.xml）
  - flutter 实现：保留 4 ShellBranch + 动态 NavigationBar destinations + view↔branch 索引映射 + 关闭时自动切回书架
  - Forbidden 反向：禁删 ShellBranch / 禁让 /explore /rss 路由失效

## 4. 测试策略

新增 `flutter_app/test/show_tab_toggles_test.dart` 4-5 个 testWidgets：

1. **toggle 默认 true** — pump router，断言 NavigationBar 4 destination 全部可见（书架/发现/订阅/我的）
2. **关 showDiscovery → 底栏 3 destination** — pump，setProvider showDiscovery=false，pumpAndSettle，destinations.length == 3，没有「发现」label
3. **关 showRss → 底栏 3 destination** — 同上
4. **同时关 → 底栏 2 destination**（书架 + 我的）
5. **当前在 /explore 时关闭 showDiscovery → 自动跳书架**（用 router.routerDelegate.currentConfiguration 验）

测试关键：
- 用 `ProviderScope.overrides` 注入 toggle 初值
- 不依赖真实 Provider load（避免 path_provider）

baseline 547 → +4-5 = 551-552/551-552 PASS 期望。

settings_page_test.dart 不需要改（工具段不动，新「主页」段不在工具段验证范围）。

## 5. 验收

- [ ] hub「其他设置」打开后，「主页」分组下有 2 个 SwitchListTile（显示「发现」/「订阅」）
- [ ] 关闭 showDiscovery → 底栏「发现」消失，剩 3 项
- [ ] 关闭 showRss → 底栏「订阅」消失
- [ ] 全关 → 底栏只剩书架 + 我的
- [ ] 关闭后直接 `/explore` URL 仍能进（路由保留）
- [ ] 当前在被隐藏 tab → 自动回书架，不出现 selectedIndex 错位
- [ ] 重启 app（widget test 用 fresh ProviderScope 模拟）后 toggle 状态恢复
- [ ] flutter analyze 0 / flutter test PASS（baseline 547 + 新增）

## 6. 不在范围

- O1：原版 `defaultHomePage` NameListPreference（启动默认到 bookshelf/discovery/rss/my）—— 留独立 follow-up
- O2：settings_page 工具段 6 项删除 / 收敛 —— 留 26d follow-up（用户体感稳定后）
- O3：toggle 关闭后从 /my hub「书源管理」等入口跳到对应页时的兜底 UI（不影响）

## 7. 风险点

- **StatefulShellRoute branches 数组固定**：方案保留 4 branch 不变，仅动态过滤 NavigationDestination。`navigationShell.currentIndex` 仍是 0..3，需要 view↔branch 映射。
- **当前 tab 被隐藏的 stale state**：`ref.listen` 兜底自动跳书架。如未实现这条，用户在 /explore 时关闭 toggle，底栏 selectedIndex 会落到 -1.clamp(0)=0（书架），但 IndexedStack 仍显示 /explore 内容 — 视觉混乱。
- **provider 初值与 disk 加载竞争**：默认 true 兜底；先用 default 渲染 4 destination，disk 值到位后 listen 触发动态调整。短暂 flash acceptable。
- **测试 ProviderScope.overrides 拦不住 default false load**：disk 加载是 fire-and-forget，测试用 fresh ProviderScope 不会触发 load 路径，验证逻辑用 override 注入直接生效。如有真实加载链路，加测试钩子绕开。
