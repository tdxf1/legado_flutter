import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

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
/// AppBar 菜单 → 管理分组（[GroupManageDialog]）/ 备份恢复 / 导入本地书。
///
/// 批次 13 (05-19): 顶栏 PopupMenu 加"导入本地书"项，触发 file_picker
/// 选 .txt/.epub/.umd → 调 [`rust_api.importLocalBook`] → invalidate
/// 书架 providers + SnackBar 成功提示 + 自动跳到 reader。
class BookshelfPage extends ConsumerStatefulWidget {
  /// 测试钩子：注入假 dbPath，避免 widget test 走 path_provider。
  final String? dbPathOverride;

  /// 测试钩子：注入假 documentsDir，避免 widget test 走 path_provider。
  final String? documentsDirOverride;

  /// 测试钩子：注入假的"导入本地书"文件选择器。返回选中文件绝对路径
  /// 或 null（用户取消）。
  final Future<String?> Function()? pickFileForLocalImportOverride;

  /// 测试钩子：注入假的 importLocalBook FRB 调用，返回与真实 FRB
  /// 相同形状的 JSON 字符串 `{"book_id":"..."}`。
  final Future<String> Function({
    required String dbPath,
    required String filePath,
    required String documentsDir,
  })? importLocalBookOverride;

  const BookshelfPage({
    super.key,
    this.dbPathOverride,
    this.documentsDirOverride,
    this.pickFileForLocalImportOverride,
    this.importLocalBookOverride,
  });

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
                } else if (value == 'backup') {
                  // 批次 10 (05-19): 备份/恢复页。
                  if (context.mounted) context.push('/backup');
                } else if (value == 'import_local') {
                  // 批次 13 (05-19): 导入本地书。
                  await _onImportLocalBook(context);
                } else if (value == 'read_stats') {
                  // 批次 14 (05-19): 阅读统计页。
                  if (context.mounted) context.push('/read-stats');
                } else if (value == 'cache_management') {
                  // 批次 15 (05-19): 缓存管理页。
                  if (context.mounted) context.push('/cache-management');
                } else if (value == 'rss_source_manage') {
                  // 批次 16 (05-19): RSS 源管理页。
                  if (context.mounted) context.push('/rss-source-manage');
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
                PopupMenuItem(
                  value: 'backup',
                  child: ListTile(
                    leading: Icon(Icons.settings_backup_restore),
                    title: Text('备份/恢复'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                PopupMenuItem(
                  value: 'import_local',
                  child: ListTile(
                    leading: Icon(Icons.note_add),
                    title: Text('导入本地书'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                PopupMenuItem(
                  value: 'read_stats',
                  child: ListTile(
                    leading: Icon(Icons.timer_outlined),
                    title: Text('阅读统计'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                PopupMenuItem(
                  value: 'cache_management',
                  child: ListTile(
                    leading: Icon(Icons.cleaning_services_outlined),
                    title: Text('缓存管理'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                PopupMenuItem(
                  value: 'rss_source_manage',
                  child: ListTile(
                    leading: Icon(Icons.rss_feed),
                    title: Text('RSS 源管理'),
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

  /// 批次 13 (05-19): 选本地文件 → 调 [`rust_api.importLocalBook`] →
  /// invalidate 书架/分组 providers → SnackBar 提示成功 → 自动跳到
  /// reader 页面。
  ///
  /// 走过 `pickFileForLocalImportOverride` / `importLocalBookOverride`
  /// 测试钩子时不依赖真实 file_picker / FRB / path_provider；生产代码
  /// 跑默认路径。
  ///
  /// 失败处理：所有异常（用户取消除外）都会 catch + SnackBar 提示，避免
  /// 把异常向上抛打断书架页。
  Future<void> _onImportLocalBook(BuildContext context) async {
    try {
      final pickFn = widget.pickFileForLocalImportOverride ??
          () async {
            final result = await FilePicker.pickFiles(
              type: FileType.custom,
              allowedExtensions: ['txt', 'epub', 'umd'],
            );
            if (result == null || result.files.isEmpty) return null;
            return result.files.single.path;
          };
      final pickedPath = await pickFn();
      if (pickedPath == null || pickedPath.isEmpty) return;
      if (!context.mounted) return;
      // 解析 dbPath / documentsDir
      final String dbPath =
          widget.dbPathOverride ?? await ref.read(dbPathProvider.future);
      final String documentsDir = widget.documentsDirOverride ??
          (await getApplicationDocumentsDirectory()).path;
      // FRB 调用
      final importFn = widget.importLocalBookOverride ??
          ({
            required String dbPath,
            required String filePath,
            required String documentsDir,
          }) =>
              rust_api.importLocalBook(
                dbPath: dbPath,
                filePath: filePath,
                documentsDir: documentsDir,
              );
      final json = await importFn(
        dbPath: dbPath,
        filePath: pickedPath,
        documentsDir: documentsDir,
      );
      // 解析返回 JSON `{"book_id": "..."}`
      String? bookId;
      try {
        final Map<String, dynamic> map =
            jsonDecode(json) as Map<String, dynamic>;
        bookId = map['book_id'] as String?;
      } catch (_) {
        bookId = null;
      }
      if (!context.mounted) return;
      // 让书架 / 分组所有相关 providers 立刻刷新
      ref.invalidate(allBooksProvider);
      ref.invalidate(booksByGroupProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(bookId != null && bookId.isNotEmpty
              ? '导入成功 (id: ${bookId.substring(0, bookId.length < 8 ? bookId.length : 8)})'
              : '导入成功'),
        ),
      );
      // 自动跳到 reader（GoRouter `/reader?bookId=...`）
      if (bookId != null && bookId.isNotEmpty && context.mounted) {
        context.push(
          Uri(path: '/reader', queryParameters: {'bookId': bookId}).toString(),
        );
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败: $e')),
      );
    }
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
              subtitle: Text(
                _formatBookSubtitle(book),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
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
                        _formatBookSubtitle(book),
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

  /// 批次 14 (05-19): 列表/网格副标题。原本只显示 `book.author`；
  /// 现在优先用 `dur_chapter_title` + 相对时间戳，回退作者。
  ///
  /// 例：`3 小时前 · 第 12 章` / `昨天 · 第 1 章` / 没有阅读记录时
  /// 退化为 `张三` 或 `未知作者`。
  String _formatBookSubtitle(Map<String, dynamic> book) {
    final durTitle = book['dur_chapter_title'] as String?;
    final durTime = (book['dur_chapter_time'] as num?)?.toInt() ?? 0;
    final author = book['author'] as String? ?? '';
    if (durTitle != null && durTitle.isNotEmpty && durTime > 0) {
      return '${_formatRelativeTime(durTime)} · $durTitle';
    }
    return author.isEmpty ? '未知作者' : author;
  }

  /// 批次 14 (05-19): 把 unix 时间戳（秒）格式化成"刚刚 / N 分钟前 /
  /// N 小时前 / N 天前 / yyyy-MM-dd"风格的相对时间字符串。
  String _formatRelativeTime(int sec) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final delta = now - sec;
    if (delta < 60) return '刚刚';
    if (delta < 3600) return '${(delta / 60).floor()} 分钟前';
    if (delta < 86400) return '${(delta / 3600).floor()} 小时前';
    if (delta < 86400 * 30) return '${(delta / 86400).floor()} 天前';
    return DateTime.fromMillisecondsSinceEpoch(sec * 1000)
        .toLocal()
        .toString()
        .split(' ')
        .first;
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
