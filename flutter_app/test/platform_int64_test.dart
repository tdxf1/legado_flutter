/// `platformInt64ToInt` helper 边界测试（BATCH-24, F-W2B-007）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/util/platform_int64.dart';

void main() {
  group('platformInt64ToInt', () {
    test('int 直接返回原值', () {
      expect(platformInt64ToInt(42), 42);
      expect(platformInt64ToInt(0), 0);
      expect(platformInt64ToInt(-7), -7);
    });

    test('BigInt-like 对象走 toInt() 路径', () {
      // 模拟 web 平台 PlatformInt64 = BigInt，BigInt.toInt() 返回 int。
      final big = BigInt.from(123456789);
      expect(platformInt64ToInt(big), 123456789);
    });

    test('null 抛异常（行为一致 — caller 不会传 null）', () {
      expect(() => platformInt64ToInt(null), throwsNoSuchMethodError);
    });
  });
}
