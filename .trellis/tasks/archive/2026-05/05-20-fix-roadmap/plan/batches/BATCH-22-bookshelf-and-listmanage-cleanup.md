# BATCH-22: bookshelf / 列表管理重复模板 + 杂项

**Stage**: P1
**Slug**: `bookshelf-and-listmanage-cleanup`
**Effort**: M (≤500 行)
**Depends on**: BATCH-18 (json_store + Provider 抽象到位)

## 1. 范围

集中 bookshelf import 错误吞掉、list/grid KeepAlive 缺失、initState then 未捕获、TabBarView sortOrder 全量重建、rule_sub / source / rss_source 三套 ~400 行重复模板这 5 条余下 P1。

## 2. 包含的 findings

- [F-W2B-015] importLocalBook 解析 catch null book_id — `flutter_app/lib/features/bookshelf/bookshelf_page.dart:299-306`
- [F-W2B-017] 列表 / 网格切换无 KeepAlive — `flutter_app/lib/features/bookshelf/bookshelf_page.dart:411-414`
- [F-W2B-041] initState 中 then(...) 未 await，未捕获 future — `flutter_app/lib/features/bookshelf/bookshelf_page.dart:64-67`
- [F-W2B-042] TabBarView children 直接列表推导，sortOrder 改时全量重建 — `flutter_app/lib/features/bookshelf/bookshelf_page.dart:240-247`
- [F-W2B-062] rule_sub / source_page / rss_source_manage_page 三套 ~400 行重复模板 — `flutter_app/lib/features/`

## 3. 影响文件

- `flutter_app/lib/features/bookshelf/bookshelf_page.dart:299-306` — 区分 jsonDecode 失败（log + "导入完成但响应格式异常"）和 book_id 缺失（log + 不跳转但不报错）
- `flutter_app/lib/features/bookshelf/bookshelf_page.dart:411-414` — `_BookListView` 加 `AutomaticKeepAliveClientMixin`，`wantKeepAlive = true`
- `flutter_app/lib/features/bookshelf/bookshelf_page.dart:64-67` — async 方法 + try-catch + debugPrint
- `flutter_app/lib/features/bookshelf/bookshelf_page.dart:240-247` — sortOrder 改用 ref.watch 在 _BookListView 内部读取（Provider）；父组件不传
- `flutter_app/lib/core/widgets/list_manage_scaffold.dart` (新增) — 接受 List provider + create/update/delete/refresh callbacks 渲染统一 UI；rule_sub / source / rss_source 三处复用

## 4. 修复方向

直接复用 master findings-flutter-features.md 各条建议。

## 5. 测试策略

- Widget test：bookshelf 切换 list/grid 后回切保留滚动位置
- Widget test：bookshelf init 失败不弹 red banner
- Widget test：rule_sub / source / rss_source 三页 UI 操作通过共同 scaffold 一致

## 6. 验收

- [ ] master finding F-W2B-015/017/041/042/062 全部消解

## 7. implement.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-flutter-features.md", "reason": "本批次涉及的 wave 2B findings"}
{"file": "flutter_app/lib/features/bookshelf/bookshelf_page.dart", "reason": "bookshelf 主体"}
{"file": "flutter_app/lib/features/source/source_page.dart", "reason": "list scaffold 复用"}
{"file": "flutter_app/lib/features/rule_sub/rule_sub_page.dart", "reason": "list scaffold 复用"}
{"file": "flutter_app/lib/features/rss/rss_source_manage_page.dart", "reason": "list scaffold 复用"}
```

## 8. check.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md", "reason": "master report"}
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-flutter-features.md", "reason": "Wave 2B"}
{"file": ".trellis/tasks/05-20-fix-roadmap/plan/batches/BATCH-22-bookshelf-and-listmanage-cleanup.md", "reason": "本批次自身验收清单"}
```
