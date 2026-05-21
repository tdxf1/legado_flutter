import 'package:legado_flutter/core/security/secure_storage.dart';

/// 内存 fake [SecureStorageImpl]，用于 widget / unit 测试避免触发
/// flutter_secure_storage platform channel（widget test 下抛
/// MissingPluginException）。
///
/// 用法：
/// ```dart
/// setUp(() => setSecureStorageOverrideForTest(InMemorySecureStorage()));
/// tearDown(() => setSecureStorageOverrideForTest(null));
/// ```
///
/// 写空串等价 delete（与 [_RealSecureStorage] 行为对齐）。
class InMemorySecureStorage implements SecureStorageImpl {
  final Map<String, String> _store = {};

  /// 测试便捷：直接读内部 map（构造预置状态、断言写入结果）。
  Map<String, String> get debugStore => _store;

  @override
  Future<String?> read(String key) async => _store[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null || value.isEmpty) {
      _store.remove(key);
    } else {
      _store[key] = value;
    }
  }

  @override
  Future<void> delete(String key) async {
    _store.remove(key);
  }
}
