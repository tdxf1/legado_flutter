import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/providers.dart';
import '../../src/rust/api.dart' as rust_api;

/// RSS 文章详情页（批次 18 / 05-19）。
///
/// 路由：`/rss-articles-detail?sourceUrl=<encoded>&link=<encoded>`。
///
/// 进页流程：
/// 1. 同步从 DB 读 RssSource + RssArticle（用 rss_source_get +
///    rss_list_articles 或后续 batch 加 get_by_origin_link 桥）
/// 2. 调 `rss_mark_read` 标记已读（read_time 仍 0 时；优化为只在未读时打）
/// 3. 调 `rss_fetch_article_content` 拉 HTML
/// 4. 调 `rss_star_is_starred` 判断收藏状态
/// 5. WebView loadHtmlString(html, baseUrl)
///
/// AppBar:
/// - title: article.title（fallback "RSS 文章"）
/// - actions:
///   - star/star_outline → toggle add/remove
///   - open_in_browser → 占位（批次 19+）
///
/// 测试钩子（与 [`RssArticleListPage`] 同模式）：
/// - `dbPathOverride` / `sourceOverride` / `articleOverride`：注入 source / article JSON
/// - `fetchHtmlOverride`：返回 `{html, base_url}` map，绕过 FRB
/// - `isStarredOverride` / `starAddOverride` / `starRemoveOverride`
/// - `markReadOverride`：避免单测里走真 DB
/// - `disableWebView` (test only)：用 Text 占位代替 WebView，避免
///   widget test 环境平台 channel 无法 mock 的问题
class RssArticleDetailPage extends ConsumerStatefulWidget {
  /// 源 URL（路由 query 参数 `sourceUrl`）。
  final String sourceUrl;

  /// 文章链接（路由 query 参数 `link`）。
  final String link;

  // 测试钩子
  final String? dbPathOverride;
  final Map<String, dynamic>? sourceOverride;
  final Map<String, dynamic>? articleOverride;

  /// fetch html 注入。返回 `{html, base_url}`。
  final Future<Map<String, dynamic>> Function(
    String dbPath,
    String sourceUrl,
    String link,
  )? fetchHtmlOverride;

  /// 注入 is_starred 检查。
  final Future<bool> Function(
    String dbPath,
    String origin,
    String link,
  )? isStarredOverride;

  /// 注入 star add（返回 affected）。
  final Future<int> Function(
    String dbPath,
    String articleJson,
    String sourceName,
  )? starAddOverride;

  /// 注入 star remove。
  final Future<int> Function(
    String dbPath,
    String origin,
    String link,
  )? starRemoveOverride;

  /// 注入 mark_read。
  final Future<int> Function(
    String dbPath,
    String link,
    int ts,
  )? markReadOverride;

  /// 测试模式下禁用 WebView，用 Text 占位（widget test 环境无法
  /// 真渲染 WebView）。
  final bool disableWebView;

  const RssArticleDetailPage({
    super.key,
    required this.sourceUrl,
    required this.link,
    this.dbPathOverride,
    this.sourceOverride,
    this.articleOverride,
    this.fetchHtmlOverride,
    this.isStarredOverride,
    this.starAddOverride,
    this.starRemoveOverride,
    this.markReadOverride,
    this.disableWebView = false,
  });

  @override
  ConsumerState<RssArticleDetailPage> createState() =>
      _RssArticleDetailPageState();
}

class _RssArticleDetailPageState extends ConsumerState<RssArticleDetailPage> {
  bool _loading = true;
  String? _error;

  Map<String, dynamic>? _source;
  Map<String, dynamic>? _article;
  String? _html;
  String? _baseUrl;

  bool _isStarred = false;
  bool _starBusy = false;

  WebViewController? _webController;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<String> _dbPath() async {
    return widget.dbPathOverride ?? await ref.read(dbPathProvider.future);
  }

