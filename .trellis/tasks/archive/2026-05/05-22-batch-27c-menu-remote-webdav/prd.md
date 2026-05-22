# BATCH-27c-1 menu_remote WebDAV 远程书浏览页（最小可用版）

> **范围已锁定**（Q1-Q7）：
> - Q1: 27c-1 列目录 + 下钻 + 单选 + 单本下载/导入；多选/排序/搜索/multi-server 留 27c-2/3
> - Q2: 单 server 复用 webdav_config_page 凭据
> - Q3: 深度 path 栈（`List<String> _pathStack`，系统 back 上钻）
> - Q4: 单选（点一本下一本，SnackBar 进度）
> - Q5: book.origin = `webdav://<path>`
> - Q6: documents_dir/remote_books/<safe-filename>
> - Q7: 新增 2 个 FRB：`webdav_list_dir` + `webdav_download_file`

**Stage**: P2
**Slug**: `batch-27c-menu-remote-webdav`
**Effort**: M-L (~600-800 行)
**Depends on**: BATCH-27a ✅（PopupMenu「添加远程书」灰显项） + BATCH-03 ✅（webdav_password secure_storage）
**对照原版**：`menu_remote` + `RemoteBookActivity.kt` + `RemoteBookViewModel.kt`

## Goal

把 BATCH-27a 灰显的 `menu_remote`（添加远程书）真正落地最小可用版：用户配好 webdav 凭据后点 PopupMenu「添加远程书」→ 跳新页 `/remote-books` → 用现有凭据 PROPFIND 列远端目录 → 文件夹/文件 ListView，点文件夹下钻、点文件下载到 `documents_dir/remote_books/` → 调 `import_local_book` 入书架 + 标 origin = `webdav://<path>` + invalidate 书架 providers。

## Requirements

### A. 新增 2 个 FRB（`core/bridge/src/api.rs` + `core/core-net/src/webdav.rs`）

#### A.1 `webdav_list_dir`

```rust
/// BATCH-27c: 列 webdav path 下的所有 entries（不过滤 backup 前缀）。
/// 与现有 `webdav_list_backups` 区分 — 后者写死 backup 过滤 + 返
/// Vec<String>；本函数返 [{name, isDir, size, lastModified}] 通用结构。
pub async fn webdav_list_dir(
    url: String,
    user: String,
    password: String,
    path: String,
) -> Result<String, String>
```

返 JSON：
```json
[
  {"name": "books", "isDir": true, "size": 0, "lastModified": 1234567890},
  {"name": "深夜食堂.epub", "isDir": false, "size": 1048576, "lastModified": 1234567890}
]
```

`path` 是相对 url 的子路径（空串 = root）。Rust 端 `core_net::webdav::WebDavClient` 加 `list_dir(path: &str) -> Result<Vec<DirEntry>>` 通用方法（不过滤 backup* 前缀）。

#### A.2 `webdav_download_file`

```rust
/// BATCH-27c: 通用 webdav 下载到本地路径。与 `webdav_download_backup`
/// 写死 backup zip 不同 — 接任意 path + 落 target_local_path。
pub async fn webdav_download_file(
    url: String,
    user: String,
    password: String,
    remote_path: String,
    target_local_path: String,
) -> Result<i64, String>
```

返下载 byte 数（i64 → Dart PlatformInt64）。Rust 端 `WebDavClient::download_to_path(remote_path, &Path)` 流式写文件（避免大文件全 buffered in memory）。

funcId 113 / 114，手编 wire impl + dispatcher arm + build.rs guard 同 27a/27b 范本。

单元测试（mock webdav server / fixture XML）：
- `test_webdav_list_dir_parses_propfind_response` — 喂固定 propfind XML 验解析
- `test_webdav_list_dir_root_path` — 空 path 走 base url
- `test_webdav_download_file_writes_target` — mock GET + 验文件落地

### B. 新增 `RemoteBooksPage` (`flutter_app/lib/features/remote_books/remote_books_page.dart`)

`ConsumerStatefulWidget`：
- 顶部 AppBar：title「远程书」+ subtitle 显示 path 栈（如 `/books/小说`）+ leading IconButton 上钻一层（栈到顶 → Navigator.pop）
- Body：`ListView.builder` 文件夹 + 文件混排
  - 每项 `ListTile(leading: Icon(folder_open / book), title: name, subtitle: lastModified + size, trailing: 进入箭头 / 下载图标)`
  - 文件夹：onTap → `_pathStack.add(name)` + setState + 重 list
  - 文件：onTap → `_onTapFile(entry)` 走下载 + 导入流程
