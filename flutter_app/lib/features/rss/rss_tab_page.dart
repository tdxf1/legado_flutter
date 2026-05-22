import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// 「订阅」tab 占位页（BATCH-26a / 05-22）。
///
/// 对齐原 legado/ Android `main_bnv.xml` 第 2 槽位 `menu_rss`
/// （RssFragment）+ `main_rss.xml` 顶部 3 个 always icon
/// （收藏 / 分组 / RSS 源设置）。
///
/// BATCH-26a 评估复用 [`RssSourceManagePage`] 的列表视图，结论：
/// 它本身带 Scaffold + AppBar，直接嵌入会重复 AppBar；改写为可嵌入
/// widget 的工作量超出本批范围（影响现有 widget test）。先用 placeholder
/// + 3 个 IconButton 入口，列表展示留 follow-up。
///
/// 不引入 ViewModel / Provider。
class RssTabPage extends StatelessWidget {
  const RssTabPage({super.key});

  @override
  Widget build(BuildContext context) {
    final outline = Theme.of(context).colorScheme.outline;
    return Scaffold(
      appBar: AppBar(
        title: const Text('订阅'),
        actions: [
          IconButton(
            icon: const Icon(Icons.star_outline),
            tooltip: '收藏',
            onPressed: () => context.push('/rss-favorites'),
          ),
          // 「分组」入口暂未实现：原版 main_rss.xml 这条菜单是动态生成的
          // 按 source_group 筛选子菜单，本批仅占位（disabled），留 follow-up。
          const IconButton(
            icon: Icon(Icons.folder_outlined),
            tooltip: '分组',
            onPressed: null,
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'RSS 源设置',
            onPressed: () => context.push('/rss-source-manage'),
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.rss_feed,
                  size: 96, color: outline.withValues(alpha: 0.4)),
              const SizedBox(height: 16),
              Text(
                '订阅源列表 (RSS)',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: outline,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                '点右上角「RSS 源设置」管理订阅，「收藏」查看已收藏文章',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: outline,
                    ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
