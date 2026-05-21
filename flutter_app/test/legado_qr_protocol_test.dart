import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/features/qr/legado_qr_protocol.dart';

/// 批次 20 (05-19): QR 协议解析单测。
///
/// 不需要 widget framework，纯 dart 函数。覆盖：
/// 1. 4 种 legado:// 协议
/// 2. URL-encoded src 解码
/// 3. 兜底直 https URL 结尾 .json → bookSource
/// 4. 不识别返回 null
/// 5. 空白 / 非法返回 null
/// 6. 编辑过的 src 末尾带 query/fragment 不破坏正则
void main() {
  group('parseLegadoQrPayload', () {
    test('legado://import/bookSource?src=https://example.com/x.json', () {
      final r =
          parseLegadoQrPayload('legado://import/bookSource?src=https://example.com/x.json');
      expect(r, isNotNull);
      expect(r!.type, LegadoQrType.bookSource);
      expect(r.fetchUrl, 'https://example.com/x.json');
    });

    test('legado://import/rssSource?src=https://example.com/r.json', () {
      final r =
          parseLegadoQrPayload('legado://import/rssSource?src=https://example.com/r.json');
      expect(r, isNotNull);
      expect(r!.type, LegadoQrType.rssSource);
      expect(r.fetchUrl, 'https://example.com/r.json');
    });

    test('legado://import/sourceSub?src=https://example.com/sub.json', () {
      final r = parseLegadoQrPayload(
          'legado://import/sourceSub?src=https://example.com/sub.json');
      expect(r, isNotNull);
      expect(r!.type, LegadoQrType.sourceSub);
      expect(r.fetchUrl, 'https://example.com/sub.json');
    });

    test('legado://import/replaceRule?src=https://example.com/p.json', () {
      final r = parseLegadoQrPayload(
          'legado://import/replaceRule?src=https://example.com/p.json');
      expect(r, isNotNull);
      expect(r!.type, LegadoQrType.replaceRule);
      expect(r.fetchUrl, 'https://example.com/p.json');
    });

    test('URL-encoded src is decoded', () {
      // src=https%3A%2F%2Fexample.com%2Fa.json
      final r = parseLegadoQrPayload(
          'legado://import/bookSource?src=https%3A%2F%2Fexample.com%2Fa.json');
      expect(r, isNotNull);
      expect(r!.fetchUrl, 'https://example.com/a.json');
    });

    test('bare https URL ending in .json → bookSource', () {
      final r = parseLegadoQrPayload('https://example.com/sources.json');
      expect(r, isNotNull);
      expect(r!.type, LegadoQrType.bookSource);
      expect(r.fetchUrl, 'https://example.com/sources.json');
    });

    test('bare http URL ending in .json → bookSource', () {
      final r = parseLegadoQrPayload('http://raw.example.com/x.json');
      expect(r, isNotNull);
      expect(r!.type, LegadoQrType.bookSource);
    });

    test('https URL with query string ending .json + ?ref=xxx → bookSource', () {
      final r = parseLegadoQrPayload('https://example.com/x.json?ref=main');
      expect(r, isNotNull);
      expect(r!.type, LegadoQrType.bookSource);
      expect(r.fetchUrl, 'https://example.com/x.json?ref=main');
    });

    test('unrecognized scheme returns null', () {
      expect(parseLegadoQrPayload('foobar://import/bookSource?src=x'), isNull);
      expect(parseLegadoQrPayload('legado://other/something'), isNull);
      expect(parseLegadoQrPayload('legado://import/unknownType?src=x'), isNull);
    });

    test('plain text returns null', () {
      expect(parseLegadoQrPayload('hello world'), isNull);
      expect(parseLegadoQrPayload(''), isNull);
      expect(parseLegadoQrPayload('   '), isNull);
    });

    test('https URL not ending in .json returns null (not auto-bookSource)', () {
      expect(parseLegadoQrPayload('https://example.com/page'), isNull);
      expect(parseLegadoQrPayload('https://example.com/'), isNull);
    });

    test('legado:// with file:// src rejected (BATCH-05)', () {
      // BATCH-05 (F-W2B-002): scheme 白名单 —— file:// 越界不识别
      expect(
        parseLegadoQrPayload(
            'legado://import/bookSource?src=file:///etc/passwd'),
        isNull,
      );
    });

    test('legado:// with javascript: src rejected (BATCH-05)', () {
      expect(
        parseLegadoQrPayload(
            'legado://import/bookSource?src=javascript:alert(1)'),
        isNull,
      );
    });

    test('legado:// with data: src rejected (BATCH-05)', () {
      expect(
        parseLegadoQrPayload(
            'legado://import/bookSource?src=data:text/html,foo'),
        isNull,
      );
    });
  });

  group('legadoQrTypeLabel', () {
    test('returns Chinese labels for all 4 types', () {
      expect(legadoQrTypeLabel(LegadoQrType.bookSource), '书源');
      expect(legadoQrTypeLabel(LegadoQrType.rssSource), 'RSS 源');
      expect(legadoQrTypeLabel(LegadoQrType.sourceSub), '订阅源');
      expect(legadoQrTypeLabel(LegadoQrType.replaceRule), '替换规则');
    });
  });
}
