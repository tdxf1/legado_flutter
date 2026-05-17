/// CoverCache：测试错误兜底。
///
/// `getApplicationDocumentsDirectory` 在 unit test 环境下没有 path_provider
/// platform handler，会抛 MissingPluginException。我们的 try/catch 应当吞
/// 掉异常并返回 null，不让上层崩溃。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/cover_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CoverCache.downloadAndCache', () {
    test('returns null on empty url', () async {
      final r = await CoverCache.downloadAndCache('');
      expect(r, isNull);
    });

    test('returns null when path_provider is unavailable', () async {
      // No mock handler installed → MissingPluginException, swallowed.
      final r =
          await CoverCache.downloadAndCache('https://example.com/cover.jpg');
      expect(r, isNull);
    });
  });
}
