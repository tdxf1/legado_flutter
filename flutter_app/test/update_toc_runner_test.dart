import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/core/update_toc_runner.dart';

/// BATCH-27b (05-22): UpdateTocRunner 单元测试。
///
/// runner 是 singleton，每个 testWidgets 间用 `runner.resetForTest()` 清
/// 状态。FRB 调用走 `overrideFn` 注入假实现，不依赖真 rust_api。
///
/// 测试覆盖（8 个）：
/// 1. enqueue dedup — 同 bookId 入两次只跑一次
/// 2. 4 worker 并发 — 用 hanging Completer 让 4 个 in-flight 同时挂起
/// 3. 单本失败不阻塞 — 一本 throw 其他 3 本正常完成
/// 4. progress stream 序列正确 — N 次 processed + 1 次 isDone
/// 5. 整批完成后 _totalEnqueued reset — 第二批从 0 起重新计数
/// 6. enqueue 空列表 no-op
/// 7. UpdateTocProgress.isRunning 三态（total=0 / done=true / 跑中）
/// 8. 失败路径 debugPrint 不抛错
///
/// NotificationService.showUpdateTocProgress 在 widget test 调时会因
/// MissingPluginException 静默 catch（hasPermission 返 false），不影响
/// runner 行为；测试不验 notification 弹出。
void main() {
  // Notification 插件在测试里没有 platform binding，runner emit progress
  // 时会触发 hasPermission() invokeMethod，需要 binding 初始化但 channel
  // 仍 missing —— NotificationService 内部 catch + debugPrint。这一行
  // 让 ServicesBinding.instance 可用，避免一长串「Binding has not yet
  // been initialized」噪声。
  TestWidgetsFlutterBinding.ensureInitialized();

  late UpdateTocRunner runner;

  setUp(() {
    runner = UpdateTocRunner();
    runner.resetForTest();
  });

  test('BATCH-27b: enqueue dedup — same bookId only runs once', () async {
    final calls = <String>[];
    final completer = Completer<int>();

    Future<int> fakeFn({required String dbPath, required String bookId}) async {
      calls.add(bookId);
      return await completer.future;
    }

    // 同 bookId 入两次
    await runner.enqueue(
      ['b1', 'b1', 'b2'],
      dbPath: '/fake/db',
      overrideFn: fakeFn,
    );

    // 等待 _start 启动 worker（_kUpTocConcurrency=4, 但只 2 个 job → 2 个
    // worker 在跑）
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(runner.debugTotalEnqueued, 2, reason: '同 bookId 只算 1 次');
    expect(calls.toSet(), {'b1', 'b2'});

    // 让 future 完成，runner 跑完整批
    completer.complete(10);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(runner.debugRunning, false);
  });

  test(
    'BATCH-27b: 4 worker concurrency — first 4 jobs go in-flight together',
    () async {
      // 4 worker 限制：5 个 job 入队后只前 4 个进 in-flight，第 5 个等
      final completer = Completer<int>();
      Future<int> fakeFn(
          {required String dbPath, required String bookId}) async {
        return await completer.future;
      }

      await runner.enqueue(
        ['b1', 'b2', 'b3', 'b4', 'b5'],
        dbPath: '/fake/db',
        overrideFn: fakeFn,
      );

      // 多 microtask 让 worker 启动
      for (int i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(runner.debugInFlightLength, 4,
          reason: '_kUpTocConcurrency=4 → 前 4 个并发入 in-flight');
      expect(runner.debugQueueLength, 1, reason: '第 5 个仍在 queue');

      // 让 4 个完成 → 第 5 个 worker pick up
      completer.complete(7);
      // 多个 await 让所有 worker 跑完
      for (int i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(runner.debugQueueLength, 0);
      expect(runner.debugInFlightLength, 0);
      expect(runner.debugRunning, false);
    },
  );

  test('BATCH-27b: single failure does not block other workers', () async {
    final progress = <UpdateTocProgress>[];
    final sub = runner.onProgress.listen(progress.add);
    addTearDown(sub.cancel);

    Future<int> fakeFn(
        {required String dbPath, required String bookId}) async {
      if (bookId == 'b_fail') {
        throw Exception('故意失败');
      }
      return 5;
    }

    await runner.enqueue(
      ['b1', 'b_fail', 'b2', 'b3'],
      dbPath: '/fake/db',
      overrideFn: fakeFn,
    );

    // 等批次完成
    for (int i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (!runner.debugRunning) break;
    }
    expect(runner.debugRunning, false);

    // 最后一次进度应是 isDone=true，success=3 fail=1
    final last = progress.last;
    expect(last.isDone, true);
    expect(last.success, 3, reason: 'b1 / b2 / b3 成功');
    expect(last.fail, 1, reason: 'b_fail 失败');
  });

  test('BATCH-27b: progress stream emits 1 event per chapter + final isDone',
      () async {
    final progress = <UpdateTocProgress>[];
    final sub = runner.onProgress.listen(progress.add);
    addTearDown(sub.cancel);

    Future<int> fakeFn(
        {required String dbPath, required String bookId}) async {
      // 微小延迟让 worker pickup 顺序明确
      await Future<void>.delayed(const Duration(milliseconds: 1));
      return 1;
    }

    await runner.enqueue(
      ['b1', 'b2', 'b3'],
      dbPath: '/fake/db',
      overrideFn: fakeFn,
    );

    for (int i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (!runner.debugRunning && progress.any((p) => p.isDone)) break;
    }

    // 应至少有 3 个 processed event + 1 个 done event
    final doneCount = progress.where((p) => p.isDone).length;
    expect(doneCount, 1, reason: 'isDone=true 仅在批次末尾 emit 一次');
    final processed = progress.where((p) => !p.isDone).toList();
    expect(processed.length, greaterThanOrEqualTo(3),
        reason: '每完成 1 本 emit 一次 processed event（>=3）');
    // 最终 done 时 success/total 应一致
    final done = progress.firstWhere((p) => p.isDone);
    expect(done.total, 3);
    expect(done.success, 3);
    expect(done.fail, 0);
  });

  test('BATCH-27b: _totalEnqueued resets after batch done — second batch '
      'counts from 0', () async {
    Future<int> fastFn(
        {required String dbPath, required String bookId}) async {
      return 1;
    }

    // 第一批 3 本（即跑即完）
    await runner.enqueue(
      ['b1', 'b2', 'b3'],
      dbPath: '/fake/db',
      overrideFn: fastFn,
    );
    for (int i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (!runner.debugRunning) break;
    }
    expect(runner.debugRunning, false);
    expect(runner.debugTotalEnqueued, 0,
        reason: '批次 isDone 后 _totalEnqueued 应 reset 为 0');

    // 第二批 2 本，但用 hanging completer 让批次悬停在 in-flight 阶段
    final completer = Completer<int>();
    Future<int> slowFn(
        {required String dbPath, required String bookId}) async {
      return await completer.future;
    }
    await runner.enqueue(
      ['b4', 'b5'],
      dbPath: '/fake/db',
      overrideFn: slowFn,
    );
    // 让 worker 启动 → b4/b5 进 in-flight
    for (int i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    // 此时 _totalEnqueued 应是 2，不是 5（第一批已 reset）
    expect(runner.debugTotalEnqueued, 2,
        reason: '第二批应从 0 起重新累加，不是 3+2=5');
    // 释放 future 让批次跑完
    completer.complete(7);
    for (int i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (!runner.debugRunning) break;
    }
    expect(runner.debugRunning, false);
  });

  test('BATCH-27b: enqueue empty list is a no-op', () async {
    Future<int> fakeFn(
        {required String dbPath, required String bookId}) async {
      return 1;
    }

    await runner.enqueue(
      const <String>[],
      dbPath: '/fake/db',
      overrideFn: fakeFn,
    );

    expect(runner.debugRunning, false);
    expect(runner.debugTotalEnqueued, 0);
  });

  test('BATCH-27b: UpdateTocProgress.isRunning false when total=0 / done=true',
      () {
    const empty = UpdateTocProgress(
      total: 0,
      success: 0,
      fail: 0,
      isDone: false,
    );
    expect(empty.isRunning, false, reason: 'total=0 不算跑');
    const done = UpdateTocProgress(
      total: 5,
      success: 3,
      fail: 2,
      isDone: true,
    );
    expect(done.isRunning, false);
    const inProgress = UpdateTocProgress(
      total: 5,
      success: 1,
      fail: 0,
      isDone: false,
    );
    expect(inProgress.isRunning, true);
    expect(inProgress.processed, 1);
  });

  /// Sanity check：debugPrint 行不进 stdout 污染其他测试 — flutter_test
  /// 默认 disable debugPrint，但 runner 内部 debugPrint 调用本身不应抛错。
  test('BATCH-27b: failure path debugPrint does not throw', () async {
    final originalPrint = debugPrint;
    addTearDown(() {
      debugPrint = originalPrint;
    });
    debugPrint = (msg, {wrapWidth}) {
      // no-op — 验调用不抛
    };

    Future<int> fakeFn(
        {required String dbPath, required String bookId}) async {
      throw StateError('boom');
    }

    await runner.enqueue(
      ['b_fail_only'],
      dbPath: '/fake/db',
      overrideFn: fakeFn,
    );
    for (int i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (!runner.debugRunning) break;
    }
    expect(runner.debugRunning, false);
  });
}
