import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// 「我的」hub 页（BATCH-26b / 05-22）。
///
/// 1:1 复刻原 legado/ Android `pref_main.xml` 14 项 + 3 分组结构：
/// - 第一组（无 header）：书源管理 / TXT 目录规则 / 替换净化 /
///   字典规则 / 主题模式 / Web 服务（SwitchListTile）
/// - 「设置」分组：备份与恢复 / 主题设置 / 其他设置
/// - 「其它」分组：书签 / 阅读记录 / 文件管理 / 关于 / 退出
///
/// 已实现 5 项（书源管理 / 替换净化 / 备份与恢复 / 其他设置 / 阅读记录）
/// onTap 跳现有 GoRoute；其余 9 项灰显（`enabled: false` + onTap 不写 /
/// SwitchListTile.onChanged: null）。占位策略对齐父 PRD R6：不弹
/// SnackBar，让对照原版 14 项可见。BATCH-26b 不引入 ViewModel/Provider，
/// 与 26a 占位风格一致；私有 `_SectionHeader` 与 settings_page 的同名
/// widget 同模式（不 import 避免 features 间互相依赖）。
class MyHubPage extends StatelessWidget {
  const MyHubPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        children: [
          // 第一组（无 header）
          ListTile(
            leading: const Icon(Icons.source_outlined),
            title: const Text('书源管理'),
            subtitle: const Text('管理书源'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/sources'),
          ),
          const ListTile(
            enabled: false,
            leading: Icon(Icons.format_list_numbered),
            title: Text('TXT 目录规则'),
            subtitle: Text('配置 txt 章节匹配'),
            trailing: Icon(Icons.chevron_right),
          ),
          ListTile(
            leading: const Icon(Icons.find_replace),
            title: const Text('替换净化'),
            subtitle: const Text('管理正则替换规则'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/replace-rules'),
          ),
          const ListTile(
            enabled: false,
            leading: Icon(Icons.translate),
            title: Text('字典规则'),
            subtitle: Text('配置词典查询'),
            trailing: Icon(Icons.chevron_right),
          ),
          const ListTile(
            enabled: false,
            leading: Icon(Icons.brightness_6_outlined),
            title: Text('主题模式'),
            subtitle: Text('跟随系统/亮/暗'),
            trailing: Icon(Icons.chevron_right),
          ),
          const SwitchListTile(
            value: false,
            onChanged: null,
            secondary: Icon(Icons.web),
            title: Text('Web 服务'),
            subtitle: Text('局域网内 HTTP 服务'),
          ),

          const Divider(indent: 16, endIndent: 16),
          // 「设置」分组
          const _SectionHeader(title: '设置'),
          ListTile(
            leading: const Icon(Icons.settings_backup_restore),
            title: const Text('备份与恢复'),
            subtitle: const Text('WebDAV 同步与本地 zip'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/backup'),
          ),
          const ListTile(
            enabled: false,
            leading: Icon(Icons.palette_outlined),
            title: Text('主题设置'),
            subtitle: Text('配色 / 排版'),
            trailing: Icon(Icons.chevron_right),
          ),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('其他设置'),
            subtitle: const Text('通用设置'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings'),
          ),

          const Divider(indent: 16, endIndent: 16),
          // 「其它」分组
          const _SectionHeader(title: '其它'),
          const ListTile(
            enabled: false,
            leading: Icon(Icons.bookmark_outline),
            title: Text('书签'),
            subtitle: Text('全局书签列表'),
            trailing: Icon(Icons.chevron_right),
          ),
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('阅读记录'),
            subtitle: const Text('累计阅读时长'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/read-stats'),
          ),
          const ListTile(
            enabled: false,
            leading: Icon(Icons.folder_outlined),
            title: Text('文件管理'),
            subtitle: Text('应用内文件浏览器'),
            trailing: Icon(Icons.chevron_right),
          ),
          const ListTile(
            enabled: false,
            leading: Icon(Icons.info_outline),
            title: Text('关于'),
            subtitle: Text('版本 / 致谢'),
            trailing: Icon(Icons.chevron_right),
          ),
          const ListTile(
            enabled: false,
            leading: Icon(Icons.exit_to_app),
            title: Text('退出'),
            trailing: Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }
}

/// 与 settings_page 私有 `_SectionHeader` 同模式（Padding + Text titleSmall +
/// color: primary）。BATCH-26b 不 import settings_page —— features 间不互相
/// 依赖，重写一份保持本 file 自洽。
class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }
}
