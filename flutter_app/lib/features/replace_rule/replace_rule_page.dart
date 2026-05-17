import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../src/rust/api.dart' as rust_api;

/// R24: 进程级标志位，避免在同一次 app 运行内重复显示迁移说明。
/// 不持久化（不靠 SharedPreferences）— 每次启动 app 重新提示一次，
/// 这是有意为之的弱提示，确保关心的用户能注意到。
bool _r24NoticeShown = false;

class ReplaceRulePage extends ConsumerStatefulWidget {
  const ReplaceRulePage({super.key});

  @override
  ConsumerState<ReplaceRulePage> createState() => _ReplaceRulePageState();
}

class _ReplaceRulePageState extends ConsumerState<ReplaceRulePage> {
  @override
  void initState() {
    super.initState();
    // R24: 提示 schema 已升级、原"作用范围"信息已重置为全局。
    if (!_r24NoticeShown) {
      _r24NoticeShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '替换规则功能已升级（v10）。原"作用范围"信息已重置为全局，'
              '可在编辑规则里填写书名或书源 URL 重新限定。',
            ),
            duration: Duration(seconds: 8),
          ),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final rulesAsync = ref.watch(allReplaceRulesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('替换规则'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(allReplaceRulesProvider),
          ),
        ],
      ),
      body: rulesAsync.when(
        data: (rules) => _buildRuleList(context, rules),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddRuleDialog(context),
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildRuleList(
      BuildContext context, List<Map<String, dynamic>> rules) {
    if (rules.isEmpty) {
      return const Center(child: Text('暂无替换规则，点击右下角添加'));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: rules.length,
      itemBuilder: (context, index) {
        final rule = rules[index];
        final enabled = rule['enabled'] == true;
        // R24: scope 现在是 Option<String> — 子串匹配 book.name 或
        // book.origin。空 / null 表示全局。
        final scope = (rule['scope'] as String?)?.trim() ?? '';
        final scopeContent = rule['scope_content'] != false;
        final scopeTitle = rule['scope_title'] == true;
        final excludeScope =
            (rule['exclude_scope'] as String?)?.trim() ?? '';
        final scopeLabel =
            scope.isEmpty ? '全局' : '范围: ${_truncate(scope, 20)}';
        final targetLabel = [
          if (scopeContent) '正文',
          if (scopeTitle) '标题',
        ].join('+');
        final excludeLabel = excludeScope.isEmpty
            ? ''
            : '  排除: ${_truncate(excludeScope, 16)}';
        return Card(
          child: ListTile(
            leading: Icon(
              enabled ? Icons.check_circle : Icons.cancel,
              color: enabled ? Colors.green : Colors.grey,
            ),
            title: Text(rule['name'] ?? '未命名规则'),
            subtitle: Text(
              '${rule['pattern'] ?? ''} → ${rule['replacement'] ?? ''}\n'
              '[$scopeLabel] [$targetLabel]$excludeLabel',
            ),
            isThreeLine: true,
            trailing: Switch(
              value: enabled,
              onChanged: (val) =>
                  _toggleRule(rule['id'] as String, val),
            ),
            onTap: () => _showRuleActions(context, rule),
          ),
        );
      },
    );
  }

  String _truncate(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';

  Future<void> _toggleRule(String id, bool enabled) async {
    try {
      await ref.read(dbInitializedProvider.future);
      final dbPath = await ref.read(dbPathProvider.future);
      await rust_api.setReplaceRuleEnabled(
          dbPath: dbPath, id: id, enabled: enabled);
      bumpReplaceRuleGeneration(ref);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败: $e')),
        );
      }
    }
  }

  void _showAddRuleDialog(BuildContext context) {
    final nameCtrl = TextEditingController();
    final patternCtrl = TextEditingController();
    final replacementCtrl = TextEditingController();
    final scopeCtrl = TextEditingController();
    final excludeCtrl = TextEditingController();
    bool scopeContent = true;
    bool scopeTitle = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('添加替换规则'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: '规则名称'),
                ),
                TextField(
                  controller: patternCtrl,
                  decoration: const InputDecoration(
                      labelText: '匹配模式 (正则)'),
                ),
                TextField(
                  controller: replacementCtrl,
                  decoration:
                      const InputDecoration(labelText: '替换文本'),
                ),
                const SizedBox(height: 8),
                // R24: scope 改为自由文本，对齐原 Legado UI（"选填
                // 书名或书源 URL"）。子串匹配，留空 = 全局。
                TextField(
                  controller: scopeCtrl,
                  decoration: const InputDecoration(
                    labelText: '作用范围',
                    helperText: '选填书名或书源 URL，留空 = 全局；多个用空格分隔',
                  ),
                ),
                TextField(
                  controller: excludeCtrl,
                  decoration: const InputDecoration(
                    labelText: '排除范围',
                    helperText: '选填书名或书源 URL，命中即跳过',
                  ),
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('作用于正文'),
                  value: scopeContent,
                  onChanged: (v) =>
                      setDialogState(() => scopeContent = v ?? true),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('作用于章节标题'),
                  value: scopeTitle,
                  onChanged: (v) =>
                      setDialogState(() => scopeTitle = v ?? false),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                final name = nameCtrl.text.trim();
                final pattern = patternCtrl.text.trim();
                if (name.isEmpty || pattern.isEmpty) return;
                try {
                  await ref.read(dbInitializedProvider.future);
                  final dbPath = await ref.read(dbPathProvider.future);
                  final now =
                      DateTime.now().millisecondsSinceEpoch ~/ 1000;
                  final id = '${now}_${Random().nextInt(99999)}';
                  final scopeText = scopeCtrl.text.trim();
                  final excludeText = excludeCtrl.text.trim();
                  final ruleJson = jsonEncode({
                    'id': id,
                    'name': name,
                    'pattern': pattern,
                    'replacement': replacementCtrl.text,
                    'enabled': true,
                    'scope': scopeText.isEmpty ? null : scopeText,
                    'scope_title': scopeTitle,
                    'scope_content': scopeContent,
                    'exclude_scope':
                        excludeText.isEmpty ? null : excludeText,
                    'sort_number': 0,
                    'created_at': now,
                    'updated_at': now,
                  });
                  await rust_api.saveReplaceRule(
                      dbPath: dbPath, ruleJson: ruleJson);
                  bumpReplaceRuleGeneration(ref);
                  if (ctx.mounted) Navigator.pop(ctx);
                } catch (e) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(content: Text('添加失败: $e')),
                    );
                  }
                }
              },
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
  }

  void _showRuleActions(
      BuildContext context, Map<String, dynamic> rule) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(rule['name'] ?? '规则操作'),
        content: Text(rule['pattern'] ?? ''),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _deleteRule(rule['id'] as String);
            },
            child:
                const Text('删除', style: TextStyle(color: Colors.red)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteRule(String id) async {
    try {
      await ref.read(dbInitializedProvider.future);
      final dbPath = await ref.read(dbPathProvider.future);
      await rust_api.deleteReplaceRule(dbPath: dbPath, id: id);
      bumpReplaceRuleGeneration(ref);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('规则已删除')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: $e')),
        );
      }
    }
  }
}
