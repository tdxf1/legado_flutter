import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/providers.dart';
import 'package:legado_flutter/features/reader/page/page_view_controller.dart';

/// 第二十五批 Task 2A — PageViewController 三章节窗口重构（A.1..A.8）
///
/// 覆盖目标：
/// 1. 默认 controller / 单章节 loadChapter / boundaryNextPage == null
/// 2. setNeighborChapter(next:) 后未到末页 → boundaryNextPage == null
/// 3. setNeighborChapter(next:) 后跳到末页 → boundaryNextPage 不为 null
/// 4. setNeighborChapter + commitToNextChapter 切换 currentChapter（含 prev 升级）
/// 5. commitToNextChapter / commitToPrevChapter 在 next/prev 为 null 时返回 false
/// 6. commitToPrevChapter 路径（含定位到 lastIndex）
/// 7. loadChapter 跳到不连续 chapterIndex 时清空 prev/next
/// 8. updateSettings 排版字段变化时清空三章 pages
/// 9. updatePageSize 同样清三章 pages
/// 10. ChapterWindow 公共构造器 + 内部 split content
/// 11. 三章节同时存在时 chapterIndex 必须递增
///
/// 测试通过 controller 的 @visibleForTesting `debugPrevChapterIndex` /
/// `debugNextChapterIndex` 等观察内部状态，不直接访问私有字段。

const _kPageSize = Size(400, 600);

