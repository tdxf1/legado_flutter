import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/providers.dart';
import '../../core/widgets/safe_setstate.dart';
import '../../src/rust/api.dart' as rust_api;

/// BATCH-21c (F-W2B-012)：mark_read 实际持久化结果。detail 页 pop
/// 时通过 GoRouter `context.pop(result)` 回传给 list，让 list 按需
/// rollback optimistic read_time。
///
/// 三态语义：
/// - [success]: detail 真正调通 mark_read（含 article 原本已读跳过的情况）
/// - [failed]: mark_read 抛异常（FRB / 网络 / db lock）—— list 应 rollback
/// - [skipped]: 未走到 mark_read（_error 早返回 / link 空 / article 缺 /
///   readTime != 0）—— db 状态未变，list 保留 optimistic 等下次刷新自然修正
enum MarkReadResult {
  success,
  failed,
  skipped,
}

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

  /// BATCH-21c (F-W2B-012)：mark_read 实际持久化结果。AppBar leading
  /// IconButton 主动 `context.pop(_markReadResult)` 时携带回 list。
  /// 默认 [MarkReadResult.skipped]：未进 mark_read 分支时兜底。
  MarkReadResult _markReadResult = MarkReadResult.skipped;

  WebViewController? _webController;

  /// WebView init 失败的错误信息（BATCH-05 / F-W2B-011）。非 null 时
  /// disableWebView 占位分支会显示具体原因，方便区分"测试模式占位"与
  /// "真实 init 失败"。
  String? _webError;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    // BATCH-05b：跨文章避免 cookie / cache / localStorage 累积。
    // RSS detail webview 加载远端 untrusted HTML（disabled JS 已是
    // BATCH-05 防线），但 cache 仍持久化跨域 cookie；dispose 时清。
    // controller.clearCache() / clearLocalStorage() 在 webview_flutter
    // 4.13 跨 Android/iOS 统一 API（pubspec ^4.8.0）。
    final ctl = _webController;
    if (ctl != null) {
      ctl.clearCache().catchError((_) {});
      ctl.clearLocalStorage().catchError((_) {});
    }
    super.dispose();
  }

  Future<String> _dbPath() async {
    return widget.dbPathOverride ?? await ref.read(dbPathProvider.future);
  }

  Future<void> _bootstrap() async {
    try {
      final dbPath = await _dbPath();

      // BATCH-21 (F-W2B-009): 并行化 source / article / is_starred 三个独立
      // FRB 调用，消除原本顺序 await 累积的网络/IO latency。fetchHtml 单独
      // 走串行（保留原有错误分支语义：fetch 失败时仍能展示 source/article
      // 元数据 + 错误占位）。
      final sourceFuture = widget.sourceOverride != null
          ? Future<Map<String, dynamic>?>.value(widget.sourceOverride)
          : (() async {
              final raw = await rust_api.rssSourceGet(
                  dbPath: dbPath, url: widget.sourceUrl);
              if (raw.isNotEmpty && raw != 'null') {
                return jsonDecode(raw) as Map<String, dynamic>?;
              }
              return null;
            })();

      final articleFuture = widget.articleOverride != null
          ? Future<Map<String, dynamic>?>.value(widget.articleOverride)
          : (() async {
              final raw = await rust_api.rssArticleGetByOriginLink(
                  dbPath: dbPath, origin: widget.sourceUrl, link: widget.link);
              if (raw.isEmpty || raw == 'null') return null;
              return jsonDecode(raw) as Map<String, dynamic>?;
            })();

      final starredFuture = (widget.isStarredOverride != null
              ? widget.isStarredOverride!(
                  dbPath, widget.sourceUrl, widget.link)
              : rust_api.rssStarIsStarred(
                  dbPath: dbPath,
                  origin: widget.sourceUrl,
                  link: widget.link))
          .catchError((_) => false);

      final results = await Future.wait<Object?>([
        sourceFuture,
        articleFuture,
        starredFuture,
      ]);
      Map<String, dynamic>? source = results[0] as Map<String, dynamic>?;
      Map<String, dynamic>? article = results[1] as Map<String, dynamic>?;
      bool starred = (results[2] as bool?) ?? false;

      // 2. mark read（如未读）— 必须在 article 之后串行，因为依赖
      // article.read_time。
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
          // BATCH-21c (F-W2B-012): mark_read 写库成功 → 回传 list 不要
          // rollback optimistic（list 端 read_time 与 db 一致）
          _markReadResult = MarkReadResult.success;
        } catch (_) {
          // mark read 失败不阻塞 UI
          // BATCH-21c (F-W2B-012): mark_read 抛异常 → 回传 list 让其
          // rollback optimistic（list 端 read_time 与 db 不一致需还原）
          _markReadResult = MarkReadResult.failed;
        }
      }
      // 不进入 if 分支（readTime != 0 / link 空）保持默认 skipped：db
      // 状态未变，list 端不应据此 rollback。

      // 3. fetch html — 单独串行保留独立错误分支（fetch 失败仍能展示
      // source/article 元数据 + 错误占位）。
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
      String? webError;
      if (!widget.disableWebView && !kIsWeb && html.isNotEmpty) {
        try {
          // BATCH-05 (F-W2B-010): RSS 文章 HTML 是远端 untrusted 内容，
          // 默认关 JS（用户在 webview 内只看正文，不需要远端 script
          // 跑）。`<script>` 标签仍会出现在 DOM 但不会执行。
          controller = WebViewController()
            ..setJavaScriptMode(JavaScriptMode.disabled)
            // BATCH-05 (F-W2B-010): 拦跨 host 导航 —— 用户点文章内的链接
            // 不会让 webview 去加载攻击者控制的页面；同 host 放行（让锚点 /
            // 同站资源 / image link 加载）。"阅读原文"应在批次 19+ 用
            // url_launcher 跳系统浏览器，更安全。
            ..setNavigationDelegate(NavigationDelegate(
              onNavigationRequest: (req) {
                try {
                  final reqHost = Uri.parse(req.url).host;
                  final baseHost = Uri.parse(baseUrl).host;
                  if (reqHost.isEmpty ||
                      baseHost.isEmpty ||
                      reqHost == baseHost) {
                    return NavigationDecision.navigate;
                  }
                  debugPrint(
                    '[RssDetail] blocked cross-origin nav: $reqHost (base=$baseHost)',
                  );
                  return NavigationDecision.prevent;
                } catch (_) {
                  return NavigationDecision.prevent;
                }
              },
            ));
          await controller.loadHtmlString(html, baseUrl: baseUrl);
        } catch (e) {
          // BATCH-05 (F-W2B-011): 平台 channel 在 widget test 环境会失败 ——
          // 不阻塞页面，但记日志 + 把错误透到 _webError 让 UI 区分原因。
          debugPrint('[RssDetail] WebView init failed: $e');
          webError = e.toString();
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
        _webError = webError;
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
        safeSetState(() => _isStarred = false);
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
        safeSetState(() => _isStarred = true);
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
      safeSetState(() => _starBusy = false);
    }
  }

  void _retry() {
    setState(() {
      _loading = true;
      _error = null;
      _webError = null;
    });
    _bootstrap();
  }

  @override
  Widget build(BuildContext context) {
    final title = (_article?['title'] as String?)?.trim().isNotEmpty == true
        ? _article!['title'] as String
        : 'RSS 文章';
    // BATCH-21c (F-W2B-012): PopScope.onPopInvokedWithResult 在 OS back
    // / 手势返回时 didPop 已发生，无法再携带 result（已知 limitation）。
    // 因此 OS back 路径下 list 收到 null，走老的"软一致"路径（保留
    // optimistic 等下次 _loadArticles 自然修正）。仅 AppBar leading
    // IconButton 主动 `context.pop(_markReadResult)` 携带 result，让 list
    // 按需 rollback。
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {},
      child: Scaffold(
        appBar: AppBar(
          // BATCH-21c (F-W2B-012): 替换默认 leading 让 AppBar back 携带
          // _markReadResult；OS back / iOS swipe back 走默认 Navigator.pop
          // 不带 result，是已知 limitation。
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: '返回',
            onPressed: () => context.pop(_markReadResult),
          ),
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
      ),
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
      // BATCH-05 (F-W2B-011): _webError 非 null 时多显示一行错误原因，
      // 让用户能区分"测试模式占位"与"真实 WebView init 失败"。
      final placeholderText = _webError != null
          ? 'WebView 加载失败：$_webError\nHTML 长度=${html.length}\nbase_url=${_baseUrl ?? ''}'
          : 'HTML 长度=${html.length}\nbase_url=${_baseUrl ?? ''}';
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Text(
          placeholderText,
          // ignore: deprecated_member_use
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }
    return WebViewWidget(controller: _webController!);
  }
}
