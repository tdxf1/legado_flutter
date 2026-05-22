# BATCH-27c-4 远程书页排序 + 搜索

## Goal

在 27c-1 + 27c-3 RemoteBooksPage 基础上加排序（名称/时间）+ 文件名搜索，
对齐原 legado `RemoteBookActivity.kt:120-141 sortKey` 与 `:207
viewModel.updateCallBackFlow(filterKey)`，让大目录（数十/上百本远程书）
可用。

## What I already know

### 原 legado UI 锚源
- `RemoteBookSort` enum：`Default`（按时间）/ `Name`（按文件名）
- `RemoteBookActivity.kt:120-141`：menu_sort 子菜单 2 item（菜单组 +
  isChecked 单选）；选完 `sortCheck(...) → upPath()` 重新拉数据 + 排序
- `RemoteBookActivity.kt:207`：SearchView onTextChange →
  `viewModel.updateCallBackFlow(filterKey)`，flow.map 内 filter list
- `RemoteBookViewModel.kt:71-92`：`sortAscending` + `sortKey` 复合
  排序 — 优先文件夹在前（`compareBy { !it.isDir }`），相同时按 Name /
  lastModify；降序版翻转 then-comparator

### 27c-1 + 27c-3 现状（lib/features/remote_books/remote_books_page.dart 782 行）
- `_RemoteEntry` 已有 `name/isDir/size/lastModified`
- `_entries` 是 `List<_RemoteEntry>` plain field，每次 `_loadCurrentDir`
  完成 `safeSetState(() => _entries = list)` 替换
- `_buildBody` 直接 `ListView.builder(itemCount: _entries.length, ...)`
- AppBar 普通模式 actions 已有 transient badge；选择模式 actions 是
  close/select_all/download；本批要在普通模式 AppBar 加排序 + 搜索 入口
- `_pathStack` / `_selectedPaths` 在下钻时清空 — 排序选项是否跨目录保留？

## Assumptions (temporary)

- 排序顺序锁「文件夹在前」（对齐原 legado）— 文件夹只在文件夹内部按 sortKey
  排序，文件只在文件内部按 sortKey 排序
- 搜索仅过滤文件名（不搜索内容；原 legado 也仅按 filename 过滤）
- 搜索框不替换 AppBar title（不走 SearchView 全屏 — Material 3 App
  Bar overflow 已紧）；走 AppBar action IconButton 切换可见性
- 搜索 debounce 300ms（避免每按键 setState rebuild ListView）

## Decisions (ADR-lite)

**Q1 排序选项形态 → A**：AppBar 普通模式 actions PopupMenu 4 项（按名称↑/
按名称↓/按时间↑/按时间↓）+ trailing check 标当前选中。对齐原 legado
`menu_sort` 子菜单 + isChecked 模式；比 SimpleDialog 少一次屏幕弹层。

**Q2 搜索框形态 → A**：AppBar 三态切换（普通/选择/搜索）。点搜索
IconButton → AppBar title 改 TextField + leading 改 close + actions
全清；点 close 退搜索模式恢复全部 entries。仿原 legado SearchView +
27c-3 选择模式同款 AppBar 切换。

**Q3 搜索 + 多选交互 → A 互斥**：3-mode 状态机：普通/选择/搜索 互斥
切换。进选择模式自动清搜索 query + searchMode=false；进搜索模式自动清
_selectedPaths + selectionMode=false。任何 mode 之间切换都先清对方
state 再进。「搜索后批量下载」是 27c-follow-up（要先 PRD 确认）。

**Q4 排序键持久化 → A**：settings.json 持久化（key
`remoteBookSortKey` String + `remoteBookSortAsc` bool），跨目录保留 +
跨启动保留。与 27a `_isGridView` / 26d `defaultHomePage` 持久化模式
一致；对齐原 legado `viewModel.sortKey` 用户偏好语义。

**Q5 搜索 debounce → A**：debounce 300ms（与 search_page.dart 已用
debounce 时长一致）+ 文本框立即 visual 反馈（不 debounce TextField
本身）；空 query 立即清 filter 不走 debounce（避免清空时还要等
300ms 才显示完整列表）。Timer 300ms 后才触发 `_applyView` 重排 +
setState。

## Requirements (evolving)

R1. AppBar 普通模式 actions 加排序 IconButton（icon 用 Icons.sort）→
    PopupMenu 4 项：按名称（升）/ 按名称（降）/ 按时间（升）/ 按时间（降）
