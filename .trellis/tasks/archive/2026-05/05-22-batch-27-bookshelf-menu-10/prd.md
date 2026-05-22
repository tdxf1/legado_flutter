# BATCH-27a bookshelf 顶部 menu PopupMenu 13 项对齐 + layout 对话框 + export FRB

> **范围已锁定**（Q1-Q5）：
> - Q1: 27a 真做 2 + 灰显 6
> - Q2: 真做 layout 对话框 + export_bookshelf_json
> - Q3: documents_dir/books.json
> - Q4: layout dialog 仅列表/网格 2 选
> - Q5: PopupMenu 严格原 main_bookshelf.xml 顺序

**Stage**: P2
**Slug**: `batch-27a-bookshelf-menu-light`
**Effort**: M (~300-400 行)
**Depends on**: BATCH-26a ✅
**对照原版**：`main_bookshelf.xml` 12 项 + `BaseBookshelfFragment.kt:96-121` handler

## Goal

把 BATCH-26a 留下的占位补齐：原 legado bookshelf PopupMenu 12 项，flutter 已实现 4 项（搜索 / 缓存导出 / 管理分组 / 导入本地书），剩 8 项中的轻量 5 项（add_url / export_bookshelf / import_bookshelf / bookshelf_layout / log）落地为真功能或灰显占位。重量 3 项（update_toc / bookshelf_manage / remote）留独立批次（27b/c/d）灰显占位先填上。

## What I already know

### 原 legado 菜单 12 项映射（`main_bookshelf.xml` + `BaseBookshelfFragment.kt:96-121`）

| # | 原 menu id | 中文 | 原行为 | flutter 现状 | 27a 处理 |
|---|---|---|---|---|---|
| 1 | menu_search | 搜索 | startActivity<SearchActivity> | ✅ AppBar IconButton | 不动 |
| 2 | menu_update_toc | 更新目录 | activityViewModel.upToc(books) 批量刷目录 | ❌ | 灰显占位（需后端批量 API） |
| 3 | menu_add_local | 添加本地书 | startActivity<ImportBookActivity> 批量文件选 | 🟡 单文件「导入本地书」 | 不动（27b 升级） |
| 4 | menu_remote | 添加远程书 | startActivity<RemoteBookActivity> WebDAV 浏览 | 🟡 webdav-config 在但无浏览页 | 灰显占位（27c 真页面） |
| 5 | menu_add_url | 添加网络URL | showAddBookByUrlAlert + WebBook URL pattern 匹配 | ❌ | **真功能** dialog + FRB add_book_by_url |
| 6 | menu_bookshelf_manage | 书架管理 | startActivity<BookshelfManageActivity> 批量编辑 | ❌ | 灰显占位（27d 批量编辑页） |
| 7 | menu_download | 缓存/导出 | startActivity<CacheActivity> | ✅ → /downloads | 不动 |
| 8 | menu_group_manage | 分组管理 | showDialogFragment<GroupManageDialog> | ✅「管理分组」 | 不动 |
| 9 | menu_bookshelf_layout | 书架布局 | configBookshelf() 列表/网格 | 🟡 _isGridView 切换在 | **真功能** SimpleDialog 列表/网格选 |
| 10 | menu_export_bookshelf | 导出书架 | viewModel.exportBookshelf JSON | ❌ | **真功能** FRB export_bookshelf_json + share/save |
| 11 | menu_import_bookshelf | 导入书架 | importBookshelfAlert URL/JSON 文本 | ❌ | **真功能** dialog 粘贴 JSON + FRB import_bookshelf_json（仅 JSON 文本，URL fetch 留 follow-up） |
| 12 | menu_log | 日志 | showDialogFragment<AppLogDialog> | ❌ | 灰显占位（无统一日志收集机制） |

### 后端 FRB 现状（`core/bridge/src/api.rs`）

- `save_book(db_path, book_json)` 单本插入存在 ✅
- `import_local_book(db_path, file_path, documents_dir)` 单文件 TXT/EPUB/UMD 存在 ✅
- `export_all_sources(db_path)` 书源 JSON 导出存在 ✅
- ❌ 缺：`export_bookshelf_json` / `import_bookshelf_json` / `add_book_by_url` 这三个新 FRB 要加
- 原版 `add_book_by_url` 依赖 BookSource 的 `book_url_pattern` 正则匹配 + `WebBook.getBookInfo` 抓详情 — flutter 后端有 `book_url_pattern` 字段（`api.rs:2522`）但无 `WebBook.preciseSearch` 等价。

