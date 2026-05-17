/// 统一传输抽象层
///
/// 把 Flutter 端访问后端的两条路径（FRB FFI / Dio HTTP）收敛到同一接口：
///
/// ```dart
/// abstract class Transport {
///   Future<dynamic> invoke(String cmd, [Map<String, dynamic>? args]);
///   Stream<TransportEvent> stream(String path, [Map<String, String>? query]);
/// }
/// ```
///
/// 当前实现两个：
/// - [LocalTransport]：invoke 走 FRB；stream 暂未接入（占位回 empty stream）
/// - [HttpTransport]：invoke 走 Dio；stream 走 Server-Sent Events
///
/// 业务侧 widget 通过 `ref.read(transportProvider)` 拿到当前 Transport 实例
/// （由 [BackendMode] 切换），无需关心底层细节。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

class TransportEvent {
  /// SSE event name (`message` 默认，或自定义如 `result` / `done`）
  final String event;

  /// SSE data 字段（已是字符串；调用方按需 jsonDecode）
  final String data;

  /// SSE id 字段（如果有）
  final String? id;

  const TransportEvent({
    required this.event,
    required this.data,
    this.id,
  });

  Map<String, dynamic>? get json {
    try {
      return jsonDecode(data) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[Transport] non-JSON SSE data: $e');
      return null;
    }
  }
}

abstract class Transport {
  /// 单次 RPC 调用。返回值是 invoke 命令的原生输出（字符串 / Map / List 等）。
  Future<dynamic> invoke(String cmd, [Map<String, dynamic>? args]);

  /// 服务器推送流。SSE 一条消息映射为一个 [TransportEvent]。
  /// 客户端取消订阅时（`subscription.cancel()`）应自动断开底层连接。
  Stream<TransportEvent> stream(
    String path, {
    Map<String, String>? query,
  });

  void close();
}

/// HTTP + SSE 实现（HttpClient 内置，无需额外 pub 依赖）。
class HttpTransport implements Transport {
  final String baseUrl;
  final String? token;

  final HttpClient _client;
  final List<HttpClientRequest> _activeRequests = [];

  HttpTransport({
    required this.baseUrl,
    this.token,
    HttpClient? client,
  }) : _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 10);
  }

  @override
  Future<dynamic> invoke(
    String cmd,
    [Map<String, dynamic>? args]) async {
    // For HTTP mode, [cmd] 是 URI path，例如 'POST /api/search'。
    // 简化：调用方按"VERB /path"格式传入。
    final parts = cmd.split(' ');
    if (parts.length != 2) {
      throw ArgumentError(
          'HttpTransport.invoke expects "VERB /path"; got "$cmd"');
    }
    final method = parts[0].toUpperCase();
    final path = parts[1];
    final uri = Uri.parse(baseUrl + path);
    final req = await _client.openUrl(method, uri);
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    if (token != null) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (args != null && method != 'GET') {
      req.add(utf8.encode(jsonEncode(args)));
    }
    final res = await req.close();
    final bodyBytes = <int>[];
    await for (final chunk in res) {
      bodyBytes.addAll(chunk);
    }
    final body = utf8.decode(bodyBytes);
    if (res.statusCode >= 400) {
      throw HttpException(
        '$method $path failed: ${res.statusCode} $body',
      );
    }
    if (body.isEmpty) return null;
    try {
      return jsonDecode(body);
    } catch (e) {
      // Body wasn't valid JSON; surface raw text to caller (server may
      // intentionally return plain text, e.g. /api/sources/export/legado).
      debugPrint('[HttpTransport] non-JSON response from $cmd: $e');
      return body;
    }
  }

  @override
  Stream<TransportEvent> stream(
    String path, {
    Map<String, String>? query,
  }) async* {
    final qs = (query == null || query.isEmpty)
        ? ''
        : '?${query.entries.map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}').join('&')}';
    final uri = Uri.parse(baseUrl + path + qs);
    final req = await _client.openUrl('GET', uri);
    req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
    req.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    if (token != null) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    _activeRequests.add(req);
    HttpClientResponse res;
    try {
      res = await req.close();
    } finally {
      _activeRequests.remove(req);
    }
    if (res.statusCode >= 400) {
      throw HttpException('GET $path SSE failed: ${res.statusCode}');
    }

    yield* parseSseStream(res.transform(utf8.decoder));
  }

  @override
  void close() {
    for (final r in _activeRequests) {
      try {
        r.abort();
      } catch (e) {
        debugPrint('[HttpTransport] abort failed: $e');
      }
    }
    _activeRequests.clear();
    _client.close(force: true);
  }
}

