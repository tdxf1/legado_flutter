# 对齐原 Legado Android 项目的页面布局

## Goal

让 flutter_app 的导航结构 / 页面层级 / 入口位置对齐原项目（Android Legado / Legado-with-MD3），减少功能错位与心智差异。范围与精度由 brainstorm 收敛。

## What I already know

### 原项目（Android Legado，参照对象 = `/root/data/workspaces/doro_FriendMessage_641981595/legado/`）

- **MainActivity 顶层 4 tab 底部导航**（`main_bnv.xml` 0-3 槽位）：
  1. 书架 (Bookshelf, BookshelfFragment)
  2. 发现 (Explore, ExploreFragment) — 各书源的 explore 分类入口
  3. 订阅 (Rss, RssFragment) — RSS 源列表
  4. 我的 (My, MyFragment) — Preference 风格 hub
- **书架顶部 menu (`main_bookshelf.xml`)** 12 项：
  - 顶部 search icon (always)
  - overflow: 更新目录 / 本地导入 / 添加远程书 / 添加在线书 / 书架管理 / 离线缓存 / 分组管理 / 书架布局 / 导出书架 / 导入书架 / 日志
- **发现顶部 menu (`main_explore.xml`)**：分组筛选
- **订阅顶部 menu (`main_rss.xml`)**：收藏 / 分组 / RSS 源设置（订阅源管理）
- **我的页 (`pref_main.xml`)** 14 项 + 3 分组：
  - 第一组（无标题）：书源管理 / TXT 目录规则 / 替换净化 / 字典规则 / 主题模式（drop-down） / Web 服务（switch）
  - 「设置」分组：备份与恢复 / 主题设置 / 其他设置
  - 「其它」分组：书签 / 阅读记录 / 文件管理 / 关于 / 退出

### 当前 flutter_app

- **顶层 5 tab 底部导航**（`flutter_app/lib/core/router.dart:155-200`）：
  1. 书架
  2. 搜索 (`/search`)
  3. 书源 (`/sources`)
  4. 下载 (`/downloads`)
  5. 设置 (`/settings`)
- 二级页面 18 条 GoRoute：reader / replace-rules / book-info-edit / backup / webdav-config / read-stats / cache-management / rss-source-manage / rss-articles / rss-articles-detail / rss-favorites / rule-subs / qr-scan
- 已实现 features 目录：`bookshelf / search / source / download / settings / replace_rule / rss / rule_sub / qr / reader`

### 差异点（精确版）

| 维度 | 原 legado | 当前 flutter | 差距 |
|---|---|---|---|
| 底部 tab 数 | 4 | 5 | 改结构 |
| Tab 1 书架 | ✓ BookshelfFragment | ✓ /bookshelf | 大致对齐 |
| Tab 2 | 发现 (Explore) | 搜索 | 概念错位：Explore = 各书源分类入口；flutter 把搜索提为 tab |
| Tab 3 | 订阅 (Rss) | 书源 | 错位：原 RSS 源列表在 tab 3；flutter RSS 入口埋在 PopupMenu |
| Tab 4 | 我的 (My) | 下载 | 错位：原"我的"是 hub；flutter 把下载提为 tab |
| Tab 5 | — | 设置 | flutter 多出 |
| 书源管理 | 我的 → 书源管理 | tab 3 /sources | 不在同一层 |
| 设置 | 我的 → 设置（其他设置） | tab 5 /settings | 不在同一层 |
| RSS 源管理 | tab 3 顶部 menu → RSS 源设置 | bookshelf PopupMenu → /rss-source-manage | 隐藏太深 |
| RSS 收藏 | tab 3 顶部 favorite icon | bookshelf PopupMenu → /rss-favorites | 隐藏太深 |
| 搜索 | 书架顶部 search icon (always) | tab 2 /search | 提升为 tab |
| 发现 | tab 2 ExploreFragment | 未实现 | 完全缺失 |
| 我的 hub 页 | tab 4 MyFragment + pref_main.xml | 未实现 | 完全缺失 |
| 替换规则 | 我的 → 替换净化 | settings → 替换规则 | 入口位置不一致 |
| 备份与恢复 | 我的 → 设置组 → 备份与恢复 | settings → 备份 | 入口位置不一致 |
| 阅读记录 | 我的 → 其它组 → 阅读记录 | settings → 阅读统计 | 入口位置不一致 |
| 书签全局列表 | 我的 → 其它组 → 书签 | 未实现 | 缺失 |
| 文件管理 | 我的 → 其它组 → 文件管理 | 未实现 | 缺失 |
| 关于 | 我的 → 其它组 → 关于 | 未实现 | 缺失 |
| 退出 | 我的 → 其它组 → 退出 | 未实现 | 缺失（一般 app 不需要） |
| TXT 目录规则 | 我的 → TXT 目录规则 | 未实现 | 缺失 |
| 字典规则 | 我的 → 字典规则 | 未实现 | 缺失 |
| Web 服务 | 我的 → Web 服务 switch | 未实现 | 缺失 |
| 主题模式 | 我的 → 主题模式 drop | settings 内 | 入口位置不一致 |
| 主题设置 | 我的 → 设置组 → 主题设置 | 未实现独立页 | 缺失 |
| 离线缓存 | 书架 menu → 离线缓存 | settings → 缓存管理 | 入口位置不一致 |
| 本地导入 | 书架 menu → 本地导入 | bookshelf PopupMenu | 入口大致对齐 |
| 分组管理 | 书架 menu → 分组管理 | bookshelf 长按 sheet | 入口位置略不同 |

