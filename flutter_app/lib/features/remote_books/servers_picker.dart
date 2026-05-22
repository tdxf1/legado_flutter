import 'package:flutter/material.dart';

import 'remote_servers.dart';

/// BATCH-27c-2 (05-22): 远程书 server 切换 + CRUD UI。
///
/// 对齐 legado `ServersDialog` (`legado/.../ServersDialog.kt:166`)：
/// 列出「默认」+ N server，单选 + edit/delete trailing；底部「+ 新建」。
///
/// 使用方式（来自 RemoteBooksPage AppBar IconButton）：
/// ```dart
/// final picked = await showServersBottomSheet(
///   context: ctx,
///   servers: ref.read(remoteServersProvider),
///   selectedId: ref.read(selectedRemoteServerIdProvider),
///   onCreate: (server, password) async { ... },
///   onUpdate: (server, password) async { ... },
///   onDelete: (server) async { ... },
/// );
/// if (picked != null) {
///   ref.read(selectedRemoteServerIdProvider.notifier).state = picked;
/// }
/// ```
///
/// 返回值是用户最终选择的 serverId（可能是 [`kDefaultRemoteServerId`]
/// 即 -1 = 默认 / >0 = 某 server id）；用户取消时返回 null。
///
/// **不持久化**（仅返回选中 id）— caller 决定是否调
/// `saveSelectedRemoteServerIdToDisk`。
Future<int?> showServersBottomSheet({
  required BuildContext context,
  required List<RemoteServer> servers,
  required int selectedId,
  required Future<void> Function(RemoteServer server, String password)
      onCreate,
  required Future<void> Function(RemoteServer server, String? password)
      onUpdate,
  required Future<void> Function(RemoteServer server) onDelete,
}) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _ServersBottomSheet(
      servers: servers,
      selectedId: selectedId,
      onCreate: onCreate,
      onUpdate: onUpdate,
      onDelete: onDelete,
    ),
  );
}

class _ServersBottomSheet extends StatefulWidget {
  final List<RemoteServer> servers;
  final int selectedId;
  final Future<void> Function(RemoteServer server, String password) onCreate;
  final Future<void> Function(RemoteServer server, String? password) onUpdate;
  final Future<void> Function(RemoteServer server) onDelete;

  const _ServersBottomSheet({
    required this.servers,
    required this.selectedId,
    required this.onCreate,
    required this.onUpdate,
    required this.onDelete,
  });

  @override
  State<_ServersBottomSheet> createState() => _ServersBottomSheetState();
}

class _ServersBottomSheetState extends State<_ServersBottomSheet> {
  late List<RemoteServer> _servers;

  @override
  void initState() {
    super.initState();
    _servers = List<RemoteServer>.from(widget.servers);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '选择 WebDAV 服务器',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  // 「默认」行（id=-1）始终在最前；不可 edit / delete。
                  ListTile(
                    leading: Icon(
                      widget.selectedId == kDefaultRemoteServerId
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                    ),
                    title: const Text('默认'),
                    subtitle: const Text('使用「设置 → WebDAV」配置的凭据'),
                    onTap: () =>
                        Navigator.of(context).pop(kDefaultRemoteServerId),
                  ),
                  for (final s in _servers)
                    ListTile(
                      leading: Icon(
                        widget.selectedId == s.id
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                      ),
                      title: Text(s.name.isEmpty ? '(未命名)' : s.name),
                      subtitle: Text(s.url, maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => Navigator.of(context).pop(s.id),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            tooltip: '编辑',
                            onPressed: () => _onEdit(s),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: '删除',
                            onPressed: () => _onDelete(s),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('新建 WebDAV 服务器'),
              onPressed: _onCreate,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onCreate() async {
    final result = await showDialog<_ServerEditResult>(
      context: context,
      builder: (ctx) => const _ServerEditDialog(),
    );
    if (result == null) return;
    final id = DateTime.now().millisecondsSinceEpoch;
    final server = RemoteServer(
      id: id,
      name: result.name,
      url: result.url,
      user: result.user,
    );
    try {
      await widget.onCreate(server, result.password ?? '');
      if (!mounted) return;
      setState(() => _servers = [..._servers, server]);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('新建失败: $e')),
      );
    }
  }

  Future<void> _onEdit(RemoteServer s) async {
    final result = await showDialog<_ServerEditResult>(
      context: context,
      builder: (ctx) => _ServerEditDialog(initial: s),
    );
    if (result == null) return;
    final updated = s.copyWith(
      name: result.name,
      url: result.url,
      user: result.user,
    );
    try {
      // password=null 表示「不改」（用户留空），caller 走分支决定是否写
      // secure_storage。
      await widget.onUpdate(updated, result.password);
      if (!mounted) return;
      setState(() {
        _servers =
            _servers.map((e) => e.id == updated.id ? updated : e).toList();
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: $e')),
      );
    }
  }

  Future<void> _onDelete(RemoteServer s) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除服务器？'),
        content: Text('「${s.name.isEmpty ? '(未命名)' : s.name}」将被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.onDelete(s);
      if (!mounted) return;
      setState(() {
        _servers = _servers.where((e) => e.id != s.id).toList();
      });
      // 删除当前选中 server → 提示并 fallback。caller (onDelete impl)
      // 已写 selectedRemoteServerId = -1 + saveSelectedRemoteServerIdToDisk，
      // BottomSheet 不主动 pop（让用户继续选）。
      if (s.id == widget.selectedId) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已切回默认服务器')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败: $e')),
      );
    }
  }
}

/// 内部 result 容器：仅用于 _ServerEditDialog 返回值。`password = null`
/// 表示「编辑场景下用户没改密码」（caller 不写 secure_storage）；空串
/// 表示「明确清空」。
class _ServerEditResult {
  final String name;
  final String url;
  final String user;
  final String? password;

  const _ServerEditResult({
    required this.name,
    required this.url,
    required this.user,
    required this.password,
  });
}

class _ServerEditDialog extends StatefulWidget {
  final RemoteServer? initial;
  const _ServerEditDialog({this.initial});

  @override
  State<_ServerEditDialog> createState() => _ServerEditDialogState();
}

class _ServerEditDialogState extends State<_ServerEditDialog> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _user;
  final TextEditingController _password = TextEditingController();
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _name = TextEditingController(text: i?.name ?? '');
    _url = TextEditingController(text: i?.url ?? '');
    _user = TextEditingController(text: i?.user ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.initial != null;
    return AlertDialog(
      title: Text(isEdit ? '编辑服务器' : '新建服务器'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            TextField(
              controller: _url,
              decoration: const InputDecoration(
                labelText: 'URL',
                hintText: 'https://dav.example.com/legado/',
              ),
            ),
            TextField(
              controller: _user,
              decoration: const InputDecoration(labelText: '用户名'),
            ),
            TextField(
              controller: _password,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: isEdit ? '密码（留空不修改）' : '密码',
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscure ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final name = _name.text.trim();
            final url = _url.text.trim();
            final user = _user.text.trim();
            final pwd = _password.text;
            if (url.isEmpty || user.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('URL 与用户名必填')),
              );
              return;
            }
            if (!isEdit && pwd.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('密码必填')),
              );
              return;
            }
            Navigator.of(context).pop(
              _ServerEditResult(
                name: name,
                url: url,
                user: user,
                // 编辑场景：留空 = null 不改密码
                password: isEdit && pwd.isEmpty ? null : pwd,
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
