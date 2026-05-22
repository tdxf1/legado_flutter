import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/persistence/json_store.dart';
import '../../core/security/secure_storage.dart';
import '../../core/widgets/safe_setstate.dart';
import '../../src/rust/api.dart' as rust_api;

/// WebDAV 配置页（批次 11 / 05-19）。
///
/// 让用户填写 WebDAV 服务端 URL、账号、密码、设备名，并提供"测试连接"
/// 按钮调用 [`webdavCheck`] 验证。保存到 `<documentsDir>/webdav.json`，
/// [`backup_page.dart`] 端在"上传到 WebDAV" / "从 WebDAV 恢复" 时
/// 读取此文件取凭据。
///
/// **配置文件格式**（BATCH-03 起）：
/// ```json
/// {
///   "url": "https://dav.jianguoyun.com/dav/legado/",
///   "user": "alice@example.com",
///   "deviceName": "Pixel"
/// }
/// ```
///
/// 密码字段不再写 webdav.json，改走
/// [`flutter_app/lib/core/security/secure_storage.dart`] 的
/// `webdav_password` key（Android Keystore / iOS Keychain）。BATCH-03
/// 引入启动迁移：旧版本写过的 password 字段会在首次打开本页时一次性
/// 迁到 secure_storage 并从 webdav.json 移除。
///
/// 批次 12（05-19）补充：新增"备份密码"字段（独立于 WebDAV 密码），调
/// [`setBackupPassword`] / [`getBackupPassword`] 持久化到
/// `<documentsDir>/legado_local.json`，对齐原 Legado `LocalConfig.password`。
/// 留空 = 不加密备份；设密码后 zip 内 servers.json + webDavPassword 走
/// AES，与原 Legado 兼容。
///
/// BATCH-03b (F-W1A-020)：备份密码也迁移到 secure_storage（key
/// `backup_password`），与 webdav_password 同模式：load 优先 secure_storage，
/// miss 时回退 FRB 旧路径并触发一次性迁移 + 清理 legado_local.json；save
/// 直接走 writeSecret。Rust 端 set/get_backup_password FRB 契约保留以备
/// 未来 backup zip 加密功能复用。
///
/// **测试钩子**：
/// - WebDAV password / FRB / path_provider 走 *Override 构造参数 +
///   top-level [setSecureStorageOverrideForTest]（避免 widget test 触发
///   platform channel）。
/// - 生产代码不传 override 时走真实路径。
class WebDavConfigPage extends ConsumerStatefulWidget {
  /// 测试钩子：注入假 documents 目录路径。
  final String? configDirOverride;

  /// 测试钩子：替换 [`webdavCheck`] FRB 调用。
  final Future<void> Function({
    required String url,
    required String user,
    required String password,
  })? webdavCheckOverride;

  /// 测试钩子：替换 [`getBackupPassword`] FRB 调用。
  final Future<String> Function({required String documentsDir})?
      getBackupPasswordOverride;

  /// 测试钩子：替换 [`setBackupPassword`] FRB 调用。
  final Future<void> Function({
    required String documentsDir,
    required String password,
  })? setBackupPasswordOverride;

  const WebDavConfigPage({
    super.key,
    this.configDirOverride,
    this.webdavCheckOverride,
    this.getBackupPasswordOverride,
    this.setBackupPasswordOverride,
  });

  @override
  ConsumerState<WebDavConfigPage> createState() => _WebDavConfigPageState();
}

class _WebDavConfigPageState extends ConsumerState<WebDavConfigPage> {
  final TextEditingController _urlCtl = TextEditingController();
  final TextEditingController _userCtl = TextEditingController();
  final TextEditingController _pwdCtl = TextEditingController();
  final TextEditingController _deviceCtl = TextEditingController();
  final TextEditingController _backupPwdCtl = TextEditingController();

