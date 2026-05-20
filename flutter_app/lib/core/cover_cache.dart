/// 封面缓存
///
/// 把 `_downloadAndCacheCover` 从 search_page 抽到独立 service：
/// - 让 search_page 不再直接 import dio（之前为它单独保留 dio 依赖会让人误以为
///   搜索路径还在用 Dart HTTP，详见已删除的 search_parse_html 注释）
/// - 集中实现命名/扩展名/哈希策略，方便后续切到 cached_network_image 的统一磁
///   盘缓存或换 http client
///
/// 目前实现仍走 `Dio().download()`：cached_network_image 的磁盘缓存对查询是
/// 黑盒，我们需要可枚举的本地路径（用于书本的 custom_cover_path 字段）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'persistence/json_store.dart';

class CoverCache {
  CoverCache._();

  /// Download `coverUrl` into the app documents `covers/` folder and return
  /// the absolute path. Skips network when the file already exists.
  /// Returns null on any failure.
  static Future<String?> downloadAndCache(String coverUrl) async {
    if (coverUrl.isEmpty) return null;
    try {
      // BATCH-18e (F-W2B-022)：走统一的 resolvePersistenceDir。Android
      // 拿 Documents、其它平台拿 Support，与 db 路径对齐。
      final dir = await resolvePersistenceDir();
      final coversDir = Directory('$dir/covers');
      if (!coversDir.existsSync()) {
        coversDir.createSync(recursive: true);
      }
      final hashBytes = md5.convert(utf8.encode(coverUrl)).bytes;
      final hash =
          hashBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final ext = coverUrl.split('.').last.split('?').first;
      final safeExt = ext.length <= 5 ? ext : 'jpg';
      final filePath = '${coversDir.path}/$hash.$safeExt';
      if (File(filePath).existsSync()) {
        return filePath;
      }
      await Dio().download(coverUrl, filePath);
      return filePath;
    } catch (e) {
      debugPrint('[CoverCache] download failed: $e');
      return null;
    }
  }
}
