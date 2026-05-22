# BATCH-27d-followup: bookshelf-manage 进阶

## Goal

延续 BATCH-27d 批量编辑页的 5 项 Out of Scope，挑选 ROI 高 + 不依赖
未实现外部组件的 followup 项落地。让 BookshelfManagePage 接近 legado
`BookshelfManageActivity` 的功能完整度，同时不引入 BookSource 管理栈
（那是 BATCH-29+ 范畴）。

## Requirements

### R1. 列表头分组筛选

- AppBar 下加 horizontal SingleChildScrollView，渲染「全部」+「未分组」
  + 各 group `Group(id, groupName)` 各 1 ChoiceChip。
- **单选**：点 chip 切换 `_filterGroupId: int?`（null = 全部 / 0 =
  未分组 / >0 = 指定 group）。点当前选中 chip 不取消（与 legado 单值
  groupId field 行为一致 VM:30 `var groupId: Long = -1L`）。
- 仅普通模式 / 选择模式都可见**且可点切换**（保留 + 允许切换）。
- **不持久化**：每次进页 `_filterGroupId = null`（默认全部），退页丢
  弃。settings.json 不动。
- 实现侧：`_filteredBooks` 由 `_books + _filterGroupId` 计算 →
  `_buildList(_filteredBooks)`。`_books` 仍是 `booksOverride` /
  全表书，不动；`_selectedIds` 跨 filter 切换保留（书被 filter 隐藏
  时仍记得已选）。

### R2. 选中区间（峰胸长按择区间）

- 选择模式下长按任意 ListTile：
  - 若 `_lastTappedId` 为 null → 行为同 27d（toggle 该项 + 设
    `_lastTappedId = id`）。
  - 若 `_lastTappedId` 非空且非当前项 → 区间起点 = `_lastTappedId`，
    终点 = 长按项；区间内**所有 `_filteredBooks`** 都加入
    `_selectedIds`（**追加不清以前**），区间外保留之前选中状态。
- 普通 onTap（选择模式下）：toggle 单项 + 更新 `_lastTappedId = id`。
- `_lastTappedId` 退出选择模式（close / 删除完成 / 移分组完成）即清。

### R3. 「点书名直接打开阅读」 toggle

- `SettingsPage` 加 SwitchListTile「点书名直接打开阅读」（同 BATCH-26d
  落点 path）。settings.json 加 `bookshelfManageOpenReader: bool`，
  默认 `false`（保持 27d 现状）。
- toggle on：bookshelf_manage 普通模式下 onTap → push '/reader'。
- toggle off：bookshelf_manage 普通模式下 onTap = no-op（27d 现状）。
- 选择模式下永远 toggle 选中（mode 互斥优先级最高，与 toggle 无关）。

## Acceptance Criteria

- [ ] BookshelfManagePage 顶部 chips 可见，「全部」默认选中
- [ ] 点「未分组」chip → `_filteredBooks` 仅 group=0 的书
- [ ] 点其他 group chip → 仅该 group 的书
- [ ] 退页重进 → 默认「全部」（不持久化）
- [ ] 选择模式下点 group chip 不退选择模式（chips 与选择模式可共存）
- [ ] 长按 b1 → b1 进 _selectedIds + _lastTappedId=b1
- [ ] 长按 b1 + 长按 b5 → _selectedIds = {b1..b5}（区间内全选）
- [ ] 选 b1 长按 b3 + 单击 b5 + 长按 b8 → _selectedIds = {b1 b3 ...
      b5..b8}（按 R2 规则：单击 b5 更新 lastTapped；长按 b8 区间是
      b5..b8）
- [ ] settings.json 加 `bookshelfManageOpenReader` 默认 false
- [ ] toggle on → 点书名 push '/reader?bookId=...'
- [ ] toggle off → 点书名 no-op
- [ ] 选择模式下点书名 = toggle 选中（toggle 状态不影响选择模式）
- [ ] flutter analyze 0 / flutter test all green

