import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../src/rust/api.dart' as rust_api;
import 'notification_service.dart';

/// BATCH-27b: 进度快照，broadcast 到 listeners + 推 NotificationService。
///
/// `total` 是当前批次入队总数（去重后）；下次新批次开始前 reset 为 0
/// 由 [UpdateTocRunner._start] 在 `await Future.wait` 后做。
/// `success / fail` 单调递增到 `total` 后 emit `isDone=true` 一次。
@immutable
class UpdateTocProgress {
  final int total;
  final int success;
  final int fail;
  final bool isDone;

  const UpdateTocProgress({
    required this.total,
    required this.success,
    required this.fail,
    required this.isDone,
  });

  int get processed => success + fail;

  /// 是否仍在跑：没标 done 且至少有 1 本入队。
  /// 空批 enqueue 不会触发 isRunning（`total == 0`）。
  bool get isRunning => !isDone && total > 0;

  @override
  String toString() =>
      'UpdateTocProgress(total: $total, success: $success, fail: $fail, isDone: $isDone)';
}

/// 测试钩子：单本目录刷新 FRB 调用替身。生产路径走
/// `rust_api.updateBookToc`。
typedef UpdateBookTocFn = Future<int> Function({
  required String dbPath,
  required String bookId,
});

/// BATCH-27b: 批量「更新目录」后台任务运行器。
///
/// 与 `download_runner.dart` 同款 singleton + Queue + StreamController +
/// Notification 模式（spec 「批量后台任务模式 (BATCH-27b)」沉淀范本）。
///
/// 行为约定：
///
/// - **去重**：`enqueue` 同 bookId 入两次只跑一次（既不在 `_queue` 也不在
///   `_inFlight` 才入队 + `_totalEnqueued++`）。第二批 enqueue 在第一批
///   完成前进来，新增 bookId 加进当前 `_totalEnqueued` 直到 `_running`
///   退出。
/// - **并发**：`_kUpTocConcurrency = 4` worker 同时跑；单本失败不阻塞
///   其他 worker。
/// - **静默 catch**：单本 throw → debugPrint + `_completedFail++`，不向上
///   抛打断整批。Dart 端 caller（bookshelf_page）只看 `onProgress` Stream
///   总结结果。
/// - **进度**：每完成 1 本 emit 一次 progress；整批跑完最后 emit `isDone=true`
///   后 reset `_totalEnqueued = 0`，下批从 0 起重新计数。
class UpdateTocRunner {
  static final UpdateTocRunner _instance = UpdateTocRunner._();
  factory UpdateTocRunner() => _instance;
  UpdateTocRunner._();

  /// Dart 端并发上限。原 legado 默认 16，flutter 端取 4 折中：与
  /// download_runner 串行（concurrency=1）形成对比，但不至于把 reqwest
  /// 连接池打满。
  static const int _kUpTocConcurrency = 4;

  /// Notification ID。与 download_runner 用的 99000-级别区分，避免
  /// 同时跑下载 + 刷目录时一方覆盖另一方的 notification（FlutterLocalNotifications
  /// `show(id)` 同 id 会替换）。
  static const int kNotificationId = 99001;

  final Queue<_UpTocJob> _queue = Queue();
  final Set<String> _inFlight = <String>{};
  bool _running = false;
  int _totalEnqueued = 0;
  int _completedSuccess = 0;
  int _completedFail = 0;

  final _progressController =
      StreamController<UpdateTocProgress>.broadcast();

  Stream<UpdateTocProgress> get onProgress => _progressController.stream;

  /// 调试钩子：测试用，验入队后 _queue + _inFlight 状态。
  @visibleForTesting
  int get debugQueueLength => _queue.length;
  @visibleForTesting
  int get debugInFlightLength => _inFlight.length;
  @visibleForTesting
  int get debugTotalEnqueued => _totalEnqueued;
  @visibleForTesting
  bool get debugRunning => _running;

