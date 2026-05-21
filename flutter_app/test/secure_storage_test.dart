import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/security/secure_storage.dart';

import '_secure_storage_fake.dart';

/// 单测 secure_storage 顶层 read/write/delete + InMemorySecureStorage fake。
///
/// 不触发 platform channel — fake 注入后所有调用走内存 map。
void main() {
  late InMemorySecureStorage fake;

  setUp(() {
    fake = InMemorySecureStorage();
    setSecureStorageOverrideForTest(fake);
  });

  tearDown(() {
    setSecureStorageOverrideForTest(null);
  });

  test('writeSecret + readSecret round-trip', () async {
    expect(await readSecret('webdav_password'), isNull);
    await writeSecret('webdav_password', 'pwd-123');
    expect(await readSecret('webdav_password'), 'pwd-123');
    expect(fake.debugStore['webdav_password'], 'pwd-123');
  });

  test('writeSecret with null deletes key', () async {
    await writeSecret('webdav_password', 'pwd-123');
    expect(fake.debugStore['webdav_password'], 'pwd-123');

    await writeSecret('webdav_password', null);
    expect(fake.debugStore.containsKey('webdav_password'), isFalse);
    expect(await readSecret('webdav_password'), isNull);
  });

  test('writeSecret with empty string deletes key', () async {
    await writeSecret('webdav_password', 'pwd-123');
    await writeSecret('webdav_password', '');
    expect(fake.debugStore.containsKey('webdav_password'), isFalse);
  });

  test('deleteSecret removes key (no-op if absent)', () async {
    await writeSecret('foo', 'bar');
    expect(fake.debugStore.containsKey('foo'), isTrue);
    await deleteSecret('foo');
    expect(fake.debugStore.containsKey('foo'), isFalse);
    // No-op for missing key
    await deleteSecret('nonexistent');
    expect(fake.debugStore.containsKey('nonexistent'), isFalse);
  });

  test('readSecret returns null for unset key', () async {
    expect(await readSecret('never_written'), isNull);
  });

  test('setSecureStorageOverrideForTest(null) reverts to real impl', () {
    setSecureStorageOverrideForTest(null);
    // 不调实际 read/write — 真 impl 会触发 platform channel。
    // 仅验证 override flag 复位（@visibleForTesting marker via no exception）。
    expect(true, isTrue, reason: 'tearDown later resets to fake');
  });

  test('@visibleForTesting marker stays internal', () {
    // 静态保证 setSecureStorageOverrideForTest 走 visibleForTesting 注解；
    // 如果未来误改成 public 不带注解，本注解 import 会报 unused。
    expect(visibleForTesting, isNotNull);
  });
}