  bool _testing = false;
  bool _saving = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _urlCtl.dispose();
    _userCtl.dispose();
    _pwdCtl.dispose();
    _deviceCtl.dispose();
    _backupPwdCtl.dispose();
    super.dispose();
  }

  Future<String> _resolveConfigDir() async {
    final override = widget.configDirOverride;
    if (override != null) return override;
    // BATCH-18e (F-W2B-022)：走统一的 resolvePersistenceDir。
    return await resolvePersistenceDir();
  }

  Future<void> _loadConfig() async {
    try {
      final dir = await _resolveConfigDir();
      // BATCH-18g (F-W2A-058)：走 json_store 公共 helper 替代 read-modify-write
      // 模板。文件不存在 / 解析失败 → null，与原 if (await f.exists()) 等价。
      final map = await readJsonFile('webdav.json', directory: dir);
      if (map != null) {
        _urlCtl.text = (map['url'] as String?) ?? '';
        _userCtl.text = (map['user'] as String?) ?? '';
        _deviceCtl.text = (map['deviceName'] as String?) ?? '';

        // BATCH-03 (F-W2B-001)：password 字段迁移到 secure_storage。
        // 旧版本写过的 webdav.json 含 password 字段，首次打开本页时一次性
        // 迁到 Keystore-backed 存储并从 webdav.json 移除（保留 url/user/
        // deviceName 3 个非敏感字段不动）。secure_storage 已存在则直接用。
        final legacyPwd = (map['password'] as String?) ?? '';
        final securePwd = await readSecret('webdav_password');
        if (legacyPwd.isNotEmpty && securePwd == null) {
          await writeSecret('webdav_password', legacyPwd);
          await writeJsonFile('webdav.json', {
            'url': map['url'] ?? '',
            'user': map['user'] ?? '',
            'deviceName': map['deviceName'] ?? '',
          }, directory: dir);
          _pwdCtl.text = legacyPwd;
        } else {
          _pwdCtl.text = securePwd ?? '';
        }
      } else {
        // 文件不存在也尝试读 secure_storage（之前用户首次配置过 url 但没保存 /
        // 或仅设了密码的边角场景）。
        _pwdCtl.text = (await readSecret('webdav_password')) ?? '';
      }
      // BATCH-03b (F-W1A-020)：备份密码迁移到 secure_storage。
      // 旧版本 set_backup_password 把字符串写到 legado_local.json 的
      // password 字段；首次打开本页时一次性迁到 Keystore-backed 存储
      // 并从 legado_local.json 移除该字段（保留 .json 文件本身——其它
      // 字段未来扩展可能用，BATCH-23 已加损坏文件 .bak 备份机制）。
      try {
        final securePwd = await readSecret('backup_password');
        if (securePwd != null) {
          _backupPwdCtl.text = securePwd;
        } else {
          // 走旧 FRB 路径读 legado_local.json，如有值则迁移
          final fn = widget.getBackupPasswordOverride ??
              ({required String documentsDir}) =>
                  rust_api.getBackupPassword(documentsDir: documentsDir);
          final legacyPwd = await fn(documentsDir: dir);
          if (legacyPwd.isNotEmpty) {
            await writeSecret('backup_password', legacyPwd);
            // 清理 legado_local.json 中的 password 字段（传空串复用
            // set_backup_password 写路径，BATCH-23 .bak 机制顺带兜底）。
            try {
              final clearFn = widget.setBackupPasswordOverride ??
                  ({required String documentsDir, required String password}) =>
                      rust_api.setBackupPassword(
                          documentsDir: documentsDir, password: password);
              await clearFn(documentsDir: dir, password: '');
            } catch (_) {
              // 清理失败不阻塞迁移；下次启动 secure_storage 命中即可
            }
            _backupPwdCtl.text = legacyPwd;
          } else {
            _backupPwdCtl.text = '';
          }
        }
      } catch (_) {
        // FRB 调用失败（如桥未初始化的测试场景）退回空串。
        _backupPwdCtl.text = '';
      }
    } catch (_) {
      // 静默忽略读取失败 — 用户首次配置时也走这里。
    } finally {
      safeSetState(() => _loaded = true);
    }
  }

  Future<void> _onTestConnection() async {
    if (_testing) return;
    final url = _urlCtl.text.trim();
    final user = _userCtl.text.trim();
    final pwd = _pwdCtl.text;
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先填写 URL')),
      );
      return;
    }
    setState(() => _testing = true);
    try {
      final fn = widget.webdavCheckOverride ??
          ({required String url,
                  required String user,
                  required String password}) =>
              rust_api.webdavCheck(url: url, user: user, password: password);
      await fn(url: url, user: user, password: pwd);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('连接成功')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('连接失败: $e')),
      );
    } finally {
      safeSetState(() => _testing = false);
    }
  }

  Future<void> _onSave() async {
    if (_saving) return;
    final url = _urlCtl.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('URL 不能为空')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final dir = await _resolveConfigDir();
      // BATCH-18g (F-W2A-058)：webdav.json 整文件覆盖式写走 json_store 公共
      // helper。writeJsonFile rethrow 让外层 try-catch 保留 '保存失败' SnackBar。
      // BATCH-03 (F-W2B-001)：password 字段不再写 webdav.json，改 secure_storage。
      await writeJsonFile('webdav.json', {
        'url': url,
        'user': _userCtl.text.trim(),
        'deviceName': _deviceCtl.text.trim(),
      }, directory: dir);
      await writeSecret('webdav_password', _pwdCtl.text);
      // BATCH-03b (F-W1A-020)：备份密码改 secure_storage。
      await writeSecret('backup_password', _backupPwdCtl.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: $e')),
      );
    } finally {
      safeSetState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('WebDAV 配置')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextField(
                  controller: _urlCtl,
                  decoration: const InputDecoration(
                    labelText: 'URL',
                    hintText: 'https://dav.jianguoyun.com/dav/legado/',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _userCtl,
                  decoration: const InputDecoration(
                    labelText: '用户名',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pwdCtl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '密码',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _deviceCtl,
                  decoration: const InputDecoration(
                    labelText: '设备名',
                    hintText: '可选,用作 backup<date>-<deviceName>.zip 后缀',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _backupPwdCtl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '备份密码',
                    helperText:
                        '留空 = 不加密。设密码后导出的 zip 内 servers.json + webDavPassword 走 AES，与原 Legado 兼容。',
                    helperMaxLines: 3,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.tonalIcon(
                        icon: const Icon(Icons.wifi_tethering),
                        label: const Text('测试连接'),
                        onPressed: (_testing || _saving) ? null : _onTestConnection,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        icon: const Icon(Icons.save),
                        label: const Text('保存'),
                        onPressed: (_testing || _saving) ? null : _onSave,
                      ),
                    ),
                  ],
                ),
                if (_testing || _saving)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: LinearProgressIndicator(),
                  ),
              ],
            ),
    );
  }
}
