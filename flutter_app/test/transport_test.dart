import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/transport.dart';

void main() {
  group('LocalTransport', () {
    test('invoke throws UnimplementedError', () async {
      const t = LocalTransport();
      expect(
        () => t.invoke('whatever'),
        throwsA(isA<UnimplementedError>()),
      );
    });

    test('stream returns empty', () async {
      const t = LocalTransport();
      final all = await t.stream('/sse').toList();
      expect(all, isEmpty);
    });
  });

  group('HttpTransport SSE parsing', () {
    late HttpServer server;
    late int port;

    setUp(() async {
      server = await HttpServer.bind('127.0.0.1', 0);
      port = server.port;
      server.listen((req) async {
        if (req.uri.path == '/sse') {
          req.response.headers
            ..set(HttpHeaders.contentTypeHeader, 'text/event-stream')
            ..set(HttpHeaders.cacheControlHeader, 'no-cache');
          req.response.write(
            'event: result\n'
            'data: {"item":1}\n\n'
            'event: result\n'
            'data: {"item":2}\n\n'
            'event: done\n'
            'data: {}\n\n',
          );
          await req.response.flush();
          await req.response.close();
        } else if (req.uri.path == '/echo') {
          req.response.headers.contentType = ContentType.json;
          req.response.write('{"ok":true}');
          await req.response.close();
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('parses event/data blocks', () async {
      final t = HttpTransport(baseUrl: 'http://127.0.0.1:$port');
      final events = await t.stream('/sse').toList();
      expect(events.length, 3);
      expect(events[0].event, 'result');
      expect(events[0].json, {'item': 1});
      expect(events[1].event, 'result');
      expect(events[1].json, {'item': 2});
      expect(events[2].event, 'done');
      t.close();
    });

    test('invoke parses JSON response', () async {
      final t = HttpTransport(baseUrl: 'http://127.0.0.1:$port');
      final r = await t.invoke('GET /echo');
      expect(r, isA<Map>());
      expect((r as Map)['ok'], true);
      t.close();
    });

    test('invoke throws ArgumentError on malformed cmd', () async {
      final t = HttpTransport(baseUrl: 'http://127.0.0.1:$port');
      expect(() => t.invoke('not_a_verb_path'),
          throwsA(isA<ArgumentError>()));
      t.close();
    });
  });

  group('HttpTransport SSE block-level aggregation', () {
    late HttpServer server;
    late int port;

    setUp(() async {
      server = await HttpServer.bind('127.0.0.1', 0);
      port = server.port;
      server.listen((req) async {
        req.response.headers
          ..set(HttpHeaders.contentTypeHeader, 'text/event-stream')
          ..set(HttpHeaders.cacheControlHeader, 'no-cache');
        // One block with three data lines — per SSE spec they should be
        // joined with '\n' and dispatched as a single event.
        req.response.write(
          'event: log\n'
          'data: line1\n'
          'data: line2\n'
          'data: line3\n\n'
          // Block without explicit event: defaults to 'message'
          'data: hello\n\n',
        );
        await req.response.flush();
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('joins multi-line data with \\n and resets event between blocks',
        () async {
      final t = HttpTransport(baseUrl: 'http://127.0.0.1:$port');
      final events = await t.stream('/').toList();
      expect(events.length, 2);
      expect(events[0].event, 'log');
      expect(events[0].data, 'line1\nline2\nline3');
      // Second block has no event: line — must default back to 'message'.
      expect(events[1].event, 'message');
      expect(events[1].data, 'hello');
      t.close();
    });
  });

  group('HttpTransport SSE CRLF normalisation (R6)', () {
    late HttpServer server;
    late int port;

    setUp(() async {
      server = await HttpServer.bind('127.0.0.1', 0);
      port = server.port;
      server.listen((req) async {
        req.response.headers
          ..set(HttpHeaders.contentTypeHeader, 'text/event-stream')
          ..set(HttpHeaders.cacheControlHeader, 'no-cache');
        // Mixed CRLF / LF — proxies sometimes do this. The parser must
        // dispatch two distinct events with clean payloads (no trailing
        // \r in the field name).
        req.response.write(
          'event: result\r\n'
          'data: {"item":1}\r\n\r\n'
          'event: done\r\n'
          'data: {}\r\n\r\n',
        );
        await req.response.flush();
        await req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('normalises CRLF/CR to LF before parsing', () async {
      final t = HttpTransport(baseUrl: 'http://127.0.0.1:$port');
      final events = await t.stream('/').toList();
      expect(events.length, 2);
      expect(events[0].event, 'result');
      expect(events[0].json, {'item': 1});
      expect(events[1].event, 'done');
      t.close();
    });
  });
}
