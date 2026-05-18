import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../src/rust/api.dart' as rust_api;

/// WebDAV 配置页（批次 11 / 05-19）。
///
/// 让用户填写 WebDAV 服务端 URL、账号、密码、设备名，并提供"测试连接"
/// 按钮调用 [`webdavCheck`] 验证。保存到 `<documentsDir>/webdav.json`，
/// [`backup_page.dart`] 端在"上传到 WebDAV" / "从 WebDAV 恢复" 时
/// 读取此文件取凭据。
///
/// **配置文件格式**：
/// ```json
/// {
///   "url": "https://dav.jianguoyun.com/dav/legado/",
///   "user": "alice@example.com",
///   "password": "...",
///   "deviceName": "Pixel"
/// }
/// ```
///
/// 密码本批次**先存明文**（PRD §"先存明文"），批次 12 加密备份时再补
/// AES 加密。
///
/// **测试钩子**：所有外部 IO（path_provider / FRB 桥）通过 `*Override`
/// 参数注入 fake 实现。生产代码不传 override 时走真实路径。
class WebDavConfigPage extends ConsumerStatefulWidget {
  /// 测试钩子：注入假 documents 目录路径。
  final String? configDirOverride;

  /// 测试钩子：替换 [`webdavCheck`] FRB 调用。
  final Future<void> Function({
    required String url,
    required String user,
    required String password,
  })? webdavCheckOverride;

  const WebDavConfigPage({
    super.key,
    this.configDirOverride,
    this.webdavCheckOverride,
  });

  @override
  ConsumerState<WebDavConfigPage> createState() => _WebDavConfigPageState();
}

class _WebDavConfigPageState extends ConsumerState<WebDavConfigPage> {
  final TextEditingController _urlCtl = TextEditingController();
  final TextEditingController _userCtl = TextEditingController();
  final TextEditingController _pwdCtl = TextEditingController();
  final TextEditingController _deviceCtl = TextEditingController();

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
    super.dispose();
  }

  Future<String> _resolveConfigDir() async {
    final override = widget.configDirOverride;
    if (override != null) return override;
    final docsDir = await getApplicationDocumentsDirectory();
    return docsDir.path;
  }

  Future<void> _loadConfig() async {
    try {
      final dir = await _resolveConfigDir();
      final f = File('$dir/webdav.json');
      if (await f.exists()) {
        final text = await f.readAsString();
        final Map<String, dynamic> map =
            jsonDecode(text) as Map<String, dynamic>;
        _urlCtl.text = (map['url'] as String?) ?? '';
        _userCtl.text = (map['user'] as String?) ?? '';
        _pwdCtl.text = (map['password'] as String?) ?? '';
        _deviceCtl.text = (map['deviceName'] as String?) ?? '';
      }
    } catch (_) {
      // 静默忽略读取失败 — 用户首次配置时也走这里。
    } finally {
      if (mounted) setState(() => _loaded = true);
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
      if (mounted) setState(() => _testing = false);
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
      final f = File('$dir/webdav.json');
      final map = {
        'url': url,
        'user': _userCtl.text.trim(),
        'password': _pwdCtl.text,
        'deviceName': _deviceCtl.text.trim(),
      };
      await f.writeAsString(jsonEncode(map));
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
      if (mounted) setState(() => _saving = false);
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
