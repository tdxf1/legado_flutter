import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/rust/api.dart' as rust_api;

/// 备份 / WebDAV 桥接调用包装。via Riverpod provider 注入便于测试 fake。
///
/// BATCH-20 (F-W2B-004)：原 `BackupPage` 构造函数 10 个 `*Override` 测试钩子
/// 全部移除，统一通过 [backupApiClientProvider] 注入。生产代码默认实现透传
/// FRB 调用；测试用 `ProviderScope.overrides` 替换 fake 类即可。
class BackupApiClient {
  const BackupApiClient();

  /// 导出 zip 备份。
  Future<void> exportBackup({
    required String dbPath,
    required String outZipPath,
  }) {
    return rust_api.exportBackupZip(dbPath: dbPath, outZipPath: outZipPath);
  }

  /// 导入 zip 备份，返回 ImportSummary JSON 字符串。
  Future<String> importBackup({
    required String dbPath,
    required String zipPath,
  }) {
    return rust_api.importBackupZip(dbPath: dbPath, zipPath: zipPath);
  }

  /// 列 zip 内识别到的 Legado 备份文件名。
  Future<List<String>> validateZip({required String zipPath}) async {
    final json = await rust_api.validateBackupZip(zipPath: zipPath);
    final List<dynamic> list = jsonDecode(json) as List<dynamic>;
    return list.cast<String>();
  }

  /// WebDAV 上传备份。
  Future<void> webdavUpload({
    required String dbPath,
    required String url,
    required String user,
    required String password,
    required String fileName,
  }) {
    return rust_api.webdavUploadBackup(
      dbPath: dbPath,
      url: url,
      user: user,
      password: password,
      fileName: fileName,
    );
  }

  /// 列远端 backup zip 文件名，返回 JSON 字符串数组。
  Future<String> webdavList({
    required String url,
    required String user,
    required String password,
  }) {
    return rust_api.webdavListBackups(
      url: url,
      user: user,
      password: password,
    );
  }

  /// WebDAV 下载并导入备份，返回 ImportSummary JSON。
  Future<String> webdavDownload({
    required String dbPath,
    required String url,
    required String user,
    required String password,
    required String fileName,
  }) {
    return rust_api.webdavDownloadBackup(
      dbPath: dbPath,
      url: url,
      user: user,
      password: password,
      fileName: fileName,
    );
  }
}

final backupApiClientProvider = Provider<BackupApiClient>(
  (ref) => const BackupApiClient(),
);
