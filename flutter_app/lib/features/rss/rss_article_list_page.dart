import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../src/rust/api.dart' as rust_api;

/// RSS 文章列表页（批次 17 / 05-19）。
///
/// 路由参数：`/rss-articles?sourceUrl=<encoded>`。进页后：
/// 1. 读 RssSource（rss_source_get）— 拿 name + sort_url + single_url
/// 2. 解析 sort_url 切 Tab（rss_get_sort_tabs）；空 / 单 URL → 不显 TabBar
/// 3. 进入每个 Tab 自动拉 rss_get_articles 一次（首次）
/// 4. 列表 ListTile（标题 / 描述 / 缩略图 / 已读 dot）
/// 5. 点击 ListTile → mark_read + SnackBar"批次 18 实装详情"
/// 6. 下拉刷新 → 再次 rss_get_articles
///
/// 测试钩子（与 cache_management_page 同模式）：
/// - `dbPathOverride` / `sourceOverride` / `tabsOverride` /
///   `articlesOverride` 注入数据，绕过 FRB
/// - `getArticlesOverride` / `markReadOverride` / `listArticlesOverride`
///   注入 FRB 调用
class RssArticleListPage extends ConsumerStatefulWidget {
  /// 源 URL（路由 query 参数 `sourceUrl`）。
  final String sourceUrl;

  // 测试钩子
  final String? dbPathOverride;
  final Map<String, dynamic>? sourceOverride;
  final List<Map<String, dynamic>>? tabsOverride;
  final List<Map<String, dynamic>>? articlesOverride;

  /// 拉取（rss_get_articles）注入。返回入库后的列表 JSON。
  final Future<String> Function(
    String dbPath,
    String sourceUrl,
    String sortName,
    String sortUrl,
    int page,
  )? getArticlesOverride;

  /// list（rss_list_articles）注入。
  final Future<String> Function(
    String dbPath,
    String sourceUrl,
    String? sort,
  )? listArticlesOverride;

  /// mark_read 注入。返回受影响行数。
  final Future<int> Function(String dbPath, String link, int ts)?
      markReadOverride;

  const RssArticleListPage({
    super.key,
    required this.sourceUrl,
    this.dbPathOverride,
    this.sourceOverride,
    this.tabsOverride,
    this.articlesOverride,
    this.getArticlesOverride,
    this.listArticlesOverride,
    this.markReadOverride,
  });

  @override
  ConsumerState<RssArticleListPage> createState() => _RssArticleListPageState();
}

