# BATCH-26b: /my hub 14 项 + 3 分组填充

**Stage**: P2
**Slug**: `batch-26b-my-hub-fill`
**Effort**: M (~200-250 行)
**Parent**: `05-22-align-ui-with-legado-android`
**Depends on**: BATCH-26a ✅
**对照原版**：`/root/data/workspaces/doro_FriendMessage_641981595/legado/app/src/main/res/xml/pref_main.xml`

## 1. 范围

把 `flutter_app/lib/features/my/my_hub_page.dart` 从 26a 占位骨架填充为完整 hub：1:1 复刻 `pref_main.xml` 14 项 + 3 分组结构。已实现项 onTap 跳现有 GoRouter 路径；未实现项灰显（`enabled: false` + onTap = null）。spec 「页面布局对齐 (BATCH-26)」段同步入 spec。

## 2. 1:1 映射表（pref_main.xml → my_hub_page.dart）

### 第一组（无标题，pref_main.xml line 7-52）

| pref key | title 文案 | summary | flutter 状态 | onTap 行为 | icon |
|---|---|---|---|---|---|
| bookSourceManage | 书源管理 | 管理书源 | ✓ 已实现 | `context.push('/sources')` | `Icons.source_outlined` |
| txtTocRuleManage | TXT 目录规则 | 配置 txt 章节匹配 | ✗ 灰 | null | `Icons.format_list_numbered` |
| replaceManage | 替换净化 | 管理正则替换规则 | ✓ 已实现 | `context.push('/replace-rules')` | `Icons.find_replace` |
| dictRuleManage | 字典规则 | 配置词典查询 | ✗ 灰 | null | `Icons.translate` |
| themeMode | 主题模式 | 跟随系统/亮/暗 | ✗ 灰（settings 内有，hub 项灰显） | null | `Icons.brightness_6_outlined` |
| webService | Web 服务 | 局域网内 HTTP 服务 | ✗ 灰，**SwitchListTile** value=false / onChanged=null | n/a | `Icons.web` |

### 「设置」分组（pref_main.xml line 54-82）

| pref key | title 文案 | summary | flutter 状态 | onTap 行为 | icon |
|---|---|---|---|---|---|
| web_dav_setting | 备份与恢复 | WebDAV 同步与本地 zip | ✓ 已实现 | `context.push('/backup')` | `Icons.settings_backup_restore` |
| theme_setting | 主题设置 | 配色 / 排版 | ✗ 灰 | null | `Icons.palette_outlined` |
| setting | 其他设置 | 通用设置 | ✓ 已实现（→ /settings） | `context.push('/settings')` | `Icons.tune` |

### 「其它」分组（pref_main.xml line 84-125）

| pref key | title 文案 | summary | flutter 状态 | onTap 行为 | icon |
|---|---|---|---|---|---|
| bookmark | 书签 | 全局书签列表 | ✗ 灰 | null | `Icons.bookmark_outline` |
| readRecord | 阅读记录 | 累计阅读时长 | ✓ 已实现 | `context.push('/read-stats')` | `Icons.history` |
| fileManage | 文件管理 | 应用内文件浏览器 | ✗ 灰 | null | `Icons.folder_outlined` |
| about | 关于 | 版本 / 致谢 | ✗ 灰 | null | `Icons.info_outline` |
| exit | 退出 | — | ✗ 灰（一般 Flutter app 不需要） | null | `Icons.exit_to_app` |

### 不在 pref_main 但 hub 应可见的项

按 PRD R4 "不在 hub 的迁移项" 决策**不进 hub**：
- 缓存/导出 → 书架 PopupMenu（26a 已建）
- RSS 源管理 / RSS 收藏 → RSS tab AppBar（26a 已建）
- 订阅源（RuleSub）/ 二维码扫描 → settings_page 工具段保留（24c 收敛时再考虑）

## 3. UI 结构

`MyHubPage` 改为 `StatelessWidget`（不引 ViewModel/Provider，与 26a 风格一致）。Body 是 `ListView`，包含：

```
┌─────────────────────────────────┐
│ [书源管理]                       │  第一组无 header
│ [TXT 目录规则] (灰)               │
│ [替换净化]                       │
│ [字典规则] (灰)                   │
│ [主题模式] (灰)                   │
│ [Web 服务] (SwitchListTile 灰)   │
├─────────────────────────────────┤
│ ── 设置 ─────────────            │  _SectionHeader('设置')
│ [备份与恢复]                     │
│ [主题设置] (灰)                   │
│ [其他设置]                       │
├─────────────────────────────────┤
│ ── 其它 ─────────────            │  _SectionHeader('其它')
│ [书签] (灰)                       │
│ [阅读记录]                       │
│ [文件管理] (灰)                   │
│ [关于] (灰)                       │
│ [退出] (灰)                       │
└─────────────────────────────────┘
```

