# BATCH-18f: F-W2B-016 bookshelf AppBar PopupMenu 重组（方案 1）

## Goal

闭环 F-W2B-016：把 `flutter_app/lib/features/bookshelf/bookshelf_page.dart:122-231` 的 9 项 PopupMenu 重组为方案 1 — bookshelf 仅保留"书架场景"4 项（manage_groups / import_local / qr_scan / rss_source_manage），把 5 项移到 `settings_page.dart` 的"工具"段（backup / read_stats / cache_management / rss_favorites / rule_subs）。`router.dart` 路由表零改动（入口位置变更，路径不变）。

## What I already know

### 来自 BATCH-18d explore audit（2026-05-20）+ 主对话复审（2026-05-21）

**1. 9 项 PopupMenu 现状**（`bookshelf_page.dart:122-231`）

| # | value | label | icon | 路由 / action |
|---|---|---|---|---|
| 1 | `manage_groups` | 管理分组 | `folder_outlined` | `showDialog(GroupManageDialog())`（无路由）|
| 2 | `backup` | 备份/恢复 | `settings_backup_restore` | `/backup`（router.dart:96 BackupPage）|
| 3 | `import_local` | 导入本地书 | `note_add` | `_onImportLocalBook(context)`（FilePicker + FRB）|
| 4 | `read_stats` | 阅读统计 | `timer_outlined` | `/read-stats`（router.dart:106）|
| 5 | `cache_management` | 缓存管理 | `cleaning_services_outlined` | `/cache-management`（router.dart:111）|
| 6 | `rss_source_manage` | RSS 源管理 | `rss_feed` | `/rss-source-manage`（router.dart:116）|
| 7 | `rss_favorites` | RSS 收藏 | `star_outline` | `/rss-favorites`（router.dart:138）|
| 8 | `rule_subs` | 订阅源 | `cloud_sync_outlined` | `/rule-subs`（router.dart:143）|
| 9 | `qr_scan` | 扫码导入 | `qr_code_scanner` | `/qr-scan`（router.dart:150）|

**2. settings_page.dart 现有"工具"段**（L181-188）

```dart
_SectionHeader(title: '工具'),
ListTile(
  leading: const Icon(Icons.rule),
  title: const Text('替换规则'),
  subtitle: const Text('管理正则替换规则'),
  trailing: const Icon(Icons.chevron_right),
  onTap: () => context.push('/replace-rules'),
),
```

只有 1 项 `replace_rules`，下面是分隔线 + "关于" 段。可以直接在"工具"段下面追加新 ListTile，不需要新建分组。

**3. 方案 1 拆分（用户决策锁定）**

**bookshelf 留 4 项**（书架场景高频需求）：
- `manage_groups`（直接操作 Tab 数据）
- `import_local`（直接产出新书到书架）
- `qr_scan`（书架页扫码导入书源/书是常用入口）
- `rss_source_manage`（书源/RSS 源同级，书架顶层入口对齐 source_page 风格）

**移 settings"工具"段 5 项**：
- `backup`（全局数据管理）
- `read_stats`（跨书统计）
- `cache_management`（管理跨书数据）
- `rss_favorites`（RSS 子功能，可后续考虑挪到 RSS 源管理页）
- `rule_subs`（订阅源管理，与书源同级）

router.dart 0 改动 — 9 个路由全保留，只是入口位置变更。

**4. 测试影响（来自 BATCH-18d audit 复用）**

- `test/bookshelf_page_test.dart` 测的是 TabBar / 排序对话框 / 书项渲染；**完全没断言 PopupMenu 9 项内容**
- `test/bookshelf_local_import_test.dart` 唯一测 PopupMenu 的 case，验证"导入本地书"项存在 + 点击触发 import override。**保留这一项即可不破**
- 其它 8 项（manage_groups / backup / read_stats / cache_management / rss_* / rule_subs / qr_scan）都没断言它们在 bookshelf PopupMenu 里
- `test/settings_page_test.dart` 检查 grep 是否需要更新（如有 ListTile 数量断言）

