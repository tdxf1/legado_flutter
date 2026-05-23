import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/colors.dart';
import '../../core/providers.dart';
import '../../core/util/platform_int64.dart';
import '../../src/rust/api.dart' as rust_api;

/// 订阅源页（批次 19 / 05-19）。
///
/// 对应原 Legado `RuleSubActivity` MVP — 用户配 1 个 URL，一键拉取
/// 最新规则 JSON 列表合并入库（书源 / RSS 源 / 替换规则）。
///
/// UI 风格沿袭 [RssSourceManagePage]：
/// - AppBar(title: "订阅源"), actions = [刷新全部 + 添加]
/// - ListView 渲染 [RuleSub]：
///   - leading icon：sub_type 0=Icons.source / 1=Icons.rss_feed /
///     2=Icons.find_replace
///   - title: name
///   - subtitle: url + " · " + sub_type 标签 (书源 / RSS / 替换规则)
///   - 长按 PopupMenu → 编辑 / 删除
///   - 点击 → 单条刷新 → SnackBar 汇总
/// - 空态："暂无订阅源，点右上角添加"
///
/// 测试钩子（与批次 16/17/18 同模式）：
/// - `dbPathOverride` 注入假 dbPath
/// - `recordsOverride` 注入假 RuleSub 列表，绕过 FRB
/// - `createOverride / updateOverride / deleteOverride / refreshOverride
///    / refreshAllOverride` 注入假 FRB 调用
class RuleSubPage extends ConsumerStatefulWidget {
  /// 测试钩子：注入假 dbPath。
  final String? dbPathOverride;

  /// 测试钩子：注入假 RuleSub map 列表（每条至少含 id/name/url/sub_type）。
  final List<Map<String, dynamic>>? recordsOverride;

  /// 测试钩子：注入假 create FRB 调用，返回 RuleSub JSON。
  final Future<String> Function(
      String dbPath, String name, String url, int subType)? createOverride;

  /// 测试钩子：注入假 update FRB 调用。
  final Future<int> Function(
      String dbPath, String id, String name, String url, int subType)?
      updateOverride;

  /// 测试钩子：注入假 delete FRB 调用。
  final Future<int> Function(String dbPath, String id)? deleteOverride;

  /// 测试钩子：注入假 refresh FRB 调用。
  final Future<String> Function(String dbPath, String id)? refreshOverride;

  /// 测试钩子：注入假 refreshAll FRB 调用。
  final Future<String> Function(String dbPath)? refreshAllOverride;

  const RuleSubPage({
    super.key,
    this.dbPathOverride,
    this.recordsOverride,
    this.createOverride,
    this.updateOverride,
    this.deleteOverride,
    this.refreshOverride,
    this.refreshAllOverride,
  });

  @override
  ConsumerState<RuleSubPage> createState() => _RuleSubPageState();
}

