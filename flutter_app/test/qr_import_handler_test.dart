import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/features/qr/legado_qr_protocol.dart';
import 'package:legado_flutter/features/qr/qr_import_handler.dart';

/// 批次 20 (05-19): QR 导入处理器单测。
///
/// 通过 *Override 钩子注入假 fetchUrl + 假 FRB 调用，验证 3 种协议
/// 各自走对应 import API + 返回字符串符合 SnackBar 契约。
///
/// 用 [Consumer] + [WidgetRef] 拿到真 ref（即使没有 dbPathProvider override
/// 也走 [dbPathOverride] 跳过 path_provider）。
class _CapturedRef {
  WidgetRef? ref;
}

Widget _buildHarness(_CapturedRef cap) {
  return ProviderScope(
    child: MaterialApp(
      home: Consumer(
        builder: (ctx, ref, _) {
          cap.ref = ref;
          return const Scaffold(body: SizedBox.shrink());
        },
      ),
    ),
  );
}

void main() {
  testWidgets('bookSource path: fetch + import returns count summary',
      (WidgetTester tester) async {
    final cap = _CapturedRef();
    await tester.pumpWidget(_buildHarness(cap));
    await tester.pumpAndSettle();

    String? fetchedUrl;
    String? importedDbPath;
    String? importedJson;
    final result = await QrImportHandler.handle(
      cap.ref!,
      const ParsedLegadoQr(
        type: LegadoQrType.bookSource,
        fetchUrl: 'https://example.com/sources.json',
      ),
      dbPathOverride: '/tmp/legado-test.db',
      fetchUrlOverride: (url) async {
        fetchedUrl = url;
        return '[{"name":"src1","url":"https://s1.com"}]';
      },
      importBookSourcesOverride: (db, json) async {
        importedDbPath = db;
        importedJson = json;
        return 7;
      },
    );

    expect(fetchedUrl, 'https://example.com/sources.json');
    expect(importedDbPath, '/tmp/legado-test.db');
    expect(importedJson, '[{"name":"src1","url":"https://s1.com"}]');
    expect(result, '已导入 7 个书源');
  });

  testWidgets('rssSource path: fetch + import returns added/updated/skipped',
      (WidgetTester tester) async {
    final cap = _CapturedRef();
    await tester.pumpWidget(_buildHarness(cap));
    await tester.pumpAndSettle();

    final result = await QrImportHandler.handle(
      cap.ref!,
      const ParsedLegadoQr(
        type: LegadoQrType.rssSource,
        fetchUrl: 'https://example.com/rss.json',
      ),
      dbPathOverride: '/tmp/legado-test.db',
      fetchUrlOverride: (url) async => '[{}]',
      importRssSourcesOverride: (db, json) async {
        return '{"added":3,"updated":1,"skipped":2}';
      },
    );

    expect(result, '新增 3，更新 1，跳过 2');
  });

  testWidgets('sourceSub path: create + refresh returns success message',
      (WidgetTester tester) async {
    final cap = _CapturedRef();
    await tester.pumpWidget(_buildHarness(cap));
    await tester.pumpAndSettle();

    String? createdName;
    String? createdUrl;
    int? createdSubType;
    String? refreshedId;
    final result = await QrImportHandler.handle(
      cap.ref!,
      const ParsedLegadoQr(
        type: LegadoQrType.sourceSub,
        fetchUrl: 'https://example.com/sub.json',
      ),
      dbPathOverride: '/tmp/legado-test.db',
      createRuleSubOverride: (db, name, url, subType) async {
        createdName = name;
        createdUrl = url;
        createdSubType = subType;
        return '{"id":"sub-uuid-123","name":"$name","url":"$url","sub_type":$subType}';
      },
      refreshRuleSubOverride: (db, id) async {
        refreshedId = id;
        return '{"sub_type":0,"count":42}';
      },
    );

    expect(createdName, contains('example.com'));
    expect(createdUrl, 'https://example.com/sub.json');
    expect(createdSubType, 0);
    expect(refreshedId, 'sub-uuid-123');
    expect(result, contains('已添加订阅源'));
    expect(result, contains('刷新完成'));
  });

  testWidgets('replaceRule path: returns placeholder message',
      (WidgetTester tester) async {
    final cap = _CapturedRef();
    await tester.pumpWidget(_buildHarness(cap));
    await tester.pumpAndSettle();

    final result = await QrImportHandler.handle(
      cap.ref!,
      const ParsedLegadoQr(
        type: LegadoQrType.replaceRule,
        fetchUrl: 'https://example.com/rules.json',
      ),
      dbPathOverride: '/tmp/legado-test.db',
    );

    expect(result, contains('替换规则订阅暂未实装'));
  });

  group('validateFetchedBody (BATCH-05)', () {
    test('body within 10MB + json content-type passes', () {
      expect(
        () => QrImportHandler.validateFetchedBody(
          '{"name":"src1"}',
          'application/json; charset=utf-8',
        ),
        returnsNormally,
      );
    });

    test('body > 10MB rejected', () {
      // 构造 10 MB + 1 字符串
      final big = 'x' * (10 * 1024 * 1024 + 1);
      expect(
        () => QrImportHandler.validateFetchedBody(big, 'application/json'),
        throwsA(isA<Exception>()),
      );
    });

    test('binary content-type rejected', () {
      expect(
        () => QrImportHandler.validateFetchedBody(
          'whatever',
          'application/x-msdownload',
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('text/plain content-type allowed', () {
      expect(
        () => QrImportHandler.validateFetchedBody(
          '{"name":"src1"}',
          'text/plain; charset=utf-8',
        ),
        returnsNormally,
      );
    });

    test('application/octet-stream allowed (GitHub raw)', () {
      // GitHub raw / pages 给 .json 文件常返 application/octet-stream
      expect(
        () => QrImportHandler.validateFetchedBody(
          '{"name":"src1"}',
          'application/octet-stream',
        ),
        returnsNormally,
      );
    });

    test('empty content-type allowed (compatibility)', () {
      expect(
        () => QrImportHandler.validateFetchedBody('{}', null),
        returnsNormally,
      );
      expect(
        () => QrImportHandler.validateFetchedBody('{}', ''),
        returnsNormally,
      );
    });
  });
}