私有 widget：
- `_SectionHeader`（与 settings_page 现有 `_SectionHeader` 同模式：`Padding` + `Text(style: titleSmall, color: primary)`），分组前用 `Divider(indent:16, endIndent:16)`
- 复用 `ListTile` + `enabled` flag；灰显项 `enabled: false`（自动应用 disabled color），onTap 不写
- Web 服务项用 `SwitchListTile(value: false, onChanged: null)`，整 ListTile 视觉灰

## 4. 影响文件

### 改写

- `flutter_app/lib/features/my/my_hub_page.dart`（从 33 行扩到 ~200 行）

### 不动

- `settings_page.dart` 工具段 6 项（A. 保留双入口）
- 26a 已建的 explore_page / rss_tab_page
- router.dart 路由结构

### 新增（spec）

- `.trellis/spec/flutter-app/quality-and-anti-patterns.md` 加「页面布局对齐 (BATCH-26)」段：4 tab destination 映射 + hub 14 项映射表 + 占位规则 + 双入口过渡说明

## 5. 测试策略

新增 `flutter_app/test/my_hub_page_test.dart`：

1. **结构骨架**：pump `MaterialApp.router(GoRouter(...))` 把 `/my` 当 initialLocation，`tester.pumpAndSettle()` 后断言：
   - 14 个 ListTile 全部出现
   - 3 个 _SectionHeader（无第一组、'设置'、'其它'）
   - 灰显项 9 个（TXT 目录规则 / 字典规则 / 主题模式 / Web 服务 / 主题设置 / 书签 / 文件管理 / 关于 / 退出）
   - SwitchListTile (Web 服务) `value: false`、`onChanged: null`
2. **已实现项 onTap**：`tester.tap(find.text('书源管理'))` 后 `pumpAndSettle`，断言路由跳到 `/sources`（用 `GoRouter.of(context).routerDelegate.currentConfiguration.uri` 验）。同样验证另外 4 项（替换净化 / 备份与恢复 / 其他设置 / 阅读记录）。
3. **灰显项不可点**：`find.byType(ListTile).at(idx)` 的 `enabled` 字段为 false。

baseline 542 → 542 + 新增（约 3-5 个新测试）。

## 6. 验收

- [ ] /my 进入显示 14 项 + 3 分组（无、设置、其它）
- [ ] 5 个已实现项点击跳对应路由（书源管理 / 替换净化 / 备份与恢复 / 其他设置 / 阅读记录）
- [ ] 9 个灰显项不可点（含 Web 服务 SwitchListTile）
- [ ] flutter analyze 0 / flutter test PASS（baseline 542 + 新增）
- [ ] spec `.trellis/spec/flutter-app/quality-and-anti-patterns.md` 加「页面布局对齐 (BATCH-26)」段
- [ ] 不破坏 settings_page 工具段双入口（A. 保留过渡性双入口）

## 7. 不在范围

- O1：settings_page 工具段 6 项删除（→ 留可能的 26c follow-up）
- O2：未实现页（TXT 目录规则 / 字典规则 / Web 服务 / 主题设置 / 书签全局 / 文件管理 / 关于 / 退出）的真实业务实现
- O3：「分组」筛选功能在 RSS tab / 「发现」tab 的真实实现
- O4：bookshelf PopupMenu 剩余 9 项原版菜单填充

## 8. 风险点

- **Theme.disabledColor 视觉**：`ListTile.enabled: false` 在 Material3 默认 disabledColor 可能太浅，需要肉眼验证。如太浅可加 `style: ListTileStyle.list` 或显式 `iconColor: outline.withValues(alpha:.4)` 微调。
- **SwitchListTile.disabled 视觉**：`onChanged: null` 自动 disabled。track / thumb 颜色由 theme 决定，如太浅可显式 inactiveTrackColor。
- **测试 GoRouter 跳转断言**：用 `routerDelegate.currentConfiguration.uri.path` 验比 expectLater(navigation event) 更稳。
- **范围漂移风险**：26b 容易扩张到 spec 完整撰写 + 测试覆盖每个 onTap 跳转。控制：spec 段约 80-100 行；测试聚焦结构骨架 + 1-2 个 onTap smoke test，不每项都测。
