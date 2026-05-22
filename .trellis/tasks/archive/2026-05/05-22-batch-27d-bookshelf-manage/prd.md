# BATCH-27d bookshelf_manage 批量编辑书籍页

## Goal

把 27a 表 7 项「书架管理」灰显占位真正落地为新页面 `/bookshelf-manage`，
对齐原 legado `BookshelfManageActivity.kt:269-313` + `bookshelf_menage_sel
.xml` 的批量编辑流程：长按多选书 → 批量删除 / 批量改 canUpdate /
批量移分组 / 批量清缓存 / 列表头部分组筛选。

## What I already know

### 原 legado UI 锚源
- `BookshelfManageActivity.kt 417 行` + `BookshelfManageViewModel.kt 130 行`
- `bookshelf_manage.xml` 顶部 menu 3 项：分组（含 group_manage 子菜单 +
  动态分组列表）/ 导出全部使用书源 / 点击书名打开详情 toggle
- `bookshelf_menage_sel.xml` 选择 actionbar 7 项：删除 / 允许更新 /
  禁用更新 / 添加到分组 / 换源 / 清缓存 / 选中区间
- ViewModel 5 函数：upCanUpdate / updateBook / deleteBook /
  saveAllUseBookSourceToFile / changeSource / clearCache

### 现状（flutter_app）
- `bookshelf_page.dart:337-347` 灰显占位 'bookshelf_manage' enabled:false
- `core/bridge/src/api.rs`：
  - `delete_book(dbPath, id)` ✓ funcId 已落
  - `set_book_group(dbPath, id, groupId)` ✓ funcId 14
  - **缺**：`set_book_can_update(dbPath, id, canUpdate)` 批量改 canUpdate
  - **缺**：`clear_book_cache(dbPath, id)` 清缓存（删 chapter contents）
- `core/core-storage/src/book_dao.rs`：
  - `set_group` ✓ 已实现
  - `delete` ✓ 已实现
  - **缺**：`set_can_update` SQL UPDATE
- 27a/27c 已沉淀范本：
  - 长按选择模式（27c-3 RemoteBooksPage 模式 / 27c-4 mode 互斥）
  - 持久化 settings.json 走 readJsonKey/writeJsonKey
  - `*Override` 注入测试钩子
- 现 bookshelf_page 已有 `_moveBookToGroup`（单本，line 937）+
  GroupManageDialog（line 261）

## Assumptions (temporary)

- 走独立页面 `/bookshelf-manage`（路由 push）而非 inline 改造 bookshelf
  AppBar — 管理操作语义重，独立页面避免书架页 AppBar 状态机过载
- 选择模式机制完全套 27c-3 RemoteBooksPage 范本（singleton + selectionMode
  + Set<String> _selectedIds + AppBar 选择 actionbar）
- 7 项 actionbar 项**不全做**第一波 — 优先 4 项（删除 / 改 canUpdate /
  改分组 / 清缓存）；换源（依赖 SourcePickerDialog + WebBook 抓详情栈）
  + 选中区间（依赖 LongClickAction） + 导出全部书源（独立功能）留 27d
  follow-up
- 列表头部分组筛选（原 ViewModel `groupId` field）— MVP 暂不做（默认显
  示全部书架），保留 27d follow-up
- 「点击书名打开详情」toggle — MVP 暂不做（点击 = 进入选择模式或 navigate
  reader 二选一，看 Q 决定）

## Decisions (ADR-lite)

**Q1 清缓存语义 → A**：`UPDATE chapters SET content = NULL WHERE
book_id = ?`，保章节 row + meta（标题/index/order）+ 用户阅读进度
（books.chapter_index 字段不动）；下次阅读触发 update_chapter FRB 重抓
正文。完全对齐原 `BookHelp.clearCache(book)` 语义。新 FRB
`clear_book_cache(dbPath, id)` funcId 116。

**Q2 删除是否提供「同时删本地源文件」选项 → A**：confirm dialog 加
Checkbox「同时删除本地源文件」，**默认 unchecked** 保守安全；FRB 新建
`delete_book_with_file(dbPath, id, deleteFile: bool)` 不破坏现有
`delete_book` binary contract（funcId 117）；deleteFile=true 时对本地
书 (source_id='local') 删 local_books/<file>；远程书 (27c-1 下载到
remote_books/) 同样能删；非本地非远程书（webdav 已上架但用户没本地
缓存）忽略 file 删除。

**Q3 canUpdate toggle UI → A**：拆 2 个 actionbar 项「允许更新」/
「禁用更新」，仿原 legado；混合状态强制统一为目标状态。FRB
`set_book_can_update(dbPath, id, canUpdate: bool)` 单接口接受目标状态
参数（funcId 115）。

**Q4 AppBar 选择模式 actions 布局 → A**：close + title「选择 N 项」+
select_all IconButton + 删除 IconButton（高频直达）+ 「⋮」overflow
PopupMenu 含 4 项（允许更新 / 禁用更新 / 移分组 / 清缓存）；Material 3
ActionMenu 标准模式。删除是最高频意图直达，其余 4 项收 overflow 避免
小屏 AppBar 拥挤。

**Q5 移分组 dialog → A**：新建私有 `_GroupPickerDialog`（pick 语义
独立于 GroupManageDialog 的 CRUD 语义）；SimpleDialog + ListView.builder
（groups + 「未分组」option）+ onTap return groupId；caller 拿
groupId 后 forEach selectedIds 调 `set_book_group(dbPath, id, groupId)`。
不复用 GroupManageDialog 避免 mode prop 侵入扩展。

