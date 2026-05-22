# BATCH-27b update_toc 批量刷目录

> **范围已锁定**（Q1-Q6）：
> - Q1: 新增单本 FRB `update_book_toc(db_path, book_id) -> Result<i32, String>`
> - Q2: Notification + AppBar transient 转圈 badge
> - Q3: 仅刷当前 Tab books（对齐原 Fragment.books）
> - Q4: Dart 端 4 worker（参数化常量 _kUpTocConcurrency）
> - Q5: 单本失败静默 catch + log + 总结 SnackBar「成 X / 失 Y」
> - Q6: AppBar transient `IconButton(CircularProgressIndicator + Badge)`，仅 _isUpdatingToc=true 时显示

**Stage**: P2
**Slug**: `batch-27b-update-toc`
**Effort**: M (~400-600 行)
**Depends on**: BATCH-27a ✅
**对照原版**：`menu_update_toc` + `BaseBookshelfFragment.kt:98 activityViewModel.upToc(books)` + `MainViewModel.kt:96-180 upToc/startUpTocJob/updateToc`

## Goal

把 BATCH-27a 灰显的 `menu_update_toc`（更新目录）真正落地：用户点 PopupMenu「更新目录」→ 后台 4 路并发刷新当前 Tab 内所有书的章节列表（filter `!isLocal && canUpdate`），刷完写库 + invalidate 书架 providers + Notification + 总结 SnackBar。失败容忍单本错（不整批中断），UI 期间可继续操作其他 tab，AppBar 显示 transient 转圈 badge。

## Requirements

### A. 新增 FRB `update_book_toc` (`core/bridge/src/api.rs`)

```rust
/// BATCH-27b: 单本目录刷新。对齐原 legado MainViewModel.kt:159 updateToc(bookUrl)。
///
/// 流程：
/// 1. BookDao::get_by_id(book_id) → 拿 Book
/// 2. SourceDao::get_by_id(book.origin) → 拿 BookSource；不存在直接返错
/// 3. parser.get_chapters(&source, &book.book_url) → 拉远端 toc
/// 4. ChapterDao::replace_by_book_preserving_content(book_id, &chapters)
///    保 content cache，与原版 delByBook + insert 等价
/// 5. BookDao::update(book.last_check_time = now, total_chapter_num = toc.len())
/// 6. 返回新章节数
pub async fn update_book_toc(
    db_path: String,
    book_id: String,
) -> Result<i32, String>
```

funcId 112，手编 wire impl + dispatcher arm + build.rs guard 同 27a 范本。

单元测试：
- `test_update_book_toc_no_source` — book.origin 找不到 source 返错
- `test_update_book_toc_local` — local book（origin 空）走错误路径（应在 Dart 端 filter 不到这里）
- 远端抓 toc 不写单测（依赖网络），由 Dart 端 mock FRB

### B. `UpdateTocRunner` singleton (`flutter_app/lib/core/update_toc_runner.dart` 新增)

仿 `download_runner.dart` 范本：

```dart
class UpdateTocRunner {
  static final UpdateTocRunner _instance = UpdateTocRunner._();
  factory UpdateTocRunner() => _instance;
  UpdateTocRunner._();

  static const _kUpTocConcurrency = 4;
  static const _kNotificationId = 99001;

  final Queue<String> _queue = Queue();        // bookId
  final Set<String> _inFlight = {};            // 去重 active
  bool _running = false;
  int _totalEnqueued = 0;
  int _completedSuccess = 0;
  int _completedFail = 0;

  final _progressController = StreamController<UpdateTocProgress>.broadcast();
  Stream<UpdateTocProgress> get onProgress => _progressController.stream;

  Future<void> enqueue(List<String> bookIds, {required String dbPath}) async {
    // dedup 入队
    for (final id in bookIds) {
      if (!_queue.contains(id) && !_inFlight.contains(id)) {
        _queue.add(id);
        _totalEnqueued++;
      }
    }
    if (!_running) await _start(dbPath);
  }

  Future<void> _start(String dbPath) async {
    _running = true;
    _completedSuccess = 0;
    _completedFail = 0;
    final futures = List.generate(_kUpTocConcurrency, (_) => _worker(dbPath));
    await Future.wait(futures);
    _running = false;
    _emitProgress(done: true);
    // 刷完整批 → reset counters，下次重新计数
    _totalEnqueued = 0;
  }

  Future<void> _worker(String dbPath) async {
    while (_queue.isNotEmpty) {
      final id = _queue.removeFirst();
      _inFlight.add(id);
      try {
        await rust_api.updateBookToc(dbPath: dbPath, bookId: id);
        _completedSuccess++;
      } catch (e) {
        debugPrint('[UpdateTocRunner] $id failed: $e');
        _completedFail++;
      } finally {
        _inFlight.remove(id);
        _emitProgress();
      }
    }
  }

  void _emitProgress({bool done = false}) {
    final progress = UpdateTocProgress(
      total: _totalEnqueued,
      success: _completedSuccess,
      fail: _completedFail,
      isDone: done,
    );
    _progressController.add(progress);
    NotificationService.showUpdateTocProgress(progress);
  }
}

class UpdateTocProgress {
  final int total, success, fail;
  final bool isDone;
  int get processed => success + fail;
  bool get isRunning => !isDone && total > 0;
  // ...
}
```

