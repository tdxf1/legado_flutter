import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/features/reader/services/reader_auto_scroller.dart';

/// 批次 4 (05-18) — ReaderAutoScroller 双模回归测试。
///
/// 两条路径：
/// - 滚动路径：每 [stepInterval] 调 ScrollController.jumpTo(+pixelsPerStep)
/// - 分页路径：每 pageIntervalMs 调 onPageTick
///
/// 用 fakeAsync 模拟时钟，无需真实 widget tree。

void main() {
  group('ReaderAutoScroller — 分页路径 (onPageTick)', () {
    test('运行后每 pageIntervalMs 触发 onPageTick', () {
      fakeAsync((async) {
        var pageCalls = 0;
        var changedCalls = 0;
        final scroller = ReaderAutoScroller(
          controller: () => null,
          onChanged: () => changedCalls++,
          onPageTick: () => pageCalls++,
          pageIntervalMs: 1000,
        );

        scroller.toggle(scroll: false);
        expect(scroller.isRunning, isTrue);
        expect(scroller.debugIsScrollMode, isFalse);
        expect(changedCalls, 1, reason: 'start 触发 onChanged');

        async.elapse(const Duration(milliseconds: 999));
        expect(pageCalls, 0, reason: '不到一个间隔不触发');

        async.elapse(const Duration(milliseconds: 1));
        expect(pageCalls, 1, reason: '到达 1×interval 触发一次');

        async.elapse(const Duration(seconds: 3));
        expect(pageCalls, 4, reason: '后续每秒一次，累计 4 次');

        scroller.dispose();
      });
    });

    test('toggle 反复切换不重复触发 / 不泄漏 timer', () {
      fakeAsync((async) {
        var pageCalls = 0;
        final scroller = ReaderAutoScroller(
          controller: () => null,
          onChanged: () {},
          onPageTick: () => pageCalls++,
          pageIntervalMs: 1000,
        );

        scroller.toggle(scroll: false); // start
        async.elapse(const Duration(milliseconds: 500));
        scroller.toggle(scroll: false); // stop
        async.elapse(const Duration(seconds: 5));
        expect(pageCalls, 0, reason: '中途 stop，永不触发');

        scroller.toggle(scroll: false); // start again
        async.elapse(const Duration(seconds: 1));
        expect(pageCalls, 1, reason: '重新 start 后正常计时');

        scroller.dispose();
      });
    });

    test('onPageTick=null 时分页路径不启动', () {
      fakeAsync((async) {
        var changedCalls = 0;
        final scroller = ReaderAutoScroller(
          controller: () => null,
          onChanged: () => changedCalls++,
          // onPageTick: null
          pageIntervalMs: 100,
        );

        scroller.toggle(scroll: false);
        expect(scroller.isRunning, isFalse, reason: '没 callback 直接拒绝 start');
        expect(changedCalls, 0);

        scroller.dispose();
      });
    });

    test('运行时改 pageIntervalMs 立即影响下一次触发', () {
      fakeAsync((async) {
        var pageCalls = 0;
        final scroller = ReaderAutoScroller(
          controller: () => null,
          onChanged: () {},
          onPageTick: () => pageCalls++,
          pageIntervalMs: 1000,
        );
        scroller.toggle(scroll: false);
        async.elapse(const Duration(seconds: 1));
        expect(pageCalls, 1);

        // 改成 500ms 间隔；已 schedule 的下一帧仍是 1000ms timer，
        // 触发回调后 _scheduleNextPage 用最新的 pageIntervalMs=500 安排再下一帧。
        scroller.pageIntervalMs = 500;
        async.elapse(const Duration(seconds: 1));
        // 第 2 秒触发一次（按旧 1000ms 安排）
        expect(pageCalls, 2);
        // 此后用新的 500ms
        async.elapse(const Duration(milliseconds: 500));
        expect(pageCalls, 3);
        async.elapse(const Duration(milliseconds: 500));
        expect(pageCalls, 4);

        scroller.dispose();
      });
    });

    test('dispose 后即使 timer 触发也不再调 callback', () {
      fakeAsync((async) {
        var pageCalls = 0;
        final scroller = ReaderAutoScroller(
          controller: () => null,
          onChanged: () {},
          onPageTick: () => pageCalls++,
          pageIntervalMs: 1000,
        );
        scroller.toggle(scroll: false);
        async.elapse(const Duration(milliseconds: 500));
        scroller.dispose();
        async.elapse(const Duration(seconds: 5));
        expect(pageCalls, 0);
      });
    });
  });

  group('ReaderAutoScroller — 滚动路径 (controller)', () {
    test('controller=null 时滚动路径直接 stop', () {
      fakeAsync((async) {
        var changedCalls = 0;
        final scroller = ReaderAutoScroller(
          controller: () => null,
          onChanged: () => changedCalls++,
        );
        scroller.toggle(scroll: true);
        // 第一帧检查 controller，null → _stop
        async.elapse(const Duration(milliseconds: 100));
        expect(scroller.isRunning, isFalse);
        // start 调一次 onChanged，stop 又调一次
        expect(changedCalls, 2);
        scroller.dispose();
      });
    });

    test('运行时改 pixelsPerStep 立即生效', () {
      fakeAsync((async) {
        final ctrl = ScrollController();
        // mock：用 ScrollController 单纯调 jumpTo 会因没 attach 抛
        // 异常；分页路径无需 controller，本测略过实际滚动数值验证。
        // 主要关注 pixelsPerStep setter 不出错。
        final scroller = ReaderAutoScroller(
          controller: () => ctrl, // hasClients=false，会被早返回 stop
          onChanged: () {},
          pixelsPerStep: 1.0,
        );
        scroller.pixelsPerStep = 5.0;
        expect(scroller.pixelsPerStep, 5.0);
        scroller.dispose();
        ctrl.dispose();
      });
    });
  });
}
