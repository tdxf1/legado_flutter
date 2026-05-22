import 'package:flutter/material.dart';

/// 「我的」hub 页占位骨架（BATCH-26a / 05-22）。
///
/// 对齐原 legado/ Android `main_bnv.xml` 第 3 槽位 `menu_my_config`
/// （MyFragment + `pref_main.xml`）。BATCH-26a 仅建空壳，14 项 ListTile
/// + 3 分组在 BATCH-26b 填充：
///
/// - 第一组（无标题）：书源管理 / TXT 目录规则 / 替换净化 /
///   字典规则 / 主题模式 / Web 服务
/// - 「设置」分组：备份与恢复 / 主题设置 / 其他设置
/// - 「其它」分组：书签 / 阅读记录 / 文件管理 / 关于 / 退出
///
/// 不引入 ViewModel / Provider。
class MyHubPage extends StatelessWidget {
  const MyHubPage({super.key});

  @override
  Widget build(BuildContext context) {
    final outline = Theme.of(context).colorScheme.outline;
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: Center(
        child: Text(
          '我的 (待 BATCH-26b 填充)',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: outline,
              ),
        ),
      ),
    );
  }
}
