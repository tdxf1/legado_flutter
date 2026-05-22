# BATCH-26d: defaultHomePage 启动默认 tab（对齐原 legado upHomePage）

**Stage**: P2
**Slug**: `batch-26d-default-home-page`
**Effort**: S-M (~120-150 行)
**Depends on**: BATCH-26a/b/c ✅
**对照原版**：`pref_config_other.xml` `defaultHomePage` NameListPreference + `MainActivity.kt:385-398` `upHomePage()`

## 1. 范围

让用户在 hub「其他设置」的「主页」分组里选启动默认 tab：书架 / 发现 / 订阅 / 我的（4 选 1，default = 书架）。app 启动 / 路由初始化时根据该值跳到对应 tab；选发现 / 订阅但对应 toggle 关闭时**不跳**（保留 bookshelf 兜底，与原版一致）。

## 2. 原版行为

- `pref_config_other.xml` line 47-54 NameListPreference key=`defaultHomePage`，default `"bookshelf"`，4 个 entry：`bookshelf` / `explore` / `rss` / `my`
- `arrays.xml` `default_home_page` 显示文案 = 书架 / 发现 / 订阅 / 我的
- `MainActivity.kt:385-398` `upHomePage()` 启动时切 ViewPager 当前 item：
  - `bookshelf` → 无操作（默认就在）
  - `explore` → 仅当 `showDiscovery=true` 才切；toggle 关闭时**保留** bookshelf
  - `rss` → 仅当 `showRSS=true` 才切；同上
  - `my` → 总是切（my tab 永久可见）

## 3. 影响文件

### 改写

- `flutter_app/lib/core/providers.dart` 加 1 个 enum + StateProvider + load/save：
  ```dart
  enum DefaultHomePage { bookshelf, explore, rss, my }
  // String 持久化（'bookshelf' / 'explore' / 'rss' / 'my'）对齐原版
  // android:defaultValue="bookshelf"
  final defaultHomePageProvider =
      StateProvider<DefaultHomePage>((_) => DefaultHomePage.bookshelf);
  Future<DefaultHomePage> loadDefaultHomePageFromDisk({String? directory}) =>
      readJsonKey<DefaultHomePage>(
        'defaultHomePage',
        (raw) => raw is String ? DefaultHomePageX.fromKey(raw) : DefaultHomePage.bookshelf,
        DefaultHomePage.bookshelf,
        directory: directory,
      );
  Future<void> saveDefaultHomePageToDisk(DefaultHomePage v, {String? directory}) =>
      writeJsonKey('defaultHomePage', v.key, directory: directory, errorTag: 'default home page');
  // extension DefaultHomePageX on DefaultHomePage { String get key; static DefaultHomePage fromKey(String s); }
  ```
  放在 `showRssProvider` 附近（line 308 之后），保持 hub-config 三件套邻接。

- `flutter_app/lib/main.dart` 启动 wire：
  - `await loadDefaultHomePageFromDisk()` + `defaultHomePageProvider.overrideWith(...)` 与 26c 同款
  - `WidgetsBinding.instance.addPostFrameCallback` 内（与 pendingRoute 兜底链同位置）按 enum + 当前 toggle 状态决定是否调 `router.go('/explore')` / `router.go('/rss')` / `router.go('/my')`：
    - bookshelf → 无操作
    - explore → 仅当 `showDiscovery == true`
    - rss → 仅当 `showRss == true`
    - my → 总是（my tab 永久可见）
  - **顺序**：pendingRoute 优先级 > defaultHomePage（已有 pendingRoute 走 pendingRoute，无 pendingRoute 才走 defaultHomePage）。

- `flutter_app/lib/features/settings/settings_page.dart` 「主页」分组追加 1 个 ListTile：
  - title「启动默认页」+ subtitle 显示当前选择的中文名（书架 / 发现 / 订阅 / 我的）
  - onTap 弹 `showDialog<DefaultHomePage>` 4 选 RadioListTile（与现有「书架排序」对话框同模式：用 `ListTile + trailing check` 而非已 deprecated 的 RadioListTile.groupValue/onChanged，对齐 BATCH-19a 决策）
  - 选完写 provider + saveDefaultHomePageToDisk
  - 插入位置：「主页」分组现有 2 SwitchListTile **下方**，作为第 3 项

