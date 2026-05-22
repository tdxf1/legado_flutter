# BATCH-27c-3 远程书多选批量下载 + RemoteBookRunner

## Goal

在 27c-1 RemoteBooksPage 单本下载基础上加多选模式 + 后台批量下载 runner，对齐
原 legado `RemoteBookActivity.kt:144-156` 的 `selectAll/revertSelection/
addToBookshelf(adapter.selected)` 流程；复用 27b 沉淀的 *Runner singleton +
StreamController + Notification 范本（spec「批量后台任务模式 (BATCH-27b)」），
**只对当前目录（不跨目录递归）的文件项**支持多选批量。

## What I already know

### 原 legado UI 锚源
- `RemoteBookActivity.kt:144-156` — selectAll / revertSelection / 长按进入选择
  模式 → addToBookshelf(adapter.selected) 走批量
- `RemoteBookViewModel.kt:134-157` — `addToBookshelf(remoteBooks: HashSet)`
  逐本 `bookWebDav.downloadRemoteBook` + `LocalBook.importFiles` + `book.save`，
  整批 try / `onError` 提示出错 / `onFinally` 通知 UI
- `RemoteBookAdapter.kt`（CHOICE 模式 + Checkbox 显示），文件夹不可勾选

### 27b runner 范本沉淀（直接套）
- `flutter_app/lib/core/update_toc_runner.dart` 210 行 — singleton + Queue
  + `_inFlight` 去重 + `_kUpTocConcurrency=4` + StreamController.broadcast +
  `_emitProgress` + `kNotificationId=99001`
- 静默 catch 单本失败累计 fail，不打断整批；done=true emit 一次后 reset
  `_totalEnqueued=0`
- `enqueue` 立即 `_emitProgress` 让 UI badge 第一帧出现

### 27c-1 RemoteBooksPage 现状
- `flutter_app/lib/features/remote_books/remote_books_page.dart` 487 行
- `_RemoteEntry` 类已有 `name/isDir/size/lastModified` 字段
- `_pathStack` 下钻、`_loadCurrentDir` seq token、6 *Override 注入点
- 单本流程 `_onTapFile`：webdavDownloadFile → import_local_book → invalidate
  allBooks/booksByGroup
- safeFileName 用 ts+random hex（无 uuid 包）
- `Icons.download_outlined` trailing + `_subtitleFor` (size + lastModified)

### Notification ID 已用
- 99000 — DownloadRunner（章节下载）
- 99001 — UpdateTocRunner
- → **27c-3 用 99002** RemoteBookRunner

## Assumptions (temporary)

- UI 走 Material 长按进选择模式 → AppBar 替换为「选择 N 项 / 全选 / 取消」
  按钮（仿原 legado）
- 选择模式下 ListTile.leading 改 Checkbox（文件夹仍 Icons.folder + 不可选 +
  灰显 onTap 拒绝）
- 批量逻辑 dispatch 到新建 `core/remote_book_runner.dart` singleton
- 失败静默累计，结束 SnackBar 总结「成功 X / 失败 Y」（27b 范本）
- 仅当前目录批量；跨目录批量留 27c-follow-up

## Decisions (ADR-lite)

**Q1 选择模式下文件夹处理 → A+1b**：长按文件进选择模式；文件夹仍可点下钻
（onTap 不变），但文件夹**不可勾选**；下钻时 `_selectedPaths` 清空（避免跨
目录混淆 — path 含目录前缀，跨目录的 selected 概念混乱）；OS back 优先级：
选择模式非空 → 退选择模式；空 + path 栈非空 → 弹 path；都空 → 退页面。

**Q2 批量入口 → A**：AppBar action 加「下载选中」IconButton（仿原
legado `RemoteBookActivity:155 menu_add_to_bookshelf`）；点击 → enqueue
全选项 → 立即退出选择模式 → AppBar transient badge 出现。

