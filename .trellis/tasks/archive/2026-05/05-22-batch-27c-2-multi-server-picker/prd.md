# BATCH-27c-2: 远程书多 server 选择

## Goal

让 RemoteBooksPage 支持多个 WebDAV server 并允许用户切换。当前 27c-1
只用 `webdav.json` 单凭据 — 用户无法连第二个 server（坚果云 + 自建
OneDrive 等场景）。对齐 legado `ServersDialog` + `ServerConfigDialog`
+ `Server entity`（servers 表）+ `AppConst.DEFAULT_WEBDAV_ID = -1L`
sentinel 行为。

## Requirements

### R1. servers.json file-based 持久化

- 新增 `<documentsDir>/servers.json` 存 `List<RemoteServer>`：
  ```json
  {
    "servers": [
      {"id": 17158, "name": "坚果云", "url": "...", "user": "..."},
      {"id": 17234, "name": "OneDrive", "url": "...", "user": "..."}
    ]
  }
  ```
  password **不**写 servers.json，走 secure_storage `webdav_password_<id>` key。
- `id` 用 millis since epoch（`DateTime.now().millisecondsSinceEpoch`），
  与 legado `Server.id = System.currentTimeMillis()` 一致。
- 新建 `flutter_app/lib/features/remote_books/remote_servers.dart`：
  - `RemoteServer` model (id / name / url / user)
  - `loadRemoteServersFromDisk` / `saveRemoteServersToDisk` helpers
    （走 `readJsonFile` / `writeJsonFile`）
  - `loadRemoteServerPassword(id)` / `saveRemoteServerPassword(id, pwd)`
    （封装 `secure_storage` 的 `webdav_password_<id>` key）
- `remoteServersProvider: StateNotifierProvider<List<RemoteServer>>`
  + `selectedRemoteServerIdProvider: StateProvider<int>`（默认 -1）

### R2. 「默认」sentinel id=-1 等价 webdav.json

- `selectedServerId == -1` 时 RemoteBooksPage._bootstrap fallback 读
  `webdav.json` + `secure_storage:webdav_password`（与 27c-1 完全
  一致）。
- 新建 server 后用户可手动切回「默认」(id=-1)。
- backup_page **不动** — 仍用单 `webdav.json` 路径。

### R3. ServersBottomSheet UI

- RemoteBooksPage AppBar 加「server 切换」 IconButton（`Icons.dns_outlined`
  或 `Icons.cloud`），点击弹 `_ServersBottomSheet`：
  - 顶部「选择 WebDAV 服务器」标题
  - ListView：「默认」(id=-1) + 各 server 各 1 RadioListTile
  - 点 server → 立即切换 + 关闭 BottomSheet + 触发 _bootstrap 重走
  - 每行 trailing edit IconButton（点弹 `_ServerEditDialog` 编辑）+
    delete IconButton（确认 dialog 后删；删当前选中则 fallback id=-1）
  - 「默认」行不带 edit/delete（webdav.json 入口仍走 WebDavConfigPage）
  - 底部「+ 新建 WebDAV 服务器」FilledButton

### R4. _ServerEditDialog 4 字段

- `name` / `url` / `user` / `password` 4 个 TextField
- save：写入 servers.json + secure_storage:webdav_password_<id>
- 编辑现有 server：name 改名、url/user 改值，password 留空表示「不改」
- 新建：4 字段必填，`id = millis`
- 保留扩展点：未来加 `deviceName` / `testConnection` 按钮，本批不做

### R5. 切 server 重走 _bootstrap

- `selectedRemoteServerIdProvider` 变化 → RemoteBooksPage `ref.listen`
  → 调 `_bootstrap()`：清 `_pathStack`、`_selectedIds`、`_searchQuery`、
  重读凭据、重拉根目录。语义 = 「进了不同世界」直接 reset。

### R6. 删除当前选中 server 自动 fallback

- 删 server 时若 `id == selectedServerId` → save selectedServerId = -1
  + SnackBar「已切回默认服务器」+ 重走 _bootstrap。
- 不允许「确定操作 — 选中项不能删」类弹窗（多一步用户操作）。

## Acceptance Criteria

- [ ] `<documentsDir>/servers.json` 加密 server 列表 + secure_storage 存
      `webdav_password_<id>`
- [ ] settings.json 加 `remoteServerId: int`，默认 -1
- [ ] RemoteBooksPage AppBar 多 1 个 server IconButton，点击弹
      BottomSheet
- [ ] BottomSheet 渲染「默认」+ N server，各带 RadioListTile + edit/delete
- [ ] 选 server → BottomSheet 关 + RemoteBooksPage 重走 _bootstrap
      + 凭据用所选 server
- [ ] 新建 server: 4 字段 → save → servers.json + secure_storage 写入
- [ ] 编辑 server: 改 name/url/user 或 password → save → servers.json
      更新 + secure_storage 更新
- [ ] 删 server: confirm → servers.json 删除 + secure_storage 删 +
      若是当前选中则 selectedServerId 切回 -1