### 不动

- 4 ShellBranch / initialLocation `/bookshelf`（router 默认仍是书架，启动后 postFrame 跳）
- 26c 的 showDiscovery/showRss toggle 逻辑
- pendingRoute 兜底链路

### 新增（spec）

- `quality-and-anti-patterns.md`「页面布局对齐 (BATCH-26)」段在「底栏 tab 显隐 toggle (BATCH-26c)」之后加「启动默认页 (BATCH-26d)」小节：
  - 原版锚（pref_config_other.xml + MainActivity upHomePage）
  - 实现契约：startup postFrame 跳；pendingRoute 优先；toggle 阻挡时回退 bookshelf
  - 与 26c 配合：选 explore/rss 但 toggle=false 时不跳

## 4. 测试策略

新增 `flutter_app/test/default_home_page_test.dart` 4-5 个 testWidgets：

1. **enum key round-trip** — `DefaultHomePage.values` 遍历 `.key` 再 `fromKey` 等价
2. **fromKey unknown → bookshelf** — `fromKey('garbage')` / `fromKey('')` 都回 bookshelf
3. **settings UI 显示选项** — pump SettingsPage，找到「启动默认页」ListTile 点开，4 选 RadioListTile 出现
4. **选后 provider 状态变化 + saveDisk 调用** — tap 「发现」选项 → provider state == DefaultHomePage.explore（用 ProviderContainer 验）

启动 router 跳转的实测在 `widget_test.dart` 加 1-2 个 case 即可（不强求新建 main 启动测试，main() 走 RustLib.init 不便 mock；启动跳转逻辑抽成 pure helper `applyDefaultHomePage(GoRouter, DefaultHomePage, {bool showDiscovery, bool showRss})` 便于单测）：

5. **applyDefaultHomePage 行为表** — 16 个组合（4 enum × showD/R 4 状态）的纯函数验
   - bookshelf → 永远不跳
   - explore + showDiscovery=true → router.go('/explore')
   - explore + showDiscovery=false → 不跳
   - rss + showRss=true → router.go('/rss')
   - rss + showRss=false → 不跳
   - my → 永远跳

baseline 552 → 552 + 5 = 557/557 期望。

## 5. 验收

- [ ] hub「其他设置」「主页」分组下加「启动默认页」ListTile（subtitle 显示当前选择）
- [ ] 点击弹 4 选对话框（书架 / 发现 / 订阅 / 我的）
- [ ] 选完写 provider + 持久化（settings.json `defaultHomePage` key）
- [ ] 重启后 app 启动到选定的 tab
- [ ] 选 explore 但关闭 showDiscovery → 启动到 bookshelf 兜底
- [ ] 选 rss 但关闭 showRss → 启动到 bookshelf 兜底
- [ ] pendingRoute 兜底链不破坏（pendingRoute 优先）
- [ ] flutter analyze 0 / flutter test PASS（baseline 552 + 5）

## 6. 不在范围

- O1：把 26c 的 2 toggle 升级成「3 项」（如「显示书架」） — 书架 / my 不可关，与原版一致
- O2：启动跳转动画（router.go 默认无动画，acceptable）
- O3：tab 当前可见时再次选同一 default 的二次跳（无意义）

## 7. 风险点

- **router.go vs goBranch**：startup 时 `_AppShell` 的 navigationShell 还没 mount，`goBranch` 不可用；用顶级 `router.go('/explore')` 让 GoRouter 自己定位 ShellBranch 即可（BATCH-26a 已验 4 ShellBranch 的 path 直接 router.go 是 OK 的）。
- **postFrame 时机**：启动 wire 链已有 pendingRoute 走 postFrame，再加 defaultHomePage 跳是同一帧顺序问题。pendingRoute 在前 / defaultHomePage 在后，pendingRoute 命中后用 `await clearPendingRoute()` 提前 return（避免双跳）。
- **enum 持久化**：选 String key 而非 int index — 与原版 SharedPreferences `"bookshelf"` 字面量对齐，未来加新 home page 时不会 index 错位（参考 BATCH-21c 选枚举优于 bool 的同款理由）。
- **SnackBar 时机**：默认页选完后用户感知不到立即效果（要重启才生效），加 SnackBar「下次启动生效」提示。
