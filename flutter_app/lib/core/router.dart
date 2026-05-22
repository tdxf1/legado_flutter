import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/bookshelf/bookshelf_page.dart';
import '../features/bookshelf/book_info_edit_page.dart';
import '../features/explore/explore_page.dart';
import '../features/my/my_hub_page.dart';
import '../features/reader/reader_page.dart';
import '../features/search/search_page.dart';
import '../features/settings/backup_page.dart';
import '../features/settings/cache_management_page.dart';
import '../features/settings/read_stats_page.dart';
import '../features/settings/settings_page.dart';
import '../features/settings/webdav_config_page.dart';
import '../features/source/source_page.dart';
import '../features/download/download_page.dart';
import '../features/replace_rule/replace_rule_page.dart';
import '../features/rss/rss_article_list_page.dart';
import '../features/rss/rss_article_detail_page.dart';
import '../features/rss/rss_favorites_page.dart';
import '../features/rss/rss_source_manage_page.dart';
import '../features/rss/rss_tab_page.dart';
import '../features/rule_sub/rule_sub_page.dart';
import '../features/qr/qr_scan_page.dart';

final router = GoRouter(
  initialLocation: '/bookshelf',
  routes: [
    // BATCH-26a (05-22): 顶层 5 tab → 4 tab 重构。对齐原 legado
    // `main_bnv.xml`（书架 / 发现 / 订阅 / 我的）。
    // /search /sources /downloads /settings 退出 ShellBranch，下移到顶级
    // GoRoute；从 bookshelf AppBar IconButton / hub ListTile / PopupMenu
    // 入。
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          _AppShell(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/bookshelf',
              builder: (context, state) => const BookshelfPage(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/explore',
              builder: (context, state) => const ExplorePage(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/rss',
              builder: (context, state) => const RssTabPage(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/my',
              builder: (context, state) => const MyHubPage(),
            ),
          ],
        ),
      ],
    ),
    // BATCH-26a (05-22): 原 ShellBranch 的 4 个路由全部下移为顶级
    // GoRoute，path / builder 不变。/search 由 bookshelf AppBar search
    // IconButton 入；/sources /settings 走 hub（BATCH-26b 填）；
    // /downloads 由 bookshelf PopupMenu「缓存/导出」入。
    GoRoute(
      path: '/search',
      builder: (context, state) => const SearchPage(),
    ),
    GoRoute(
      path: '/sources',
      builder: (context, state) => const SourcePage(),
    ),
    GoRoute(
      path: '/downloads',
      builder: (context, state) => const DownloadPage(),
    ),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const SettingsPage(),
    ),
    GoRoute(
      path: '/reader',
      builder: (context, state) {
        final bookId = state.uri.queryParameters['bookId'] ?? '';
        final chapterIndex =
            int.tryParse(state.uri.queryParameters['chapterIndex'] ?? '0') ?? 0;
        return ReaderPage(bookId: bookId, chapterIndex: chapterIndex);
      },
    ),
    GoRoute(
      path: '/replace-rules',
      builder: (context, state) => const ReplaceRulePage(),
    ),
    // 批次 9 (05-19): 书信息编辑页。bookId 通过 query param 传入；页面内
    // 用 [bookByIdProvider] 拉完整 book Map 初始化 5 个 TextField。
    GoRoute(
      path: '/book-info-edit',
      builder: (context, state) {
        final bookId = state.uri.queryParameters['bookId'] ?? '';
        return BookInfoEditPage(bookId: bookId);
      },
    ),
    // 批次 10 (05-19): 本地备份/恢复页。导出 zip / 选 zip 导入。
    GoRoute(
      path: '/backup',
      builder: (context, state) => const BackupPage(),
    ),
    // 批次 11 (05-19): WebDAV 同步配置页。URL/账号/密码/设备名 4 字段。
    GoRoute(
      path: '/webdav-config',
      builder: (context, state) => const WebDavConfigPage(),
    ),
    // 批次 14 (05-19): 阅读统计页。bookshelf_page PopupMenu 入口。
    GoRoute(
      path: '/read-stats',
      builder: (context, state) => const ReadStatsPage(),
    ),
    // 批次 15 (05-19): 缓存管理页。bookshelf_page PopupMenu 入口。
    GoRoute(
      path: '/cache-management',
      builder: (context, state) => const CacheManagementPage(),
    ),
    // 批次 16 (05-19): RSS 源管理页。BATCH-26a 后入口改由 RSS tab AppBar
    // 「RSS 源设置」IconButton 进入（原 bookshelf PopupMenu 入口已撤）。
    GoRoute(
      path: '/rss-source-manage',
      builder: (context, state) => const RssSourceManagePage(),
    ),
    // 批次 17 (05-19): RSS 文章列表页。从源管理页 ListTile 点击进入。
    GoRoute(
      path: '/rss-articles',
      builder: (context, state) {
        final sourceUrl = state.uri.queryParameters['sourceUrl'] ?? '';
        return RssArticleListPage(sourceUrl: sourceUrl);
      },
    ),
    // 批次 18 (05-19): RSS 文章详情页（WebView 渲染）。从文章列表 / 收藏页进入。
    GoRoute(
      path: '/rss-articles-detail',
      builder: (context, state) {
        final sourceUrl = state.uri.queryParameters['sourceUrl'] ?? '';
        final link = state.uri.queryParameters['link'] ?? '';
        return RssArticleDetailPage(sourceUrl: sourceUrl, link: link);
      },
    ),
    // 批次 18 (05-19): RSS 收藏页。BATCH-26a 后入口改由 RSS tab AppBar
    // 「收藏」IconButton 进入（原 bookshelf PopupMenu 入口已撤）。
    GoRoute(
      path: '/rss-favorites',
      builder: (context, state) => const RssFavoritesPage(),
    ),
    // 批次 19 (05-19): 订阅源页（RuleSub MVP）。bookshelf_page PopupMenu 入口。
    GoRoute(
      path: '/rule-subs',
      builder: (context, state) => const RuleSubPage(),
    ),
    // 批次 20 (05-19): QR 扫码导入页。
    // 入口：bookshelf_page PopupMenu / source_page / rss_source_manage /
    // rule_sub 各 AppBar IconButton。扫描结果由 page 自己处理 + pop。
    GoRoute(
      path: '/qr-scan',
      builder: (context, state) => const QrScanPage(),
    ),
  ],
);

class _AppShell extends StatelessWidget {
  final StatefulNavigationShell navigationShell;

  const _AppShell({required this.navigationShell});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      // BATCH-26a (05-22): 4 NavigationDestination 对齐原 legado
      // `main_bnv.xml` 0-3 槽位（书架 / 发现 / 订阅 / 我的）。
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: (index) => navigationShell.goBranch(
          index,
          initialLocation: index == navigationShell.currentIndex,
        ),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.library_books_outlined),
            selectedIcon: Icon(Icons.library_books),
            label: '书架',
          ),
          NavigationDestination(
            icon: Icon(Icons.explore_outlined),
            selectedIcon: Icon(Icons.explore),
            label: '发现',
          ),
          NavigationDestination(
            icon: Icon(Icons.rss_feed_outlined),
            selectedIcon: Icon(Icons.rss_feed),
            label: '订阅',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: '我的',
          ),
        ],
      ),
    );
  }
}