### flutter PopupMenu 现状（`bookshelf_page.dart:132-193`）

4 项：管理分组 / 导入本地书 / 缓存/导出 / 扫码导入（最后一项是 flutter 自加，原版无；保留即可）。

## Requirements

### A. PopupMenu 结构对齐（13 项排序对齐原版）

按原 `main_bookshelf.xml` 顺序重排，13 项 = 原 12 项 + flutter「扫码导入」（保留位于「导入本地书」附近）：

```
1. 搜索（已是 AppBar IconButton，不动）
2. 更新目录（灰显，27 占位）
3. 添加本地书（已实现「导入本地书」）
4. 添加远程书（灰显，27 占位）
5. 添加网络URL（真功能，dialog + FRB）
6. 扫码导入（flutter 自加，保留）
7. 书架管理（灰显，27 占位）
8. 缓存/导出（已实现 → /downloads）
9. 分组管理（已实现「管理分组」）
10. 书架布局（真功能 SimpleDialog 列表/网格切换）
11. 导出书架（真功能 FRB JSON 导出）
12. 导入书架（真功能 dialog 粘贴 JSON + FRB）
13. 日志（灰显占位）
```

### B. 新增 FRB API（核心改动）

1. `pub fn export_bookshelf_json(db_path: String) -> Result<String, String>` — 把书架所有 Book 拉成 JSON Array（{name, author, intro}）按原版 `BookshelfViewModel.kt:102-128` 写
2. `pub fn import_bookshelf_json(db_path: String, json: String, group_id: i64) -> Result<i32, String>` — 解析 JSON Array，对每条 {name, author} 在 BookSource 里做 search 匹配后插入；返回成功数。
   - **简化版**：先做最小路径 — 仅插入 BOOK 记录（name + author + group_id + intro，无 BookSource origin），用户加完后自己在书源管理里走 search 流程；或仅当 books 表里同 (name, author) 已存在则跳过。原版 `WebBook.preciseSearch` 大改造留 follow-up。
   - **再简化**：仅当用户能凑齐 origin（书源URL）+ bookUrl 时才插，否则 SnackBar「需补充书源」— 此版本 27a 暂不做完整 search，定位为「JSON 元数据导入」便于备份恢复
3. `pub async fn add_book_by_url(db_path: String, url: String) -> Result<i32, String>` — 走原版 URL → BookSource.book_url_pattern 正则匹配 → WebBook.getBookInfo 抓详情 → 插入 books 表。这个**重量级**，和「真 search」依赖同一栈。**评估后建议留 27 后续批次**，27a 暂用灰显占位

→ **范围微调**：27a 真做 2 项（layout 对话框 + export_bookshelf JSON），轻量 3 项（add_url / import_bookshelf / log）灰显占位，重量 3 项也灰显占位。

### C. UI 改动

- `bookshelf_page.dart:132-193` PopupMenu 重排为 13 项，灰显项 `enabled: false`（不写 onTap，对齐 BATCH-26b 决策）
- 新增私有 `_showLayoutDialog(context)` — SimpleDialog + 2 ListTile（列表 / 网格）+ check trailing，对齐 BATCH-19a 决策
- 新增私有 `_onExportBookshelf(context)` — 调 FRB export_bookshelf_json → write 到 documents_dir/books.json → SnackBar 提示路径
  - 不强求 share intent / file_picker（保持 27a 范围内）；用户自己去文件管理器找

### D. 新增 spec 段

`quality-and-anti-patterns.md`「页面布局对齐 (BATCH-26)」段在「启动默认页 (BATCH-26d)」之后加「bookshelf 顶部 menu (BATCH-27a)」小节：

- 13 项映射表（含已实现 / 真功能 / 灰显占位 3 类）
- 灰显占位的判断准则：依赖未实现 FRB API / 依赖新页面 → 灰显
- 真功能项的实现契约（layout 对话框 + export FRB）
- Forbidden 反向：灰显项不要弹 SnackBar / 不要把灰显项对应 FRB 改成 hardcoded 假数据

## Acceptance Criteria