挪到 settings_page 后**不会破现有测试**，但可以顺手补 ListTile 存在断言。

**5. 顺手 finding**

BATCH-18d audit 提到 settings_page.dart:165 `saveThemeModeToDisk` 仍调用（OK，BATCH-18d 不动 themeMode），但 `settings_page.dart` 注释里的"批次 N (05-19)" mention 9 个批次的功能逐步追加 — 没有 cleanup，本批不动。

## Open Questions

（已收敛）

## Requirements (final)

### MVP scope（4 项）

1. **改 `flutter_app/lib/features/bookshelf/bookshelf_page.dart:122-231`**
   - PopupMenu `onSelected` switch：删 5 个 case（backup / read_stats / cache_management / rss_favorites / rule_subs）
   - PopupMenu `itemBuilder`：删 5 个 PopupMenuItem
   - 顺序保留：`manage_groups` → `import_local` → `qr_scan` → `rss_source_manage`
   - 顶部加注释指向 BATCH-18f / F-W2B-016 + settings_page 工具段

2. **改 `flutter_app/lib/features/settings/settings_page.dart:181-188`**
   - "工具"段下追加 5 个 ListTile（顺序：backup / read_stats / cache_management / rss_source_manage NO（保留 bookshelf）/ rss_favorites / rule_subs）
   - 调整顺序：backup（最常用） → read_stats → cache_management → rss_favorites → rule_subs（订阅源最专业）→ replace_rules（最末）
   - 等等 — replace_rules 已经在工具段，新增的 5 项**追加在 replace_rules 之前还是之后**？建议：备份/恢复（最常用）→ 阅读统计 → 缓存管理 → RSS 收藏 → 订阅源 → 替换规则（保留原位置最末）
   - icon + label + subtitle + onTap 与 bookshelf 原内容对齐
   - subtitle 写功能简介（"导出/导入到 zip" / "查看阅读时长统计" 等）

3. **新增 widget test 验证 settings_page ListTile**
   - `test/settings_page_test.dart`（如不存在则新建）：渲染 SettingsPage，断言 6 个工具段 ListTile 全部存在（备份/阅读统计/缓存管理/RSS 收藏/订阅源/替换规则）+ 点击其中 2-3 项触发预期路由（用 `goRouter` mock 或 navigator observer）
   - 若已有 settings_page_test：追加 6 项 ListTile 存在断言

4. **master report 同步**
   - F-W2B-016 标 "Resolved by BATCH-18f (方案 1)"
   - findings-flutter-features.md + findings.md 主索引

### 不在范围内

- 新建独立"工具"页（方案 1 不需要，settings"工具"段够用）
- 修改 router.dart 路由表（路径不变，仅入口移动）
- BATCH-18 路线图剩余 finding（已全部完成 W2A-001/002/003/008 + W2B-022/016 共 6 条 + 衍生 W1A-055/056 + W2A-081）
- saveRefreshRateModeToDisk 0 caller 死代码（BATCH-18c 留观察）

## Acceptance Criteria

- [ ] `bookshelf_page.dart` PopupMenu 仅 4 项：manage_groups / import_local / qr_scan / rss_source_manage
- [ ] `bookshelf_page.dart::onSelected` switch 仅 4 个 case + 备注 BATCH-18f 注释
- [ ] `settings_page.dart` "工具"段 6 个 ListTile：备份/恢复 → 阅读统计 → 缓存管理 → RSS 收藏 → 订阅源 → 替换规则
- [ ] `flutter analyze` 0 warning
- [ ] `flutter test` 全部 PASS（旧 402 + 新增 settings ListTile 测试 ≈ 405）
- [ ] master report `findings-flutter-features.md` F-W2B-016 标 "Resolution (BATCH-18f, 方案 1)"
- [ ] master report `findings.md` 主索引同步
- [ ] `bookshelf_local_import_test.dart` 维持 PASS（"导入本地书"项保留）

## Definition of Done