  /// 重置 singleton 内部状态，仅供测试用（每个 testWidgets 间互不干扰）。
  /// 生产路径不应调用 —— singleton 模式天然横跨页面 lifecycle。
  @visibleForTesting
  void resetForTest() {
    _queue.clear();
    _inFlight.clear();
    _totalEnqueued = 0;
    _completedSuccess = 0;
    _completedFail = 0;
    _running = false;
  }

  /// 入队一批 bookId。同一 bookId 在 `_queue` 或 `_inFlight` 内已存在时
  /// 跳过（不重复跑）。空列表早返回。
  ///
  /// `overrideFn` 是测试钩子（避免 mock 全局 `rust_api`，与
  /// `bookshelf_page::importLocalBookOverride` 同款 *Override constructor 模式
  /// 不同，runner 是 singleton 不能进 ctor，故用方法参数透传）。
  Future<void> enqueue(
    List<String> bookIds, {
    required String dbPath,
    UpdateBookTocFn? overrideFn,
  }) async {
    if (bookIds.isEmpty) return;
    int newlyAdded = 0;
    for (final id in bookIds) {
      if (id.isEmpty) continue;
      if (_inFlight.contains(id)) continue;
      if (_queue.any((j) => j.bookId == id)) continue;
      _queue.add(_UpTocJob(bookId: id, dbPath: dbPath, overrideFn: overrideFn));
      _totalEnqueued++;
      newlyAdded++;
    }
    if (newlyAdded == 0) return;
    if (!_running) {
      // ignore: discarded_futures — _start 是 fire-and-forget，调用方靠
      // onProgress Stream 监听完成；让 enqueue 自身 await 整批完成会
      // block 调用方 setState，UI 上 transient badge 不能立即显示。
      _start();
    }
  }

  Future<void> _start() async {
    _running = true;
    // _completedSuccess / _completedFail / _totalEnqueued 在批次结束时
    // reset；这里不重置以支持「批次跑到一半，后续 enqueue 继续追加」的
    // 场景（_completedSuccess + _completedFail 累加到新 total 上仍正确）。
    _completedSuccess = 0;
    _completedFail = 0;
    // 立即 emit 一次 progress=0/total 让 UI transient badge 在 worker
    // 第一帧就出现；不然首本 job 会先 await（FRB 抓 toc 通常 >1s）才
    // 触发首个 _emitProgress，UI 看起来「点了菜单没反应」。
    _emitProgress();
    final futures = List<Future<void>>.generate(
      _kUpTocConcurrency,
      (_) => _worker(),
    );
    await Future.wait(futures);
    _running = false;
    // 最后一次 emit：done=true 表示批次完成。
    _emitProgress(done: true);
    // reset _totalEnqueued 让下次 enqueue 从 0 起重新计数；isDone 已 emit
    // 给监听方记录。
    _totalEnqueued = 0;
  }

  Future<void> _worker() async {
    while (_queue.isNotEmpty) {
      final job = _queue.removeFirst();
      _inFlight.add(job.bookId);
      try {
        final fn = job.overrideFn ??
            ({required String dbPath, required String bookId}) =>
                rust_api.updateBookToc(dbPath: dbPath, bookId: bookId);
        await fn(dbPath: job.dbPath, bookId: job.bookId);
        _completedSuccess++;
      } catch (e) {
        debugPrint('[UpdateTocRunner] book ${job.bookId} failed: $e');
        _completedFail++;
      } finally {
        _inFlight.remove(job.bookId);
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
    // Notification 是 fire-and-forget；插件失败不阻塞 progress emit。
    // ignore: discarded_futures
    NotificationService.showUpdateTocProgress(progress);
  }
}

class _UpTocJob {
  final String bookId;
  final String dbPath;
  final UpdateBookTocFn? overrideFn;
  const _UpTocJob({
    required this.bookId,
    required this.dbPath,
    required this.overrideFn,
  });
}
