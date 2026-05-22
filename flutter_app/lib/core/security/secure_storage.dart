import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 凭据保险柜薄包装（BATCH-03 / F-W2B-001）。
///
/// 用于把敏感字段（如 WebDAV 密码）存到 Android Keystore-backed
/// `EncryptedSharedPreferences`（flutter_secure_storage v9 默认）；iOS 走
/// Keychain。Web/Desktop 不在主线，未验证。
///
/// ## 公开 API
///
/// - [readSecret] / [writeSecret] / [deleteSecret] — 顶层函数，调用方直接用。
/// - [setSecureStorageOverrideForTest] — 测试钩子，注入内存 fake 实现，避免
///   widget test 触发 platform channel 抛 `MissingPluginException`。
///
/// ## key 命名空间
///
/// - `webdav_password` — WebDAV 凭据中的密码字段（BATCH-03 引入）。
/// - `backup_password` — Legado 备份密码字段（BATCH-03b 引入；旧版本写在
///   legado_local.json，启动期一次性迁移）。
///
/// ## 行为约定
///
/// - [readSecret] 在 key 不存在 / 读失败时返回 `null`，**不**抛异常。
/// - [writeSecret] 接受 nullable value：传 `null` 或空串等价 [deleteSecret]，
///   语义上"清空 = 删 key"，避免空串与"未配置"混淆。
/// - [deleteSecret] 在 key 不存在时静默 no-op。
///
/// 与 `core/persistence/json_store.dart` 是两条并行 IO 路径：json_store
/// 走应用 documents 明文 JSON；secure_storage 走平台原生加密存储。
abstract class SecureStorageImpl {
  Future<String?> read(String key);

  /// 写 key=[value]。value 为 null 或空串等价 delete（语义清晰：清空 = 没配置）。
  Future<void> write(String key, String? value);

  Future<void> delete(String key);
}

class _RealSecureStorage implements SecureStorageImpl {
  // Android v9：EncryptedSharedPreferences 走 Keystore-backed AES/GCM，
  // 与项目 minSdk 23+ 对齐。AndroidOptions 是 const，整个 storage 也 const。
  static const _opts = AndroidOptions(encryptedSharedPreferences: true);
  static const _storage = FlutterSecureStorage(aOptions: _opts);

  const _RealSecureStorage();

  @override
  Future<String?> read(String key) {
    return _storage.read(key: key);
  }

  @override
  Future<void> write(String key, String? value) {
    if (value == null || value.isEmpty) {
      return _storage.delete(key: key);
    }
    return _storage.write(key: key, value: value);
  }

  @override
  Future<void> delete(String key) {
    return _storage.delete(key: key);
  }
}

SecureStorageImpl? _override;

SecureStorageImpl get _impl => _override ?? const _RealSecureStorage();

/// 测试钩子：注入 fake [SecureStorageImpl] 替代真实平台后端。
///
/// 传 `null` 复原（建议在 tearDown 中调用避免跨用例污染）。Pattern 与
/// `core/persistence/json_store.dart` 的 top-level fn 测试模式一致 ——
/// secure_storage 是 cross-feature 工具，不绑定 Riverpod provider 注入。
@visibleForTesting
void setSecureStorageOverrideForTest(SecureStorageImpl? impl) {
  _override = impl;
}

Future<String?> readSecret(String key) => _impl.read(key);

Future<void> writeSecret(String key, String? value) => _impl.write(key, value);

Future<void> deleteSecret(String key) => _impl.delete(key);
