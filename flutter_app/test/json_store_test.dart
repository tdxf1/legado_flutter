import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/persistence/json_store.dart';

void main() {
  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('json_store_test_');
  });

  tearDown(() async {
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  test('round-trip: writeJsonKey then readJsonKey returns same value',
      () async {
    await writeJsonKey('foo', 'bar', directory: tmpDir.path);
    final v = await readJsonKey<String>(
      'foo',
      (raw) => raw as String,
      'default',
      directory: tmpDir.path,
    );
    expect(v, 'bar');
  });

  test('readJsonKey returns default when file missing', () async {
    final v = await readJsonKey<int>(
      'missing',
      (raw) => raw as int,
      42,
      directory: tmpDir.path,
    );
    expect(v, 42);
  });

  test('readJsonKey returns default when key missing', () async {
    await writeJsonKey('a', 1, directory: tmpDir.path);
    final v = await readJsonKey<int>(
      'b',
      (raw) => raw as int,
      99,
      directory: tmpDir.path,
    );
    expect(v, 99);
  });

  test('readJsonKey returns default when parse throws', () async {
    await writeJsonKey('foo', 'not-a-number', directory: tmpDir.path);
    final v = await readJsonKey<int>(
      'foo',
      (raw) => raw as int,
      7,
      directory: tmpDir.path,
    );
    expect(v, 7);
  });

  test('deleteJsonKey removes the key but keeps siblings', () async {
    await writeJsonKey('keep', 'me', directory: tmpDir.path);
    await writeJsonKey('drop', 'gone', directory: tmpDir.path);
    await deleteJsonKey('drop', directory: tmpDir.path);

    final dropped = await readJsonKey<String?>(
      'drop',
      (raw) => raw as String?,
      null,
      directory: tmpDir.path,
    );
    final kept = await readJsonKey<String?>(
      'keep',
      (raw) => raw as String?,
      null,
      directory: tmpDir.path,
    );
    expect(dropped, isNull);
    expect(kept, 'me');
  });

  test('deleteJsonKey is a no-op when file or key missing', () async {
    // No file yet — should not throw / create file.
    await deleteJsonKey('foo', directory: tmpDir.path);
    expect(await File('${tmpDir.path}/settings.json').exists(), isFalse);

    // File exists but key absent.
    await writeJsonKey('a', 1, directory: tmpDir.path);
    await deleteJsonKey('b', directory: tmpDir.path);
    final v = await readJsonKey<int>(
      'a',
      (raw) => raw as int,
      0,
      directory: tmpDir.path,
    );
    expect(v, 1);
  });

  test('concurrent writes serialize correctly: all keys persisted', () async {
    final futures = List.generate(
      10,
      (i) => writeJsonKey('k$i', i, directory: tmpDir.path),
    );
    await Future.wait(futures);

    final file = File('${tmpDir.path}/settings.json');
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    for (var i = 0; i < 10; i++) {
      expect(json['k$i'], i, reason: 'key k$i missing or wrong');
    }
  });

  test('read does not block write and vice versa', () async {
    await writeJsonKey('seed', 1, directory: tmpDir.path);
    final futures = <Future<void>>[];
    for (var i = 0; i < 5; i++) {
      futures.add(
        readJsonKey<int>(
          'seed',
          (raw) => raw as int,
          0,
          directory: tmpDir.path,
        ),
      );
      futures.add(writeJsonKey('w$i', i, directory: tmpDir.path));
    }
    // 5 秒超时即认为没死锁；正常情况下应在毫秒级完成。
    await Future.wait(futures).timeout(const Duration(seconds: 5));
  });

  test('writeJsonKey errors are swallowed when errorTag null', () async {
    // 用一个不存在的目录触发底层 IO 异常；错误应被静默吞掉，不向上抛。
    final bogusDir = '${tmpDir.path}/does_not_exist_${DateTime.now().microsecondsSinceEpoch}';
    // 不传 errorTag → 静默；调用应返回正常。
    await writeJsonKey('foo', 'bar', directory: bogusDir);
    // 也确认没建出意外文件。
    expect(await Directory(bogusDir).exists(), isFalse);
  });

  // ─────────────────────────────────────────────────────────────────────
  // BATCH-18g (F-W2A-058)：整文件 IO API（一文件一对象）
  // ─────────────────────────────────────────────────────────────────────
  group('json file (whole-file IO)', () {
    test('writeJsonFile then readJsonFile returns same map', () async {
      await writeJsonFile(
        'webdav.json',
        {'url': 'https://x', 'user': 'a'},
        directory: tmpDir.path,
      );
      final v = await readJsonFile('webdav.json', directory: tmpDir.path);
      expect(v, {'url': 'https://x', 'user': 'a'});
    });

    test('readJsonFile returns null when file missing', () async {
      final v = await readJsonFile('nope.json', directory: tmpDir.path);
      expect(v, isNull);
    });

    test('readJsonFile returns null when content is malformed JSON', () async {
      await File('${tmpDir.path}/bad.json').writeAsString('not-json{');
      final v = await readJsonFile('bad.json', directory: tmpDir.path);
      expect(v, isNull);
    });

    test('writeJsonFile is whole-file overwrite (does not merge)', () async {
      await writeJsonFile(
        'cfg.json',
        {'a': 1, 'b': 2},
        directory: tmpDir.path,
      );
      await writeJsonFile(
        'cfg.json',
        {'c': 3},
        directory: tmpDir.path,
      );
      final v = await readJsonFile('cfg.json', directory: tmpDir.path);
      expect(v, {'c': 3}); // a, b 被整覆盖
    });

    test('deleteJsonFile removes the file', () async {
      await writeJsonFile('tmp.json', {'x': 1}, directory: tmpDir.path);
      expect(await File('${tmpDir.path}/tmp.json').exists(), isTrue);
      await deleteJsonFile('tmp.json', directory: tmpDir.path);
      expect(await File('${tmpDir.path}/tmp.json').exists(), isFalse);
      expect(
        await readJsonFile('tmp.json', directory: tmpDir.path),
        isNull,
      );
    });

    test('deleteJsonFile is a no-op when file missing', () async {
      // 不抛、不创建、不留痕迹。
      await deleteJsonFile('ghost.json', directory: tmpDir.path);
      expect(await File('${tmpDir.path}/ghost.json').exists(), isFalse);
    });

    test('writeJsonFile rethrows on IO error (does not silently swallow)',
        () async {
      // 用不存在的目录触发底层 IO 异常；与 writeJsonKey 的吞错策略不同，
      // writeJsonFile 应该 rethrow 让 caller 决定如何提示用户。
      final bogusDir =
          '${tmpDir.path}/does_not_exist_${DateTime.now().microsecondsSinceEpoch}';
      expect(
        () => writeJsonFile(
          'foo.json',
          {'x': 1},
          directory: bogusDir,
        ),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('concurrent writes to different fileNames serialize via shared lock',
        () async {
      // 共用 _writeLock：10 个交错写到 a.json / b.json 全部完成且数据可解析。
      final futures = <Future<void>>[];
      for (var i = 0; i < 5; i++) {
        futures.add(writeJsonFile('a.json', {'i': i}, directory: tmpDir.path));
        futures.add(writeJsonFile('b.json', {'i': i}, directory: tmpDir.path));
      }
      await Future.wait(futures).timeout(const Duration(seconds: 5));
      final a = await readJsonFile('a.json', directory: tmpDir.path);
      final b = await readJsonFile('b.json', directory: tmpDir.path);
      expect(a, isNotNull);
      expect(b, isNotNull);
      expect(a!['i'], inInclusiveRange(0, 4));
      expect(b!['i'], inInclusiveRange(0, 4));
    });

    test(
        'settings.json must not be used with whole-file API (documenting convention)',
        () async {
      // 文档化约定：settings.json 走 readJsonKey/writeJsonKey 多 key 共享；
      // writeJsonFile('settings.json', ...) 整覆盖会清掉既有 key。本 test
      // 不阻止使用，仅声明行为，防止后人误用。
      await writeJsonKey('a', 1, directory: tmpDir.path);
      await writeJsonFile(
        'settings.json',
        {'b': 2},
        directory: tmpDir.path,
      );
      final v = await readJsonKey<int?>(
        'a',
        (raw) => raw as int?,
        null,
        directory: tmpDir.path,
      );
      expect(v, isNull); // a 被整覆盖干掉
    });
  });
}
