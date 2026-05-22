# BATCH-29: easy-win 零星收尾

## Goal

收尾 27d/27e/28 累积的 4 项低 complexity Out of Scope，全部纯 Dart 无 Rust。
每项 ~30-60 分钟，总 ~半天。

## Requirements

### R1. RSS GridView responsive 列数

- `_buildBody` 的 GridView delegate 改用 `SliverGridDelegateWithMaxCrossAxisExtent`
  （`maxCrossAxisExtent: 120`），自适应屏幕宽度。单行替换 ~3 字符。
- 手机竖屏 ~360dp → 3 列，平板 ~600dp → 5 列。与固定 4 列比肉眼体验一致
  且跨设备自适应。

### R2. RSS 搜索 `group:` prefix

- `_filteredSources` 搜索逻辑加 prefix 检测：
  - `_searchQuery.startsWith('group:')` → 去掉 `group:` 前缀 → 匹配
    `source_group` contains（而非 name/URL）。
  - 其余 query 走原逻辑（name+URL+group 模糊匹配）。
- ~10 行 Dart 改。

### R3. add_url 多行 URL 批量 add

- `_AddUrlDialog`: `TextField(maxLines: 5)` → 用户可粘贴多行 URL。
- `_onAddUrl` handler：`\n` split → 逐行 trim → 跳过空行 → 对每行走
  原逻辑（find_source → getBookInfo → saveBook）。
- 进度：简单计数成功数，SnackBar 总结「添加完成：成功 X / 失败 Y」。
- ~30 行 Dart 改。

### R4. import_bookshelf URL→json

- `_onImportBookshelf` SimpleDialog 加第 3 选项「从 URL 导入」（1=粘贴
  / 2=文件 / 3=URL）。
- 选 URL → `_UrlImportDialog` 单行 TextField → 输 URL → HTTP GET（用
  `dart:io` HttpClient 或简单 `http` package？检查项目已有依赖）。
- 返回 JSON string → 进入现有 parse 流程。
- ~30 行 Dart 改。

## Acceptance Criteria

- [ ] GridView 自适应列数（maxCrossAxisExtent=120）
- [ ] 搜索 `group:科技` → 仅「科技」组源可见
- [ ] add_url 多行 TextField → 多 URL 逐行 add → 总结 SnackBar
- [ ] import_bookshelf URL 导入 option → HTTP GET → parse JSON
- [ ] flutter analyze 0 / flutter test all green
- [ ] 现有测试不变（最多加 1 项 group prefix 测试）

## Definition of Done

- spec 加 BATCH-29 easy-win 子节（4 项契约 + Forbidden ≥2 条）
- 无 Rust/FRB 改动

## Out of Scope

- 换源（BookSource 表 + WebBook stack） → BATCH-30+
- 导出全部使用书源 → BATCH-30+
- 置顶 FRB → BATCH-30+
- 规则订阅 header → BATCH-30+

## Technical Notes

### Flutter 端改动文件

- `flutter_app/lib/features/rss/rss_tab_page.dart`：R1 列数 + R2 group prefix
- `flutter_app/lib/features/bookshelf/bookshelf_page.dart`：R3 _AddUrlDialog + _onAddUrl / R4 _onImportBookshelf + _UrlImportDialog
- `flutter_app/test/rss_tab_page_test.dart`：1 新 testWidgets（R2 group prefix）
- `flutter_app/test/bookshelf_add_url_test.dart`：可能扩展（R3 多行）
