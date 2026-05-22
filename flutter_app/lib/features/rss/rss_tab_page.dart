import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../core/util/platform_int64.dart';
import '../../src/rust/api.dart' as rust_api;

/// BATCH-28 (05-22): 「订阅」tab 页 — RSS 源网格。
///
/// 对齐原 legado `RssFragment.kt` (RssAdapter 4 列网格 + 分组筛选)。
/// 从 BATCH-26a 占位页改造为 ConsumerStatefulWidget，显示 enabled
/// RSS sources 的 GridView + 未读 badge + 分组 chips + pull-to-refresh。
///
/// 测试钩子（与 [RssSourceManagePage] 同模式）：
/// - `dbPathOverride` 注入假 dbPath
/// - `sourcesOverride` 注入假 RssSource 列表
/// - `groupsOverride` 注入假分组名列表
/// - `unreadCountsOverride` 注入假未读数 Map<sourceUrl, count>
class RssTabPage extends ConsumerStatefulWidget {
  final String? dbPathOverride;

  /// 测试钩子：注入假 RssSource 列表。
  final List<Map<String, dynamic>>? sourcesOverride;

  /// 测试钩子：注入假分组名列表。
  final List<String>? groupsOverride;

  /// 测试钩子：注入假未读数 Map<sourceUrl, count>。
  final Map<String, int>? unreadCountsOverride;

  const RssTabPage({
    super.key,
    this.dbPathOverride,
    this.sourcesOverride,
    this.groupsOverride,
    this.unreadCountsOverride,
  });

  @override
  ConsumerState<RssTabPage> createState() => _RssTabPageState();
}

