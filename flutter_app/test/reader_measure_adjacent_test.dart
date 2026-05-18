import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/core/providers.dart';
import 'package:legado_flutter/features/reader/page/page_view_controller.dart';
import 'package:legado_flutter/features/reader/reader_page.dart';

/// 第二十六批 Subtask B — ReaderPage 邻章预加载灌入 controller。
///
/// 覆盖目标（PRD 7 个测试用例 + 1 个集成 setup）：
///   1. currentIndex=0 → prev=null, next 有效
///   2. currentIndex=last → prev 有效, next=null
///   3. currentIndex 中间 → prev/next 都有效
///   4. 邻章 content=null → 对应方向 ChapterWindow=null
///   5. 邻章 content='' → 对应方向 ChapterWindow=null
///   6. chapters=null → (null, null)
///   7. ChapterWindow 字段值（chapterIndex / title / content）正确
///   8. computeAdjacentWindows + setNeighborChapter 集成：controller
///      在末页能拿到 boundaryNextPage（验证灌入路径完整工作）
///   9. invalid currentIndex（越界）→ (null, null)
///
/// 测试调 [ReaderPage.computeAdjacentWindows] 静态方法（不需要构造 widget），
/// 这样既覆盖纯计算逻辑，又不污染 production runtime API。

const _kPageSize = Size(400, 600);

/// 构造一个生成多页的中文长内容。
String _longContent(int paragraphs) {
  return List<String>.generate(
    paragraphs,
    (i) =>
        '这是用于翻页测试的中文段落第 $i 段，需要足够长才能让 PageMeasure 切成多页。',
  ).join('\n');
}