### C. `bookshelf_page.dart` 改动

1. **PopupMenu「更新目录」**：从 `enabled: false` 改 `enabled: true` + `value: 'update_toc'` + onSelected 分支调 `_onUpdateToc(context, currentTabBooks)`
2. **`_onUpdateToc(BuildContext, List<Map<String, dynamic>> books)`**：
   - filter `!book['origin'].isLocal && book['can_update'] != false`（local 判断：origin 空或以 'local://' 开头；can_update 字段对齐原版 `Book.canUpdate`）
   - 拿 dbPath → 提取 bookIds → `UpdateTocRunner().enqueue(bookIds, dbPath: dbPath)`
   - listen `onProgress` Stream → 更新 `_isUpdatingToc` + counts state
   - isDone → 总结 SnackBar「目录刷新完成：成 X / 失 Y」 + invalidate `allBooksProvider` / `booksByGroupProvider`
3. **AppBar.actions transient badge**：`if (_isUpdatingToc) IconButton(CircularProgressIndicator strokeWidth:2, child: Badge('${processed}/${total}'))`
4. **「当前 Tab books」获取**：当前 `_BookListView` 通过 `booksByGroupProvider((groupId, sortOrder))` 拿；`_onUpdateToc` 在父级 `_BookshelfPageState` 的 `tabSpec[_tabController.index]` 拿到 groupId/sortOrder → `ref.read(booksByGroupProvider((groupId, sortOrder)).future)` 拿当前 tab books

### D. `notification_service.dart` 加 `showUpdateTocProgress`

仿 `showDownloadProgress` 同模式：
```dart
static Future<void> showUpdateTocProgress(UpdateTocProgress progress) async {
  // notificationId 99001（与 download 99000 区分）
  // title: 「正在更新目录...」
  // body: 「${progress.processed}/${progress.total}」
  // progress: progress.processed, max: progress.total
  // ongoing: !progress.isDone
}
```

完成时短暂显示「目录刷新完成」notification 5s 后自动消失（onlyAlertOnce + setTimeoutAfter）。

### E. 测试

新增 `flutter_app/test/update_toc_runner_test.dart`：
- enqueue dedup（同 bookId 入两次只跑一次）
- 4 worker 并发（mock updateBookToc 注入 Completer 验同时 4 个 in-flight）
- 单本失败不阻塞（一本 throw 其他继续）
- progress stream 序列正确（n 次 progress + 一次 isDone）
- 整批完成后 _totalEnqueued reset

新增 `flutter_app/test/bookshelf_update_toc_test.dart`（或并入 `bookshelf_menu_test.dart`）：
- 「更新目录」从灰显改可点（enabled true）
- onSelected 触发 enqueue（用 mock UpdateTocRunner override）
- filter local books（fixture 含 origin 为空的本地书 → 不入队）
- 进度中 AppBar transient badge 显示
- 完成 SnackBar「成 X / 失 Y」
- invalidate providers

baseline 575 → ~585 期望（runner 4 + bookshelf 5 = 9）

### F. spec 段「批量后台任务模式 (BATCH-27b)」