## 批量调用模式（implicit Q）

4 actionbar 操作都是本地 SQL（无网络）+ ~ms 级延迟，**不引 Runner**：

```dart
for (final id in selectedIds) {
  try {
    await rust_api.deleteBookWithFile(dbPath: dbPath, id: id,
        deleteFile: deleteFile);
    successCount++;
  } catch (e) {
    debugPrint('[BookshelfManage] delete $id failed: $e');
    failCount++;
  }
}
ref.invalidate(allBooksProvider);
ref.invalidate(booksByGroupProvider);
ScaffoldMessenger... 「批量删除完成：成功 X / 失败 Y」
```

Runner 模式（27b/27c-3）适用于网络 IO 的长任务（批量抓 toc / 批量
WebDAV 下载）；本批纯本地 SQL ms 级，简单 forEach + 静默 catch + 总结
SnackBar 即可，与 Runner 模式差异化决策记入 spec。

## Requirements (evolving)

R1. 路由 `/bookshelf-manage` + bookshelf 27a menu 第 7 项 `bookshelf_manage`
    enabled:true onTap context.push('/bookshelf-manage')
R2. 新页面 BookshelfManagePage：ListView 显示全部书（books_by_group
    或 allBooks fallback）+ 长按进选择模式（仿 27c-3 模式）
R3. 选择模式 AppBar：close / title 「选择 N 项」/ select_all / **批量
    actionbar**（4 项：删除 / 允许更新 toggle / 移分组 / 清缓存）
R4. 删除 actionbar：弹 confirm dialog → 调 delete_book per book →
    完成后 invalidate allBooksProvider
R5. canUpdate toggle actionbar：批量调 set_book_can_update（新 FRB）
    → 完成后 invalidate
R6. 移分组 actionbar：复用 GroupManageDialog 选 group → 批量调
    set_book_group → 完成后 invalidate
R7. 清缓存 actionbar：调 clear_book_cache（新 FRB，参考 BookHelp.clearCache：
    删 chapter content 但保 chapter row）→ 完成后 invalidate
    bookChaptersProvider
R8. 新增 FRB：set_book_can_update + clear_book_cache（funcId 115/116 双
    新增）；frb_generated.rs 手编 wire impl + dispatcher arm；build.rs
    REQUIRED_*_FRAGMENTS 加守卫
R9. 测试：BookshelfManagePage testWidgets ≥6（长按选择 / 4 actionbar
    各 1 + spec compliance）+ 新 FRB Rust 端单测
R10. 27a 表 第 7 项 bookshelf_manage 状态同步「BATCH-27d」

## Acceptance Criteria

- [ ] flutter analyze 0
- [ ] flutter test 全 PASS（≥625 baseline + 新 ≥6 widget = ≥631）
- [ ] cargo build --workspace OK / cargo test --workspace 全 PASS
- [ ] 长按一本 → 选择模式启动 + Checkbox + actionbar 出现
- [ ] 删除 5 本 → confirm → invalidate → 书架重拉
- [ ] 改 canUpdate 5 本 → invalidate → 27b update_toc 看到 filter 变化
- [ ] 移分组 5 本 → 选 group → 全 5 本 group_id 变
- [ ] 清缓存 5 本 → bookChaptersProvider 重拉空 contents

## Definition of Done

- spec 「页面布局对齐 (BATCH-26)」段补 27d 子节（批量编辑模式契约 +
  Forbidden 反向 ≥3 条）
- 27a 表第 7 行 bookshelf_manage 同步「已实现（BATCH-27d）」
- 27c-3 选择模式范本被 27d 复用（沉淀「批量编辑选择模式范本」段）

## Out of Scope

- 换源（依赖 SourcePickerDialog + WebBook 抓详情栈）→ 27d-followup
- 选中区间（双击+长按起止）→ 27d-followup
- 导出全部使用书源 → 独立功能，不在 27d
- 列表头部分组筛选 → 27d-followup（默认全部书架）
- 「点击书名打开详情」toggle → 27d-followup
- search filter 列表（27c-4 已为 RemoteBooksPage 落，bookshelf-manage
  另一栈）→ 27d-followup

## Technical Notes

- 路由：`features/bookshelf/bookshelf_manage_page.dart` 新建
- 选择模式 state：`bool _selectionMode + Set<String> _selectedIds`
  （key=book.id）+ 沿袭 27c-3 PopScope 优先级（选择→页面）
- 新 FRB:
  - `set_book_can_update(db_path, id, can_update) -> Result<(), String>`
    funcId 115
  - `clear_book_cache(db_path, id) -> Result<(), String>` funcId 116
    （DELETE FROM chapters WHERE book_id = ? — 仅删 contents，row 保留？
    或 UPDATE contents = NULL 留 row + index — 看 Q 决定）
- BookDao 新方法：set_can_update + clear_cache_for_book
- 测试隔离：BookshelfManagePage 多 *Override（dbPathOverride /
  documentsDirOverride / deleteOverride / setCanUpdateOverride /
  setBookGroupOverride / clearCacheOverride / allBooksOverride 注入
  fixture List<Map>）

## Research References

（参考 BookshelfManageActivity:269-313 onCompatOptionsItemSelected +
:299-314 onMenuItemClick + ViewModel 5 函数 + 27c-3 选择模式范本 — 无需
新研究）