Map<String, dynamic> _chapter({
  required String title,
  String? content,
}) =>
    <String, dynamic>{
      'title': title,
      if (content != null) 'content': content,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReaderPage.computeAdjacentWindows — 边界 / 内容缺失', () {
    test('chapters=null → (null, null)', () {
      final (prev, next) = ReaderPage.computeAdjacentWindows(0, null);
      expect(prev, isNull);
      expect(next, isNull);
    });

    test('chapters 空列表 → (null, null)', () {
      final (prev, next) =
          ReaderPage.computeAdjacentWindows(0, <Map<String, dynamic>>[]);
      expect(prev, isNull);
      expect(next, isNull);
    });

    test('currentIndex 越界（负数）→ (null, null)', () {
      final chapters = <Map<String, dynamic>>[
        _chapter(title: '第一章', content: 'a'),
        _chapter(title: '第二章', content: 'b'),
      ];
      final (prev, next) =
          ReaderPage.computeAdjacentWindows(-1, chapters);
      expect(prev, isNull);
      expect(next, isNull);
    });

    test('currentIndex 越界（>= length）→ (null, null)', () {
      final chapters = <Map<String, dynamic>>[
        _chapter(title: '第一章', content: 'a'),
        _chapter(title: '第二章', content: 'b'),
      ];
      final (prev, next) =
          ReaderPage.computeAdjacentWindows(2, chapters);
      expect(prev, isNull);
      expect(next, isNull);
    });

    test('currentIndex=0 → prev=null, next 有效', () {
      final chapters = <Map<String, dynamic>>[
        _chapter(title: '第一章', content: '第一章正文'),
        _chapter(title: '第二章', content: '第二章正文'),
        _chapter(title: '第三章', content: '第三章正文'),
      ];
      final (prev, next) = ReaderPage.computeAdjacentWindows(0, chapters);
      expect(prev, isNull, reason: '首章无 prev');
      expect(next, isNotNull);
      expect(next!.chapterIndex, 1);
      expect(next.title, '第二章');
      expect(next.content, '第二章正文');
    });

    test('currentIndex=last → prev 有效, next=null', () {
      final chapters = <Map<String, dynamic>>[
        _chapter(title: '第一章', content: '第一章正文'),
        _chapter(title: '第二章', content: '第二章正文'),
        _chapter(title: '第三章', content: '第三章正文'),
      ];
      final (prev, next) = ReaderPage.computeAdjacentWindows(2, chapters);
      expect(prev, isNotNull);
      expect(prev!.chapterIndex, 1);
      expect(prev.title, '第二章');
      expect(prev.content, '第二章正文');
      expect(next, isNull, reason: '末章无 next');
    });

    test('currentIndex 中间 → prev/next 都有效，字段值正确', () {
      final chapters = <Map<String, dynamic>>[
        _chapter(title: '第一章', content: 'A 章正文'),
        _chapter(title: '第二章', content: 'B 章正文'),
        _chapter(title: '第三章', content: 'C 章正文'),
      ];
      final (prev, next) = ReaderPage.computeAdjacentWindows(1, chapters);
      expect(prev, isNotNull);
      expect(prev!.chapterIndex, 0);
      expect(prev.title, '第一章');
      expect(prev.content, 'A 章正文');
      expect(next, isNotNull);
      expect(next!.chapterIndex, 2);
      expect(next.title, '第三章');
      expect(next.content, 'C 章正文');
    });

    test('邻章 content=null → 对应方向 ChapterWindow=null', () {
      final chapters = <Map<String, dynamic>>[
        // prev 章 content 缺失
        _chapter(title: '第一章'),
        _chapter(title: '第二章', content: '第二章正文'),
        // next 章 content 缺失
        _chapter(title: '第三章'),
      ];
      final (prev, next) = ReaderPage.computeAdjacentWindows(1, chapters);
      expect(prev, isNull, reason: 'prev content=null 时不应灌');
      expect(next, isNull, reason: 'next content=null 时不应灌');
    });

    test('邻章 content="" 空字符串 → 对应方向 ChapterWindow=null', () {
      final chapters = <Map<String, dynamic>>[
        _chapter(title: '第一章', content: ''),
        _chapter(title: '第二章', content: '第二章正文'),
        _chapter(title: '第三章', content: ''),
      ];
      final (prev, next) = ReaderPage.computeAdjacentWindows(1, chapters);
      expect(prev, isNull, reason: 'prev content 空字符串不应灌');
      expect(next, isNull, reason: 'next content 空字符串不应灌');
    });

    test('单一邻章 content 就绪 → 只灌已就绪那个方向', () {
      final chapters = <Map<String, dynamic>>[
        _chapter(title: '第一章', content: 'A 章已就绪'),
        _chapter(title: '第二章', content: 'B 章正文'),
        _chapter(title: '第三章'), // next 还没 fetch
      ];
      final (prev, next) = ReaderPage.computeAdjacentWindows(1, chapters);
      expect(prev, isNotNull);
      expect(prev!.content, 'A 章已就绪');
      expect(next, isNull, reason: 'next content 还没 fetch 不应灌');
    });

    test('title 缺失 → ChapterWindow.title 为空字符串（不抛异常）', () {
      final chapters = <Map<String, dynamic>>[
        // 故意只放 content，没 title
        <String, dynamic>{'content': '第一章正文'},
        _chapter(title: '第二章', content: '第二章正文'),
      ];
      final (prev, next) = ReaderPage.computeAdjacentWindows(1, chapters);
      expect(prev, isNotNull);
      expect(prev!.title, '');
      expect(prev.content, '第一章正文');
      expect(next, isNull);
    });
  });

  group('ReaderPage.computeAdjacentWindows + PageViewController 集成', () {
    test('灌入 controller → 末页可拿到 boundaryNextPage', () {
      const settings = ReaderSettings();
      final controller = PageViewController(settings: settings);
      addTearDown(controller.dispose);
      controller.updatePageSize(_kPageSize);

      // 当前章节就位
      controller.loadChapter(0, '第一章', _longContent(80));
      expect(controller.totalPagesInChapter, greaterThan(1));

      // 模拟 reader 灌入邻章
      final chapters = <Map<String, dynamic>>[
        _chapter(title: '第一章', content: _longContent(80)),
        _chapter(title: '第二章', content: _longContent(40)),
      ];
      final (prev, next) = ReaderPage.computeAdjacentWindows(0, chapters);
      controller.setNeighborChapter(prev: prev, next: next);

      // 跳到末页 → boundaryNextPage 应来自 next 章首页
      controller.jumpToPage(controller.totalPagesInChapter - 1);
      final boundary = controller.boundaryNextPage;
      expect(boundary, isNotNull);
      expect(boundary!.chapterIndex, 1);
      expect(boundary.pageIndex, 0);
    });

    test('邻章 content 缺失时灌 null → boundary 也为 null', () {
      const settings = ReaderSettings();
      final controller = PageViewController(settings: settings);
      addTearDown(controller.dispose);
      controller.updatePageSize(_kPageSize);

      controller.loadChapter(0, '第一章', _longContent(80));
      // 模拟邻章字符串还没 fetch（prefetch 异步未到）
      final chapters = <Map<String, dynamic>>[
        _chapter(title: '第一章', content: _longContent(80)),
        _chapter(title: '第二章'), // content=null
      ];
      final (prev, next) = ReaderPage.computeAdjacentWindows(0, chapters);
      expect(next, isNull);
      controller.setNeighborChapter(prev: prev, next: next);

      controller.jumpToPage(controller.totalPagesInChapter - 1);
      expect(controller.boundaryNextPage, isNull,
          reason: 'next 章 content 缺失 → boundary fallback 路径生效');
    });

    test('从中间章灌入 → controller 同时拿到 prev/next 章节窗口', () {
      const settings = ReaderSettings();
      final controller = PageViewController(settings: settings);
      addTearDown(controller.dispose);
      controller.updatePageSize(_kPageSize);

      controller.loadChapter(1, '第二章', _longContent(80));
      final chapters = <Map<String, dynamic>>[
        _chapter(title: '第一章', content: _longContent(40)),
        _chapter(title: '第二章', content: _longContent(80)),
        _chapter(title: '第三章', content: _longContent(40)),
      ];
      final (prev, next) = ReaderPage.computeAdjacentWindows(1, chapters);
      controller.setNeighborChapter(prev: prev, next: next);

      expect(controller.debugPrevChapterIndex, 0);
      expect(controller.debugNextChapterIndex, 2);
      expect(controller.debugPrevChapterPageCount, greaterThan(0));
      expect(controller.debugNextChapterPageCount, greaterThan(0));
    });
  });
}