## Assumptions (temporary)

- A1：参照对象是 `legado-with-MD3` 的 4 tab 结构（更新；MD3 + Compose），而不是经典 legado 的 ViewPager 式 4 tab。两者 destination 一致，UI 风格不同。
- A2：用户希望 **结构 + 入口位置** 对齐，不要求像素级 UI 复刻（Compose 视觉与 flutter Material3 仍允许差异）。
- A3："未实现的功能就先用文本占位 + 跳转到页面的就先提示待实现"——意思是新增"发现 / 我的 hub"骨架页时，未实现的子项用占位 ListTile + SnackBar/Toast 提示"待实现"，不去抠每个子页面真实功能。
- A4：现有已实现的页面（reader / search / source / settings / rss-* / replace-rule / cache-management 等）尽量复用，仅调整入口与导航位置，不重写其内容。

## Open Questions

（已收敛，全部移入 Decision）

## Requirements

R1 router 顶层改 4 tab，destination = bookshelf / explore / rss / my，对齐 `legado/main_bnv.xml`。
R2 现有 5 tab 内容映射：
- `/search` 退出 tab，由书架顶部 search icon (always) + GoRouter `context.push('/search')` 入。
- `/sources` (书源管理) 退出 tab，移入「我的」hub 第一组「书源管理」。
- `/downloads` 退出 tab，移入**书架 AppBar PopupMenu**「缓存/导出」项（对齐原 `main_bookshelf.xml` line 44-47 `menu_download` 用 `@string/cache_export` 文案），不去 hub。原项目没有"下载"作为独立 tab/页。
- `/settings` 退出 tab，移入「我的」hub「设置」分组下的「其他设置」入口；hub 第一组直接含「书源管理 / TXT 目录规则 / 替换净化 / 字典规则 / 主题模式 / Web 服务」等顶级项。
R3 新增「发现」tab `/explore` 骨架页：AppBar 标题 / Center 占位文本「发现待实现」+ 图标。空 UI，不接 ViewModel。
R4 新增「我的」hub `/my` 页面：1:1 复刻 `pref_main.xml` 14 项 + 3 分组结构。已实现项 onTap 跳现有 GoRouter 路径；未实现项灰显 + onTap=null。
  - 第一组（无标题）：书源管理 (→/sources) / TXT 目录规则 (灰) / 替换净化 (→/replace-rules) / 字典规则 (灰) / 主题模式 (灰，留 settings 内） / Web 服务 (灰)
  - 「设置」分组：备份与恢复 (→/backup) / 主题设置 (灰) / 其他设置 (→/settings)
  - 「其它」分组：书签 (灰) / 阅读记录 (→/read-stats) / 文件管理 (灰) / 关于 (灰) / 退出 (灰)
  - **不在 hub 的迁移项**：缓存/导出 (→书架 PopupMenu) / RSS 源管理 (→RSS tab 顶部 menu「设置」icon) / RSS 收藏 (→RSS tab 顶部 menu「收藏」icon) / 订阅源 (RuleSub) — 留独立项位置 26b 决定 / 二维码扫描 (各页 AppBar 已有，不动)。
R5 RSS 收藏 / RSS 源管理 由原 bookshelf PopupMenu 入口同步删除（避免双入口），全部归集到 RSS tab 顶部 menu（对齐 `main_rss.xml`：收藏 / 分组 / 设置三个 always icon）。
R6 占位策略：未实现子项 ListTile + `enabled: false`（灰显）+ onTap = null；不弹 SnackBar；保留显示项让对照原版可见。

## Acceptance Criteria

- [ ] flutter analyze 0 / flutter test PASS（baseline 542，允许某些 search/source tab 测试需要按入口路径调整）
- [ ] 顶部 4 NavigationDestination：书架 / 发现 / 订阅 / 我的，icon 与原版语义一致
- [ ] 4 个 StatefulShellBranch + initialLocation `/bookshelf`
- [ ] `/explore` 占位页存在并能从 tab 进入
- [ ] `/my` hub 页存在，pref_main.xml 14 项全部可见，已实现项 onTap 工作，未实现项灰显
- [ ] 书架 AppBar 加 search icon → `context.push('/search')`，原 `/search` 路由仍可用
- [ ] 原 5 tab 内容（search / sources / downloads / settings）全部能从新路径进入
- [ ] bookshelf PopupMenu 删除迁去 RSS tab / My hub 的入口，避免双入口
- [ ] 决策入 spec `quality-and-anti-patterns.md`「页面布局对齐 (BATCH-26)」段

## Technical Approach

### BATCH-26a 路由主脉重构（约 300-400 行）

- 改写 `flutter_app/lib/core/router.dart`：
  - `StatefulShellRoute.indexedStack` 4 branch（bookshelf/explore/rss/my）
  - 新建 `flutter_app/lib/features/explore/explore_page.dart` 骨架占位页（AppBar + Center 文本）
  - 新建 `flutter_app/lib/features/my/my_hub_page.dart` 骨架（先空 ListView）
  - 保留 18 条二级 GoRoute（reader / replace-rules / book-info-edit / backup / webdav-config / read-stats / cache-management / rss-source-manage / rss-articles / rss-articles-detail / rss-favorites / rule-subs / qr-scan）—— 但 `/search` `/sources` `/downloads` `/settings` 从 ShellBranch 移到顶级 GoRoute
- bookshelf AppBar 加 search IconButton → `context.push('/search')`
- bookshelf PopupMenu 加「缓存/导出」项 → `context.push('/downloads')`（沿用现有 download_page.dart 实现，title 改文案）
- bookshelf PopupMenu 删除已迁出项（rss-source-manage / rss-favorites），保留：本地导入 / 添加远程 / 添加 URL / 书架管理 / 离线缓存(下文「缓存/导出」) / 分组管理 / 书架布局 / 导入导出书架 / 日志（这些等 26b/未来批再细化）
- RSS tab 顶部 menu 加 3 个 always icon（收藏 / 分组 / 设置），分别 push `/rss-favorites` / 占位 / `/rss-source-manage`
- 测试：`flutter test` 跑全量 + 修任何因路由变更失败的 widget test

### BATCH-26b 「我的」hub 内容填充（约 200 行）

- 在 `my_hub_page.dart` 实现 pref_main.xml 1:1 结构：
  - 用 `ListView` + `_GroupHeader` widget 模拟 PreferenceCategory 标题
  - 每项一个 `_HubTile` widget（icon + title + summary + onTap）
  - 灰显项 `enabled: false`
- 复用现有 GoRouter 路径，不改任何二级页面内部
- 文档：spec 加一段「页面布局对齐」记录 4 tab destination 映射 + hub 14 项映射表 + 占位规则

## Decision (ADR-lite)

**Context**：原 legado/ 4 tab 结构（书架/发现/订阅/我的） vs flutter 5 tab（书架/搜索/书源/下载/设置）差距大，影响用户心智迁移成本与功能可发现性（RSS/书源管理在 flutter 都被埋深）。

**Decision**：选 A 精度（4 tab 重构 + 二级入口迁移 + 2 hub 骨架），B 拆批（router / hub 填充），未实现项 B 占位（灰显 + 禁用）。

**Consequences**：
- 短期：bookshelf PopupMenu / settings 内某些入口位置变化，用户需要重新熟悉一次。
- 中期：未实现项的对照可见 → 后续每个真功能落地时只需替换灰显 ListTile 的 enabled + onTap，迁移成本最低。
- 远期：原 legado pref_main.xml 14 项 + 3 分组结构成为对照锚，新加管理类页面默认归入 hub，避免重新出现 5/6 tab 蔓延。
- 风险：StatefulShellRoute branch 切换可能让原本在 tab 上的 page state（搜索结果 / 书源列表）丢失，要在 26a 测试时确认。

## Out of Scope

- O1：「发现」tab 的真实业务逻辑（书源 explore 分类拉取/展示）—— 26a 仅占位
- O2：原版书架顶部 menu 12 项的剩余 9 项（更新目录 / 添加远程书 / 书架管理 / 书架布局 / 导出书架 / 导入书架 / 日志）—— 留独立 follow-up
- O3：原版 RSS tab 顶部「分组筛选」业务逻辑（菜单子项动态生成）—— 26a 仅 push 到占位或现有页
- O4：MD3 expressive UI 风格（GlassTopAppBar / GlassCard）复刻 —— 不做
- O5：现有二级页面（reader / sources / settings / search 等）内部内容重构 —— 不做
- O6：「退出」按钮真功能（一般 Flutter app 不需要显式 exit）—— 灰显占位即可

## Technical Notes

- 当前 router：`flutter_app/lib/core/router.dart`
- 当前 5 tab：bookshelf / search / sources / downloads / settings
- 原项目 4 tab destination：bookshelf / explore / rss / my
- 原"我的" 聚合项：书源管理 / 替换规则 / TXT 目录规则 / 字典规则 / 设置 / 书签 / 阅读记录 / 缓存管理 / 文件管理 / 关于 / 退出 / Web 服务
- flutter 已实现对应：书源管理(/sources) / 替换规则(/replace-rules) / 设置(/settings) / 阅读记录(/read-stats) / 缓存管理(/cache-management) / 备份(/backup) / RSS 收藏(/rss-favorites) / 订阅源(/rule-subs)
- flutter 未实现对应：发现 (Explore) / 书签全局列表 / TXT 目录规则 / 字典规则 / 文件管理 / 关于 / Web 服务

## Research References

待 Q1 后按需 dispatch research sub-agent。
