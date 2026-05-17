/// 书签服务
///
/// 把对 `rust_api.getBookmarks / addBookmark / deleteBookmark` 的调用从
/// ReaderPage State 中剥离出来，并集中处理 JSON 序列化 + 错误吞没。
///
/// 服务本身保持无状态，调用方负责持有 bookmark list（这样 widget 可以根据
/// 业务情况控制刷新粒度）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../src/rust/api.dart' as rust_api;

class ReaderBookmarkService {
  ReaderBookmarkService();

  /// 获取指定书的全部书签（无记录返回空数组）。
  Future<List<Map<String, dynamic>>> list({
    required String dbPath,
    required String bookId,
  }) async {
    try {
      final json = await rust_api.getBookmarks(dbPath: dbPath, bookId: bookId);
      if (json.isEmpty || json == 'null') return const [];
      final decoded = jsonDecode(json);
      if (decoded is List) {
        return decoded.cast<Map<String, dynamic>>();
      }
      return const [];
    } catch (e) {
      debugPrint('[ReaderBookmark] list failed: $e');
      return const [];
    }
  }

  /// 新增书签，返回新书签的 Map（失败返回 null）。
  Future<Map<String, dynamic>?> add({
    required String dbPath,
    required String bookId,
    required int chapterIndex,
    required String content,
    int paragraphIndex = 0,
  }) async {
    try {
      final json = await rust_api.addBookmark(
        dbPath: dbPath,
        bookId: bookId,
        chapterIndex: chapterIndex,
        paragraphIndex: paragraphIndex,
        content: content,
      );
      if (json.isEmpty) return null;
      final decoded = jsonDecode(json);
      if (decoded is Map<String, dynamic>) return decoded;
      return null;
    } catch (e) {
      debugPrint('[ReaderBookmark] add failed: $e');
      return null;
    }
  }

  /// 删除指定书签。失败抛异常，让调用方决定如何提示用户。
  Future<void> remove({
    required String dbPath,
    required String bookmarkId,
  }) async {
    await rust_api.deleteBookmark(dbPath: dbPath, bookmarkId: bookmarkId);
  }
}
