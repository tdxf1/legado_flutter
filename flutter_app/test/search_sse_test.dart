import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/transport.dart';

/// 模拟 axum `/api/search/sse` 响应，确认 search_page 的合并/去重/done 终止逻辑
/// 在协议层是健壮的（不直接驱动 widget，专心校验流处理）。
void main() {
  late HttpServer server;
  late int port;

  setUp(() async {
    server = await HttpServer.bind('127.0.0.1', 0);
    port = server.port;
    server.listen((req) async {
      if (req.uri.path != '/api/search/sse') {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      req.response.headers
        ..set(HttpHeaders.contentTypeHeader, 'text/event-stream')
        ..set(HttpHeaders.cacheControlHeader, 'no-cache');
      // Two batches with overlapping (name, author) → should dedupe
      req.response.write(
        'event: result\n'
        'data: {"source_id":"a","items":[{"name":"X","author":"Y"}]}\n\n'
        'event: result\n'
        'data: {"source_id":"b","items":[{"name":"X","author":"Y"},{"name":"Z","author":"W"}]}\n\n'
        'event: error\n'
        'data: {"source_id":"c","source_name":"broken","error":"boom"}\n\n'
        'event: done\n'
        'data: {}\n\n',
      );
      await req.response.flush();
      await req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('SSE search merges results and dedupes by (name, author)', () async {
    final t = HttpTransport(baseUrl: 'http://127.0.0.1:$port');
    final events =
        await t.stream('/api/search/sse', query: {'q': 'kw'}).toList();
    t.close();

    // event sequence: 2 result + 1 error + 1 done
    expect(events.length, 4);
    expect(events[0].event, 'result');
    expect(events[1].event, 'result');
    expect(events[2].event, 'error');
    expect(events[3].event, 'done');

    // dedupe simulation (mirrors search_page logic)
    final results = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final e in events.where((e) => e.event == 'result')) {
      final items = (e.json!['items'] as List).cast<Map<String, dynamic>>();
      for (final m in items) {
        final key = '${m['name']}_${m['author']}';
        if (seen.add(key)) results.add(m);
      }
    }
    expect(results.length, 2);
    expect(results[0]['name'], 'X');
    expect(results[1]['name'], 'Z');
  });
}
