import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/persistence/json_store.dart';
import '../../core/security/secure_storage.dart';

/// BATCH-27c-2 (05-22): 远程书多 server 管理模型 + 持久化 helpers。
///
/// 对齐 legado `Server entity` (`legado/.../data/entities/Server.kt:57`)
/// + `ServersDialog` + `ServerConfigDialog` + `AppConfig.remoteServerId`
/// + `AppConst.DEFAULT_WEBDAV_ID = -1L` 行为。
///
/// **持久化分层**：
///
/// - **非敏感字段**（id / name / url / user）走 `<documentsDir>/servers.json`
///   （file-based json_store），与 `webdav.json` 范本同模式。
/// - **敏感字段**（password）走 `secure_storage` 的 `webdav_password_<id>`
///   key 命名空间，**不**塞 servers.json — 对齐 BATCH-03「凭据保险柜」
///   契约。
///
/// **「默认」sentinel**：`id = -1` 等价旧 `webdav.json` 单凭据
/// （`webdav_password` key），向后兼容 BATCH-27c-1 + backup_page。
/// 用户**不能**通过本模块编辑/删除 id=-1 的「默认」server，那条路径
/// 仍走 `WebDavConfigPage`。
///
/// **id 生成**：`DateTime.now().millisecondsSinceEpoch`，与 legado
/// `Server.id = System.currentTimeMillis()` 一致。
const int kDefaultRemoteServerId = -1;
const String kRemoteServersFile = 'servers.json';

/// 单 server 元数据。`password` 不在此 model 内（走 secure_storage）。
@immutable
class RemoteServer {
  final int id;
  final String name;
  final String url;
  final String user;

  const RemoteServer({
    required this.id,
    required this.name,
    required this.url,
    required this.user,
  });

  RemoteServer copyWith({
    int? id,
    String? name,
    String? url,
    String? user,
  }) {
    return RemoteServer(
      id: id ?? this.id,
      name: name ?? this.name,
      url: url ?? this.url,
      user: user ?? this.user,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'user': user,
      };

  factory RemoteServer.fromJson(Map<String, dynamic> raw) {
    final id = raw['id'];
    return RemoteServer(
      id: id is int
          ? id
          : id is num
              ? id.toInt()
              : 0,
      name: (raw['name'] as String?) ?? '',
      url: (raw['url'] as String?) ?? '',
      user: (raw['user'] as String?) ?? '',
    );
  }

  @override
  bool operator ==(Object other) {
    return other is RemoteServer &&
        other.id == id &&
        other.name == name &&
        other.url == url &&
        other.user == user;
  }

  @override
  int get hashCode => Object.hash(id, name, url, user);
}

/// secure_storage 单 server password key 命名规则。
String webdavPasswordKey(int serverId) => 'webdav_password_$serverId';

/// 加载 servers.json → `List<RemoteServer>`。文件不存在 / 损坏返回空列表。
Future<List<RemoteServer>> loadRemoteServersFromDisk(
    {String? directory}) async {
  try {
    final raw = await readJsonFile(
      kRemoteServersFile,
      directory: directory,
    );
    if (raw == null) return const <RemoteServer>[];
    final list = raw['servers'];
    if (list is List) {
      return list
          .whereType<Map>()
          .map((e) => RemoteServer.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    return const <RemoteServer>[];
  } catch (_) {
    return const <RemoteServer>[];
  }
}

/// 写 servers.json（整文件覆盖）。`servers` 应为完整列表。
/// IO 失败 rethrow（caller 外层 try-catch 给 SnackBar）。
Future<void> saveRemoteServersToDisk(List<RemoteServer> servers,
        {String? directory}) =>
    writeJsonFile(
      kRemoteServersFile,
      {'servers': servers.map((s) => s.toJson()).toList()},
      directory: directory,
    );

/// 读 server password。`id == kDefaultRemoteServerId` 时走旧 key
/// `webdav_password`（兼容 27c-1）；否则走 `webdav_password_<id>`。
Future<String> loadRemoteServerPassword(int id) async {
  final key =
      id == kDefaultRemoteServerId ? 'webdav_password' : webdavPasswordKey(id);
  return (await readSecret(key)) ?? '';
}

/// 写 server password。`null` 或空串 → 删除。
Future<void> saveRemoteServerPassword(int id, String? password) async {
  final key =
      id == kDefaultRemoteServerId ? 'webdav_password' : webdavPasswordKey(id);
  await writeSecret(key, password);
}
