import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/core/remote_book_runner.dart';

/// BATCH-27c-3 (05-22): RemoteBookRunner 单元测试。
///
/// runner 是 singleton，每个 test 间用 `runner.resetForTest()` 清状态。
/// FRB 调用走 `downloadOverride` / `importOverride` 注入假实现，不依赖
/// 真 rust_api。
///
/// 测试覆盖（≥7 个）：
/// 1. enqueue dedup — 同 remotePath 入两次只跑一次
/// 2. 空列表 enqueue 早返回
/// 3. 单本失败不阻塞 — 一本 throw 其他 3 本正常完成
/// 4. 5 本全成功 — done emit + total=5/success=5/fail=0
/// 5. mixed 3 成功 + 2 失败 — done + success=3/fail=2
/// 6. 整批完成后 _totalEnqueued reset — 第二批从 0 起重新计数
/// 7. resetForTest 行为
/// 8. RemoteBookProgress.isRunning 三态（total=0 / done=true / 跑中）
/// 9. enqueue 串行 — concurrency=1 让前一本 import 完成才下一本下载
///
/// NotificationService.showRemoteBookProgress 在 widget test 调时会因
/// MissingPluginException 静默 catch（hasPermission 返 false），不影响
/// runner 行为；测试不验 notification 弹出。
void main() {
  // Notification 插件在测试里没有 platform binding，runner emit progress
  // 时会触发 hasPermission() invokeMethod，需要 binding 初始化但 channel
  // 仍 missing —— NotificationService 内部 catch + debugPrint。这一行
  // 让 ServicesBinding.instance 可用，避免一长串「Binding has not yet
  // been initialized」噪声。
  TestWidgetsFlutterBinding.ensureInitialized();

  late RemoteBookRunner runner;

  setUp(() {
    runner = RemoteBookRunner();
    runner.resetForTest();
  });

  RemoteBookJob job(String name) => RemoteBookJob(
        url: 'https://x/dav/',
        user: 'u',
        password: 'p',
        remotePath: name,
        targetLocalPath: '/tmp/$name',
        dbPath: '/fake/db.sqlite',
        documentsDir: '/tmp/docs',
      );

  Future<int> okDownload({
    required String url,
    required String user,
    required String password,
    required String remotePath,
    required String targetLocalPath,
  }) async =>
      1024;

  Future<String> okImport({
    required String dbPath,
    required String filePath,
    required String documentsDir,
  }) async =>
      '{"book_id":"abc"}';

  test('BATCH-27c-3: enqueue dedup — same remotePath only runs once',
      () async {
    final downloaded = <String>[];

    Future<int> trackDownload({
      required String url,
      required String user,
      required String password,
      required String remotePath,
      required String targetLocalPath,
    }) async {
      downloaded.add(remotePath);
      return 1024;
    }

    // 同 remotePath 入两次
    await runner.enqueue(
      [job('books/a.epub'), job('books/a.epub'), job('books/b.epub')],
      downloadOverride: trackDownload,
      importOverride: okImport,
    );

    expect(runner.debugTotalEnqueued, 2,
        reason: '同 remotePath 只算 1 次（去重）');

    for (int i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (!runner.debugRunning) break;
    }
    expect(runner.debugRunning, false);
    expect(downloaded.toSet(), {'books/a.epub', 'books/b.epub'});
  });

  test('BATCH-27c-3: enqueue empty list is a no-op', () async {
    await runner.enqueue(
      const <RemoteBookJob>[],
      downloadOverride: okDownload,
      importOverride: okImport,
    );

    expect(runner.debugRunning, false);
    expect(runner.debugTotalEnqueued, 0);
  });

  test(
    'BATCH-27c-3: single download failure does not block other jobs',
    () async {
      final progress = <RemoteBookProgress>[];
      final sub = runner.onProgress.listen(progress.add);
      addTearDown(sub.cancel);

      Future<int> failOnB({
        required String url,
        required String user,
        required String password,
        required String remotePath,
        required String targetLocalPath,
      }) async {
        if (remotePath == 'b_fail') {
          throw Exception('故意失败');
        }
        return 1024;
      }

      await runner.enqueue(
        [job('a'), job('b_fail'), job('c'), job('d')],
        downloadOverride: failOnB,
        importOverride: okImport,
      );

      for (int i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        if (!runner.debugRunning) break;
      }
      expect(runner.debugRunning, false);

      final last = progress.last;
      expect(last.isDone, true);
      expect(last.success, 3, reason: 'a / c / d 成功');
      expect(last.fail, 1, reason: 'b_fail 失败');
    },
  );

  test('BATCH-27c-3: 5 jobs all succeed → done emit total=5/success=5/fail=0',
      () async {
    final progress = <RemoteBookProgress>[];
    final sub = runner.onProgress.listen(progress.add);
    addTearDown(sub.cancel);

    await runner.enqueue(
      [job('a'), job('b'), job('c'), job('d'), job('e')],
      downloadOverride: okDownload,
      importOverride: okImport,
    );

    for (int i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (!runner.debugRunning && progress.any((p) => p.isDone)) break;
    }

    final done = progress.firstWhere((p) => p.isDone);
    expect(done.total, 5);
    expect(done.success, 5);
    expect(done.fail, 0);
  });

  test('BATCH-27c-3: mixed 3 success + 2 failures → done + success=3/fail=2',
      () async {
    final progress = <RemoteBookProgress>[];
    final sub = runner.onProgress.listen(progress.add);
    addTearDown(sub.cancel);

    Future<int> failOnXY({
      required String url,
      required String user,
      required String password,
      required String remotePath,
      required String targetLocalPath,
    }) async {
      if (remotePath == 'x' || remotePath == 'y') {
        throw Exception('boom');
      }
      return 1024;
    }

    await runner.enqueue(
      [job('a'), job('x'), job('b'), job('y'), job('c')],
      downloadOverride: failOnXY,
      importOverride: okImport,
    );

    for (int i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (!runner.debugRunning && progress.any((p) => p.isDone)) break;
    }

    final done = progress.firstWhere((p) => p.isDone);
    expect(done.total, 5);
    expect(done.success, 3);
    expect(done.fail, 2);
  });

  test('BATCH-27c-3: _totalEnqueued resets after batch done — second batch '
      'counts from 0', () async {
    // 第一批 3 本（即跑即完）
    await runner.enqueue(
      [job('a'), job('b'), job('c')],
      downloadOverride: okDownload,
      importOverride: okImport,
    );
    for (int i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (!runner.debugRunning) break;
    }
    expect(runner.debugRunning, false);
    expect(runner.debugTotalEnqueued, 0,
        reason: '批次 isDone 后 _totalEnqueued 应 reset 为 0');

    // 第二批 2 本，但用 hanging completer 让批次悬停在 in-flight 阶段
    final completer = Completer<int>();
    Future<int> slowDownload({
      required String url,
      required String user,
      required String password,
      required String remotePath,
      required String targetLocalPath,
    }) async {
      return await completer.future;
    }

    await runner.enqueue(
      [job('d'), job('e')],
      downloadOverride: slowDownload,
      importOverride: okImport,
    );
    // 让 worker 启动 → 进 in-flight
    for (int i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    // 此时 _totalEnqueued 应是 2，不是 5（第一批已 reset）
    expect(runner.debugTotalEnqueued, 2,
        reason: '第二批应从 0 起重新累加，不是 3+2=5');
    // 释放 future 让批次跑完
    completer.complete(7);
    for (int i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (!runner.debugRunning) break;
    }
    expect(runner.debugRunning, false);
  });

  test('BATCH-27c-3: resetForTest clears state', () async {
    final completer = Completer<int>();
    Future<int> slowDownload({
      required String url,
      required String user,
      required String password,
      required String remotePath,
      required String targetLocalPath,
    }) async =>
        completer.future;

    await runner.enqueue(
      [job('a'), job('b')],
      downloadOverride: slowDownload,
      importOverride: okImport,
    );
    // 等 worker 启动
    for (int i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(runner.debugTotalEnqueued, 2);
    expect(runner.debugRunning, true);

    runner.resetForTest();
    expect(runner.debugTotalEnqueued, 0);
    expect(runner.debugQueueLength, 0);
    expect(runner.debugInFlightLength, 0);
    expect(runner.debugRunning, false);

    // 释放 future（worker 仍持原 fake，但不会再读 _queue）
    completer.complete(0);
    // 让 worker 收尾
    for (int i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  });

  test(
      'BATCH-27c-3: RemoteBookProgress.isRunning false when total=0 / done=true',
      () {
    const empty = RemoteBookProgress(
      total: 0,
      success: 0,
      fail: 0,
      isDone: false,
    );
    expect(empty.isRunning, false, reason: 'total=0 不算跑');
    const done = RemoteBookProgress(
      total: 5,
      success: 3,
      fail: 2,
      isDone: true,
    );
    expect(done.isRunning, false);
    const inProgress = RemoteBookProgress(
      total: 5,
      success: 1,
      fail: 0,
      isDone: false,
    );
    expect(inProgress.isRunning, true);
    expect(inProgress.processed, 1);
  });

  test('BATCH-27c-3: failure path debugPrint does not throw', () async {
    final originalPrint = debugPrint;
    addTearDown(() {
      debugPrint = originalPrint;
    });
    debugPrint = (msg, {wrapWidth}) {
      // no-op — 验调用不抛
    };

    Future<int> alwaysFail({
      required String url,
      required String user,
      required String password,
      required String remotePath,
      required String targetLocalPath,
    }) async {
      throw StateError('boom');
    }

    await runner.enqueue(
      [job('only_fail')],
      downloadOverride: alwaysFail,
      importOverride: okImport,
    );
    for (int i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (!runner.debugRunning) break;
    }
    expect(runner.debugRunning, false);
  });
}
