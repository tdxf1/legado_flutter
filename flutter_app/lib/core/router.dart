import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/bookshelf/bookshelf_page.dart';
import '../features/bookshelf/book_info_edit_page.dart';
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

final router = GoRouter(
  initialLocation: '/bookshelf',
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) => _AppShell(navigationShell: navigationShell),
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
              path: '/search',
              builder: (context, state) => const SearchPage(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/sources',
              builder: (context, state) => const SourcePage(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/downloads',
              builder: (context, state) => const DownloadPage(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/settings',
              builder: (context, state) => const SettingsPage(),
            ),
          ],
        ),
      ],
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
  ],
);

class _AppShell extends StatelessWidget {
  final StatefulNavigationShell navigationShell;

  const _AppShell({required this.navigationShell});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
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
            icon: Icon(Icons.search_outlined),
            selectedIcon: Icon(Icons.search),
            label: '搜索',
          ),
          NavigationDestination(
            icon: Icon(Icons.source_outlined),
            selectedIcon: Icon(Icons.source),
            label: '书源',
          ),
          NavigationDestination(
            icon: Icon(Icons.download_outlined),
            selectedIcon: Icon(Icons.download),
            label: '下载',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}