- bookshelf AppBar PopupMenu 从 9 项缩到 4 项（书架场景高频）
- 5 项移 settings_page"工具"段，与 replace_rules 共置
- router.dart 0 改动
- F-W2B-016 闭环（方案 1）
- BATCH-18 路线图 6 条 Flutter finding 全部清完

## Decision (ADR-lite)

**Context**: BATCH-18d explore 把 F-W2B-016 拆出三个候选方案：保守（4+5 拆分）/ 折中（3+RSS 中转）/ 激进（navbar 6 tab）。F-W2A-008/W2B-022/W2A-058(-081) 三条已闭环（BATCH-18d/18e/18g），F-W2B-016 是 BATCH-18 路线图最后一条 Flutter finding。

**Decision**: 选项 1（保守 4+5）— bookshelf 留 4 项书架场景高频，移 5 项到 settings"工具"段，router.dart 0 改动。

**Consequences**:
- ~100 行净 diff（bookshelf -50 行 PopupMenu 项 / settings_page +60 行 ListTile / test +30 行）
- bookshelf AppBar PopupMenu 项从 9 项缩到 4 项，UI 简洁
- settings"工具"段从 1 项扩到 6 项，分类合理（数据 / 统计 / 配置）
- 用户心智模型：书架页 = 书架操作，设置页 = 工具/数据管理
- 不引入新页面（独立"工具"页）或 navbar tab 重构（方案 2/3 留未来需要时再拆）

## Technical Notes

### 风险点

- **用户习惯变更**：现有用户在 bookshelf PopupMenu 用过 backup / read_stats / cache_management / rss_favorites / rule_subs；改后他们要改去 settings 找。Android-only 主线阶段影响有限（用户量小），但需在 commit message 写清楚帮助用户感知。
- **settings"工具"段视觉密度**：从 1 项扩到 6 项，下面紧跟"关于"段，整页 ListView 仍可滚动；如果视觉太挤，可以加 SubHeader 二级分类（"数据管理"/"配置"），但本批保守不做。
- **rss_favorites 的归属**：理论上 RSS 收藏更适合 RSS 源管理页内 tab 切换，但本批不动 RSS 内部架构，先把入口集中到 settings。

### 实施顺序

1. read `bookshelf_page.dart:122-231` 完整 PopupMenu 段
2. read `settings_page.dart:181-188` 工具段
3. 改 `bookshelf_page.dart`：onSelected switch + itemBuilder 删 5 项
4. 改 `settings_page.dart`：工具段追加 5 个 ListTile，顺序：backup → read_stats → cache_management → rss_favorites → rule_subs → 现有 replace_rules
5. `flutter analyze` 验证
6. 看 `test/settings_page_test.dart` 是否存在，决定新建 vs 追加
7. 加新 widget test 验证 6 个 ListTile + 至少 1 项点击触发路由
8. `flutter test` 验证（用户跑）
9. 更新 master report：F-W2B-016 标 Resolution
10. archive + commit

### settings_page.dart 工具段改造草稿

```dart
_SectionHeader(title: '工具'),
ListTile(
  leading: const Icon(Icons.settings_backup_restore),
  title: const Text('备份/恢复'),
  subtitle: const Text('导出/导入书架数据到 zip'),
  trailing: const Icon(Icons.chevron_right),
  onTap: () => context.push('/backup'),
),
ListTile(
  leading: const Icon(Icons.timer_outlined),
  title: const Text('阅读统计'),
  subtitle: const Text('查看阅读时长'),
  trailing: const Icon(Icons.chevron_right),
  onTap: () => context.push('/read-stats'),
),
ListTile(
  leading: const Icon(Icons.cleaning_services_outlined),
  title: const Text('缓存管理'),
  subtitle: const Text('清理章节内容缓存'),
  trailing: const Icon(Icons.chevron_right),
  onTap: () => context.push('/cache-management'),
),
ListTile(
  leading: const Icon(Icons.star_outline),
  title: const Text('RSS 收藏'),
  subtitle: const Text('已收藏的 RSS 文章'),
  trailing: const Icon(Icons.chevron_right),
  onTap: () => context.push('/rss-favorites'),
),
ListTile(
  leading: const Icon(Icons.cloud_sync_outlined),
  title: const Text('订阅源'),
  subtitle: const Text('RuleSub 订阅管理'),
  trailing: const Icon(Icons.chevron_right),
  onTap: () => context.push('/rule-subs'),
),
ListTile(
  leading: const Icon(Icons.rule),
  title: const Text('替换规则'),
  subtitle: const Text('管理正则替换规则'),
  trailing: const Icon(Icons.chevron_right),
  onTap: () => context.push('/replace-rules'),
),
```