class _RssTabPageState extends ConsumerState<RssTabPage> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _sources = const [];
  List<String> _groups = const [];
  Map<String, int> _unreadCounts = const {};
  String? _filterGroup;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    try {
      final String dbPath =
          widget.dbPathOverride ?? await ref.read(dbPathProvider.future);
      await Future.wait([
        _loadSources(dbPath),
        _loadGroups(dbPath),
      ]);
      await _loadUnreadCounts(dbPath);
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '加载失败: $e';
        _loading = false;
      });
    }
  }

  Future<void> _loadSources(String dbPath) async {
    if (widget.sourcesOverride != null) {
      _sources = widget.sourcesOverride!;
      return;
    }
    final json = await rust_api.rssSourceListEnabled(dbPath: dbPath);
    final list = jsonDecode(json) as List;
    _sources = list
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<void> _loadGroups(String dbPath) async {
    if (widget.groupsOverride != null) {
      _groups = widget.groupsOverride!;
      return;
    }
    final json = await rust_api.rssSourceListGroups(dbPath: dbPath);
    final list = jsonDecode(json) as List;
    _groups = list.whereType<String>().toList();
  }

  Future<void> _loadUnreadCounts(String dbPath) async {
    if (widget.unreadCountsOverride != null) {
      _unreadCounts = widget.unreadCountsOverride!;
      return;
    }
    final counts = <String, int>{};
    for (final s in _sources) {
      final url = (s['source_url'] as String?) ?? '';
      if (url.isEmpty) continue;
      try {
        final raw = await rust_api.rssCountUnread(
          dbPath: dbPath,
          sourceUrl: url,
        );
        final n = platformInt64ToInt(raw);
        if (n > 0) counts[url] = n;
      } catch (_) {
        // 单源失败不阻塞
      }
    }
    _unreadCounts = counts;
  }

  Future<void> _refreshAll() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      final String dbPath =
          widget.dbPathOverride ?? await ref.read(dbPathProvider.future);
      for (final s in _sources) {
        final url = (s['source_url'] as String?) ?? '';
        if (url.isEmpty) continue;
        try {
          await rust_api.rssGetArticles(
            dbPath: dbPath,
            sourceUrl: url,
            sortName: '',
            sortUrl: '',
            page: 1,
          );
        } catch (_) {
          // 单源失败不阻塞
        }
      }
      await _loadUnreadCounts(dbPath);
      if (!mounted) return;
      setState(() {});
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  List<Map<String, dynamic>> get _filteredSources {
    final g = _filterGroup;
    if (g == null) return _sources;
    return _sources.where((s) {
      final groups = (s['source_group'] as String?) ?? '';
      return groups.split(',').map((e) => e.trim()).contains(g);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('订阅'),
        bottom: _groups.isNotEmpty
            ? PreferredSize(
                preferredSize: const Size.fromHeight(48),
                child: _buildGroupChips(),
              )
            : null,
        actions: [
          IconButton(
            icon: const Icon(Icons.star_outline),
            tooltip: '收藏',
            onPressed: () => context.push('/rss-favorites'),
          ),
          IconButton(
            icon: const Icon(Icons.folder_outlined),
            tooltip: '分组',
            onPressed: _groups.isNotEmpty
                ? () => _showGroupPicker(context)
                : null,
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'RSS 源设置',
            onPressed: () => context.push('/rss-source-manage'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: () {
                          setState(() {
                            _loading = true;
                            _error = null;
                          });
                          _loadAll();
                        },
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                )
              : _sources.isEmpty
                  ? _buildEmptyState()
                  : RefreshIndicator(
                      onRefresh: _refreshAll,
                      child: GridView.builder(
                        padding: const EdgeInsets.all(8),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          childAspectRatio: 0.75,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                        itemCount: _filteredSources.length,
                        itemBuilder: (context, index) =>
                            _buildSourceItem(_filteredSources[index]),
                      ),
                    ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.rss_feed,
              size: 96,
              color:
                  Theme.of(context).colorScheme.outline.withValues(alpha: 0.4)),
          const SizedBox(height: 16),
          Text(
            '暂无订阅源',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('去添加'),
            onPressed: () => context.push('/rss-source-manage'),
          ),
        ],
      ),
    );
  }

  Widget _buildSourceItem(Map<String, dynamic> source) {
    final url = (source['source_url'] as String?) ?? '';
    final name = (source['source_name'] as String?) ?? '(未命名)';
    final iconUrl = (source['source_icon'] as String?) ?? '';
    final unread = _unreadCounts[url] ?? 0;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          final encoded = Uri.encodeQueryComponent(url);
          context.push('/rss-articles?sourceUrl=$encoded');
        },
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Expanded(
              flex: 3,
              child: Stack(
                children: [
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: iconUrl.isNotEmpty
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: CachedNetworkImage(
                                imageUrl: iconUrl,
                                width: 50,
                                height: 50,
                                fit: BoxFit.cover,
                                placeholder: (_, __) =>
                                    const SizedBox.shrink(),
                                errorWidget: (_, __, ___) =>
                                    const Icon(Icons.rss_feed, size: 50),
                              ),
                            )
                          : const Icon(Icons.rss_feed, size: 50),
                    ),
                  ),
                  if (unread > 0)
                    Positioned(
                      right: 4,
                      top: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.error,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          unread > 99 ? '99+' : '$unread',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onError,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupChips() {
    return SizedBox(
      height: 48,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            _buildChip(label: '全部', value: null),
            for (final g in _groups) ...[
              const SizedBox(width: 8),
              _buildChip(label: g, value: g),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildChip({required String label, required String? value}) {
    final selected = _filterGroup == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (s) {
        if (!s) return;
        setState(() => _filterGroup = value);
      },
    );
  }

  void _showGroupPicker(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择分组'),
        children: [
          SimpleDialogOption(
            onPressed: () {
              setState(() => _filterGroup = null);
              Navigator.of(ctx).pop();
            },
            child: const Text('全部'),
          ),
          for (final g in _groups)
            SimpleDialogOption(
              onPressed: () {
                setState(() => _filterGroup = g);
                Navigator.of(ctx).pop();
              },
              child: Text(g),
            ),
        ],
      ),
    );
  }
}