入「页面布局对齐 (BATCH-26)」段「bookshelf 顶部 menu (BATCH-27a)」之后新加「批量后台任务模式 (BATCH-27b)」：
- Singleton runner + queue + StreamController + Notification 范本（download_runner / update_toc_runner 共享）
- 单本 FRB + Dart 端 worker pool + 静默 catch + 总结 SnackBar 决策
- transient AppBar badge 模式
- Forbidden 反向：禁批量 FRB（事务原子性失真）/ 禁全屏阻塞 dialog / 禁失败时单弹 SnackBar / 禁单 worker（threadCount=1 等于全串行）

## Acceptance Criteria

- [ ] FRB `update_book_toc(db_path, book_id) -> Result<i32, String>` 实现 + 2 单测
- [ ] `UpdateTocRunner` singleton + queue + 4 worker + StreamController + 5+ widget test
- [ ] `notification_service.dart::showUpdateTocProgress` 实现（notificationId 99001）
- [ ] PopupMenu「更新目录」从灰显改可点
- [ ] `_onUpdateToc` filter !local && canUpdate + 拿 dbPath + 入队
- [ ] AppBar transient badge `_isUpdatingToc=true` 时显示
- [ ] 完成 SnackBar「目录刷新完成：成 X / 失 Y」
- [ ] invalidate `allBooksProvider` / `booksByGroupProvider`
- [ ] flutter analyze 0 / flutter test PASS（baseline 575 → ~585）
- [ ] cargo test PASS（rust 单测）
- [ ] cargo build --workspace 通过 build.rs funcId 112 guard
- [ ] spec 入「批量后台任务模式 (BATCH-27b)」小节

## Out of Scope (27b)

- O1：自动「刷完触发缓存章节」 — 原版 `cacheBook()` 在 onCompletion 调，flutter 留 27 follow-up
- O2：`BookType.updateError` 字段写入 / UI 警示图标（Q5 选静默）
- O3：upAllBookToc 全书架刷（Q3 仅当前 Tab）
- O4：Notification 通道点击跳转书架（与 download 同 deep-link 留 follow-up）
- O5：Rust Semaphore 并发控制（Q4 选 Dart 端控）
- O6：cancel 进行中任务（点 transient badge 取消的 UX 留 follow-up）
- O7：retry 失败的书（用户重新点「更新目录」即可，原版亦无）

## Decision (ADR-lite)

**Context**：原 legado 单本 updateToc 隐含书源 + WebBook + chapter 写库 + book 元数据更新四步合一。flutter 端需要把这四步打包到 FRB 单本调用避免 Dart 端跨多个 FRB 编排（事务一致性 + Rust 错误信息一站式 + 减少 FRB call 数）。

**Decision**：单本 FRB（funcId 112） + Dart 端 4 worker pool + Notification + AppBar transient badge + 静默 catch + 总结 SnackBar。

**Consequences**：
- 短期：单本 FRB 把 BookSource fetch + WebBook 抓 toc + ChapterDao replace_by_book_preserving_content 一站式封装，Dart 端只关心 dbPath + bookId 即可
- 中期：UpdateTocRunner 与 DownloadRunner 共享 singleton/queue/StreamController/Notification 模式，未来加新批量任务（如 menu_bookshelf_manage 批量删 / 批量移分组）能直接复用
- 远期：spec 「批量后台任务模式 (BATCH-27b)」沉淀范本，避免每个新 bg 任务重新发明轮子

## Technical Notes

- `flutter_app/lib/features/bookshelf/bookshelf_page.dart:148+` PopupMenu「更新目录」灰显项
- `core/bridge/src/api.rs:422` 现有 `get_chapter_list_online` 单本异步参考
- `core/core-storage/src/chapter_dao.rs:115` `replace_by_book_preserving_content` 保 content 替换
- `flutter_app/lib/core/download_runner.dart` Singleton runner + queue 范本
- `flutter_app/lib/core/notification_service.dart::showDownloadProgress` 范本
- 原 legado 锚源码：
  - `MainViewModel.kt:96-180` upToc/startUpTocJob/updateToc
  - `main_bookshelf.xml:13-17` menu_update_toc
  - `BaseBookshelfFragment.kt:98` handler
- BATCH-26b 决策：灰显改可点时改 enabled / onTap，标题 + icon + 分组位置不动
- BATCH-21 决策：Future seq token / immutable update / KeepAlive 模板（runner 内不需要 seq token，singleton + queue 模型自身去重）