## Definition of Done

- spec 「批量编辑选择模式 (BATCH-27d)」段补 27d-followup 子节
  （3 项功能契约 + Forbidden 反向 ≥3 条）
- 27a 表 第 7 行「书架管理」状态保持「BATCH-27d」+ 加「+27d-followup
  group filter / 区间选 / openReader toggle」备注
- 27d 既有 8 testWidgets 不动，新功能补 ≥4 testWidgets：
  - group chips 默认全部 / 选未分组过滤
  - 区间选峰胸长按（已选 b1 + 长按 b3 → {b1 b2 b3}）
  - openReader toggle on push reader / off no-op

## Decision (ADR-lite)

**Context**: 27d Out of Scope 5 项，需挑能落地的做。

**Decision**:

- 做：列表头分组筛选 / 选中区间（峰胸长按）/ 点书名 toggle
- 不做：换源 / 导出全部使用书源（依赖 BookSource 表，留 BATCH-29+）

**Consequences**:

- group filter 不持久化与 legado Activity unsave 语义一致；后续若用
  户反映「每次重进还要选」可加 settings.json，是单向兼容扩展。
- 区间起点 = 上次点击项与 Material 列表选择业界惯例对齐
  （Gmail / Files app 同行为）。
- toggle 默认 false 保持 27d 不破坏现状；on 时 push reader 与主
  bookshelf 一致（Flutter 端无 BookDetailsPage，与 legado 走详情页
  不同 — 项目侧 reader = 主入口）。

## Out of Scope (explicit / 永久 skip)

- 换源 — 依赖 BookSource 表 + WebBook 抓详情栈（preciseSearchAwait
  / getBookInfoAwait / getChapterListAwait / migrateTo），留 BATCH-29
  之后独立批
- 导出全部使用书源 — 同依赖 BookSource 表，留 BATCH-29 后
- BookDetailsPage 新建 — 与 legado BookInfoActivity 对齐独立批
  （不属 27d-followup 范围）
- group chips 多选 / filter 持久化 — 单向兼容扩展，按需加

## Technical Notes

### 锚源

- `legado/app/src/main/java/io/legado/app/ui/book/manage/`
  - `BookshelfManageActivity.kt` 417 行
  - `BookshelfManageViewModel.kt` 131 行（VM:30 `var groupId: Long
    = -1L` 单值 filter）
  - `BookAdapter.kt` 238 行

### Flutter 端改动点

- `flutter_app/lib/features/bookshelf/bookshelf_manage_page.dart`：
  - State 加 `int? _filterGroupId` + `String? _lastTappedId`
  - `build` 顶部 `_filteredBooks` getter
  - AppBar bottom 加 SingleChildScrollView (horizontal) + ChoiceChip
  - `onLongPress` 改区间逻辑（先看 `_lastTappedId` 决定 toggle vs
    range select）
  - `onTap` 选择模式下更新 `_lastTappedId`
  - 普通模式 onTap 看 `bookshelfManageOpenReader` push '/reader'
- `flutter_app/lib/core/providers.dart`：settings.json 加
  `bookshelfManageOpenReader: bool` 持久化 helper（参考 26d
  `defaultHomePage` 范本）
- `flutter_app/lib/features/settings/settings_page.dart`：加 SwitchListTile
- 8 *Override 注入点不变 + 加 1：`openReaderOverride: bool?`
  （测试旁路 settings.json）

### 测试新增

- `bookshelf_manage_page_test.dart` 现 8 testWidgets + 加 5：
  - group chips 默认「全部」选中
  - 选「未分组」→ 仅 group=0 书
  - 区间选（已选 b1 + 长按 b3 → {b1 b2 b3}）
  - openReader=true → 点书名 push reader
  - openReader=false → 点书名 no-op

无 Rust / FRB 改动（纯 Flutter 端 UI + state 变化）。

## Research References

无（决策已通过 27d archive PRD §Out of Scope + legado 锚源摸清，
不需 research-first）。
