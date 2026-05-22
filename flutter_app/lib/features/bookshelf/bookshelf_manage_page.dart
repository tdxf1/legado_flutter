import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/persistence/json_store.dart';
import '../../core/providers.dart';
import '../../core/util/platform_int64.dart';
import '../../src/rust/api.dart' as rust_api;

/// BATCH-27d (05-22) 书架管理批量编辑页。BATCH-27d-followup (05-22) 加
/// 列表头分组筛选 + 选中区间（峰胸长按）+ 「点书名直接打开阅读」 toggle。
///
/// 对齐原 legado [`BookshelfManageActivity.kt:269-313`] +
/// [`bookshelf_menage_sel.xml`] 的批量编辑流程：长按多选书 → 4 项
/// actionbar（删除 / canUpdate toggle / 移分组 / 清缓存）。`换源` /
/// `导出全部书源` 依赖 BookSource 表（Flutter 端未实现），留 BATCH-29+
/// 独立批。
///
/// 选择模式范本完全套 BATCH-27c-3 RemoteBooksPage：
/// - `_selectionMode` + `Set<String> _selectedIds`（key=book.id）
/// - PopScope 优先级：选择模式非空 → 退选择；空 → 默认 pop 关页
/// - 长按文件项进选择 + Checkbox leading
///
/// BATCH-27d-followup 加：
/// - `_filterGroupId: int?`（null=全部 / 0=未分组 / >0=指定 group），顶部
///   horizontal ChoiceChip 单选；不持久化（每次进页 = 全部）；选择模式
///   下也可见可点切换；切换 filter 不动 `_selectedIds`（被 filter 隐藏
///   的项仍记得已选，重切回时 Checkbox 仍勾上）。
/// - `_lastTappedId: String?`：选择模式下区间选起点。长按时若起点非空 +
///   非当前项 → 起点到当前项的 `_filteredBooks` 范围全加入 `_selectedIds`
///   （**追加不清以前**）；起点为空时 fallback 为单 toggle 加入 +
///   `_lastTappedId = id`。普通 onTap 在选择模式下也更新 `_lastTappedId`。
/// - 普通模式 onTap → 看 [bookshelfManageOpenReaderProvider]（settings.json
///   bool）决定 push '/reader' 或 no-op。选择模式优先级最高，永远 toggle
///   选中（与 toggle 状态无关）。
///
/// 批量调用模式（与 27b/27c-3 Runner 模式差异化）：
/// - 27b update_toc / 27c-3 batch download 是网络 IO 长任务，走
///   singleton runner + Queue + StreamController + Notification id
/// - 27d 4 actionbar 都是本地 SQL（~ms 级）+ FRB Rust 端 SQLite UPDATE
///   单个 await 完成；用简单 forEach + 静默 catch + 总结 SnackBar 即可，
///   不需要 Runner 模式（操作不阻塞 UI 长时间，~10-100ms 内反馈）
class BookshelfManagePage extends ConsumerStatefulWidget {
  /// 测试用：注入 dbPath 跳过 path_provider。
  final String? dbPathOverride;

  /// 测试用：注入 documents_dir 跳过 path_provider（delete_book_with_file
  /// 需要 documentsDir 决定 file 删除范围）。
  final String? documentsDirOverride;

  /// 测试用：注入书列表 fixture，跳过 FRB 真查 books 表。生产路径走
  /// `ref.watch(allBooksProvider)`。
  final List<Map<String, dynamic>>? booksOverride;

  /// 测试用：注入分组列表 fixture，跳过 FRB 真查 book_groups 表。生产
  /// 路径走 `ref.watch(bookGroupsProvider)`。
  final List<Map<String, dynamic>>? groupsOverride;

  /// 测试用：注入 delete FRB 替身。生产路径走
  /// [`rust_api.deleteBookWithFile`]（funcId 117）。
  final Future<void> Function({
    required String dbPath,
    required String id,
    required bool deleteFile,
    required String documentsDir,
  })? deleteOverride;

  /// 测试用：注入 set_can_update FRB 替身。生产路径走
  /// [`rust_api.setBookCanUpdate`]（funcId 115）。
  final Future<void> Function({
    required String dbPath,
    required String id,
    required bool canUpdate,
  })? setCanUpdateOverride;