class _RssArticleListPageState extends ConsumerState<RssArticleListPage>
    with SingleTickerProviderStateMixin {
  bool _initialLoading = true;
  String? _error;
  Map<String, dynamic>? _source;
  // 每个 tab `(name, url)`；len=0 表示单 URL 模式（不显 TabBar）。
  List<({String name, String url})> _tabs = const [];
  TabController? _tabController;
  // 每个 sort name → 文章列表。空字符串 key 表示单 URL 模式。
  final Map<String, List<Map<String, dynamic>>> _articlesBySort = {};
  // 当前正在拉取的 tab name（用来给 AppBar 旋转 icon）。
  String? _refreshingSort;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  Future<String> _dbPath() async {
    return widget.dbPathOverride ?? await ref.read(dbPathProvider.future);
  }

  Future<void> _bootstrap() async {
    try {
      // 1. source
      Map<String, dynamic>? source = widget.sourceOverride;
      if (source == null) {
        final dbPath = await _dbPath();
        final raw = await rust_api.rssSourceGet(
            dbPath: dbPath, url: widget.sourceUrl);
        if (raw.isNotEmpty && raw != 'null') {
          source = jsonDecode(raw) as Map<String, dynamic>?;
        }
      }
      // 2. tabs
      List<({String name, String url})> tabs = const [];
      if (widget.tabsOverride != null) {
        tabs = widget.tabsOverride!
            .map((m) => (
                  name: (m['name'] as String?) ?? '',
                  url: (m['url'] as String?) ?? '',
                ))
            .toList();
      } else if (source != null) {
        final isSingle = (source['single_url'] as bool?) ?? false;
        final sortUrl = source['sort_url'] as String? ?? '';
        if (!isSingle && sortUrl.isNotEmpty) {
          // 直接复用 rust_api.rssGetSortTabs 解析（端口已加锁逻辑），
          // 失败时降级解析。
          try {
            final dbPath = await _dbPath();
            final raw = await rust_api.rssGetSortTabs(
                dbPath: dbPath, sourceUrl: widget.sourceUrl);
            final List<dynamic> arr = jsonDecode(raw);
            tabs = arr
                .map((e) => e as Map<String, dynamic>)
                .map((m) => (
                      name: (m['name'] as String?) ?? '',
                      url: (m['url'] as String?) ?? '',
                    ))
                .toList();
          } catch (_) {
            tabs = _parseSortUrl(sortUrl);
          }
        }
      }

      _tabs = tabs;
      _source = source;
      if (_tabs.isNotEmpty) {
        _tabController = TabController(length: _tabs.length, vsync: this);
      }

      // 3. 注入 articlesOverride（test 用）
      if (widget.articlesOverride != null) {
        // 单 URL 模式：key=''；多分类：放第一个 tab
        final key = _tabs.isEmpty ? '' : _tabs.first.name;
        _articlesBySort[key] = List.of(widget.articlesOverride!);
      }

      if (!mounted) return;
      setState(() {
        _initialLoading = false;
      });

      // 4. 自动首次拉取（无 articlesOverride 时）
      if (widget.articlesOverride == null) {
        final initialKey = _tabs.isEmpty ? '' : _tabs.first.name;
        await _loadArticles(initialKey, refresh: true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _initialLoading = false;
      });
    }
  }

  /// 解析 source.sort_url 字符串，与 Rust 端 [`rss_get_sort_tabs`] 同语义。
  List<({String name, String url})> _parseSortUrl(String s) {
    final out = <({String name, String url})>[];
    for (final line in s.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final idx = trimmed.indexOf('::');
      if (idx > 0) {
        out.add((
          name: trimmed.substring(0, idx).trim(),
          url: trimmed.substring(idx + 2).trim(),
        ));
      } else {
        out.add((name: trimmed, url: ''));
      }
    }
    return out;
  }

  Future<void> _loadArticles(String sortName, {required bool refresh}) async {
    setState(() {
      _refreshingSort = sortName;
    });
    try {
      String resultJson;
      if (widget.getArticlesOverride != null && refresh) {
        // 测试 + 真实代码路径都走 override。
        final url = _tabs.firstWhere(
              (t) => t.name == sortName,
              orElse: () => (name: sortName, url: ''),
            ).url;
        resultJson = await widget.getArticlesOverride!(
          await _dbPath(),
          widget.sourceUrl,
          sortName,
          url,
          1,
        );
      } else if (widget.listArticlesOverride != null && !refresh) {
        resultJson = await widget.listArticlesOverride!(
          await _dbPath(),
          widget.sourceUrl,
          sortName.isEmpty ? null : sortName,
        );
      } else {
        final dbPath = await _dbPath();
        if (refresh) {
          final url = _tabs
              .firstWhere(
                (t) => t.name == sortName,
                orElse: () => (name: sortName, url: ''),
              )
              .url;
          resultJson = await rust_api.rssGetArticles(
            dbPath: dbPath,
            sourceUrl: widget.sourceUrl,
            sortName: sortName,
            sortUrl: url,
            page: 1,
          );
        } else {
          resultJson = await rust_api.rssListArticles(
            dbPath: dbPath,
            sourceUrl: widget.sourceUrl,
            sort: sortName.isEmpty ? null : sortName,
          );
        }
      }
      final List<dynamic> arr = jsonDecode(resultJson);
      final list = arr.cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        _articlesBySort[sortName] = list;
        _refreshingSort = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _refreshingSort = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('拉取失败: $e')),
      );
    }
  }

  Future<void> _onArticleTap(Map<String, dynamic> article) async {
    final link = article['link'] as String? ?? '';
    if (link.isEmpty) return;
    // 批次 18 (05-19): optimistic 已读 dot — 点击立刻消失；mark_read
    // 真正写入由 detail 页 init 完成（避免列表 + 详情双写）。
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    setState(() {
      article['read_time'] = ts;
    });
    if (!mounted) return;
    final encodedSource = Uri.encodeQueryComponent(widget.sourceUrl);
    final encodedLink = Uri.encodeQueryComponent(link);
    context.push(
      '/rss-articles-detail?sourceUrl=$encodedSource&link=$encodedLink',
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = _source?['source_name'] as String? ?? 'RSS';
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        bottom: _tabs.isEmpty
            ? null
            : TabBar(
                controller: _tabController,
                isScrollable: true,
                tabs: [for (final t in _tabs) Tab(text: t.name)],
                onTap: (i) {
                  final name = _tabs[i].name;
                  if (!_articlesBySort.containsKey(name)) {
                    // 首次进 tab 自动拉取
                    _loadArticles(name, refresh: true);
                  }
                },
              ),
        actions: [
          IconButton(
            icon: _refreshingSort != null
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child:
                        CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _refreshingSort != null
                ? null
                : () {
                    final key = _tabs.isEmpty
                        ? ''
                        : _tabs[_tabController?.index ?? 0].name;
                    _loadArticles(key, refresh: true);
                  },
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_initialLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text('加载失败: $_error'));
    }
    if (_tabs.isEmpty) {
      return _buildArticleList(context, '');
    }
    return TabBarView(
      controller: _tabController,
      children: [for (final t in _tabs) _buildArticleList(context, t.name)],
    );
  }

  Widget _buildArticleList(BuildContext context, String sortName) {
    final articles = _articlesBySort[sortName];
    if (articles == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (articles.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => _loadArticles(sortName, refresh: true),
        child: ListView(
          children: const [
            SizedBox(height: 200),
            Center(child: Text('暂无文章，下拉刷新')),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _loadArticles(sortName, refresh: true),
      child: ListView.builder(
        itemCount: articles.length,
        itemBuilder: (context, index) =>
            _buildArticleTile(context, articles[index]),
      ),
    );
  }

  Widget _buildArticleTile(BuildContext context, Map<String, dynamic> article) {
    final title = article['title'] as String? ?? '(无标题)';
    final pubDate = article['pub_date'] as String? ?? '';
    final description = (article['description'] as String? ?? '').trim();
    final image = article['image'] as String?;
    final readTime = (article['read_time'] as num?)?.toInt() ?? 0;
    final isRead = readTime > 0;
    final shortDesc = description.length > 50
        ? '${description.substring(0, 50)}…'
        : description;
    final subtitle = [
      if (pubDate.isNotEmpty) pubDate,
      if (shortDesc.isNotEmpty) shortDesc,
    ].join(' · ');
    return ListTile(
      onTap: () => _onArticleTap(article),
      leading: _buildThumbnail(image),
      title: Row(
        children: [
          if (!isRead)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isRead
                    ? Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.6)
                    : null,
              ),
            ),
          ),
        ],
      ),
      subtitle: subtitle.isEmpty
          ? null
          : Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
    );
  }

  Widget _buildThumbnail(String? image) {
    final box = SizedBox(
      width: 64,
      height: 64,
      child: image == null || image.isEmpty
          ? const Icon(Icons.article, size: 40)
          : CachedNetworkImage(
              imageUrl: image,
              fit: BoxFit.cover,
              placeholder: (_, __) => const Icon(Icons.article, size: 40),
              errorWidget: (_, __, ___) =>
                  const Icon(Icons.article, size: 40),
            ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: box,
    );
  }
}