/// 构造一个生成 ~N 页的中文长内容（每段重复同一句话，足够 PageMeasure
/// 切出多页）。
String _longContent(int paragraphs) {
  return List<String>.generate(
    paragraphs,
    (i) =>
        '这是用于翻页测试的中文段落第 $i 段，需要足够长才能让 PageMeasure 切成多页。',
  ).join('\n');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PageViewController 默认状态', () {
    test('未 loadChapter / 未 setNeighborChapter → boundary getter 都为 null',
        () {
      const settings = ReaderSettings();
      final controller = PageViewController(settings: settings);
      addTearDown(controller.dispose);
      controller.updatePageSize(_kPageSize);

      expect(controller.boundaryNextPage, isNull);
      expect(controller.boundaryPrevPage, isNull);
      expect(controller.currentPage, isNull);
      expect(controller.hasNext, isFalse);
      expect(controller.hasPrev, isFalse);
      expect(controller.totalPagesInChapter, 0);
      expect(controller.debugPrevChapterIndex, isNull);
      expect(controller.debugNextChapterIndex, isNull);
    });

    test('initialChapterIndex 在 loadChapter 之前可读', () {
      const settings = ReaderSettings();
      final controller = PageViewController(
        settings: settings,
        initialChapterIndex: 7,
        initialPageIndex: 3,
      );
      addTearDown(controller.dispose);
      expect(controller.currentChapterIndex, 7);
      expect(controller.currentPageIndex, 3);
    });
  });

  group('boundaryNextPage / boundaryPrevPage', () {
    late PageViewController controller;
    setUp(() {
      const settings = ReaderSettings();
      controller = PageViewController(settings: settings);
      controller.updatePageSize(_kPageSize);
    });
    tearDown(() => controller.dispose());

    test('单章节 loadChapter（无邻章）→ boundaryNextPage == null', () {
      controller.loadChapter(0, '第一章', _longContent(80));
      // 不调 setNeighborChapter，邻章为 null。
      controller.jumpToPage(controller.totalPagesInChapter - 1);
      expect(controller.boundaryNextPage, isNull,
          reason: '没灌入下一章 → 即使本章末页 boundaryNextPage 也应为 null');
    });

    test('setNeighborChapter(next:) 后未到末页 → boundaryNextPage == null', () {
      controller.loadChapter(0, '第一章', _longContent(80));
      expect(controller.totalPagesInChapter, greaterThan(1));
      controller.setNeighborChapter(
        next: ChapterWindow(
          chapterIndex: 1,
          title: '第二章',
          content: _longContent(40),
        ),
      );
      // 当前停在 page 0，未到末页。
      expect(controller.currentPageIndex, 0);
      expect(controller.boundaryNextPage, isNull);
    });

    test('setNeighborChapter(next:) 后跳到末页 → boundaryNextPage 不为 null', () {
      controller.loadChapter(0, '第一章', _longContent(80));
      controller.setNeighborChapter(
        next: ChapterWindow(
          chapterIndex: 1,
          title: '第二章',
          content: _longContent(40),
        ),
      );
      controller.jumpToPage(controller.totalPagesInChapter - 1);
      final boundary = controller.boundaryNextPage;
      expect(boundary, isNotNull);
      expect(boundary!.chapterIndex, 1,
          reason: 'boundaryNextPage 应来自下一章首页');
      expect(boundary.pageIndex, 0);
    });

    test('setNeighborChapter(prev:) 在本章首页时 → boundaryPrevPage 不为 null',
        () {
      controller.loadChapter(1, '第二章', _longContent(80));
      controller.setNeighborChapter(
        prev: ChapterWindow(
          chapterIndex: 0,
          title: '第一章',
          content: _longContent(40),
        ),
      );
      // 默认在 page 0（章首）
      expect(controller.currentPageIndex, 0);
      final boundary = controller.boundaryPrevPage;
      expect(boundary, isNotNull);
      expect(boundary!.chapterIndex, 0,
          reason: 'boundaryPrevPage 应来自上一章末页');
      // 是末页：pageIndex == prev 章 totalPages - 1
      expect(boundary.pageIndex, controller.debugPrevChapterPageCount - 1);
    });

    test('未在本章首页时 boundaryPrevPage == null', () {
      controller.loadChapter(1, '第二章', _longContent(80));
      controller.setNeighborChapter(
        prev: ChapterWindow(
          chapterIndex: 0,
          title: '第一章',
          content: _longContent(40),
        ),
      );
      controller.jumpToPage(1);
      expect(controller.boundaryPrevPage, isNull);
    });
  });

  group('commitToNextChapter / commitToPrevChapter', () {
    late PageViewController controller;
    setUp(() {
      const settings = ReaderSettings();
      controller = PageViewController(settings: settings);
      controller.updatePageSize(_kPageSize);
    });
    tearDown(() => controller.dispose());

    test('commitToNextChapter：next 提升为 cur，旧 cur 降为 prev，next 清空', () {
      controller.loadChapter(0, '第一章', _longContent(80));
      controller.setNeighborChapter(
        next: ChapterWindow(
          chapterIndex: 1,
          title: '第二章',
          content: _longContent(40),
        ),
      );

      final ok = controller.commitToNextChapter();
      expect(ok, isTrue);
      expect(controller.currentChapterIndex, 1);
      expect(controller.currentPageIndex, 0,
          reason: '提升后 currentPageIndex 应重置为 0');
      expect(controller.debugCurrentChapterTitle, '第二章');
      // 旧 cur 降为 prev
      expect(controller.debugPrevChapterIndex, 0);
      expect(controller.debugPrevChapterTitle, '第一章');
      // next 清空
      expect(controller.debugNextChapterIndex, isNull);
    });

    test('commitToNextChapter 在 _nextChapter == null 时返回 false', () {
      controller.loadChapter(0, '第一章', _longContent(80));
      // 不灌 next。
      final ok = controller.commitToNextChapter();
      expect(ok, isFalse);
      expect(controller.currentChapterIndex, 0,
          reason: '失败时不应改变 currentChapter');
    });

    test('commitToPrevChapter：prev 提升为 cur，currentPageIndex 定位到末页', () {
      controller.loadChapter(1, '第二章', _longContent(80));
      controller.setNeighborChapter(
        prev: ChapterWindow(
          chapterIndex: 0,
          title: '第一章',
          content: _longContent(40),
        ),
      );

      // prev 章 measure 后的总页数
      final prevTotal = controller.debugPrevChapterPageCount;
      expect(prevTotal, greaterThan(0));

      final ok = controller.commitToPrevChapter();
      expect(ok, isTrue);
      expect(controller.currentChapterIndex, 0);
      expect(controller.currentPageIndex, prevTotal - 1,
          reason: '提升后 currentPageIndex 应定位到上一章末页');
      expect(controller.debugCurrentChapterTitle, '第一章');
      // 旧 cur 降为 next
      expect(controller.debugNextChapterIndex, 1);
      expect(controller.debugNextChapterTitle, '第二章');
      // prev 清空
      expect(controller.debugPrevChapterIndex, isNull);
    });

    test('commitToPrevChapter 在 _prevChapter == null 时返回 false', () {
      controller.loadChapter(1, '第二章', _longContent(80));
      final ok = controller.commitToPrevChapter();
      expect(ok, isFalse);
      expect(controller.currentChapterIndex, 1);
    });

    test('commit 后 chapterIndex 三章节仍递增', () {
      controller.loadChapter(5, '第六章', _longContent(40));
      controller.setNeighborChapter(
        prev: ChapterWindow(
          chapterIndex: 4,
          title: '第五章',
          content: _longContent(40),
        ),
        next: ChapterWindow(
          chapterIndex: 6,
          title: '第七章',
          content: _longContent(40),
        ),
      );
      // commit next：cur 5 → prev 5, next 6 → cur，旧 prev 4 释放。
      controller.commitToNextChapter();
      expect(controller.currentChapterIndex, 6);
      expect(controller.debugPrevChapterIndex, 5);
      expect(controller.debugNextChapterIndex, isNull,
          reason: 'commit 后 next 必须清空避免错位');
    });
  });

  group('loadChapter 不连续清邻章', () {
    test('loadChapter 跳章（与现有 prev/next 不连续）→ 清空 prev/next', () {
      const settings = ReaderSettings();
      final controller = PageViewController(settings: settings);
      addTearDown(controller.dispose);
      controller.updatePageSize(_kPageSize);

      controller.loadChapter(5, '第六章', _longContent(40));
      controller.setNeighborChapter(
        prev: ChapterWindow(
          chapterIndex: 4,
          title: '第五章',
          content: _longContent(40),
        ),
        next: ChapterWindow(
          chapterIndex: 6,
          title: '第七章',
          content: _longContent(40),
        ),
      );
      expect(controller.debugPrevChapterIndex, 4);
      expect(controller.debugNextChapterIndex, 6);

      // 跳到第 10 章（不连续）。
      controller.loadChapter(10, '第十一章', _longContent(40));
      expect(controller.debugPrevChapterIndex, isNull,
          reason: 'prev.chapterIndex(4) != 10 - 1，应被清掉');
      expect(controller.debugNextChapterIndex, isNull,
          reason: 'next.chapterIndex(6) != 10 + 1，应被清掉');
    });

    test('loadChapter 相邻翻章（index+1）→ 现有 prev/next 不连续部分清空', () {
      const settings = ReaderSettings();
      final controller = PageViewController(settings: settings);
      addTearDown(controller.dispose);
      controller.updatePageSize(_kPageSize);

      controller.loadChapter(5, '第六章', _longContent(40));
      controller.setNeighborChapter(
        prev: ChapterWindow(
          chapterIndex: 4,
          title: '第五章',
          content: _longContent(40),
        ),
        next: ChapterWindow(
          chapterIndex: 6,
          title: '第七章',
          content: _longContent(40),
        ),
      );
      // 旧 cur=5；现在 loadChapter(6)：旧 prev=4 != 6-1=5 → 清空；
      // 旧 next=6 != 6+1=7 → 也清空。
      controller.loadChapter(6, '第七章', _longContent(40));
      expect(controller.debugPrevChapterIndex, isNull);
      expect(controller.debugNextChapterIndex, isNull);
    });
  });

  group('updateSettings / updatePageSize 清三章 pages', () {
    test('updateSettings 改 fontSize → 三章 pages 全部清空', () {
      const settings = ReaderSettings(fontSize: 18.0);
      final controller = PageViewController(settings: settings);
      addTearDown(controller.dispose);
      controller.updatePageSize(_kPageSize);

      controller.loadChapter(1, '第二章', _longContent(80));
      controller.setNeighborChapter(
        prev: ChapterWindow(
          chapterIndex: 0,
          title: '第一章',
          content: _longContent(40),
        ),
        next: ChapterWindow(
          chapterIndex: 2,
          title: '第三章',
          content: _longContent(40),
        ),
      );
      expect(controller.totalPagesInChapter, greaterThan(0));
      expect(controller.debugPrevChapterPageCount, greaterThan(0));
      expect(controller.debugNextChapterPageCount, greaterThan(0));

      controller.updateSettings(settings.copyWith(fontSize: 28.0));
      // updateSettings 重测 cur，但 prev/next 整个被清空（chapterIndex 都
      // 应消失，等外层 setNeighborChapter 重灌）。
      expect(controller.debugPrevChapterIndex, isNull,
          reason: 'updateSettings 排版变更后 prev 必须清空');
      expect(controller.debugNextChapterIndex, isNull,
          reason: 'updateSettings 排版变更后 next 必须清空');
      // cur pages 应被重测（因为 _measureCurrentChapterIfNeeded 被调）
      expect(controller.totalPagesInChapter, greaterThan(0));
    });

    test('updateSettings 仅改颜色 → 不重测', () {
      const settings = ReaderSettings(fontSize: 18.0);
      final controller = PageViewController(settings: settings);
      addTearDown(controller.dispose);
      controller.updatePageSize(_kPageSize);

      controller.loadChapter(1, '第二章', _longContent(80));
      controller.setNeighborChapter(
        next: ChapterWindow(
          chapterIndex: 2,
          title: '第三章',
          content: _longContent(40),
        ),
      );
      expect(controller.debugNextChapterIndex, 2);

      // 仅改 textColor（在 ReaderSettings 里属于颜色字段，不影响排版）。
      controller.updateSettings(
          settings.copyWith(textColor: 0xFF333333));
      expect(controller.debugNextChapterIndex, 2,
          reason: '颜色变更不应清邻章');
      expect(controller.debugNextChapterPageCount, greaterThan(0),
          reason: '颜色变更不应丢弃 next pages');
    });

    test('updatePageSize 改大小 → 三章 pages 全部清空', () {
      const settings = ReaderSettings();
      final controller = PageViewController(settings: settings);
      addTearDown(controller.dispose);
      controller.updatePageSize(_kPageSize);

      controller.loadChapter(1, '第二章', _longContent(80));
      controller.setNeighborChapter(
        next: ChapterWindow(
          chapterIndex: 2,
          title: '第三章',
          content: _longContent(40),
        ),
      );
      expect(controller.debugNextChapterIndex, 2);

      controller.updatePageSize(const Size(800, 1200));
      expect(controller.debugNextChapterIndex, isNull,
          reason: 'updatePageSize 应清空邻章（外层重新 setNeighborChapter）');
      expect(controller.totalPagesInChapter, greaterThan(0),
          reason: 'cur 应自动重测');
    });
  });

  group('ChapterWindow 公共构造器 + 内部 split', () {
    test('ChapterWindow 是不可变值对象', () {
      const w1 = ChapterWindow(
        chapterIndex: 1,
        title: '第二章',
        content: 'foo\n\nbar',
      );
      expect(w1.chapterIndex, 1);
      expect(w1.title, '第二章');
      expect(w1.content, 'foo\n\nbar');
    });

    test('setNeighborChapter 内部按 \\n+ 切段并过滤空行', () {
      const settings = ReaderSettings();
      final controller = PageViewController(settings: settings);
      addTearDown(controller.dispose);
      controller.updatePageSize(_kPageSize);

      controller.loadChapter(1, '第二章', _longContent(40));
      // content 里夹空行：split('\n+') 应跳过它们。
      const content = '段落 1\n\n\n段落 2\n   \n段落 3';
      controller.setNeighborChapter(
        next: ChapterWindow(
          chapterIndex: 2,
          title: '第三章',
          content: content,
        ),
      );
      // 至少应 measure 出 1 页（段落 = 3，pageMeasure 兜底返回 1 页）。
      expect(controller.debugNextChapterPageCount, greaterThan(0));
      expect(controller.debugNextChapterTitle, '第三章');
    });
  });

  group('clearChapter 清三章', () {
    test('clearChapter 后 cur / prev / next 全部释放', () {
      const settings = ReaderSettings();
      final controller = PageViewController(settings: settings);
      addTearDown(controller.dispose);
      controller.updatePageSize(_kPageSize);

      controller.loadChapter(1, '第二章', _longContent(40));
      controller.setNeighborChapter(
        prev: ChapterWindow(
          chapterIndex: 0,
          title: '第一章',
          content: _longContent(40),
        ),
        next: ChapterWindow(
          chapterIndex: 2,
          title: '第三章',
          content: _longContent(40),
        ),
      );
      expect(controller.debugCurrentChapterTitle, '第二章');
      expect(controller.debugPrevChapterIndex, 0);
      expect(controller.debugNextChapterIndex, 2);

      controller.clearChapter();
      expect(controller.debugCurrentChapterTitle, isNull);
      expect(controller.debugPrevChapterIndex, isNull);
      expect(controller.debugNextChapterIndex, isNull);
      expect(controller.totalPagesInChapter, 0);
    });
  });

  group('三章节 chapterIndex 同时存在时递增', () {
    test('prev < cur < next', () {
      const settings = ReaderSettings();
      final controller = PageViewController(settings: settings);
      addTearDown(controller.dispose);
      controller.updatePageSize(_kPageSize);

      controller.loadChapter(5, '第六章', _longContent(40));
      controller.setNeighborChapter(
        prev: ChapterWindow(
          chapterIndex: 4,
          title: '第五章',
          content: _longContent(40),
        ),
        next: ChapterWindow(
          chapterIndex: 6,
          title: '第七章',
          content: _longContent(40),
        ),
      );
      expect(controller.debugPrevChapterIndex! < controller.currentChapterIndex,
          isTrue);
      expect(controller.currentChapterIndex < controller.debugNextChapterIndex!,
          isTrue);
    });
  });

  /// T1 (05-18): getPageIndexByCharOffset 用 [TextPage.startCharOffset] /
  /// [TextPage.endCharOffset] 反算页索引，对齐 MD3
  /// `TextChapter.getPageIndexByCharIndex`。
  group('getPageIndexByCharOffset', () {
    test('未 loadChapter / pages 为空 → 返回 0', () {
      const settings = ReaderSettings();
      final controller = PageViewController(settings: settings);
      addTearDown(controller.dispose);
      controller.updatePageSize(_kPageSize);

      expect(controller.getPageIndexByCharOffset(0), 0);
      expect(controller.getPageIndexByCharOffset(100), 0);
      expect(controller.getPageIndexByCharOffset(-1), 0);
    });

    test('charOffset == 0 → 返回首页 0', () {
      const settings = ReaderSettings();
      final controller = PageViewController(settings: settings);
      addTearDown(controller.dispose);
      controller.updatePageSize(_kPageSize);
      controller.loadChapter(0, '第一章', _longContent(80));
      expect(controller.totalPagesInChapter, greaterThan(1));

      expect(controller.getPageIndexByCharOffset(0), 0);
    });

    test('charOffset 为负数 → 返回 0（防御）', () {
      const settings = ReaderSettings();
      final controller = PageViewController(settings: settings);
      addTearDown(controller.dispose);
      controller.updatePageSize(_kPageSize);
      controller.loadChapter(0, '第一章', _longContent(80));

      expect(controller.getPageIndexByCharOffset(-100), 0);
    });

    test('charOffset 落在中间页范围 → 返回该页 idx', () {
      const settings = ReaderSettings();
      final controller = PageViewController(settings: settings);
      addTearDown(controller.dispose);
      controller.updatePageSize(_kPageSize);
      controller.loadChapter(0, '第一章', _longContent(80));
      final total = controller.totalPagesInChapter;
      expect(total, greaterThanOrEqualTo(3));

      // 取第 2 页（idx=1）的 startCharOffset 当作恢复目标。
      controller.jumpToPage(1);
      final page1Start = controller.currentPage!.startCharOffset;
      // 跳回首页，再用 offset 反算。
      controller.jumpToPage(0);
      expect(controller.getPageIndexByCharOffset(page1Start), 1);

      // 同样验证最后一页。
      controller.jumpToPage(total - 1);
      final lastStart = controller.currentPage!.startCharOffset;
      controller.jumpToPage(0);
      expect(controller.getPageIndexByCharOffset(lastStart), total - 1);
    });

    test('charOffset 落在某页 [start, end] 范围内 → 该页 idx', () {
      const settings = ReaderSettings();
      final controller = PageViewController(settings: settings);
      addTearDown(controller.dispose);
      controller.updatePageSize(_kPageSize);
      controller.loadChapter(0, '第一章', _longContent(80));
      final total = controller.totalPagesInChapter;
      expect(total, greaterThanOrEqualTo(2));

      // 测每一页中点都能反算回该页。
      for (var i = 0; i < total; i++) {
        controller.jumpToPage(i);
        final page = controller.currentPage!;
        final mid =
            ((page.startCharOffset + page.endCharOffset) / 2).floor();
        expect(controller.getPageIndexByCharOffset(mid), i,
            reason: 'page $i 中点 offset $mid 应反算回 $i');
      }
    });

    test('charOffset 越过末页 endCharOffset → 返回末页 idx', () {
      const settings = ReaderSettings();
      final controller = PageViewController(settings: settings);
      addTearDown(controller.dispose);
      controller.updatePageSize(_kPageSize);
      controller.loadChapter(0, '第一章', _longContent(80));
      final total = controller.totalPagesInChapter;
      expect(total, greaterThan(0));

      controller.jumpToPage(total - 1);
      final lastEnd = controller.currentPage!.endCharOffset;
      controller.jumpToPage(0);
      // 越过末页的 offset：应返回最后一页 idx。
      expect(controller.getPageIndexByCharOffset(lastEnd + 1000), total - 1);
      expect(controller.getPageIndexByCharOffset(99999999), total - 1);
    });

    test('getPageIndexByCharOffset 不修改 currentPageIndex', () {
      const settings = ReaderSettings();
      final controller = PageViewController(settings: settings);
      addTearDown(controller.dispose);
      controller.updatePageSize(_kPageSize);
      controller.loadChapter(0, '第一章', _longContent(80));
      controller.jumpToPage(1);
      final before = controller.currentPageIndex;
      controller.getPageIndexByCharOffset(0);
      controller.getPageIndexByCharOffset(99999);
      expect(controller.currentPageIndex, before,
          reason: 'getPageIndexByCharOffset 是只读查询，不应改变 currentPageIndex');
    });
  });

  /// T1 (05-18): TextPage.startCharOffset / endCharOffset 单调性测试 —
  /// 验证 PageMeasure 的累加逻辑正确，否则 getPageIndexByCharOffset 会落错页。
  group('TextPage startCharOffset 单调性', () {
    test('页与页之间 startCharOffset 单调递增', () {
      const settings = ReaderSettings();
      final controller = PageViewController(settings: settings);
      addTearDown(controller.dispose);
      controller.updatePageSize(_kPageSize);
      controller.loadChapter(0, '第一章', _longContent(80));
      final total = controller.totalPagesInChapter;
      expect(total, greaterThan(1));

      int? prev;
      for (var i = 0; i < total; i++) {
        controller.jumpToPage(i);
        final page = controller.currentPage!;
        if (prev != null) {
          expect(page.startCharOffset, greaterThanOrEqualTo(prev),
              reason: 'page $i.startCharOffset 应 >= 上一页 startCharOffset');
        }
        prev = page.startCharOffset;
      }
    });

    test('每页 endCharOffset >= startCharOffset', () {
      const settings = ReaderSettings();
      final controller = PageViewController(settings: settings);
      addTearDown(controller.dispose);
      controller.updatePageSize(_kPageSize);
      controller.loadChapter(0, '第一章', _longContent(40));
      final total = controller.totalPagesInChapter;

      for (var i = 0; i < total; i++) {
        controller.jumpToPage(i);
        final page = controller.currentPage!;
        expect(page.endCharOffset, greaterThanOrEqualTo(page.startCharOffset),
            reason: 'page $i: end >= start');
      }
    });

    test('首页 startCharOffset == 0', () {
      const settings = ReaderSettings();
      final controller = PageViewController(settings: settings);
      addTearDown(controller.dispose);
      controller.updatePageSize(_kPageSize);
      controller.loadChapter(0, '第一章', _longContent(40));
      controller.jumpToPage(0);
      expect(controller.currentPage!.startCharOffset, 0);
    });
  });
}