class _RuleSubPageState extends ConsumerState<RuleSubPage> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _records = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      if (widget.recordsOverride != null) {
        if (!mounted) return;
        setState(() {
          _records = widget.recordsOverride!;
          _loading = false;
        });
        return;
      }
      final String dbPath =
          widget.dbPathOverride ?? await ref.read(dbPathProvider.future);
      final json = await rust_api.ruleSubListAll(dbPath: dbPath);
      final List<dynamic> raw = jsonDecode(json);
      final records = raw.cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        _records = records;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  String _subTypeLabel(int subType) {
    switch (subType) {
      case 0:
        return '书源';
      case 1:
        return 'RSS';
      case 2:
        return '替换规则';
      default:
        return '未知';
    }
  }

  IconData _subTypeIcon(int subType) {
    switch (subType) {
      case 0:
        return Icons.source;
      case 1:
        return Icons.rss_feed;
      case 2:
        return Icons.find_replace;
      default:
        return Icons.help_outline;
    }
  }

  Future<int> _resolveDeleteFn(String dbPath, String id) async {
    final fn = widget.deleteOverride ??
        (String db, String i) async {
          final n = await rust_api.ruleSubDelete(dbPath: db, id: i);
          return platformInt64ToInt(n);
        };
    return fn(dbPath, id);
  }

  Future<int> _resolveUpdateFn(
      String dbPath, String id, String name, String url, int subType) async {
    final fn = widget.updateOverride ??
        (String db, String i, String n, String u, int t) async {
          final res = await rust_api.ruleSubUpdate(
              dbPath: db, id: i, name: n, url: u, subType: t);
          return platformInt64ToInt(res);
        };
    return fn(dbPath, id, name, url, subType);
  }

  Future<void> _onAdd() async {
    final result = await _showEditDialog(
      title: '添加订阅源',
      initialName: '',
      initialUrl: '',
      initialSubType: 0,
    );
    if (result == null) return;
    if (!mounted) return;
    try {
      final String dbPath =
          widget.dbPathOverride ?? await ref.read(dbPathProvider.future);
      final fn = widget.createOverride ??
          (String db, String n, String u, int t) =>
              rust_api.ruleSubCreate(dbPath: db, name: n, url: u, subType: t);
      await fn(dbPath, result.name, result.url, result.subType);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已添加《${result.name}》')),
      );
      setState(() => _loading = true);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('添加失败: $e')),
      );
    }
  }

  Future<void> _onEdit(Map<String, dynamic> record) async {
    final id = record['id'] as String? ?? '';
    if (id.isEmpty) return;
    final result = await _showEditDialog(
      title: '编辑订阅源',
      initialName: record['name'] as String? ?? '',
      initialUrl: record['url'] as String? ?? '',
      initialSubType: (record['sub_type'] as num?)?.toInt() ?? 0,
    );
    if (result == null) return;
    if (!mounted) return;
    try {
      final String dbPath =
          widget.dbPathOverride ?? await ref.read(dbPathProvider.future);
      await _resolveUpdateFn(
          dbPath, id, result.name, result.url, result.subType);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已更新《${result.name}》')),
      );
      setState(() => _loading = true);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('更新失败: $e')),
      );
    }
  }

  Future<void> _onDelete(Map<String, dynamic> record) async {
    final id = record['id'] as String? ?? '';
    final name = record['name'] as String? ?? '未知';
    if (id.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除订阅源'),
        content: Text('确定要删除《$name》吗？\n\n该操作只删除订阅条目，已导入的书源/RSS 源不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('确定删除', style: TextStyle(color: context.al.destructive)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    try {
      final String dbPath =
          widget.dbPathOverride ?? await ref.read(dbPathProvider.future);
      final affected = await _resolveDeleteFn(dbPath, id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(affected > 0 ? '已删除《$name》' : '未找到订阅源')),
      );
      setState(() => _loading = true);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败: $e')),
      );
    }
  }

  Future<void> _onRefreshOne(Map<String, dynamic> record) async {
    final id = record['id'] as String? ?? '';
    final name = record['name'] as String? ?? '未知';
    if (id.isEmpty) return;
    if (!mounted) return;
    // 先弹一条"正在刷新"
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(content: Text('正在刷新《$name》...')));
    try {
      final String dbPath =
          widget.dbPathOverride ?? await ref.read(dbPathProvider.future);
      final fn = widget.refreshOverride ??
          (String db, String i) => rust_api.ruleSubRefresh(dbPath: db, id: i);
      final json = await fn(dbPath, id);
      final summary = _formatRefreshResult(json);
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text('《$name》: $summary')));
    } catch (e) {
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text('《$name》刷新失败: $e')));
    }
  }

  Future<void> _onRefreshAll() async {
    if (_records.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂无订阅源')),
      );
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('正在刷新全部订阅源...')));
    try {
      final String dbPath =
          widget.dbPathOverride ?? await ref.read(dbPathProvider.future);
      final fn = widget.refreshAllOverride ??
          (String db) => rust_api.ruleSubRefreshAll(dbPath: db);
      final json = await fn(dbPath);
      final List<dynamic> raw = jsonDecode(json);
      final results = raw.cast<Map<String, dynamic>>();
      final ok = results.where((r) => r['ok'] == true).length;
      final fail = results.length - ok;
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
          content: Text('刷新完成：成功 $ok 个，失败 $fail 个')));
    } catch (e) {
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger
          .showSnackBar(SnackBar(content: Text('全部刷新失败: $e')));
    }
  }

  /// 根据 [`rule_sub_refresh`] 返回 JSON 提炼一行人类可读的摘要。
  String _formatRefreshResult(String json) {
    try {
      final Map<String, dynamic> map = jsonDecode(json) as Map<String, dynamic>;
      if (map['error'] != null) {
        return map['error'].toString();
      }
      if (map['count'] != null) {
        return '已导入 ${map['count']} 个书源';
      }
      if (map['summary'] is Map) {
        final s = map['summary'] as Map<String, dynamic>;
        final added = (s['added'] as num?)?.toInt() ?? 0;
        final updated = (s['updated'] as num?)?.toInt() ?? 0;
        final skipped = (s['skipped'] as num?)?.toInt() ?? 0;
        return 'RSS 源：新增 $added，更新 $updated，跳过 $skipped';
      }
      return '已刷新';
    } catch (_) {
      return '已刷新';
    }
  }

  Future<_EditResult?> _showEditDialog({
    required String title,
    required String initialName,
    required String initialUrl,
    required int initialSubType,
  }) async {
    final nameController = TextEditingController(text: initialName);
    final urlController = TextEditingController(text: initialUrl);
    int subType = initialSubType;
    return showDialog<_EditResult>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setLocal) {
          return AlertDialog(
            title: Text(title),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: '名称',
                      hintText: '示例订阅',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: urlController,
                    decoration: const InputDecoration(
                      labelText: 'URL',
                      hintText: 'https://example.com/sub.json',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('类型', style: Theme.of(ctx).textTheme.bodyMedium),
                  // 用 ListTile + trailing check 实现单选（与
                  // bookshelf_page._showSortDialog / GroupSelectDialog
                  // 同模式，避免 Flutter 3.32 后 RadioListTile 的弃用警告）。
                  for (final entry in const <int, String>{
                    0: '书源',
                    1: 'RSS 源',
                    2: '替换规则',
                  }.entries)
                    ListTile(
                      title: Text(entry.value),
                      leading: Icon(_subTypeIcon(entry.key)),
                      trailing: entry.key == subType
                          ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
                          : null,
                      onTap: () => setLocal(() => subType = entry.key),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  final name = nameController.text.trim();
                  final url = urlController.text.trim();
                  if (name.isEmpty || url.isEmpty) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('名称 / URL 不能为空')),
                    );
                    return;
                  }
                  Navigator.pop(
                      ctx, _EditResult(name: name, url: url, subType: subType));
                },
                child: const Text('确定'),
              ),
            ],
          );
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('订阅源'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新全部',
            onPressed: _onRefreshAll,
          ),
          // 批次 20 (05-19): QR 扫码导入。补充入口，原添加按钮保留。
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: '扫码导入',
            onPressed: () => context.push('/qr-scan'),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '添加',
            onPressed: _onAdd,
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text('加载失败: $_error'));
    }
    if (_records.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_sync_outlined,
                size: 56, color: Theme.of(context).disabledColor),
            const SizedBox(height: 12),
            const Text('暂无订阅源'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _onAdd,
              icon: const Icon(Icons.add),
              label: const Text('添加订阅源'),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      itemCount: _records.length,
      itemBuilder: (context, i) => _buildTile(context, _records[i]),
    );
  }

  Widget _buildTile(BuildContext context, Map<String, dynamic> record) {
    final name = record['name'] as String? ?? '未知';
    final url = record['url'] as String? ?? '';
    final subType = (record['sub_type'] as num?)?.toInt() ?? 0;
    return ListTile(
      leading: Icon(_subTypeIcon(subType)),
      title: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '$url · ${_subTypeLabel(subType)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => _onRefreshOne(record),
      trailing: PopupMenuButton<String>(
        tooltip: '操作',
        onSelected: (value) {
          if (value == 'edit') {
            _onEdit(record);
          } else if (value == 'delete') {
            _onDelete(record);
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            value: 'edit',
            child: ListTile(
              leading: Icon(Icons.edit_outlined),
              title: Text('编辑'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          PopupMenuItem(
            value: 'delete',
            child: ListTile(
              leading: Icon(Icons.delete_outline, color: context.al.destructive),
              title: Text('删除', style: TextStyle(color: context.al.destructive)),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
  }
}

/// 编辑 dialog 返回的临时数据载体。
class _EditResult {
  final String name;
  final String url;
  final int subType;
  const _EditResult({
    required this.name,
    required this.url,
    required this.subType,
  });
}