- [ ] PopupMenu 13 项与原 legado 顺序 1:1 对齐
- [ ] 灰显项（更新目录 / 添加远程书 / 添加网络URL / 书架管理 / 导入书架 / 日志）`enabled: false` 不弹 SnackBar
- [ ] 「书架布局」点击弹 SimpleDialog 2 项（列表 / 网格）+ check trailing；选完写 `_isGridView` + 持久化（与现 `Icons.list/Icons.grid_view` IconButton 同步）
- [ ] 「导出书架」点击调 FRB → JSON 写入 documents_dir/books.json → SnackBar 显示路径；空书架时按钮可点但 SnackBar「书架为空」
- [ ] FRB `export_bookshelf_json(db_path)` 返回 `Result<String, String>`，对齐原版 `BookshelfViewModel.kt:102-128` 字段（name/author/intro）
- [ ] flutter analyze 0 / flutter test 全 PASS（baseline 567 → ~575 期望，layout dialog × 2-3 + export × 2-3 + 灰显 × 1 + 顺序 × 1）
- [ ] spec 入「页面布局对齐 (BATCH-26)」段「bookshelf 顶部 menu (BATCH-27a)」小节

## Definition of Done

- 测试覆盖：layout dialog（默认 list / 切到 grid 后 _isGridView=true / check 标记跟随）+ export 调用（mock FRB 返回 JSON / SnackBar 显示路径）+ 灰显项 enabled: false 验收
- spec 文档化：13 项映射表 + 真功能契约 + Forbidden 反向 4 条
- 后端 Rust：`export_bookshelf_json` 单元测试（空书架 / 有书架 fixture）

## Out of Scope (27a)

- O1：menu_add_url 真功能（依赖 WebBook 抓详情栈，留 27 follow-up）
- O2：menu_import_bookshelf 真功能（依赖 search 栈或简化版「仅元数据」需做产品决策，留 27 follow-up）
- O3：menu_update_toc 批量刷目录（需 FRB 批量 API + 后台进度，留 27b）
- O4：menu_bookshelf_manage 批量编辑页（独立大页面，留 27c）
- O5：menu_remote 远程书浏览（独立大页面，留 27d）
- O6：menu_log 日志收集机制（无统一日志收集机制，留独立批次）
- O7：menu_add_local 单文件 → 多文件升级（留 27 follow-up）
- O8：导出后 share intent / file_picker 选位置（保持简化版）

## Decision (ADR-lite)

**Context**：原 legado 12 项 menu 中 8 项缺失 / 部分缺失，全做工作量 ~1000 行 + 风险大。轻量 5 项里 add_url / import_bookshelf / log 这 3 项又依赖外部能力（FRB 重写或日志机制），实质轻量的只剩 layout + export 2 项。

**Decision**：27a 真做 2 项（layout 对话框 + export JSON）+ 6 项灰显占位（更新目录 / 远程书 / 添加URL / 书架管理 / 导入书架 / 日志）。结构对齐原版 13 项顺序，让用户感知到「能力地图」即使大部分还没填。

**Consequences**：
- 短期：用户看到大量灰显项可能困惑「为啥这么多没做」 — 需 SnackBar 之外的指引（spec 注明灰显本身就是信号，不弹 SnackBar 对齐 26b）
- 中期：后续批次只需把灰显项改 enabled: true + onTap，迁移成本最低
- 远期：4 个 follow-up 批次（27b update_toc / 27c manage / 27d remote / 27e add_url+import）让重活按需推进，不堵 26 主线收尾

## Technical Notes

- `flutter_app/lib/features/bookshelf/bookshelf_page.dart:132-193` PopupMenu 主改文件
- `core/bridge/src/api.rs` 新增 `export_bookshelf_json` FRB（参考 `export_all_sources:919` 同模式）
- 原 legado 锚源码：
  - `app/src/main/res/menu/main_bookshelf.xml` 12 项 menu 定义
  - `app/src/main/java/io/legado/app/ui/main/bookshelf/BaseBookshelfFragment.kt:96-121` handler 映射
  - `app/src/main/java/io/legado/app/ui/main/bookshelf/BookshelfViewModel.kt:102-128` exportBookshelf 实现
- BATCH-26b 决策回顾：灰显项 `enabled: false`，**onTap 不写**（不弹 SnackBar），灰显本身就是信号
- BATCH-19a 决策回顾：对话框选项用 `SimpleDialog + ListTile + check trailing`，不用 deprecated `RadioListTile.groupValue`
- BATCH-26b 测试钩子：用 `routerDelegate.currentConfiguration.matches.last.matchedLocation` 验路由（go_router 14 imperative push uri 字段不更新）
