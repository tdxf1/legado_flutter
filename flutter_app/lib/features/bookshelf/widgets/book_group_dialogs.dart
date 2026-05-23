import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/colors.dart';
import '../../../core/providers.dart';
import '../../../core/widgets/safe_setstate.dart';
import '../../../src/rust/api.dart' as rust_api;

/// 批次 7：分组管理对话框。
///
/// 列出所有用户自建分组（不含 id=-1 / id=0 虚拟 Tab），支持：
/// - 行内"+"添加新分组（默认 `sort_order = 当前最大 + 1`）
/// - 编辑（铅笔按钮）— 弹小输入框改名
/// - 删除（垃圾桶按钮）— 二次确认后调 deleteBookGroup（Rust 同事务把组内书 group_id 重置为 0）
///
/// 排序调整、封面、show 开关等高级特性留后续批次（批次 7 PRD Out of Scope）。
class GroupManageDialog extends ConsumerStatefulWidget {
  const GroupManageDialog({super.key});

  @override
  ConsumerState<GroupManageDialog> createState() => _GroupManageDialogState();
}

class _GroupManageDialogState extends ConsumerState<GroupManageDialog> {
  final _addController = TextEditingController();

  @override
  void dispose() {
    _addController.dispose();
    super.dispose();
  }

  Future<String> _dbPath() => ref.read(dbPathProvider.future);

  Future<void> _addGroup() async {
    final name = _addController.text.trim();
    if (name.isEmpty) return;
    try {
      final groups = await ref.read(bookGroupsProvider.future);
      // sort_order 取当前最大 + 1，让新分组追加到最后；
      // 若没有任何分组则从 0 开始。
      final nextSort = groups.isEmpty
          ? 0
          : (groups
                  .map((g) => (g['sort_order'] as int?) ?? 0)
                  .reduce((a, b) => a > b ? a : b)) +
              1;
      final dbPath = await _dbPath();
      await rust_api.createBookGroup(
        dbPath: dbPath,
        name: name,
        sortOrder: nextSort,
      );
      _addController.clear();
      ref.invalidate(bookGroupsProvider);
      safeSetState(() {});
    } catch (e) {
      _showError('创建分组失败: $e');
    }
  }

  Future<void> _renameGroup(Map<String, dynamic> group) async {
    final controller = TextEditingController(
      text: group['name'] as String? ?? '',
    );
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名分组'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '新名字'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newName == null || newName.isEmpty) return;
    try {
      final dbPath = await _dbPath();
      await rust_api.updateBookGroup(
        dbPath: dbPath,
        id: (group['id'] as num).toInt(),
        name: newName,
        sortOrder: (group['sort_order'] as int?) ?? 0,
      );
      ref.invalidate(bookGroupsProvider);
      safeSetState(() {});
    } catch (e) {
      _showError('更新分组失败: $e');
    }
  }

  Future<void> _deleteGroup(Map<String, dynamic> group) async {
    final name = group['name'] as String? ?? '未命名分组';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定删除分组《$name》吗？\n组内书籍会自动回到"未分组"。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('删除', style: TextStyle(color: context.al.destructive)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final dbPath = await _dbPath();
      await rust_api.deleteBookGroup(
        dbPath: dbPath,
        id: (group['id'] as num).toInt(),
      );
      ref.invalidate(bookGroupsProvider);
      // 删分组后书的 group_id 被重置为 0，需要刷新所有 group tab 的列表
      ref.invalidate(booksByGroupProvider);
      safeSetState(() {});
    } catch (e) {
      _showError('删除分组失败: $e');
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final groupsAsync = ref.watch(bookGroupsProvider);

    return AlertDialog(
      title: const Text('管理分组'),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(
              child: groupsAsync.when(
                data: (groups) {
                  if (groups.isEmpty) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('还没有分组，下面输入名字添加第一个吧'),
                      ),
                    );
                  }
                  return ListView.builder(
                    shrinkWrap: true,
                    itemCount: groups.length,
                    itemBuilder: (context, index) {
                      final g = groups[index];
                      return ListTile(
                        title: Text(g['name'] as String? ?? '未命名'),
                        subtitle: Text('排序: ${g['sort_order'] ?? 0}'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit, size: 20),
                              tooltip: '重命名',
                              onPressed: () => _renameGroup(g),
                            ),
                            IconButton(
                              icon: Icon(Icons.delete_outline,
                                  size: 20, color: context.al.destructive),
                              tooltip: '删除',
                              onPressed: () => _deleteGroup(g),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('加载失败: $e')),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _addController,
                      decoration: const InputDecoration(
                        hintText: '新分组名',
                        isDense: true,
                      ),
                      onSubmitted: (_) => _addGroup(),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle),
                    tooltip: '添加',
                    onPressed: _addGroup,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// 批次 7：分组选择对话框。长按书架某本书"移动到分组"时弹出。
///
/// 选项：
/// - "未分组"（id=0）— 永远第一个，不可删除（虚拟分组）
/// - 用户自建分组（id >= 1）— 来自 [bookGroupsProvider]
///
/// `currentGroupId` 用来高亮当前归属（视觉提示，不限制操作）。
/// 用户选完点确定后，把选中的 group_id 通过 [Navigator.pop] 返回。
class GroupSelectDialog extends ConsumerStatefulWidget {
  final int currentGroupId;

  const GroupSelectDialog({super.key, required this.currentGroupId});

  @override
  ConsumerState<GroupSelectDialog> createState() => _GroupSelectDialogState();
}

class _GroupSelectDialogState extends ConsumerState<GroupSelectDialog> {
  late int _selectedGroupId;

  @override
  void initState() {
    super.initState();
    _selectedGroupId = widget.currentGroupId;
  }

  @override
  Widget build(BuildContext context) {
    final groupsAsync = ref.watch(bookGroupsProvider);

    return AlertDialog(
      title: const Text('移动到分组'),
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      content: SizedBox(
        width: double.maxFinite,
        child: groupsAsync.when(
          data: (groups) {
            // 列表第一项永远是"未分组"虚拟分组（id=0）
            final items = <_GroupItem>[
              const _GroupItem(id: 0, name: '未分组'),
              ...groups.map((g) => _GroupItem(
                    id: (g['id'] as num).toInt(),
                    name: g['name'] as String? ?? '未命名',
                  )),
            ];
            return ListView.builder(
              shrinkWrap: true,
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                final selected = item.id == _selectedGroupId;
                // Flutter 3.32 后 RadioListTile 的 groupValue/onChanged 已弃用，
                // 但 RadioGroup 暂时不通用且嵌套在 AlertDialog 里需要更多脚手架。
                // 这里改用 ListTile + 尾部 check icon 自己实现"单选"语义，
                // 行为与 Radio 等价（点行选中），UI 上更接近 Material 3 推荐
                // 的"single-select list"模式。
                return ListTile(
                  title: Text(item.name),
                  trailing: selected
                      ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
                      : null,
                  onTap: () => setState(() => _selectedGroupId = item.id),
                );
              },
            );
          },
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Padding(
            padding: const EdgeInsets.all(16),
            child: Text('加载失败: $e'),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_selectedGroupId),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

class _GroupItem {
  final int id;
  final String name;
  const _GroupItem({required this.id, required this.name});
}
