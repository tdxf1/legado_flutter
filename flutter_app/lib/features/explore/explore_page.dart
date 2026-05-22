import 'package:flutter/material.dart';

/// 「发现」tab 占位页（BATCH-26a / 05-22）。
///
/// 对齐原 legado/ Android `main_bnv.xml` 第 1 槽位 `menu_discovery`
/// （ExploreFragment）。BATCH-26a 仅建骨架，真业务（书源 explore 分类）
/// 留 follow-up。不引入 ViewModel / Provider。
class ExplorePage extends StatelessWidget {
  const ExplorePage({super.key});

  @override
  Widget build(BuildContext context) {
    final outline = Theme.of(context).colorScheme.outline;
    return Scaffold(
      appBar: AppBar(title: const Text('发现')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.explore, size: 96, color: outline.withValues(alpha: 0.4)),
            const SizedBox(height: 16),
            Text(
              '发现待实现 (Explore)',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: outline,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