### bookshelf_page.dart 改造草稿

```dart
PopupMenuButton<String>(
  tooltip: '更多',
  onSelected: (value) async {
    // BATCH-18f (F-W2B-016)：bookshelf AppBar 仅保留书架场景高频 4 项；
    // backup / read_stats / cache_management / rss_favorites / rule_subs
    // 已移到 settings_page 工具段。router.dart 路由表 0 改动。
    if (value == 'manage_groups') {
      await showDialog(
        context: context,
        builder: (_) => const GroupManageDialog(),
      );
    } else if (value == 'import_local') {
      await _onImportLocalBook(context);
    } else if (value == 'rss_source_manage') {
      if (context.mounted) context.push('/rss-source-manage');
    } else if (value == 'qr_scan') {
      if (context.mounted) context.push('/qr-scan');
    }
  },
  itemBuilder: (context) => const [
    PopupMenuItem(
      value: 'manage_groups',
      child: ListTile(...),
    ),
    PopupMenuItem(
      value: 'import_local',
      child: ListTile(...),
    ),
    PopupMenuItem(
      value: 'rss_source_manage',
      child: ListTile(...),
    ),
    PopupMenuItem(
      value: 'qr_scan',
      child: ListTile(...),
    ),
  ],
),
```

### 测试 case 设计

**新增 `test/settings_page_test.dart`**（如不存在）或追加：

```dart
testWidgets('SettingsPage 工具段含 6 项 ListTile', (tester) async {
  await tester.pumpWidget(MaterialApp(home: ProviderScope(child: SettingsPage())));
  await tester.pumpAndSettle();
  
  expect(find.text('备份/恢复'), findsOneWidget);
  expect(find.text('阅读统计'), findsOneWidget);
  expect(find.text('缓存管理'), findsOneWidget);
  expect(find.text('RSS 收藏'), findsOneWidget);
  expect(find.text('订阅源'), findsOneWidget);
  expect(find.text('替换规则'), findsOneWidget);
});
```

router 触发的实际跳转 widget test 比较麻烦（需要 mock GoRouter），可以单独 verify ListTile 的 `onTap` 不为 null + finger tap，或用 NavigatorObserver 捕获 push。本批简单做：仅断言 ListTile 存在，不测跳转（路由路径已经在 router.dart 现有），跳转测试在每个 page 自己的 test 里覆盖。

### 净 diff 估算

| 文件 | +行 | -行 | 净 |
|---|---|---|---|
| `lib/features/bookshelf/bookshelf_page.dart` | +5（注释） | -55（5 个 onSelect case + 5 个 PopupMenuItem）| -50 |
| `lib/features/settings/settings_page.dart` | +50（5 个 ListTile）| 0 | +50 |
| `test/settings_page_test.dart` | +30（如新建）| 0 | +30 |
| **合计** | **+85** | **-55** | **+30** |

## Research References

- 本任务沿用 BATCH-18d explore audit + 主对话复审 settings_page.dart 现状
- BATCH-18 路线图：`.trellis/tasks/archive/2026-05/05-20-fix-roadmap/plan/batches/BATCH-18-flutter-dead-code-and-io-abstract.md`
- F-W2B-016 finding：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-flutter-features.md:226-234`
- BATCH-18d archive：`.trellis/tasks/archive/2026-05/05-20-batch-18d-flutter-w2a-w2b-finding/`（拆分方案 1/2/3 草案）