- [ ] selectedServerId=-1 时凭据走 webdav.json（兼容 27c-1）
- [ ] backup_page 完全兼容，旧用户 webdav.json 不动
- [ ] flutter analyze 0 / flutter test all green
- [ ] ≥4 testWidgets：BottomSheet 渲染 + 切 server / 新建 server
      / 编辑 server / 删除当前选中 server fallback

## Definition of Done

- spec 「远程书浏览模式 (BATCH-27c)」段加 27c-2 子节
  （多 server 模型契约 + sentinel id=-1 + secure_storage key 命名 +
  Forbidden 反向 ≥4 条）
- 27a 表第 4 行 add_remote 加「+27c-2 多 server 选择」备注
- testing.md 不动（已有 *Override 模式可复用）

## Decision (ADR-lite)

**Context**: 当前 RemoteBooksPage 仅 1 个 webdav 凭据，用户无法连第二个
WebDAV。需多 server 切换，对齐 legado ServersDialog 行为。

**Decision**:

- 持久化用 `servers.json` file-based + secure_storage `webdav_password_<id>`
  per-id，**不**引入 SQLite servers 表 + ServerDao（Q1 决策）
- 「默认」sentinel id=-1 等价当前 webdav.json，向后兼容 27c-1（Q2）
- UI 用 BottomSheet 而非独立页（Q3，UX 轻量）
- ServerEditDialog 4 字段：name / url / user / password（Q4，与 legado
  ServerConfigDialog 一致，不带 deviceName / 测试连接 — 留扩展点）
- 切 server 重走 _bootstrap reset 语义（Q5）
- 删当前选中 server 自动 fallback id=-1（Q6）

**Consequences**:

- ROI：纯 Dart 端实现，无 Rust / FRB 改动；对比 SQLite 表节省 5 个 FRB
  + 1 张表 + dao 层 = ~2-3 倍工作量节省。
- 不与 legado servers 表完全数据兼容（迁移 .legado.json 时多 server
  不会自动还原）— 接受。导入备份时若需多 server 还原是 BATCH-29+ 范畴。
- secure_storage `webdav_password_<id>` key 命名空间不与既有
  `webdav_password` 冲突；删 server 时清对应 secret，不会泄漏。
- ServerEdit dialog 字段决策：4 字段是「最小够用」，未来 deviceName /
  testConnection 按需加 = 单向兼容扩展（json 字段缺失走 fallback）。

## Out of Scope

- backup_page 改多 server — 单文件备份保持单 server，留 BATCH-29+
- 跨设备同步 servers 列表 — 用户可手动复制 servers.json
- server type 扩展（FTP / SMB / S3）— 当前仅 WebDAV，与 legado 一致
- BookSource 表多 server — 与远程书 server 不同概念，留 BATCH-29+
- 测试连接按钮 / 服务器图标 / sortNumber 排序 — 单向兼容扩展，按需加

## Technical Notes

### 锚源

- `legado/.../ui/book/import/remote/{ServersDialog.kt:166,
  ServerConfigDialog.kt:131}` UI 范本
- `legado/.../data/entities/Server.kt:57` Server entity
  （id=millis / name / type=WEBDAV / config=json）
- `legado/.../model/remote/RemoteBookWebDav.kt:21` `serverID: Long?`
- `legado/.../constant/AppConst.kt:27` `DEFAULT_WEBDAV_ID = -1L`
- `legado/.../help/config/AppConfig.kt:240-243` `remoteServerId`
  SharedPreferences

### Flutter 端改动文件

- 新建 `flutter_app/lib/features/remote_books/remote_servers.dart`
  + helper + model
- 新建 `flutter_app/lib/features/remote_books/_servers_bottom_sheet.dart`
  + `_server_edit_dialog.dart`（同 dir，私有 widget）
- 修改 `flutter_app/lib/features/remote_books/remote_books_page.dart`：
  - AppBar 加 IconButton + show BottomSheet
  - _bootstrap 改读 selectedServer 凭据（id=-1 走 webdav.json fallback）
  - ref.listen 切 server → reset state + 重走 _bootstrap
- 修改 `flutter_app/lib/core/providers.dart`：
  - `selectedRemoteServerIdProvider: StateProvider<int>` + load/save
  - `remoteServersProvider: StateNotifierProvider`（List<RemoteServer>
    state，内置 add/update/delete/reload）
- 修改 `flutter_app/lib/main.dart`：启动加载 selectedServerId +
  servers list

### secure_storage key 命名

- 现有：`webdav_password`（用于 webdav.json 默认 server / id=-1
  fallback）
- 新增：`webdav_password_<id>`（每个 server 一个，id 是 millis）
- secure_storage helper 不动（API 已经 read/write key 字符串），仅
  caller 传不同 key

### 测试隔离

- RemoteServersStore 加 `*Override` 测试钩子（servers 列表 + secret
  read/write）
- _ServersBottomSheet / _ServerEditDialog 走 widget test，复用
  `setSecureStorageOverrideForTest`

无 Rust / FRB 改动。

## Research References

无（决策已通过 legado 锚源摸清，不需 research-first）
