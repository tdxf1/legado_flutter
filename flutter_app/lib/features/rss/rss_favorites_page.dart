import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/colors.dart';
import '../../core/providers.dart';
import '../../src/rust/api.dart' as rust_api;

/// RSS 收藏页（批次 18 / 05-19）。
///
/// 路由 `/rss-favorites`。AppBar(title: "RSS 收藏")。ListView 渲染
/// 全部 [`RssStar`]：
/// - leading 64×64 缩略图（CachedNetworkImage，缺图 Icon.article）
/// - title: title
/// - subtitle: source_name + " · " + pub_date
/// - 长按 → confirm dialog → remove → invalidate
/// - 点击 → push detail 页
///
/// MVP 不做分页：调用 `rss_star_list(limit=-1, offset=0)`。
///
/// 测试钩子：
/// - `dbPathOverride` 注入 dbPath
/// - `starsOverride` 注入假 RssStar map 列表，绕过 FRB
/// - `removeOverride` 注入假 remove FRB 调用
class RssFavoritesPage extends ConsumerStatefulWidget {
  /// 测试钩子：注入假 dbPath。
  final String? dbPathOverride;

  /// 测试钩子：注入假收藏列表，绕过 FRB。
  final List<Map<String, dynamic>>? starsOverride;

  /// 测试钩子：注入假 remove FRB。
  final Future<int> Function(String dbPath, String origin, String link)?
      removeOverride;

  const RssFavoritesPage({
    super.key,
    this.dbPathOverride,
    this.starsOverride,
    this.removeOverride,
  });

  @override
  ConsumerState<RssFavoritesPage> createState() => _RssFavoritesPageState();
}

class _RssFavoritesPageState extends ConsumerState<RssFavoritesPage> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _stars = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      if (widget.starsOverride != null) {
        if (!mounted) return;
        setState(() {
          _stars = widget.starsOverride!;
          _loading = false;
        });
        return;
      }
      final String dbPath =
          widget.dbPathOverride ?? await ref.read(dbPathProvider.future);
      // limit=-1 → 不分页（MVP）。i64 在 dart 端是 int。
      final json = await rust_api.rssStarList(
        dbPath: dbPath,
        limit: -1,
        offset: 0,
      );
      final List<dynamic> arr = jsonDecode(json);
      final list = arr.cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        _stars = list;
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

  Future<void> _onRemove(Map<String, dynamic> record) async {
    final origin = record['origin'] as String? ?? '';
    final link = record['link'] as String? ?? '';
    final title = record['title'] as String? ?? '';
    if (origin.isEmpty || link.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('取消收藏'),
        content: Text('确定要从收藏中移除《$title》吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('确定移除', style: TextStyle(color: context.al.destructive)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;

    try {
      final String dbPath =
          widget.dbPathOverride ?? await ref.read(dbPathProvider.future);
      if (widget.removeOverride != null) {
        await widget.removeOverride!(dbPath, origin, link);
      } else {
        await rust_api.rssStarRemove(
            dbPath: dbPath, origin: origin, link: link);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已取消收藏')),
      );
      setState(() => _loading = true);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('取消失败: $e')),
      );
    }
  }

  void _onTap(Map<String, dynamic> record) {
    final origin = record['origin'] as String? ?? '';
    final link = record['link'] as String? ?? '';
    if (origin.isEmpty || link.isEmpty) return;
    context.push(
      '/rss-articles-detail'
      '?sourceUrl=${Uri.encodeQueryComponent(origin)}'
      '&link=${Uri.encodeQueryComponent(link)}',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('RSS 收藏')),
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
    if (_stars.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.star_border,
                size: 56, color: Theme.of(context).disabledColor),
            const SizedBox(height: 12),
            const Text('暂无收藏'),
            const SizedBox(height: 4),
            Text(
              '去文章列表点 ★ 收藏喜欢的内容',
              style: TextStyle(color: context.al.textSecondary),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      itemCount: _stars.length,
      itemBuilder: (context, index) =>
          _buildStarTile(context, _stars[index]),
    );
  }

  Widget _buildStarTile(BuildContext context, Map<String, dynamic> record) {
    final title = record['title'] as String? ?? '(无标题)';
    final sourceName = record['source_name'] as String? ?? '';
    final pubDate = record['pub_date'] as String? ?? '';
    final image = record['image'] as String?;
    final subtitle = [
      if (sourceName.isNotEmpty) sourceName,
      if (pubDate.isNotEmpty) pubDate,
    ].join(' · ');
    return ListTile(
      onTap: () => _onTap(record),
      onLongPress: () => _onRemove(record),
      leading: _buildThumbnail(image),
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
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