- `_pathStack: List<String>` plain field 维护当前路径（join('/')）
- `WillPopScope` / `PopScope` 拦截系统 back：栈非空 → pop 一层 + setState；栈空 → return false 让默认 pop

`_loadCurrentDir()` 初次 + path 切换时调：
- 拿 webdav 凭据：webdav.json `url` + `user` + secure_storage `webdav_password`
- 凭据缺：SnackBar「请先配置 WebDAV」+ button 跳 `/webdav-config`，禁加载
- 调 FRB `webdav_list_dir(url, user, password, _pathStack.join('/'))`
- jsonDecode + setState `_entries = list`
- 失败 SnackBar「列目录失败：X」

`_onTapFile(entry)` 走单本下载 + 导入：
1. SnackBar「下载中: filename...」（无 dismiss timer）
2. 拿 `documents_dir`（path_provider 标准路径）→ make subdir `remote_books/`
3. 生成 safe filename（UUID 前缀 + sanitize）：`uuid_v4 + '_' + filename` 避免重名 + 防特殊字符
4. 调 FRB `webdav_download_file(url, user, password, remotePath, localPath)` 拿 size
5. 调 FRB `import_local_book(dbPath, localPath, documentsDir)` 拿 book_id
6. 标 `book.origin = webdav://<path>` —— ⚠️ 这步要在 import_local_book 之后通过 `update_book_origin(book_id, origin)` FRB 单独写 / 或 import_local_book 入参加 `origin: Option<String>` —— **27c-1 简化版**：先不标 origin（保持 import_local_book 默认 source_id='local'）+ Out of Scope 留 follow-up；用户从 webdav 导入的书与本地书无差异，不影响功能但失「来源可见性」
7. invalidate `allBooksProvider` / `booksByGroupProvider`
8. SnackBar 「《name》导入成功」

错误处理：每步 try / catch + hideCurrentSnackBar + SnackBar「下载失败 / 导入失败」+ 不向上抛。

### C. 新增 GoRoute `/remote-books`

`flutter_app/lib/core/router.dart` 加：
```dart
GoRoute(
  path: '/remote-books',
  builder: (_, __) => const RemoteBooksPage(),
),
```

### D. `bookshelf_page.dart` PopupMenu「添加远程书」改可点

- `enabled: false` → `enabled: true`
- onSelected 'add_remote' 分支：`if (context.mounted) context.push('/remote-books');`

### E. 测试

新增 `flutter_app/test/remote_books_page_test.dart`：

测试钩子（与 BookshelfPage 同款）— `RemoteBooksPage` 加 4 个 override 字段：
- `Future<String> Function({required String url, required String user, required String password, required String path})? listDirOverride`
- `Future<int> Function({required String url, required String user, required String password, required String remotePath, required String targetLocalPath})? downloadFileOverride`
- `Future<String> Function({required String dbPath, required String filePath, required String documentsDir})? importLocalBookOverride`
- `String? dbPathOverride` / `String? documentsDirOverride`

至少 6 testWidgets：
1. 凭据缺失 → SnackBar「请先配置 WebDAV」+ 跳转 button
2. 列目录成功 → ListView 显示 entries（文件夹 + 文件）
3. 点文件夹下钻 → AppBar 显示新 path + 重新调 listDir
4. 系统 back → 上钻一层（栈非空时不 pop 页面）
5. 点文件 → SnackBar「下载中」→ 下载完 → 调 import → SnackBar「导入成功」
6. 下载失败 → SnackBar「下载失败」不打断页面

baseline 587 → ~595（runner 0 + page 6 + FRB rust 单测 3 = 9）

新增 `bookshelf_menu_test.dart` 改：把 `add_remote` 从 disabledValues 移到 enabledValues（4 disabled / 8 enabled）。

### F. spec 段「远程书浏览模式 (BATCH-27c)」

入「页面布局对齐 (BATCH-26)」段「批量后台任务模式 (BATCH-27b)」之后新加：
- 27c-1 范围（最小可用版：列目录 + 下钻 + 单选 + 单本下载/导入）
- pathStack 维护契约（systemBack 上钻到顶 pop 页面）
- webdav 凭据复用 webdav_config_page + secure_storage
- FRB 双新增（list_dir / download_file）签名 + funcId 113/114
- 下载位置 documents_dir/remote_books/<uuid_filename>
- origin 标记 webdav://<path> 留 27c follow-up
- Forbidden 反向：禁 Dart 端手写 propfind XML parser / 禁同 base_url 直连不复用 webdav_config_page 凭据 / 禁深度路径用 URL queryParameter 污染历史

