/// Reader services 不依赖 RustLib 初始化的 fallback 行为单测。
///
/// 这些 service 都通过 try/catch 兜住 FRB 调用，errors 应静默吞掉并返回安全
/// 的空值（或保持 progress / bookmark list 不变）。在 unit test 环境里
/// `RustLib` 没 init 过，rust_api.* 必然抛 — 正好用来验证 fallback。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/features/reader/services/reader_bookmark_service.dart';
import 'package:legado_flutter/features/reader/services/reader_progress_service.dart';

void main() {
  group('ReaderProgressService.load fallback', () {
    test('returns null when FRB is not initialised', () async {
      final svc = ReaderProgressService();
      final p = await svc.load(dbPath: '/tmp/nonexistent.db', bookId: 'x');
      expect(p, isNull);
    });

    test('save() does not throw when FRB is not initialised', () async {
      final svc = ReaderProgressService();
      // Should swallow the exception; if it propagates, the test fails.
      await svc.save(
        dbPath: '/tmp/nonexistent.db',
        bookId: 'x',
        chapterIndex: 0,
        offset: 0,
      );
    });
  });

  group('ReaderBookmarkService.list fallback', () {
    test('returns empty list when FRB is not initialised', () async {
      final svc = ReaderBookmarkService();
      final list =
          await svc.list(dbPath: '/tmp/nonexistent.db', bookId: 'x');
      expect(list, isEmpty);
    });

    test('add() returns null when FRB is not initialised', () async {
      final svc = ReaderBookmarkService();
      final r = await svc.add(
        dbPath: '/tmp/nonexistent.db',
        bookId: 'x',
        chapterIndex: 0,
        content: 'mark',
      );
      expect(r, isNull);
    });
  });
}