  Future<void> _bootstrap() async {
    try {
      // 1. 取 source / article（测试覆盖优先；否则走 FRB）
      Map<String, dynamic>? source = widget.sourceOverride;
      Map<String, dynamic>? article = widget.articleOverride;
      final dbPath = await _dbPath();

      if (source == null) {
        final raw = await rust_api.rssSourceGet(
            dbPath: dbPath, url: widget.sourceUrl);
        if (raw.isNotEmpty && raw != 'null') {
          source = jsonDecode(raw) as Map<String, dynamic>?;
        }
      }
      if (article == null) {
        // 通过 list 找 — RssArticleDao 没有暴露 get_by_origin_link 桥，
        // 但 list_by_origin_sort 已能拿全量。MVP 用全量过滤；列表通常不大。
        final json = await rust_api.rssListArticles(
            dbPath: dbPath, sourceUrl: widget.sourceUrl);
        final List<dynamic> arr = jsonDecode(json);
        for (final e in arr) {
          final m = e as Map<String, dynamic>;
          if (m['link'] == widget.link) {
            article = m;
            break;
          }
        }
      }

      // 2. mark read（如未读）
      final readTime = (article?['read_time'] as num?)?.toInt() ?? 0;
      if (readTime == 0 && widget.link.isNotEmpty) {
        final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        try {
          if (widget.markReadOverride != null) {
            await widget.markReadOverride!(dbPath, widget.link, ts);
          } else {
            await rust_api.rssMarkRead(
                dbPath: dbPath, link: widget.link, ts: ts);
          }
          article?['read_time'] = ts;
        } catch (_) {
          // mark read 失败不阻塞 UI
        }
      }

      // 3. is_starred
      bool starred = false;
      try {
        if (widget.isStarredOverride != null) {
          starred = await widget.isStarredOverride!(
              dbPath, widget.sourceUrl, widget.link);
        } else {
          starred = await rust_api.rssStarIsStarred(
              dbPath: dbPath, origin: widget.sourceUrl, link: widget.link);
        }
      } catch (_) {
        starred = false;
      }

      // 4. fetch html
      Map<String, dynamic>? fetched;
      try {
        if (widget.fetchHtmlOverride != null) {
          fetched = await widget.fetchHtmlOverride!(
              dbPath, widget.sourceUrl, widget.link);
        } else {
          final raw = await rust_api.rssFetchArticleContent(
            dbPath: dbPath,
            sourceUrl: widget.sourceUrl,
            link: widget.link,
          );
          fetched = jsonDecode(raw) as Map<String, dynamic>;
        }
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _source = source;
          _article = article;
          _isStarred = starred;
          _error = e.toString();
          _loading = false;
        });
        return;
      }

      final html = fetched['html'] as String? ?? '';
      final baseUrl = fetched['base_url'] as String? ?? widget.sourceUrl;

      // 5. WebView controller（非 test 模式下）
      WebViewController? controller;
      if (!widget.disableWebView && !kIsWeb && html.isNotEmpty) {
        try {
          controller = WebViewController()
            ..setJavaScriptMode(JavaScriptMode.unrestricted);
          await controller.loadHtmlString(html, baseUrl: baseUrl);
        } catch (e) {
          // 平台 channel 在 widget test 环境会失败 — 不阻塞页面
          controller = null;
        }
      }

      if (!mounted) return;
      setState(() {
        _source = source;
        _article = article;
        _html = html;
        _baseUrl = baseUrl;
        _isStarred = starred;
        _webController = controller;
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

  Future<void> _toggleStar() async {
    if (_starBusy || _article == null) return;
    setState(() => _starBusy = true);
    try {
      final dbPath = await _dbPath();
      if (_isStarred) {
        if (widget.starRemoveOverride != null) {
          await widget.starRemoveOverride!(dbPath, widget.sourceUrl, widget.link);
        } else {
          await rust_api.rssStarRemove(
              dbPath: dbPath, origin: widget.sourceUrl, link: widget.link);
        }
        if (mounted) setState(() => _isStarred = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已取消收藏')),
          );
        }
      } else {
        final sourceName = (_source?['source_name'] as String?) ?? '';
        final articleJson = jsonEncode(_article);
        if (widget.starAddOverride != null) {
          await widget.starAddOverride!(dbPath, articleJson, sourceName);
        } else {
          await rust_api.rssStarAdd(
            dbPath: dbPath,
            articleJson: articleJson,
            sourceName: sourceName,
          );
        }
        if (mounted) setState(() => _isStarred = true);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已加入收藏')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _starBusy = false);
    }
  }

  void _retry() {
    setState(() {
      _loading = true;
      _error = null;
    });
    _bootstrap();
  }

  @override
  Widget build(BuildContext context) {
    final title = (_article?['title'] as String?)?.trim().isNotEmpty == true
        ? _article!['title'] as String
        : 'RSS 文章';
    return Scaffold(
      appBar: AppBar(
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: Icon(_isStarred ? Icons.star : Icons.star_outline),
            tooltip: _isStarred ? '取消收藏' : '收藏',
            onPressed: (_loading || _article == null || _starBusy)
                ? null
                : _toggleStar,
          ),
          IconButton(
            icon: const Icon(Icons.open_in_browser),
            tooltip: '阅读原文（批次 19+）',
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('阅读原文功能将在后续批次实装')),
              );
            },
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
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline,
                  size: 56, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 12),
              Text('加载失败：$_error', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _retry,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    final html = _html ?? '';
    if (widget.disableWebView || _webController == null) {
      // 测试模式 / WebView 不可用：用 Text 显示 HTML 长度作占位（widget
      // test 验证渲染流程进入到这一步即可）。生产场景里 _webController
      // 在 _bootstrap 里已成功 init，会走 WebViewWidget 分支。
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Text(
          'HTML 长度=${html.length}\nbase_url=${_baseUrl ?? ''}',
          // ignore: deprecated_member_use
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }
    return WebViewWidget(controller: _webController!);
  }
}