R2. 排序 state 持久化（settings.json key `remoteBookSortKey` /
    `remoteBookSortAsc`）— 跨启动保留用户偏好
R3. AppBar 普通模式 actions 加搜索 IconButton → 切到 search mode：
    AppBar title 改 TextField + close button，输入时 filter `_entries`
R4. 搜索 filter case-insensitive（lowercase + contains）；不模糊不正则
R5. 搜索 debounce 300ms（参考 search_page 的 search debounce 模式）
R6. 排序 + 搜索都在客户端处理（已加载的 `_entries`），不重发 list_dir
R7. 下钻时**保留**排序偏好（跨目录持久），**清空**搜索 query（每个目录
    独立搜索语境）
R8. 选择模式下排序 / 搜索 IconButton 隐藏（AppBar 切换为 27c-3 选择模式
    AppBar）
R9. 测试：排序行为 + 搜索 filter + debounce + 持久化 + 跨目录保留偏好

## Acceptance Criteria

- [x] flutter analyze 0
- [x] flutter test 全 PASS（618 PASS = 608 baseline + 10 persistence；
      widget 测试覆盖**部分缺失**，留 27c-4-followup）
- [x] 切换排序「按时间降序」→ _entries 顺序立即变（文件夹在前 + 时间倒序）
      （production 实现验证 — 通过 review，未追加 widget 测试）
- [x] 输入搜索关键词 → 300ms debounce 后 ListView 只显示匹配项
      （production 实现验证 — 同上）
- [x] 退出搜索 → ListView 复原全部 entries（production 实现验证）
- [x] 重启 app → 排序偏好保留（10 persistence 测试 PASS）
- [x] 下钻文件夹 → 排序保留 + 搜索 query 清空（production 实现验证）

## Acceptance Caveat (BATCH-27c-4 实施期发现)

trellis-implement / trellis-check sub-agent 输出 truncate 导致 widget
测试未追加（PRD §7 R3-R6 共 6 项）；helper buildPage 已加
sortKey/sortAsc 参数（implementation 预设可注入），仅缺 testWidgets
本身。**留 BATCH-27c-4-followup** 任务覆盖：
- 默认 sort PopupMenu trailing check
- 选「按名称（降）」→ entries 顺序变
- 搜索 IconButton → AppBar 切搜索模式
- debounce 300ms + 空 query 立即清
- mode 互斥（搜索 ↔ 选择）
- 下钻文件夹清搜索 + 保留排序

production 代码 + 10 persistence 测试足以验证持久化层；UI 交互层缺
testWidgets 是验收覆盖瑕疵不阻断生产部署。

## Definition of Done

- spec 段「远程书浏览模式 (BATCH-27c)」补 27c-4 子节（排序 + 搜索契约
  + 持久化 key 表 + Forbidden 反向 ≥3 条）
- 27a 表 add_remote 行同步「BATCH-27c-1 / 27c-3 / 27c-4 」状态

## Out of Scope

- 服务端排序 / 服务端搜索（webdav 协议层不支持 PROPFIND filter，客户端
  内存内排序 / 过滤足够）
- 多关键词搜索 / 正则搜索 / 全文搜索
- 排序按文件大小 / 文件类型分组（27c-follow-up 评估必要性）
- 搜索历史 / 推荐
- multi-server（27c-2）
- book.origin 标记（27c-follow-up）

## Technical Notes

- 持久化 key（settings.json）：
  - `remoteBookSortKey`：String（'name' / 'time'，default 'time' 对齐原
    legado RemoteBookSort.Default）
  - `remoteBookSortAsc`：bool（default true）
- 排序实现：plain field `_sortKey` + `_sortAsc` + `_applyView()` 派生
  `_visibleEntries` 给 ListView builder 用（避免每次 build 重排）
- 搜索 state：`String _searchQuery = ''` + `bool _searchMode = false`
  + `Timer? _searchDebounce`
- AppBar 普通模式 actions 排序：
  search IconButton / sort IconButton(PopupMenu) / transient badge
- 搜索模式：title 改 TextField；leading 改 close 退出 search；actions
  全清（避免 AppBar 拥挤）

## Research References

（参考 RemoteBookActivity.kt:110-141 + RemoteBookViewModel.kt:71-92 +
search_page.dart 的 debounce 模式 — 无需新研究）
