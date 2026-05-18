/// Task 1 — 搜索精确模式
///
/// 校验三件事：
///   1. SharedPreferences/settings.json 默认值为 false
///   2. load/save round-trip 一致
///   3. [SearchPage.applyPrecisionFilter] 三档排序 + 不匹配丢弃
///
/// 持久化测试通过把 path_provider 的 PlatformInterface 替换成 tmp dir 实现
/// （unit test 没有真实平台 channel），settings.json 写到 tmp，每个测试用
/// 唯一目录隔离。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/providers.dart';
import 'package:legado_flutter/features/search/search_page.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _TmpPathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _TmpPathProvider(this.tmpDir);
  final String tmpDir;

  @override
  Future<String?> getApplicationDocumentsPath() async => tmpDir;

  @override
  Future<String?> getApplicationSupportPath() async => tmpDir;

  @override
  Future<String?> getTemporaryPath() async => tmpDir;

  @override
  Future<String?> getApplicationCachePath() async => tmpDir;

  @override
  Future<String?> getDownloadsPath() async => tmpDir;

  @override
  Future<String?> getLibraryPath() async => tmpDir;

  @override
  Future<String?> getExternalStoragePath() async => tmpDir;
}

Future<Directory> _setupTmp() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final dir = await Directory.systemTemp.createTemp('search_precision_test_');
  PathProviderPlatform.instance = _TmpPathProvider(dir.path);
  return dir;
}

void main() {
  group('search precision persistence', () {
    test('load defaults to false when settings.json absent', () async {
      final dir = await _setupTmp();
      try {
        // 没写过任何东西，应当返回默认 false
        final v = await loadSearchPrecisionFromDisk();
        expect(v, isFalse);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('save then load round-trip preserves value (true)', () async {
      final dir = await _setupTmp();
      try {
        await saveSearchPrecisionToDisk(true);
        expect(await loadSearchPrecisionFromDisk(), isTrue);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('save then load round-trip preserves value (false)', () async {
      final dir = await _setupTmp();
      try {
        await saveSearchPrecisionToDisk(true);
        await saveSearchPrecisionToDisk(false);
        expect(await loadSearchPrecisionFromDisk(), isFalse);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('precision flag does not clobber search history', () async {
      final dir = await _setupTmp();
      try {
        await saveSearchHistoryToDisk(['玄幻', '都市']);
        await saveSearchPrecisionToDisk(true);
        // 两个 key 共享同一份 settings.json，互不污染
        expect(await loadSearchHistoryFromDisk(), ['玄幻', '都市']);
        expect(await loadSearchPrecisionFromDisk(), isTrue);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('SearchPage.applyPrecisionFilter', () {
    test('name == keyword排在最前', () {
      final results = <Map<String, dynamic>>[
        {'name': '斗破苍穹外传', 'author': 'X'},
        {'name': '斗破苍穹', 'author': 'Y'}, // equalName
        {'name': '别的', 'author': 'Z'}, // 不匹配
      ];
      final out = SearchPage.applyPrecisionFilter(results, '斗破苍穹');
      expect(out.length, 2);
      expect(out[0]['name'], '斗破苍穹');
      expect(out[1]['name'], '斗破苍穹外传');
    });

    test('author == keyword 排在 contains 之前但在 equalName 之后', () {
      final results = <Map<String, dynamic>>[
        {'name': '某书包含天蚕土豆', 'author': '别人'}, // contains by name
        {'name': '随便', 'author': '天蚕土豆'}, // equalAuthor
        {'name': '天蚕土豆', 'author': 'AA'}, // equalName
      ];
      final out = SearchPage.applyPrecisionFilter(results, '天蚕土豆');
      expect(out.length, 3);
      expect(out[0]['name'], '天蚕土豆'); // equalName 第一
      expect(out[1]['author'], '天蚕土豆'); // equalAuthor 第二
      expect(out[2]['name'], '某书包含天蚕土豆'); // contains 第三
    });

    test('contains 第三档保留', () {
      final results = <Map<String, dynamic>>[
        {'name': '完全不匹配的书', 'author': '不匹配作者'}, // 应该丢
        {'name': '玄幻小说大集合', 'author': '某人'}, // contains by name
        {'name': '某人写的书', 'author': '玄幻达人'}, // contains by author
      ];
      final out = SearchPage.applyPrecisionFilter(results, '玄幻');
      expect(out.length, 2);
      // 只要保留这两个 contains 即可，顺序按输入序
      expect(out.map((r) => r['name']),
          containsAll(<String>['玄幻小说大集合', '某人写的书']));
      expect(out.map((r) => r['name']), isNot(contains('完全不匹配的书')));
    });

    test('全不匹配丢弃', () {
      final results = <Map<String, dynamic>>[
        {'name': 'A', 'author': 'B'},
        {'name': 'C', 'author': 'D'},
      ];
      final out = SearchPage.applyPrecisionFilter(results, '玄幻');
      expect(out, isEmpty);
    });

    test('null 字段安全 + 空 keyword 原样返回', () {
      final results = <Map<String, dynamic>>[
        {'name': null, 'author': null}, // 全 null
        {'name': '玄幻', 'author': null},
      ];
      // 空 keyword：返回原 list
      expect(SearchPage.applyPrecisionFilter(results, '').length, 2);
      // 非空 keyword：null 字段不应崩溃；'玄幻' 命中
      final out = SearchPage.applyPrecisionFilter(results, '玄幻');
      expect(out.length, 1);
      expect(out[0]['name'], '玄幻');
    });
  });
}
