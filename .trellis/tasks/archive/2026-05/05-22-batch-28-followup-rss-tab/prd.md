# BATCH-28-followup: RSS tab 搜索 + 长按菜单

## Goal

BATCH-28 Out of Scope 收尾两项：搜索 + 长按菜单。对齐 legado RssFragment
SearchView + `rss_main_item.xml` 长按菜单。纯 Flutter 端，不引入新
FRB / Rust。

## Requirements

### R1. AppBar 搜索 SearchView

- AppBar actions 加搜索 IconButton（`Icons.search`），点击进搜索模式。
- 搜索模式 AppBar：`[back arrow] [TextField]`，actions 清空。
- `_searchQuery: String` + `TextEditingController` + debounce 300ms
  Timer（`_searchDebounce`）。
- filter 逻辑：`_filteredSources` getter 先按 `_filterGroup` 筛，再按
  `_searchQuery`（toLowerCase contains）匹配 `source_name / source_url
  / source_group`。
- 空 query 立即清 filter（不走 debounce，与 27c-4 同款）。
- 退出搜索模式：back arrow 或 Tap outside → `_searchQuery = ''` + 退
  出搜索模式 + GridView 恢复原状。
- **不**支持 `group:<name>` prefix 语法（留 followup）。

### R2. 长按 3 项菜单

- GridView item onLongPress → 弹 `showModalBottomSheet` 或
  `showMenu`（PopupMenuButton 嵌入长按回调）。
- 3 项：
  1. **禁用/启用** toggle：当前 enabled ? 显示「禁用源」 : 显示「启用源」
     → `rssSourceSetEnabled(dbPath, url, !enabled)` → SnackBar →
     `_loadAll()` 刷新。
  2. **删除**：confirm dialog → `rssSourceDelete(dbPath, url)` →
     SnackBar → `_loadAll()` 刷新。
  3. **编辑**：push `/rss-source-manage`（快捷跳转到源管理页）。
- 「置顶」不在 MVP（需新 FRB `rssSourceSetOrder`，留 BATCH-29+）。

## Acceptance Criteria

- [ ] AppBar 搜索 IconButton 可见
- [ ] 点搜索 IconButton → AppBar 切 TextField
- [ ] 输入文字 → debounce 300ms filter GridView（按 name/URL/group）
- [ ] 空 query → 立即恢复完整列表
- [ ] back → 退出搜索模式
- [ ] 长按 source item → 弹 3 项菜单
- [ ] 「禁用源」→ 调 setEnabled(false) → SnackBar + 列表刷新
- [ ] 「删除」→ confirm dialog → delete → SnackBar + 列表刷新
- [ ] 「编辑」→ push `/rss-source-manage`
- [ ] flutter analyze 0 / flutter test all green
- [ ] ≥3 testWidgets

## Definition of Done

- spec「RSS 订阅源网格 (BATCH-28)」段补 28-followup 子节（搜索模式
  契约 + Forbidden 反向 ≥2 条）
- 既有 4 testWidgets 不动，加 ≥3 新 testWidgets

## Decision (ADR-lite)

**Context**: BATCH-28 Out of Scope 需收尾。

**Decision**:
- AppBar SearchView + debounce 300ms（Q1，与 27c-4 RemoteBooksPage
  同款）
- 3 项长按菜单（toggle 禁用+删除+编辑 → 源管理页，Q2，无新 FRB）

**Consequences**:
- 「置顶」+ `group:<name>` search prefix 留 BATCH-29+（前者需新 FRB，
  后者是 nice-to-have）
- 「编辑」项跳源管理页（不新做 dialog）— 复用现有页面，不重复造轮子

## Out of Scope

- 搜索 `group:<name>` prefix → followup
- 「置顶」→ 需新 FRB，BATCH-29+
- 「规则订阅」header → 需 RuleSub 管理页，BATCH-29+
- responsive 列数 → BATCH-29+

## Technical Notes

### Flutter 端改动

- `flutter_app/lib/features/rss/rss_tab_page.dart`：
  - State 加 `_searchMode / _searchQuery / _searchController /
    _searchDebounce`
  - `_filteredSources` getter 改：先 group filter 再 search filter
  - `_buildAppBar` 分 normal/search 两 mode
  - GridView item 加 `onLongPress` → showMenu / BottomSheet
  - dispose 清理 `_searchDebounce?.cancel() + _searchController.dispose()`
- 测试 `flutter_app/test/rss_tab_page_test.dart`：加 3 项

### 依赖

- 已有 FRB：`rssSourceSetEnabled` / `rssSourceDelete`
- 路由：`/rss-source-manage` 已存在
- 无新 Rust/FRB

## Research References

无（决策已通过 27c-4 搜索范本 + legado 锚源摸清，不需 research-first）