/// SSE chunk stream → [TransportEvent] stream.
///
/// Pulled out as a top-level function so it's testable with a synthetic
/// `Stream<String>` (the real wire-level [HttpClientResponse] is hard to
/// shape into specific chunk boundaries).
///
/// Handles:
/// - LF / CR / CRLF line terminators (R6)
/// - CRLF that gets split across two chunks: trailing '\r' is held back
///   until the next chunk so it can be paired or normalised correctly (R29)
/// - lone trailing '\r' at end-of-stream: flushed as '\n' so the final
///   block is still parseable (R52)
/// - non-spec final block without a trailing blank line: dispatched on
///   stream close so partial servers don't drop the last event (R53)
/// - multi-line `data:` joined with '\n' per the SSE spec
@visibleForTesting
Stream<TransportEvent> parseSseStream(Stream<String> chunks) async* {
  final buffer = StringBuffer();
  // R29: if a chunk ends in a bare '\r' it might be the first half of a
  // CRLF that got split across the HTTP chunk boundary. Hold it back
  // until the next chunk arrives so we can see whether to drop it
  // (CRLF -> LF) or convert it (lone CR -> LF). Without this, naive
  // per-chunk normalization turns the trailing '\r' into '\n', then the
  // next chunk's leading '\n' stays, producing a spurious '\n\n' block
  // separator and mis-dispatching the SSE event.
  bool pendingCr = false;

  // Drain whatever is in `buffer` up to the last '\n\n' boundary,
  // dispatching a TransportEvent per block. Returns events via the
  // provided sink so the same routine can also be called once after the
  // stream ends to flush any final block (R53).
  Iterable<TransportEvent> drainBlocks() sync* {
    while (true) {
      final raw = buffer.toString();
      final sep = raw.indexOf('\n\n');
      if (sep < 0) break;
      final block = raw.substring(0, sep);
      buffer.clear();
      buffer.write(raw.substring(sep + 2));
      final dispatched = _parseSseBlock(block);
      if (dispatched != null) yield dispatched;
    }
  }

  await for (final chunk in chunks) {
    // Empty keep-alive chunks (some servers send empty data frames) must
    // not consume the pendingCr — that decision needs to wait for the
    // next chunk that actually has bytes.
    if (chunk.isEmpty) continue;
    var work = chunk;
    if (pendingCr) {
      // Carry-over from previous chunk. If the new chunk starts with
      // '\n', the held '\r' was the first half of CRLF: emit a single
      // '\n' for the pair. Otherwise the held '\r' was a lone CR and
      // should be normalised to '\n' on its own.
      if (work.startsWith('\n')) {
        buffer.write('\n');
        work = work.substring(1);
      } else {
        buffer.write('\n');
      }
      pendingCr = false;
    }
    if (work.endsWith('\r')) {
      pendingCr = true;
      work = work.substring(0, work.length - 1);
    }
    // R6: SSE allows LF / CR / CRLF as line terminators; normalise both
    // so the rest of the parser only deals with '\n'.
    final normalized = work.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    buffer.write(normalized);
    yield* Stream.fromIterable(drainBlocks());
  }

  // R52: stream ended while holding a trailing '\r'. There is no next
  // chunk to pair it with, so treat it as a lone CR and flush as '\n'.
  if (pendingCr) {
    buffer.write('\n');
    pendingCr = false;
  }
  // R53: drain again in case the trailing CR completed a block. Then
  // dispatch any remaining content even without a final '\n\n' — some
  // servers close the connection right after the last event without the
  // spec-required blank-line terminator.
  yield* Stream.fromIterable(drainBlocks());
  final tail = buffer.toString();
  buffer.clear();
  if (tail.isNotEmpty) {
    final dispatched = _parseSseBlock(tail);
    if (dispatched != null) yield dispatched;
  }
}

/// Parse a single SSE block (lines separated by '\n', no terminating
/// blank line). Returns the dispatched event, or null when the block
/// produced no `data:` lines (per spec: ignore).
TransportEvent? _parseSseBlock(String block) {
  String currentEvent = 'message';
  String currentId = '';
  final dataLines = <String>[];
  for (final line in block.split('\n')) {
    if (line.isEmpty) continue;
    if (line.startsWith(':')) continue; // SSE comment
    final colonIdx = line.indexOf(':');
    if (colonIdx < 0) continue;
    final field = line.substring(0, colonIdx).trim();
    var value = line.substring(colonIdx + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'event':
        currentEvent = value;
        break;
      case 'data':
        dataLines.add(value);
        break;
      case 'id':
        currentId = value;
        break;
    }
  }
  if (dataLines.isEmpty) return null;
  return TransportEvent(
    event: currentEvent,
    data: dataLines.join('\n'),
    id: currentId.isEmpty ? null : currentId,
  );
}

/// 占位 LocalTransport — 为了让上层在 BackendMode.frb 时也能拿到一个非空实例。
///
/// invoke 永远抛 [UnimplementedError]，stream 返回空 stream。业务代码现阶段
/// 仍直接使用 `rust_api.xxx`，未来逐步迁移到 Transport 抽象后才会真正调用此类。
class LocalTransport implements Transport {
  const LocalTransport();

  @override
  Future<dynamic> invoke(String cmd, [Map<String, dynamic>? args]) {
    throw UnimplementedError(
      'LocalTransport.invoke is a placeholder. Call rust_api directly for now.',
    );
  }

  @override
  Stream<TransportEvent> stream(String path, {Map<String, String>? query}) {
    debugPrint('[LocalTransport] stream($path) — no FRB Stream wired yet');
    return const Stream.empty();
  }

  @override
  void close() {}
}
