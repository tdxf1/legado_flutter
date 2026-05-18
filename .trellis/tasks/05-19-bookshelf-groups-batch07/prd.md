# 书架分组 BookGroup (批次 7)

## Goal

让书架支持**用户自建分组**：用户可创建/编辑/删除分组，把书归入分组，书架顶部 Tab 切换分组查看。对齐原 Legado MD3 BookGroup 功能（简化 bitmask → 普通 group_id 外键，schema 已在批次 6 就绪）。

## What I already know

- 批次 6 已建 `book_groups` 表 + `Book.group_id` 字段（默认 0=未分组）
- `BookGroup` Rust struct 已在 `models.rs`，未实现 DAO
- Bridge API `get_all_books` 现状返回所有书；要加 group 过滤入参
- `bookshelf_page.dart` 顶栏 IconButton 切列表/网格视图，无 Tab；需要加分组 TabBar
- 原项目 `ui/book/group/GroupManageDialog.kt` / `GroupEditDialog.kt` / `GroupSelectDialog.kt` 三套对话框

## Decision

**实现路径**：
1. Rust: 新增 `book_group_dao.rs` + 6 个 bridge API
2. Flutter: 加 `bookGroupsProvider`（FutureProvider）+ TabBar 切分组 + 长按"移动到分组"对话框
3. 默认分组：用户创建的 group_id 1+；id=0 永远是"未分组"虚拟分组（不入库），id=-1 用于"全部"虚拟 Tab
4. 不实现 `bitmask`：一本书只能在一个分组（设计简化，后续如有需求再扩展）

## Requirements

### Rust 端
1. **新增 `book_group_dao.rs`**：list_all / create / update / delete / by_id
2. **`book_dao.rs` 加 2 方法**：`list_by_group(group_id)` / `set_book_group(book_id, group_id)`
3. **bridge API 暴露 6 个新 fn**：
   - `list_book_groups(db_path) -> Vec<BookGroup>`
   - `create_book_group(db_path, name, sort_order) -> BookGroup`
   - `update_book_group(db_path, id, name, sort_order) -> ()`
   - `delete_book_group(db_path, id) -> ()` (删分组时把组内书的 group_id 重置为 0)
   - `list_books_by_group(db_path, group_id) -> Vec<Book>` (group_id=-1 表示全部，0 表示未分组，>=1 表示具体分组)
   - `set_book_group(db_path, book_id, group_id) -> ()`

### Flutter 端
4. **新增 `bookGroupsProvider`**：FutureProvider 拉所有分组
5. **`bookshelf_page.dart` 重构**：
   - AppBar bottom 加 TabBar：第一个 Tab 固定"全部"+"未分组"，后面跟用户分组
   - TabBarView 每个 Tab 调 `list_books_by_group` 拿对应书列表
   - 顶栏菜单加"管理分组"按钮 → 弹 GroupManageDialog
6. **新增 `widgets/book_group_dialogs.dart`**：
   - `GroupManageDialog`：列出所有分组 + 增 / 改 / 删 / 排序
   - `GroupSelectDialog`：长按书时弹出，选目标分组
7. **书架长按菜单加"移动到分组"动作**（与现有"删除"并列）

## Acceptance Criteria

- [ ] Rust: `cargo test -p core-storage` 全绿（含 BookGroupDao 单测）
- [ ] Rust: `cargo build -p bridge` 通过 + FRB regen 后 Dart 端可调新 API
- [ ] Flutter: `flutter analyze` 0 issue
- [ ] Flutter: `flutter test` ≥ 340 (338 baseline + 至少 2 新单测)
- [ ] 实机: 创建分组 / 把书移到分组 / TabBar 切换 / 删除分组（书自动回未分组）

## Definition of Done

- cargo test + flutter test 全绿
- analyze 0 issue
- debug APK 构建到 dist/
- commit + archive

## Technical Approach

### A. Rust DAO

新建 `core/core-storage/src/book_group_dao.rs`：
```rust
pub struct BookGroupDao;
impl BookGroupDao {
    pub fn list_all(conn: &Connection) -> SqlResult<Vec<BookGroup>>
    pub fn get_by_id(conn: &Connection, id: i64) -> SqlResult<Option<BookGroup>>
    pub fn create(conn: &Connection, name: &str, sort_order: i32) -> SqlResult<BookGroup>
    pub fn update(conn: &Connection, id: i64, name: &str, sort_order: i32) -> SqlResult<()>
    pub fn delete(conn: &Connection, id: i64) -> SqlResult<()> // 删分组同时 UPDATE books SET group_id=0
}
```

`book_dao.rs` 加：
```rust
pub fn list_by_group(conn, group_id: i64) -> SqlResult<Vec<Book>>
// group_id=-1 → list_all（全部）
// group_id=0 → WHERE group_id=0
// group_id>=1 → WHERE group_id=?
pub fn set_group(conn, book_id, group_id) -> SqlResult<()>
```

### B. Bridge API

`core/bridge/src/api.rs` 新增 6 个 pub fn，统一返回 JSON 字符串（与现有风格一致）。

### C. Flutter 端

`providers.dart` 加：
```dart
final bookGroupsProvider = FutureProvider.autoDispose<List<BookGroup>>((ref) async {
  final dbPath = await ref.watch(dbPathProvider.future);
  final json = await rust_api.listBookGroups(dbPath: dbPath);
  return ...;
});

final booksByGroupProvider =
    FutureProvider.family.autoDispose<List<Map<String, dynamic>>, int>((ref, groupId) async {
  final dbPath = await ref.watch(dbPathProvider.future);
  final json = await rust_api.listBooksByGroup(dbPath: dbPath, groupId: groupId);
  return ...;
});
```

`bookshelf_page.dart`：
- 用 DefaultTabController；第 0 Tab="全部"(group_id=-1) + 第 1 Tab="未分组"(group_id=0) + 用户分组
- TabBarView 各自调 `booksByGroupProvider(groupId)`
- AppBar actions 加"管理分组"菜单项

新建 `widgets/book_group_dialogs.dart`：
- GroupManageDialog (StatefulWidget)：ListView + 行内编辑 + "+" 增加 + 长按删除
- GroupSelectDialog (StatelessWidget)：单选 + 确定回 group_id

### D. 单测

`book_group_dao_test.rs`：CRUD + delete 时 books.group_id=0 重置

Flutter 单测限于 mock 场景（无 native plugin），主要测 dto/provider 层。

## Out of Scope

- 一本书属于多个分组（bitmask 设计） — 简化为单组
- 分组封面 / 自定义封面规则
- 分组内书排序（依赖批次 8）
- 分组导入导出
- 网格 / 列表视图独立设计每个分组（保持当前全局切换）

## Notes

- group_id 外键不做 ON DELETE CASCADE — 删分组时 dao 显式更新 books.group_id=0
- "未分组" 虚拟 Tab 永远显示 group_id=0 的书（不可删）
- "全部" 虚拟 Tab 等价旧行为（不过滤）