## Acceptance Criteria

- [ ] FRB `webdav_list_dir` + `webdav_download_file` 实现 + 3 单测
- [ ] funcId 113/114 双 build.rs guard
- [ ] `RemoteBooksPage` UI + path 栈下钻 + 系统 back 拦截
- [ ] 凭据缺失提示 + 跳转 webdav-config
- [ ] 单文件下载 → import_local_book → invalidate providers + SnackBar
- [ ] PopupMenu「添加远程书」改可点
- [ ] GoRoute `/remote-books` 注册
- [ ] flutter analyze 0 / flutter test PASS（baseline 587 → ~595）
- [ ] cargo test PASS / cargo build --workspace OK
- [ ] spec 入「远程书浏览模式 (BATCH-27c)」小节

## Out of Scope (27c-1)

- O1：multi-server / ServerDao / ServersDialog（27c follow-up，需后端表 + dao + FRB 一栈，量级 = 27c-1 自身）
- O2：long-press 多选批量下载 + 27b 同款 RemoteBookRunner singleton + Notification（27c-2）
- O3：排序（按 name / lastModified asc/desc）+ AppBar 排序 IconButton
- O4：搜索过滤（顶部 SearchView 实时过滤）
- O5：isOnBookShelf 状态包（标已下载书的视觉提示，需 books 表 origin LIKE 'webdav://%' 反查）
- O6：book.origin = webdav://<path> 标记（需 update_book_origin FRB 或 import_local_book 加 origin 参数）
- O7：下载断点续传 / 进度条
- O8：移动到分组（导入后默认入「未分组」，用户后续 long-press 自己移）
- O9：下载缓存清理（用户文件管理器手动清 documents_dir/remote_books/）

## Decision (ADR-lite)

**Context**：原 RemoteBookActivity 全功能 ~1500+ 行（多选 + 排序 + 搜索 + multi-server + 上架状态包）。flutter 27c-1 锁最小可用版避免一次写大 + 出问题难定位。

**Decision**：单 server + 单选 + 深度栈下钻 + 复用 webdav_config_page + 复用 import_local_book FRB + 不动 book.origin。新增 2 个 FRB（list_dir + download_file）让 Rust 端 webdav 能力完整。

**Consequences**：
- 短期：用户能从 webdav 浏览远端书 + 下一本入一本，覆盖 80% 使用场景；多选 / 搜索 / 排序留 27c-2/3 渐进做
- 中期：webdav 列目录 / 通用下载两个 FRB 沉淀，未来 backup 路径也能复用通用 download_file（替代 webdav_download_backup）
- 远期：spec 「远程书浏览模式 (BATCH-27c)」沉淀单 server + 复用凭据 + 浅栈范本；future multi-server 升级路径在 spec 留笔记

## Technical Notes

- `flutter_app/lib/features/bookshelf/bookshelf_page.dart:148+` PopupMenu「添加远程书」灰显项
- `flutter_app/lib/features/settings/webdav_config_page.dart` webdav 凭据 UI（已存在）
- `core/bridge/src/api.rs:1454+` 现有 webdav_check / webdav_list_backups
- `core/core-net/src/webdav.rs:101+` WebDavClient 加 list_dir + download_to_path 通用方法
- `core/bridge/src/api.rs:1569 import_local_book` 单文件导入复用
- `flutter_app/lib/core/persistence/json_store.dart` 读 webdav.json
- `flutter_app/lib/core/security/secure_storage.dart` 读 webdav_password
- 原 legado 锚源码：
  - `RemoteBookActivity.kt` UI（multi-server / SearchView / SelectActionBar / 排序）
  - `RemoteBookViewModel.kt:97 initData` / `:117 loadRemoteBookList(path)` / `:135 addToBookshelf` 业务逻辑
  - `RemoteBook` model: filename / path / isDir / size / lastModify
- BATCH-26b 决策：灰显改可点时改 enabled / onTap，标题 + icon 不动
- BATCH-27a 决策：保留 PopupMenuItem value key 名 `add_remote`
- BATCH-03 决策：webdav_password 走 secure_storage，不进 webdav.json
- BATCH-19a 决策：对话框 SimpleDialog + ListTile + check trailing 不用 deprecated RadioListTile
- BATCH-21c 决策：跨页通信用 `context.push<T>(...)` 而不引入 Riverpod cross-page state
