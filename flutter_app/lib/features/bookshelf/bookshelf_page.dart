import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:io';

import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../src/rust/api.dart' as rust_api;
import 'widgets/book_group_dialogs.dart';

/// 书架页（批次 7：加分组 TabBar）。
///
/// AppBar.bottom = TabBar：第 0 Tab "全部"(group_id=-1) + 第 1 Tab "未分组"
/// (group_id=0) + 用户分组（来自 [bookGroupsProvider]）。每个 Tab 调
/// [booksByGroupProvider](groupId) 拿对应书列表。
///
/// 长按书条 → 底部 Sheet：删除 / 移动到分组（[GroupSelectDialog]）。
/// AppBar 菜单 → 管理分组（[GroupManageDialog]）。
class BookshelfPage extends ConsumerStatefulWidget {
  const BookshelfPage({super.key});

  @override
  ConsumerState<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends ConsumerState<BookshelfPage> {
  bool _isGridView = false;

  @override
  void initState() {
    super.initState();
    loadBookshelfGridViewFromDisk().then((value) {
      if (mounted) setState(() => _isGridView = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final groupsAsync = ref.watch(bookGroupsProvider);
    // 批次 8: 全局监听排序方式；切换排序后下方所有 Tab 都会重新拉书。
    final sortOrder = ref.watch(bookshelfSortProvider);

    return groupsAsync.when(
      // 错误 / loading 时仍展示 TabBar 骨架（只有"全部"+"未分组"两个虚拟 Tab），
      // 避免分组拉取失败导致整页都进不去。
      loading: () => _buildScaffold(context, const [], sortOrder),
      error: (e, _) => _buildScaffold(context, const [], sortOrder),
      data: (groups) => _buildScaffold(context, groups, sortOrder),
    );
  }

  Widget _buildScaffold(BuildContext context,
      List<Map<String, dynamic>> groups, int sortOrder) {
    // Tab 总数 = 2 (全部 + 未分组) + N 个用户分组。
    // ValueKey 让用户分组数变化时 DefaultTabController 重建，避免 controller
    // 长度不匹配抛 assertion。
    final tabSpec = <_TabSpec>[
      const _TabSpec(label: '全部', groupId: -1),
      const _TabSpec(label: '未分组', groupId: 0),
      for (final g in groups)
        _TabSpec(
          label: g['name'] as String? ?? '未命名',
          groupId: (g['id'] as num).toInt(),
        ),
    ];

    return DefaultTabController(
      key: ValueKey(tabSpec.length),
      length: tabSpec.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('书架'),
          actions: [
            IconButton(
              icon: Icon(_isGridView ? Icons.view_list : Icons.grid_view),
              tooltip: _isGridView ? '列表视图' : '网格视图',
              onPressed: () {
                setState(() => _isGridView = !_isGridView);
                saveBookshelfGridViewToDisk(_isGridView);
              },
            ),
            // 批次 8 (05-19): 排序按钮。打开 6 选 RadioListTile 对话框，选完
            // 通过 [readerSettingsProvider] 持久化，让 [bookshelfSortProvider]
            // 自动派生新值并触发各 Tab 重新拉书。
            IconButton(
              icon: const Icon(Icons.sort),
              tooltip: '书架排序',
              onPressed: () => _showSortDialog(context),
            ),
            PopupMenuButton<String>(
              tooltip: '更多',
              onSelected: (value) async {
                if (value == 'manage_groups') {
                  await showDialog(
                    context: context,
                    builder: (_) => const GroupManageDialog(),
                  );
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'manage_groups',
                  child: ListTile(
                    leading: Icon(Icons.folder_outlined),
                    title: Text('管理分组'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ],
          bottom: TabBar(
            isScrollable: true,
            tabs: [for (final t in tabSpec) Tab(text: t.label)],
          ),
        ),
        body: TabBarView(
          children: [
            for (final t in tabSpec)
              _BookListView(
                groupId: t.groupId,
                sortOrder: sortOrder,
                isGridView: _isGridView,
              )
          ],
        ),
      ),
    );
  }

  /// 批次 8 (05-19): 排序选择对话框。点 AppBar `Icons.sort` 按钮触发，
  /// 选中后写回 [readerSettingsProvider] 并落盘 [saveReaderSettingsToDisk]。
  /// `bookshelfSortProvider` 是从 readerSettings 派生的 Provider，state 一变
  /// 各 Tab 的 [booksByGroupProvider]`((groupId, sort))` 自然换 key 触发重拉。
  ///
  /// UI 用 ListTile + trailing check 模拟单选；不用 RadioListTile 是因为
  /// Flutter 3.32 后其 groupValue/onChanged 已弃用（与
  /// [GroupSelectDialog] 同模式，避免新增 deprecation warning）。
  Future<void> _showSortDialog(BuildContext context) async {
    final current = ref.read(readerSettingsProvider).bookshelfSort;
    // 0..5 与 Rust BookSort enum 对齐（含 0=Default）。
    const labels = <int, String>{
      0: '默认',
      1: '名称',
      2: '作者',
      3: '加入时间',
      4: '上次阅读',
      5: '章节数',
    };
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) {
        return SimpleDialog(
          title: const Text('书架排序'),
          children: [
            for (final entry in labels.entries)
              ListTile(
                title: Text(entry.value),
                trailing: entry.key == current
                    ? const Icon(Icons.check, color: Colors.blue)
                    : null,
                onTap: () => Navigator.pop(ctx, entry.key),
              ),
          ],
        );
      },
    );
    if (picked == null || picked == current) return;
    final notifier = ref.read(readerSettingsProvider.notifier);
    final updated = notifier.state.copyWith(bookshelfSort: picked);
    notifier.state = updated;
    // 持久化到 settings.json，杀进程重启后保留排序。
    await saveReaderSettingsToDisk(updated);
  }
}

/// 单个 Tab 内的书列表视图。
///
/// 抽出独立 widget 以便每个 Tab 通过 [booksByGroupProvider]`((groupId, sortOrder))`
/// 各自拿数据，互不污染缓存。`isGridView` 由父级 [BookshelfPage] 全局
/// 控制（"列表/网格"切换是用户在所有 Tab 间共享的偏好）；`sortOrder`
/// 同样全局共享（批次 8）。
class _BookListView extends ConsumerWidget {
  final int groupId;
  final int sortOrder;
  final bool isGridView;

  const _BookListView({
    required this.groupId,
    required this.sortOrder,
    required this.isGridView,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final booksAsync = ref.watch(booksByGroupProvider((groupId, sortOrder)));
    return booksAsync.when(
      data: (books) => _buildBookList(context, ref, books),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('加载失败: $e')),
    );
  }

  Widget _buildBookList(BuildContext context, WidgetRef ref,
      List<Map<String, dynamic>> books) {
    if (books.isEmpty) {
      return const Center(child: Text('书架为空，去搜索添加书籍吧'));
    }
    if (isGridView) {
      return _buildGridView(context, ref, books);
    }
    return _buildListView(context, ref, books);
  }

  Widget _buildListView(
      BuildContext context, WidgetRef ref, List<Map<String, dynamic>> books) {
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemExtent: 72,
      itemCount: books.length,
      itemBuilder: (context, index) {
        final book = books[index];
        return GestureDetector(
          onLongPress: () => _showBookActionSheet(context, ref, book),
          child: Card(
            child: ListTile(
              leading: _buildCover(book),
              title: Text(book['name'] ?? '未知书名'),
              subtitle: Text(book['author'] ?? '未知作者'),
              trailing: Text('${book['chapter_count'] ?? 0}章'),
              onTap: () => context.push(
                Uri(path: '/reader', queryParameters: {
                  'bookId': book['id'] as String? ?? '',
                }).toString(),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildGridView(
      BuildContext context, WidgetRef ref, List<Map<String, dynamic>> books) {
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.65,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: books.length,
      itemBuilder: (context, index) {
        final book = books[index];
        return Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => context.push(
              Uri(path: '/reader', queryParameters: {
                'bookId': book['id'] as String? ?? '',
              }).toString(),
            ),
            onLongPress: () => _showBookActionSheet(context, ref, book),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _buildCover(book),
                ),
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        book['name'] ?? '未知书名',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      Text(
                        book['author'] ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCover(Map<String, dynamic> book) {
    final localPath = book['custom_cover_path'] as String?;
    if (localPath != null && localPath.isNotEmpty) {
      return Image.file(
        File(localPath),
        fit: BoxFit.cover,
        cacheWidth: 100,
        cacheHeight: 150,
        errorBuilder: (_, __, ___) =>
            _buildNetworkCover(book['cover_url'] as String?),
      );
    }
    return _buildNetworkCover(book['cover_url'] as String?);
  }

  Widget _buildNetworkCover(String? coverUrl) {
    if (coverUrl == null || coverUrl.isEmpty) {
      return Container(
        color: Colors.grey.shade200,
        child: Icon(Icons.book, size: 40, color: Colors.grey.shade500),
      );
    }
    return CachedNetworkImage(
      imageUrl: coverUrl,
      fit: BoxFit.cover,
      memCacheWidth: 100,
      memCacheHeight: 150,
      placeholder: (context, url) => const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      errorWidget: (context, url, error) => Container(
        color: Colors.grey.shade200,
        child: Icon(Icons.broken_image, size: 32, color: Colors.grey.shade500),
      ),
    );
  }

  /// 长按书条弹底部 Sheet：移动到分组 / 删除。
  /// 抽出独立方法是因为列表 / 网格两套渲染都需要复用同一份动作菜单。
  Future<void> _showBookActionSheet(
      BuildContext context, WidgetRef ref, Map<String, dynamic> book) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('移动到分组'),
              onTap: () => Navigator.pop(ctx, 'move'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑信息'),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('删除', style: TextStyle(color: Colors.red)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    if (action == 'move') {
      await _moveBookToGroup(context, ref, book);
    } else if (action == 'edit') {
      final bookId = book['id'] as String?;
      if (bookId != null && bookId.isNotEmpty) {
        context.push(
          Uri(path: '/book-info-edit', queryParameters: {'bookId': bookId})
              .toString(),
        );
      }
    } else if (action == 'delete') {
      await _deleteBook(context, ref, book);
    }
  }

  Future<void> _moveBookToGroup(BuildContext context, WidgetRef ref,
      Map<String, dynamic> book) async {
    final currentGroupId = (book['group_id'] as num?)?.toInt() ?? 0;
    final newGroupId = await showDialog<int>(
      context: context,
      builder: (_) => GroupSelectDialog(currentGroupId: currentGroupId),
    );
    if (newGroupId == null || newGroupId == currentGroupId) return;
    if (!context.mounted) return;
    try {
      await ref.read(dbInitializedProvider.future);
      final dbPath = await ref.read(dbPathProvider.future);
      final bookId = book['id'] as String?;
      if (bookId == null || bookId.isEmpty) return;
      await rust_api.setBookGroup(
        dbPath: dbPath,
        bookId: bookId,
        groupId: newGroupId,
      );
      // 刷新所有分组的书列表（旧分组要少一本，新分组要多一本）
      ref.invalidate(booksByGroupProvider);
      ref.invalidate(allBooksProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已移动到目标分组')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('移动失败: $e')),
        );
      }
    }
  }

  Future<void> _deleteBook(BuildContext context, WidgetRef ref,
      Map<String, dynamic> book) async {
    final name = book['name'] as String? ?? '未知';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要把《$name》从书架中删除吗？\n\n该操作会同时删除章节缓存和阅读进度。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;
    try {
      await ref.read(dbInitializedProvider.future);
      final dbPath = await ref.read(dbPathProvider.future);
      final bookId = book['id'] as String?;
      if (bookId == null || bookId.isEmpty) return;
      await rust_api.deleteBook(dbPath: dbPath, id: bookId);
      ref.invalidate(allBooksProvider);
      ref.invalidate(booksByGroupProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已删除《$name》')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: $e')),
        );
      }
    }
  }
}

class _TabSpec {
  final String label;
  final int groupId;
  const _TabSpec({required this.label, required this.groupId});
}