  /// 测试用：注入 set_book_group FRB 替身。生产路径走
  /// [`rust_api.setBookGroup`]（funcId 14）。
  final Future<void> Function({
    required String dbPath,
    required String id,
    required int groupId,
  })? setBookGroupOverride;

  /// 测试用：注入 clear_book_cache FRB 替身（funcId 80，BATCH-26a）。
  final Future<int> Function({
    required String dbPath,
    required String bookId,
  })? clearCacheOverride;

  /// BATCH-27d-followup 测试用：注入 [bookshelfManageOpenReaderProvider]
  /// 的初始值，跳过 settings.json IO。生产路径走 `ref.watch(...)`。
  final bool? openReaderOverride;

  const BookshelfManagePage({
    super.key,
    this.dbPathOverride,
    this.documentsDirOverride,
    this.booksOverride,
    this.groupsOverride,
    this.deleteOverride,
    this.setCanUpdateOverride,
    this.setBookGroupOverride,
    this.clearCacheOverride,
    this.openReaderOverride,
  });

  @override
  ConsumerState<BookshelfManagePage> createState() =>
      _BookshelfManagePageState();
}

class _BookshelfManagePageState extends ConsumerState<BookshelfManagePage> {
  bool _selectionMode = false;
  final Set<String> _selectedIds = <String>{};

  /// BATCH-27d-followup: 列表头分组筛选。`null` = 全部（默认），`0` =
  /// 未分组，`>0` = 指定 group id。每次进页重置（不持久化）。选择模式
  /// 下也可点切换 — 不退选择模式，不清 `_selectedIds`（被 filter 隐藏
  /// 的项仍记得已选）。
  int? _filterGroupId;

  /// BATCH-27d-followup: 区间选起点。选择模式下每次 onTap/onLongPress
  /// 更新；退选择模式时清。
  String? _lastTappedId;

  /// BATCH-27d-followup: 当前 filter 下的书列表。选择模式 `_selectAll`
  /// 也按 filter 范围算，区间选 range 也按 filter 范围算（避免「选了不
  /// 可见的书」反直觉）。
  List<Map<String, dynamic>> _filterBooks(List<Map<String, dynamic>> books) {
    final f = _filterGroupId;
    if (f == null) return books;
    return books.where((book) {
      final g = book['group'];
      final groupId = g is int
          ? g
          : g is num
              ? g.toInt()
              : 0;
      return groupId == f;
    }).toList();
  }

  /// BATCH-27d-followup: 取 groupsOverride 或 provider，给顶部 chips +
  /// _GroupPickerDialog 共用数据源。
  List<Map<String, dynamic>> _readGroups() {
    return widget.groupsOverride ??
        ref.watch(bookGroupsProvider).valueOrNull ??
        const <Map<String, dynamic>>[];
  }

