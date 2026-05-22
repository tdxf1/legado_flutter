import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../src/rust/api.dart' as rust_api;
import 'notification_service.dart';
import 'util/platform_int64.dart';

/// BATCH-27c-3: 进度快照，broadcast 到 listeners + 推 NotificationService。
///
/// 与 [`UpdateTocProgress`] 同形态（27b 范本）：`total` 是当前批次入队总数
/// （去重后）；`success / fail` 单调递增到 `total` 后 emit `isDone=true` 一次。
/// 下次新批次开始前 reset 为 0 由 [`RemoteBookRunner._start`] 在
/// `await Future.wait` 后做。
@immutable
class RemoteBookProgress {
  final int total;
  final int success;
  final int fail;
  final bool isDone;

  const RemoteBookProgress({
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
      'RemoteBookProgress(total: $total, success: $success, fail: $fail, isDone: $isDone)';
}

/// 测试钩子：webdav 单文件下载 FRB 调用替身。生产路径走
/// `rust_api.webdavDownloadFile`。返字节数（int）。
typedef RemoteBookDownloadFn = Future<int> Function({
  required String url,
  required String user,
  required String password,
  required String remotePath,
  required String targetLocalPath,
});

/// 测试钩子：本地书入库 FRB 调用替身。生产路径走 `rust_api.importLocalBook`。
typedef ImportLocalBookFn = Future<String> Function({
  required String dbPath,
  required String filePath,
  required String documentsDir,
});

/// 单个远程书下载任务。
class RemoteBookJob {
  final String url;
  final String user;
  final String password;

  /// webdav 远端绝对路径（含目录前缀 + 文件名）。也是去重 key。
  final String remotePath;

  /// 本地目标绝对路径。
  final String targetLocalPath;

  final String dbPath;
  final String documentsDir;

  const RemoteBookJob({
    required this.url,
    required this.user,
    required this.password,
    required this.remotePath,
    required this.targetLocalPath,
    required this.dbPath,
    required this.documentsDir,
  });
}

/// BATCH-27c-3: 远程书批量下载后台任务运行器。
///
/// 与 [`UpdateTocRunner`] 同款 singleton + Queue + StreamController +
/// Notification 模式（spec 「批量后台任务模式 (BATCH-27b)」沉淀范本）。
///
/// 行为约定：
///
/// - **去重**：`enqueue` 同 `remotePath` 入两次只跑一次。`remotePath` 含
///   完整路径前缀（如 `books/小说/foo.epub`），跨目录不会撞 key。
/// - **并发**：`_kRemoteBookConcurrency = 1` 串行（PRD §Q4 决策 — webdav
///   服务端常对单连接并发限速 + Rust `download_to_path` 已流式）。常量
///   保留以支持 follow-up 调高。worker pool 抽象通过 `Future.wait +
///   List.generate(N)` 仍然成立。
/// - **静默 catch**：单本 throw → debugPrint + `_completedFail++`，不向上
///   抛打断整批。Dart 端 caller（remote_books_page）只看 `onProgress` Stream
///   总结结果。
/// - **进度**：每完成 1 本 emit 一次 progress；整批跑完最后 emit `isDone=true`
///   后 reset `_totalEnqueued = 0`，下批从 0 起重新计数。
class RemoteBookRunner {
  static final RemoteBookRunner _instance = RemoteBookRunner._();
  factory RemoteBookRunner() => _instance;
  RemoteBookRunner._();

  /// Dart 端并发上限。串行（=1）— webdav 单连接服务端常并发限速；流式
  /// 下载文件大小 MB 级，并发收益 marginal。常量保留以便 follow-up 调高。
  static const int _kRemoteBookConcurrency = 1;

  /// Notification ID。99002 — 与 download_runner（99000）/
  /// update_toc_runner（99001）区分，避免同时跑多个批量任务时互相覆盖
  /// 同 id notification（FlutterLocalNotifications `show(id)` 同 id 会替换）。
  static const int kNotificationId = 99002;

  final Queue<RemoteBookJob> _queue = Queue();
  final Set<String> _inFlight = <String>{};
  bool _running = false;
  int _totalEnqueued = 0;
  int _completedSuccess = 0;
  int _completedFail = 0;

  /// 当前批次的 override 钩子。enqueue 时由 caller 透传，整批走同一对
  /// fake 实现；批次跑完后 reset。
  RemoteBookDownloadFn? _downloadOverride;
  ImportLocalBookFn? _importOverride;

  final _progressController =
      StreamController<RemoteBookProgress>.broadcast();

  Stream<RemoteBookProgress> get onProgress => _progressController.stream;

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
    _downloadOverride = null;
    _importOverride = null;
  }

  /// 入队一批 job。同 `remotePath` 在 `_queue` 或 `_inFlight` 内已存在
  /// 时跳过（不重复跑）。空列表早返回。
  ///
  /// `downloadOverride` / `importOverride` 是测试钩子（避免 mock 全局
  /// `rust_api`，与 [`UpdateTocRunner.enqueue.overrideFn`] 同款 — runner
  /// 是 singleton 不能进 ctor，故用方法参数透传）。一批 enqueue 内的
  /// 所有 job 走同一对 override；整批跑完后 reset。
  Future<void> enqueue(
    List<RemoteBookJob> jobs, {
    RemoteBookDownloadFn? downloadOverride,
    ImportLocalBookFn? importOverride,
  }) async {
    if (jobs.isEmpty) return;
    int newlyAdded = 0;
    for (final job in jobs) {
      if (job.remotePath.isEmpty) continue;
      if (_inFlight.contains(job.remotePath)) continue;
      if (_queue.any((j) => j.remotePath == job.remotePath)) continue;
      _queue.add(job);
      _totalEnqueued++;
      newlyAdded++;
    }
    if (newlyAdded == 0) return;
    // 仅在第一次启动时记 override；同批 enqueue 透传同一对 fake。
    if (!_running) {
      _downloadOverride = downloadOverride;
      _importOverride = importOverride;
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
    // 第一帧就出现；不然首本 job 会先 await（webdav download 通常 >1s）才
    // 触发首个 _emitProgress，UI 看起来「点了菜单没反应」。
    _emitProgress();
    final futures = List<Future<void>>.generate(
      _kRemoteBookConcurrency,
      (_) => _worker(),
    );
    await Future.wait(futures);
    _running = false;
    // 最后一次 emit：done=true 表示批次完成。
    _emitProgress(done: true);
    // reset _totalEnqueued 让下次 enqueue 从 0 起重新计数；isDone 已 emit
    // 给监听方记录。reset override 钩子让下批重新接受新 fake。
    _totalEnqueued = 0;
    _downloadOverride = null;
    _importOverride = null;
  }

  Future<void> _worker() async {
    while (_queue.isNotEmpty) {
      final job = _queue.removeFirst();
      _inFlight.add(job.remotePath);
      try {
        final downloadFn = _downloadOverride ??
            ({
              required String url,
              required String user,
              required String password,
              required String remotePath,
              required String targetLocalPath,
            }) async {
              final n = await rust_api.webdavDownloadFile(
                url: url,
                user: user,
                password: password,
                remotePath: remotePath,
                targetLocalPath: targetLocalPath,
              );
              return platformInt64ToInt(n);
            };
        await downloadFn(
          url: job.url,
          user: job.user,
          password: job.password,
          remotePath: job.remotePath,
          targetLocalPath: job.targetLocalPath,
        );
        final importFn = _importOverride ??
            ({
              required String dbPath,
              required String filePath,
              required String documentsDir,
            }) =>
                rust_api.importLocalBook(
                  dbPath: dbPath,
                  filePath: filePath,
                  documentsDir: documentsDir,
                );
        await importFn(
          dbPath: job.dbPath,
          filePath: job.targetLocalPath,
          documentsDir: job.documentsDir,
        );
        _completedSuccess++;
      } catch (e) {
        debugPrint('[RemoteBookRunner] ${job.remotePath} failed: $e');
        _completedFail++;
      } finally {
        _inFlight.remove(job.remotePath);
        _emitProgress();
      }
    }
  }

  void _emitProgress({bool done = false}) {
    final progress = RemoteBookProgress(
      total: _totalEnqueued,
      success: _completedSuccess,
      fail: _completedFail,
      isDone: done,
    );
    _progressController.add(progress);
    // Notification 是 fire-and-forget；插件失败不阻塞 progress emit。
    // ignore: discarded_futures
    NotificationService.showRemoteBookProgress(progress);
  }
}
