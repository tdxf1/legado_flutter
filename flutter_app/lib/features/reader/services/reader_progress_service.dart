/// 阅读进度服务
///
/// 无状态 helper，把对 `rust_api.saveReadingProgress / getReadingProgress`
/// 的调用从 ReaderPage State 中剥离出来。
///
/// 调用方提供 dbPath / bookId / 当前章节索引 / scrollOffset，
/// 由 service 处理 JSON 解析、错误吞没等模板代码。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../src/rust/api.dart' as rust_api;

class SavedReadingProgress {
  final int chapterIndex;
  final int paragraphIndex;
  final int offset;

  const SavedReadingProgress({
    required this.chapterIndex,
    required this.paragraphIndex,
    required this.offset,
  });
}

class ReaderProgressService {
  ReaderProgressService();

  /// 保存当前阅读进度。失败时记录到 logcat 但不抛出（避免阻塞 UI 线程）。
  Future<void> save({
    required String dbPath,
    required String bookId,
    required int chapterIndex,
    required int offset,
    int paragraphIndex = 0,
  }) async {
    try {
      await rust_api.saveReadingProgress(
        dbPath: dbPath,
        bookId: bookId,
        chapterIndex: chapterIndex,
        paragraphIndex: paragraphIndex,
        offset: offset,
      );
      debugPrint(
          '[ReaderProgress] save OK: bookId=$bookId chapter=$chapterIndex offset=$offset');
    } catch (e) {
      debugPrint('[ReaderProgress] save failed: $e');
    }
  }

  /// 加载阅读进度。无记录返回 null，错误也返回 null。
  Future<SavedReadingProgress?> load({
    required String dbPath,
    required String bookId,
  }) async {
    try {
      final json =
          await rust_api.getReadingProgress(dbPath: dbPath, bookId: bookId);
      debugPrint(
          '[ReaderProgress] load: bookId=$bookId rawJson=${json.isEmpty ? "<EMPTY>" : (json.length > 200 ? "${json.substring(0, 200)}..." : json)}');
      if (json.isEmpty || json == 'null') return null;
      final decoded = jsonDecode(json);
      if (decoded is! Map<String, dynamic>) return null;
      final result = SavedReadingProgress(
        chapterIndex: decoded['chapter_index'] as int? ?? 0,
        paragraphIndex: decoded['paragraph_index'] as int? ?? 0,
        offset: decoded['offset'] as int? ?? 0,
      );
      debugPrint(
          '[ReaderProgress] load OK: chapter=${result.chapterIndex} offset=${result.offset} paragraph=${result.paragraphIndex}');
      return result;
    } catch (e) {
      debugPrint('[ReaderProgress] load failed: $e');
      return null;
    }
  }
}