  @override
  Widget build(BuildContext context) {
    final booksAsync = widget.booksOverride != null
        ? AsyncValue.data(widget.booksOverride!)
        : ref.watch(allBooksProvider);

    return PopScope(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // 选择模式非空 → 退选择；否则普通模式由 canPop=true 默认 pop 关页
        if (_selectionMode) {
          _exitSelectionMode();
        }
      },
      child: Scaffold(
        appBar: _buildAppBar(context),
        body: booksAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('加载书架失败: $e')),
          data: (books) => _buildBody(_filterBooks(books)),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    final groupChipsBar = _buildGroupChipsBar();
    if (_selectionMode) {
      return AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: '取消',
          onPressed: _exitSelectionMode,
        ),
        title: Text('选择 ${_selectedIds.length} 项'),
        bottom: groupChipsBar,
        actions: [
          IconButton(
            icon: const Icon(Icons.select_all),
            tooltip: '全选',
            onPressed: _selectAll,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '删除',
            onPressed:
                _selectedIds.isEmpty ? null : () => _onDeleteSelected(context),
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            enabled: _selectedIds.isNotEmpty,
            onSelected: (value) async {
              if (value == 'enable_update') {
                await _onSetCanUpdate(context, true);
              } else if (value == 'disable_update') {
                await _onSetCanUpdate(context, false);
              } else if (value == 'move_group') {
                await _onMoveGroup(context);
              } else if (value == 'clear_cache') {
                await _onClearCache(context);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'enable_update',
                child: ListTile(
                  leading: Icon(Icons.refresh),
                  title: Text('允许更新'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'disable_update',
                child: ListTile(
                  leading: Icon(Icons.do_not_disturb_alt),
                  title: Text('禁用更新'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'move_group',
                child: ListTile(
                  leading: Icon(Icons.drive_file_move_outline),
                  title: Text('移到分组'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'clear_cache',
                child: ListTile(
                  leading: Icon(Icons.cleaning_services_outlined),
                  title: Text('清缓存'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      );
    }
    return AppBar(
      title: const Text('书架管理'),
      bottom: _buildGroupChipsBar(),
    );
  }

  /// BATCH-27d-followup: 顶部 horizontal ChoiceChip 单选筛选条。
  /// 「全部」（_filterGroupId=null）/「未分组」（=0）/ 各 group 各 1 chip。
  /// 选择模式下也可见可点（与选择模式不互斥）。
  PreferredSize _buildGroupChipsBar() {
    final groups = _readGroups();
    return PreferredSize(
      preferredSize: const Size.fromHeight(48),
      child: SizedBox(
        height: 48,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              _buildFilterChip(label: '全部', value: null),
              const SizedBox(width: 8),
              _buildFilterChip(label: '未分组', value: 0),
              for (final g in groups) ...[
                const SizedBox(width: 8),
                _buildFilterChip(
                  label: (g['group_name'] as String?) ??
                      (g['name'] as String?) ??
                      '(未命名)',
                  value: () {
                    final id = g['id'];
                    return id is int
                        ? id
                        : id is num
                            ? id.toInt()
                            : 0;
                  }(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFilterChip({required String label, required int? value}) {
    final selected = _filterGroupId == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (s) {
        if (!s) return; // 不允许反选 (单选语义对齐 legado VM:30 单值 groupId)
        setState(() => _filterGroupId = value);
      },
    );
  }

  Widget _buildBody(List<Map<String, dynamic>> books) {
    if (books.isEmpty) {
      return const Center(child: Text('书架为空'));
    }
    return ListView.builder(
      itemCount: books.length,
      itemBuilder: (context, index) {
        final book = books[index];
        final id = (book['id'] as String?) ?? '';
        final selected = _selectedIds.contains(id);
        return ListTile(
          leading: _selectionMode
              ? Checkbox(
                  value: selected,
                  onChanged: (_) => _onItemTap(id, books),
                )
              : const Icon(Icons.book_outlined),
          title: Text((book['name'] as String?) ?? '(无标题)'),
          subtitle: Text((book['author'] as String?) ?? '(未知作者)'),
          onTap: () => _onItemTap(id, books),
          onLongPress: () => _onItemLongPress(id, books),
        );
      },
    );
  }

  /// BATCH-27d-followup: ListTile onTap 行为统一收口。
  /// - 选择模式：toggle 选中 + 更新 `_lastTappedId`（区间选起点）
  /// - 普通模式：看 [bookshelfManageOpenReaderProvider]（settings.json
  ///   bool）→ true=push '/reader' / false=no-op
  void _onItemTap(String id, List<Map<String, dynamic>> books) {
    if (id.isEmpty) return;
    if (_selectionMode) {
      setState(() {
        if (_selectedIds.contains(id)) {
          _selectedIds.remove(id);
        } else {
          _selectedIds.add(id);
        }
        _lastTappedId = id;
      });
      return;
    }
    final bool openReader = widget.openReaderOverride ??
        ref.read(bookshelfManageOpenReaderProvider);
    if (openReader) {
      context.push(
        Uri(path: '/reader', queryParameters: {'bookId': id}).toString(),
      );
    }
    // openReader=false 时 no-op（27d 现状 — 仅长按出菜单）
  }

  /// BATCH-27d-followup: ListTile onLongPress 行为分两种。
  /// - 普通模式：进选择模式 + 该项进 `_selectedIds` + 设 `_lastTappedId`
  /// - 选择模式：区间选 — 起点 = `_lastTappedId`（若为空 fallback 为
  ///   该项 toggle 加入），终点 = 该项；区间内所有 `_filteredBooks`
  ///   **追加**进 `_selectedIds`（不清以前）；起点更新为该项。
  void _onItemLongPress(String id, List<Map<String, dynamic>> books) {
    if (id.isEmpty) return;
    if (!_selectionMode) {
      _enterSelectionMode(id);
      return;
    }
    final start = _lastTappedId;
    if (start == null || start == id) {
      // fallback: 单 toggle + 更新起点
      setState(() {
        _selectedIds.add(id);
        _lastTappedId = id;
      });
      return;
    }
    final ids = books.map((b) => (b['id'] as String?) ?? '').toList();
    final si = ids.indexOf(start);
    final ei = ids.indexOf(id);
    if (si < 0 || ei < 0) {
      // 起点不在当前 filter 列表内 → fallback 单 toggle 该项
      setState(() {
        _selectedIds.add(id);
        _lastTappedId = id;
      });
      return;
    }
    final lo = si < ei ? si : ei;
    final hi = si < ei ? ei : si;
    setState(() {
      for (var i = lo; i <= hi; i++) {
        final v = ids[i];
        if (v.isNotEmpty) _selectedIds.add(v);
      }
      _lastTappedId = id;
    });
  }

  void _enterSelectionMode(String firstId) {
    setState(() {
      _selectionMode = true;
      _selectedIds.add(firstId);
      _lastTappedId = firstId;
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
      _lastTappedId = null;
    });
  }

  void _selectAll() {
    final raw = widget.booksOverride ?? ref.read(allBooksProvider).value;
    if (raw == null) return;
    final books = _filterBooks(raw); // BATCH-27d-followup: 全选按 filter 范围
    setState(() {
      for (final book in books) {
        final id = (book['id'] as String?) ?? '';
        if (id.isNotEmpty) _selectedIds.add(id);
      }
    });
  }

  /// 删除：confirm dialog + 「同时删除本地源文件」checkbox（默认 unchecked
  /// 保守，对齐 PRD §Q2 决策）→ batch delete_book_with_file。
  Future<void> _onDeleteSelected(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    bool deleteFile = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('删除选中的书？'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('共 ${_selectedIds.length} 本'),
                const SizedBox(height: 12),
                CheckboxListTile(
                  value: deleteFile,
                  onChanged: (v) => setDialogState(() => deleteFile = v ?? false),
                  title: const Text('同时删除本地源文件'),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                ),
              ],
            ),
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
      },
    );
    if (confirmed != true) return;
    if (!mounted) return;

    final String dbPath = widget.dbPathOverride ??
        await ref.read(dbPathProvider.future);
    if (!mounted) return;
    final String docsDir =
        widget.documentsDirOverride ?? await resolvePersistenceDir();
    if (!mounted) return;

    final fn = widget.deleteOverride ??
        ({
          required String dbPath,
          required String id,
          required bool deleteFile,
          required String documentsDir,
        }) =>
            rust_api.deleteBookWithFile(
              dbPath: dbPath,
              id: id,
              deleteFile: deleteFile,
              documentsDir: documentsDir,
            );

    int success = 0;
    int fail = 0;
    final ids = _selectedIds.toList();
    for (final id in ids) {
      try {
        await fn(
          dbPath: dbPath,
          id: id,
          deleteFile: deleteFile,
          documentsDir: docsDir,
        );
        success++;
      } catch (e) {
        debugPrint('[BookshelfManage] delete $id failed: $e');
        fail++;
      }
    }
    if (!mounted) return;
    ref.invalidate(allBooksProvider);
    ref.invalidate(booksByGroupProvider);
    _exitSelectionMode();
    messenger.showSnackBar(
      SnackBar(content: Text('批量删除完成：成功 $success / 失败 $fail')),
    );
  }

  /// canUpdate toggle：批量 set_book_can_update + invalidate。
  Future<void> _onSetCanUpdate(BuildContext context, bool canUpdate) async {
    final messenger = ScaffoldMessenger.of(context);
    final String dbPath =
        widget.dbPathOverride ?? await ref.read(dbPathProvider.future);
    if (!mounted) return;

    final fn = widget.setCanUpdateOverride ??
        ({
          required String dbPath,
          required String id,
          required bool canUpdate,
        }) =>
            rust_api.setBookCanUpdate(
              dbPath: dbPath,
              id: id,
              canUpdate: canUpdate,
            );

    int success = 0;
    int fail = 0;
    final ids = _selectedIds.toList();
    for (final id in ids) {
      try {
        await fn(dbPath: dbPath, id: id, canUpdate: canUpdate);
        success++;
      } catch (e) {
        debugPrint('[BookshelfManage] setCanUpdate $id failed: $e');
        fail++;
      }
    }
    if (!mounted) return;
    ref.invalidate(allBooksProvider);
    _exitSelectionMode();
    final label = canUpdate ? '允许更新' : '禁用更新';
    messenger.showSnackBar(
      SnackBar(content: Text('$label 完成：成功 $success / 失败 $fail')),
    );
  }

  /// 移分组：弹 _GroupPickerDialog 选 group → batch set_book_group。
  Future<void> _onMoveGroup(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final groups = _readGroups();

    final pickedGroupId = await showDialog<int>(
      context: context,
      builder: (dialogCtx) => _GroupPickerDialog(groups: groups),
    );
    if (pickedGroupId == null) return;
    if (!mounted) return;

    final String dbPath =
        widget.dbPathOverride ?? await ref.read(dbPathProvider.future);
    if (!mounted) return;

    final fn = widget.setBookGroupOverride ??
        ({
          required String dbPath,
          required String id,
          required int groupId,
        }) =>
            rust_api.setBookGroup(
                dbPath: dbPath, bookId: id, groupId: groupId);

    int success = 0;
    int fail = 0;
    final ids = _selectedIds.toList();
    for (final id in ids) {
      try {
        await fn(dbPath: dbPath, id: id, groupId: pickedGroupId);
        success++;
      } catch (e) {
        debugPrint('[BookshelfManage] setGroup $id failed: $e');
        fail++;
      }
    }
    if (!mounted) return;
    ref.invalidate(allBooksProvider);
    ref.invalidate(booksByGroupProvider);
    _exitSelectionMode();
    messenger.showSnackBar(
      SnackBar(content: Text('移到分组完成：成功 $success / 失败 $fail')),
    );
  }

  /// 清缓存：复用 BATCH-26a `clearBookCache`（funcId 80）。
  Future<void> _onClearCache(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final String dbPath =
        widget.dbPathOverride ?? await ref.read(dbPathProvider.future);
    if (!mounted) return;

    final fn = widget.clearCacheOverride ??
        ({
          required String dbPath,
          required String bookId,
        }) async {
          final n = await rust_api.clearBookCache(
              dbPath: dbPath, bookId: bookId);
          return platformInt64ToInt(n);
        };

    int success = 0;
    int fail = 0;
    final ids = _selectedIds.toList();
    for (final id in ids) {
      try {
        await fn(dbPath: dbPath, bookId: id);
        success++;
      } catch (e) {
        debugPrint('[BookshelfManage] clearCache $id failed: $e');
        fail++;
      }
    }
    if (!mounted) return;
    // 清缓存 invalidate bookChaptersProvider family（每本都要重拉空 contents）
    // — 但 family 没法精准 invalidate，整个 family 失效；用户重进 reader
    // 时该 book 的 chapters 重抓。
    _exitSelectionMode();
    messenger.showSnackBar(
      SnackBar(content: Text('清缓存完成：成功 $success / 失败 $fail')),
    );
  }
}

/// BATCH-27d: 批量移分组的 SimpleDialog —— pick 语义独立于
/// `GroupManageDialog` 的 CRUD 语义。`groups` 列表不含「未分组」option，
/// dialog 内手动加 group_id=0 项。
class _GroupPickerDialog extends StatelessWidget {
  final List<Map<String, dynamic>> groups;

  const _GroupPickerDialog({required this.groups});

  @override
  Widget build(BuildContext context) {
    return SimpleDialog(
      title: const Text('选择分组'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.of(context).pop(0),
          child: const Text('未分组'),
        ),
        for (final group in groups)
          SimpleDialogOption(
            onPressed: () {
              final id = group['id'];
              final groupId = id is int
                  ? id
                  : id is num
                      ? id.toInt()
                      : 0;
              Navigator.of(context).pop(groupId);
            },
            child: Text((group['group_name'] as String?) ??
                (group['name'] as String?) ??
                '(未命名)'),
          ),
      ],
    );
  }
}
