/// BATCH-27c-4: 远程书排序持久化测试（disk round-trip + 损坏 JSON 兜底）。
///
/// settings.json 走 [readJsonKey] / [writeJsonKey]，与 BATCH-26d
/// `default_home_page_test` 同款临时目录策略：每个 test 独立 temp dir +
/// addTearDown 兜底清理，避免 module-level `_writeLock` 跨 test 串扰。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/core/providers.dart';

void main() {
  group('BATCH-27c-4: remote book sort key persistence', () {
    test('saveRemoteBookSortKeyToDisk + load round-trip — name', () async {
      final dir =
          Directory.systemTemp.createTempSync('remote_sort_key_rt_name_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      await saveRemoteBookSortKeyToDisk('name', directory: dir.path);
      final loaded = await loadRemoteBookSortKeyFromDisk(directory: dir.path);
      expect(loaded, 'name');
    });

    test('saveRemoteBookSortKeyToDisk + load round-trip — time', () async {
      final dir =
          Directory.systemTemp.createTempSync('remote_sort_key_rt_time_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      await saveRemoteBookSortKeyToDisk('time', directory: dir.path);
      final loaded = await loadRemoteBookSortKeyFromDisk(directory: dir.path);
      expect(loaded, 'time');
    });

    test('load 不存在 → default time', () async {
      final dir =
          Directory.systemTemp.createTempSync('remote_sort_key_empty_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final loaded = await loadRemoteBookSortKeyFromDisk(directory: dir.path);
      expect(loaded, 'time', reason: '默认应为 time（对齐原 legado RemoteBookSort.Default）');
    });

    test('load 损坏 JSON（非法字符串值）→ 兜回 time', () async {
      final dir = Directory.systemTemp
          .createTempSync('remote_sort_key_corrupt_string_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      // 直接写非法 String 到 settings.json
      final file = File('${dir.path}/settings.json');
      await file.writeAsString(jsonEncode({'remoteBookSortKey': 'garbage'}));
      final loaded = await loadRemoteBookSortKeyFromDisk(directory: dir.path);
      expect(loaded, 'time');
    });

    test('load 损坏类型（int 而非 String）→ 兜回 time', () async {
      final dir = Directory.systemTemp
          .createTempSync('remote_sort_key_corrupt_type_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final file = File('${dir.path}/settings.json');
      await file.writeAsString(jsonEncode({'remoteBookSortKey': 42}));
      final loaded = await loadRemoteBookSortKeyFromDisk(directory: dir.path);
      expect(loaded, 'time');
    });

    test('save 非法 key → 实际持久化 fallback time', () async {
      // 防御层：即使 caller 传错值（理论上不应发生），落库也必须是合法 key
      // 让下次 load 不依赖 helper 的兜底链路。
      final dir = Directory.systemTemp
          .createTempSync('remote_sort_key_save_invalid_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      await saveRemoteBookSortKeyToDisk('invalid', directory: dir.path);
      final loaded = await loadRemoteBookSortKeyFromDisk(directory: dir.path);
      expect(loaded, 'time');
    });
  });

  group('BATCH-27c-4: remote book sort asc persistence', () {
    test('round-trip true', () async {
      final dir =
          Directory.systemTemp.createTempSync('remote_sort_asc_rt_true_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      await saveRemoteBookSortAscToDisk(true, directory: dir.path);
      final loaded = await loadRemoteBookSortAscFromDisk(directory: dir.path);
      expect(loaded, true);
    });

    test('round-trip false', () async {
      final dir =
          Directory.systemTemp.createTempSync('remote_sort_asc_rt_false_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      await saveRemoteBookSortAscToDisk(false, directory: dir.path);
      final loaded = await loadRemoteBookSortAscFromDisk(directory: dir.path);
      expect(loaded, false);
    });

    test('load 不存在 → default true', () async {
      final dir = Directory.systemTemp
          .createTempSync('remote_sort_asc_empty_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final loaded = await loadRemoteBookSortAscFromDisk(directory: dir.path);
      expect(loaded, true, reason: '默认应为 true（升序）');
    });

    test('load 损坏类型（String 而非 bool）→ 兜回 true', () async {
      final dir = Directory.systemTemp
          .createTempSync('remote_sort_asc_corrupt_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final file = File('${dir.path}/settings.json');
      await file.writeAsString(jsonEncode({'remoteBookSortAsc': 'yes'}));
      final loaded = await loadRemoteBookSortAscFromDisk(directory: dir.path);
      expect(loaded, true);
    });
  });
}
