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
        onPressed: () => _showRuleEditDialog(context),
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

  /// R110: 统一的添加 / 编辑对话框。`existing == null` 时表现等同
  /// 原 `_showAddRuleDialog`（生成新 id）；`existing != null` 时预填
  /// 全部字段、保留原 id / sort_number / created_at / enabled，
  /// 通过 `saveReplaceRule` upsert。
  void _showRuleEditDialog(BuildContext context,
      [Map<String, dynamic>? existing]) {
    final isEdit = existing != null;
    final nameCtrl =
        TextEditingController(text: existing?['name'] as String? ?? '');
    final patternCtrl = TextEditingController(
        text: existing?['pattern'] as String? ?? '');
    final replacementCtrl = TextEditingController(
        text: existing?['replacement'] as String? ?? '');
    final scopeCtrl = TextEditingController(
        text: (existing?['scope'] as String?) ?? '');
    final excludeCtrl = TextEditingController(
        text: (existing?['exclude_scope'] as String?) ?? '');
    // R24 默认值：scope_content=true, scope_title=false。
    bool scopeContent = existing == null
        ? true
        : (existing['scope_content'] != false);
    bool scopeTitle = existing == null
        ? false
        : (existing['scope_title'] == true);

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(isEdit ? '编辑替换规则' : '添加替换规则'),
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
                  // R110: edit 模式复用原 id / sort_number / created_at /
                  // enabled，仅刷新 updated_at；add 模式生成新 id。
                  final id = isEdit
                      ? existing['id'] as String
                      : '${now}_${Random().nextInt(99999)}';
                  final scopeText = scopeCtrl.text.trim();
                  final excludeText = excludeCtrl.text.trim();
                  final ruleJson = jsonEncode({
                    'id': id,
                    'name': name,
                    'pattern': pattern,
                    'replacement': replacementCtrl.text,
                    'enabled':
                        isEdit ? (existing['enabled'] != false) : true,
                    'scope': scopeText.isEmpty ? null : scopeText,
                    'scope_title': scopeTitle,
                    'scope_content': scopeContent,
                    'exclude_scope':
                        excludeText.isEmpty ? null : excludeText,
                    'sort_number': isEdit
                        ? (existing['sort_number'] as int? ?? 0)
                        : 0,
                    'created_at': isEdit
                        ? (existing['created_at'] as int? ?? now)
                        : now,
                    'updated_at': now,
                  });
                  await rust_api.saveReplaceRule(
                      dbPath: dbPath, ruleJson: ruleJson);
                  bumpReplaceRuleGeneration(ref);
                  if (ctx.mounted) Navigator.pop(ctx);
                } catch (e) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(
                          content:
                              Text('${isEdit ? "保存" : "添加"}失败: $e')),
                    );
                  }
                }
              },
              child: Text(isEdit ? '保存' : '添加'),
            ),
          ],
        ),
      ),
    );
  }

  void _showRuleActions(
      BuildContext context, Map<String, dynamic> rule) {
    // R111: 结构化展示完整字段而非仅 pattern，方便用户在不进入编辑
    // 的情况下确认规则配置（scope / exclude_scope / 作用对象）。
    final pattern = rule['pattern'] as String? ?? '';
    final replacement = rule['replacement'] as String? ?? '';
    final scope = (rule['scope'] as String?)?.trim() ?? '';
    final excludeScope =
        (rule['exclude_scope'] as String?)?.trim() ?? '';
    final scopeContent = rule['scope_content'] != false;
    final scopeTitle = rule['scope_title'] == true;
    final targetLabel = scopeContent && scopeTitle
        ? '正文+标题'
        : scopeContent
            ? '正文'
            : scopeTitle
                ? '标题'
                : '（未选）';
    final scopeDisplay = scope.isEmpty ? '全局' : _truncate(scope, 200);
    final excludeDisplay =
        excludeScope.isEmpty ? '无' : _truncate(excludeScope, 200);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(rule['name'] ?? '规则操作'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ruleDetailRow('匹配模式', _truncate(pattern, 200)),
              _ruleDetailRow('替换为',
                  replacement.isEmpty ? '（空）' : _truncate(replacement, 200)),
              _ruleDetailRow('作用范围', scopeDisplay),
              _ruleDetailRow('排除范围', excludeDisplay),
              _ruleDetailRow('作用对象', targetLabel),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _showRuleEditDialog(context, rule);
            },
            child: const Text('编辑'),
          ),
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

  Widget _ruleDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 2),
          SelectableText(value),
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
