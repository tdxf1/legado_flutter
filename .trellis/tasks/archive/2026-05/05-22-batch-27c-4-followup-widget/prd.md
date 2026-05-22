# BATCH-27c-4-followup 远程书页排序+搜索 widget 测试补齐

## Goal

补 27c-4 PRD §7 R3-R6 缺失的 widget 测试（≥6 项），覆盖 sort PopupMenu /
search AppBar 三态切换 / debounce / mode 互斥 / 下钻清搜索保留排序。
production 代码 + helper buildPage 注入参数已就绪，仅缺 testWidgets 本身。

## Background

BATCH-27c-4 实施期 sub-agent 输出 truncate 导致 widget 测试未追加；
implement / check 两次 dispatch 都断在「准备追加 widget 测试」时。
production 代码（providers + page 1009 行）齐全且 `buildPage` helper
已加 sortKey/sortAsc 参数（line 54-72 of remote_books_page_test.dart）。

## What I already know (production hooks 已就绪)

- `_visibleEntries` getter (page line 198) 派生：sortKey + sortAsc 排序
  + 文件夹永远在前 + searchQuery filter
- 排序 PopupMenu 4 项 trailing check：`_sortKey == key && _sortAsc == asc`
  (page line 856)
- 搜索 IconButton → `_enterSearchMode` (line 794) → `_buildSearchAppBar`
  (line 742)
- mode 互斥：`_enterSelectionMode` 内 `if (_searchMode) ...` (line 452)；
  `_onLongPressEntry` 内 `if (_searchMode) return;` (line 477)
- debounce 300ms `_onSearchChanged` (line 895)：cancel + Timer 300ms
  setState；空 query 立即 setState 不走 debounce
- 下钻 `_onTapEntry` folder 分支 → 清 _searchQuery + 退搜索模式 (line 408)
- testKey override：`sortKeyOverride / sortAscOverride` (line 100/114)
- 既有 helper `buildPage(... sortKey, sortAsc)` (line 54-72)

## Requirements

R1. **默认 sort PopupMenu trailing check**：默认 sortKey='time' /
    sortAsc=true → 开 sort PopupMenu，验「按时间（升）」trailing
    `Icon(Icons.check)`，其它 3 项 trailing null（findsNothing）

R2. **选「按名称（降）」→ entries 顺序变**：注入 entries
    `[folderA(dir), fileC.txt(time newest), fileA.txt, fileB.txt]`，
    默认 sort time asc → fileA-A → fileB-B → fileC-C 中 fileC 最新；
    选 sort name desc：第 0 项 = folderA（**文件夹永远在前**），第 1-3 项
    fileC > fileB > fileA 字母倒序

R3. **搜索 IconButton → AppBar 切搜索模式**：普通模式 actions 验有
    Icons.search IconButton；点击后 AppBar title 变 TextField
    （`find.byType(TextField)` findsOneWidget）+ leading 变 close
    （`find.byIcon(Icons.close)` findsOneWidget）+ 不再有 sort
    PopupMenu actions（`find.byIcon(Icons.sort)` findsNothing）

R4. **debounce 300ms + 空 query 立即清**：
    - 输入 'fil' → tester.pump(Duration(ms: 100)) 此时 _searchQuery 仍
      空，所有 entries 可见
    - tester.pump(Duration(ms: 250)) 累计 350ms → debounce 触发，
      ListView 仅 'fileXxx' 项可见
    - 清空 TextField → 不需 pump 300ms，立即下一帧 ListView 复原全部

R5. **mode 互斥（搜索 → 选择阻断）**：搜索模式下长按文件 → onLongPress
    被 `if (_searchMode) return;` 拦截 → AppBar 仍是搜索模式（TextField
    存在）+ 选择模式 close icon **不**出现

R6. **mode 互斥（选择模式无搜索 IconButton）**：长按文件 → 进选择模式 →
    AppBar actions 应是 close/select_all/download_outlined（27c-3）；
    搜索 IconButton 不可见（`find.byIcon(Icons.search)` findsNothing）

R7. **下钻清搜索 + 保留排序**：选 sort name desc → 进搜索模式 → 输入
    'fold' filter 留 [folderA] → 点击 folderA 下钻 → 验：
    - _searchMode=false（AppBar 复原普通模式 + TextField 不见）
    - _searchQuery='' （ListView 显示子目录全部 entries 不被 filter）
    - sortKey='name' / sortAsc=false 保留（下钻后开 PopupMenu 仍「按名称
      （降）」trailing check）

## Acceptance Criteria

- [ ] flutter analyze 0
- [ ] flutter test 全 PASS（618 baseline + ≥7 widget = ≥625）
- [ ] R1-R7 7 项 testWidgets 全 PASS
- [ ] 测试用 buildPage helper 注入 sortKey/sortAsc 不触 path_provider
- [ ] testWidgets 命名 `BATCH-27c-4: <场景>` 标记

## Definition of Done

- 27c-4 PRD §AC widget 测试覆盖瑕疵堵掉（spec 27c-4 子节「待覆盖测试」段
  更新为「全覆盖」状态）
- 27c-4 task PRD §AC checkbox 全勾

## Out of Scope

- production 代码改动（27c-4 已落 + analyze 0 无修复需求）
- 新功能（仅追加测试）
- 多关键词搜索 / 跨目录搜索（27c-follow-up 需新 PRD）

## Technical Notes

- 测试文件在 `flutter_app/test/remote_books_page_test.dart` 末尾追加
  `group('BATCH-27c-4: 排序 + 搜索')`
- 用 buildPage helper 已有 `sortKey/sortAsc` 参数；listDirOverride 注入
  fixture entries `[folderA(dir), fileC.txt(ts=300), fileA.txt(ts=100),
  fileB.txt(ts=200)]`
- `tester.pump(Duration(milliseconds: 300))` 推 debounce timer
- `tester.tap(find.byIcon(Icons.sort))` + `pumpAndSettle` 开 PopupMenu
- testKey 用 `Directory.systemTemp.createTempSync` + `addTearDown`
  对齐 27a/27c-1/27c-3/27c-4 决策

## Decisions

直落范围 — 不需 brainstorm（PRD §7 R3-R6 已明确，sub-agent 仅需把已
sketch 的测试形态写出）。