**Q3 进度 UI → A**：RemoteBooksPage AppBar transient badge（仿 27b
bookshelf）；`StreamSubscription` 挂 RemoteBooksPage initState，dispose
cancel；singleton 状态跨页面持久；离开页面时 badge 消失但任务继续，下次
进来重新挂上 listener（如 runner 仍在跑）。

**Q4 并发数 → A=1（串行）**：远程书 MB 级文件 + WebDAV 服务端常对单连接并发
限速 + rust `download_to_path` 已流式；常量名 `_kRemoteBookConcurrency = 1`
保留 worker pool 抽象（`Future.wait + List.generate`）便于 follow-up 调高。

**Q5 失败处理 → A**：静默 catch + `_completedFail++` + `debugPrint`，不打断
队列；done emit 后 caller 弹「批量下载完成：成功 X / 失败 Y」总结 SnackBar；
失败列表收集留 27c-follow-up。

## Requirements (evolving)

R1. 长按文件项进入选择模式（文件夹长按不进入或被忽略）
R2. AppBar 选择模式下显示：返回（退出选择）/ 标题改「选择 N 项」/ 全选 /
    取消选择 / 「下载选中」action
R3. 文件项 leading 在选择模式下为 Checkbox（点 ListTile = toggle 选中），
    非选择模式同 27c-1（点单本下载）
R4. 文件夹项在选择模式下不可勾选；点击仍下钻（或被禁用？需 Q）
R5. RemoteBookRunner 单例，Queue + 4 worker、StreamController.broadcast、
    Notification id 99002、静默 catch、done=true emit 后 reset
R6. _RemoteJob 字段：url/user/password/remotePath/targetLocalPath/dbPath/
    documentsDir + overrideFn + bookId（用于 UI 端去重，wrap remotePath 即可）
R7. AppBar transient badge 进度条（仿 27b bookshelf）
R8. 总结 SnackBar：「批量下载完成：成功 X / 失败 Y」
R9. RemoteBooksPage 加 Override：remoteBookRunnerOverride（singleton 测试隔离）
R10. 测试：runner 单测 + page 多选模式交互测（≥6）

## Acceptance Criteria

- [ ] flutter analyze 0
- [ ] flutter test 全 PASS（含新 ≥10 项 testWidgets）
- [ ] cargo build --workspace OK（无 Rust 改动应不破）
- [ ] 长按文件 → 选择模式启动 + Checkbox 显示
- [ ] 全选只勾文件不勾文件夹
- [ ] 退出选择模式 → AppBar 复原 27c-1 状态
- [ ] 5 个文件批量下载 → progress 累加到 5 → 结束 SnackBar + 书架 invalidate

## Definition of Done

- 测试覆盖 runner 去重、worker 并发、单本失败不阻塞、done emit + reset
- 选择模式 UI 交互测（长按进入、勾选、全选、取消、退出）
- spec 「批量后台任务模式」段补 27c-3 子节（重申 Notification id 表 +
  bookId 去重 key 取 remotePath 而非文件名）
- 27a 表如有 add_remote 行需要更新「（27c-3 加批量）」
- Forbidden 反向 ≥3 条

## Out of Scope

- 跨目录批量（_pathStack push/pop 切换会清 selection？需 Q）
- multi-server（27c-2）
- 排序 + 搜索（27c-4）
- 失败单本重试（无 UI 入口）
- book.origin 标记 webDavTag + serverID（27c-follow-up）

## Technical Notes

- Notification id 99002 RemoteBookRunner
- bookId 去重 key = remotePath（含路径前缀 + 文件名，不会跨目录冲突）
- 长按 GestureDetector vs ListTile `onLongPress` → ListTile 自带 onLongPress
- 选择模式 state：`bool _selectionMode + Set<String> _selectedPaths`
- 退出选择模式条件：选择数 = 0 / OS back（`PopScope` 优先级先于 path 栈弹）
- runner 不能进 ctor → 测试钩子用 `enqueue(... overrideFn:)` 同 27b

## Research References

（参考 RemoteBookActivity.kt:144-156 + UpdateTocRunner 范本，无需新研究）
