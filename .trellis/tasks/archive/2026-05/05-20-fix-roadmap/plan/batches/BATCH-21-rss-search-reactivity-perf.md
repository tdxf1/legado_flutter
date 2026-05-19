# BATCH-21: RSS / search 反应式性能 + 时序

**Stage**: P1
**Slug**: `rss-search-reactivity-perf`
**Effort**: M (≤500 行)
**Depends on**: BATCH-20 (API client wrappers 到位)

## 1. 范围

集中 RSS / search 7 条性能与时序问题：article detail 全数组遍历、optimistic mark_read 与 detail 写库时序、article_list setState 整 map 重建、source manage onToggleEnabled 直接修改原 map、SSE 流式搜索每条 List.unmodifiable、并行搜索旧 future 无法取消、RSS catch 中 setState + ScaffoldMessenger 顺序。

## 2. 包含的 findings

- [F-W2B-009] rss article detail 找文章用全数组遍历 — `flutter_app/lib/features/rss/rss_article_detail_page.dart:146-159`
- [F-W2B-012] RSS optimistic mark_read 与 detail 异步写库时序 — `flutter_app/lib/features/rss/rss_article_list_page.dart:268-270`
- [F-W2B-013] rss article_list setState 整 map 重建 — `flutter_app/lib/features/rss/rss_article_list_page.dart:357-364`
- [F-W2B-014] rss source manage onToggleEnabled 直接修改原 map — `flutter_app/lib/features/rss/rss_source_manage_page.dart:191-196`
- [F-W2B-018] SSE 流式搜索每条 result List.unmodifiable — `flutter_app/lib/features/search/search_page.dart:439-444, 469-473`
- [F-W2B-019] 多书源并行搜索旧 future 无法取消 — `flutter_app/lib/features/search/search_page.dart:347-358`
- [F-W2B-032] rss _loadArticles catch 中 setState + ScaffoldMessenger 顺序 — `flutter_app/lib/features/rss/rss_article_list_page.dart:255-256`

## 3. 影响文件

- `core/bridge/src/api.rs` — 新增 `rss_article_get_by_origin_link(origin, link) -> RssArticle` FRB 桥（避免 Dart 端全数组遍历）
- `flutter_app/lib/features/rss/rss_article_detail_page.dart:146-159` — 用新 FRB 桥 + Future.wait 并行
- `flutter_app/lib/features/rss/rss_article_list_page.dart` — 每个 sort 的 list 抽 ConsumerWidget + StateProvider.family；optimistic mark_read 路径加回调让 list 决定保留 / rollback；catch 中 mounted check 移到方法开头
- `flutter_app/lib/features/rss/rss_source_manage_page.dart:191-196` — `_records = List.of(_records)..[idx] = {...record, 'enabled': newValue}` immutable update
- `flutter_app/lib/features/search/search_page.dart:347-358, 439-473` — `int _searchSeq` token；SSE 累积到一定数量再触发 setState；precision 过滤改增量

## 4. 修复方向

直接复用 master findings-flutter-features.md 各条建议。

## 5. 测试策略

- Widget test：search 切换 keyword 后旧结果不会覆盖新结果
- Widget test：RSS detail 打开速度提升（FRB 单条查询）
- Widget test：source manage toggle 后 _records 不被原地修改（aliasing 校验）
- Performance overlay：search SSE / RSS list rebuild 量下降

## 6. 验收

- [ ] master finding F-W2B-009/012/013/014/018/019/032 全部消解
- [ ] 现有 Flutter 测试套件回归通过

## 7. implement.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-flutter-features.md", "reason": "本批次涉及的 wave 2B findings"}
{"file": "core/bridge/src/api.rs", "reason": "新增 rss_article_get_by_origin_link"}
{"file": "flutter_app/lib/features/rss/rss_article_detail_page.dart", "reason": "detail 全数组遍历"}
{"file": "flutter_app/lib/features/rss/rss_article_list_page.dart", "reason": "list reactivity"}
{"file": "flutter_app/lib/features/rss/rss_source_manage_page.dart", "reason": "immutable update"}
{"file": "flutter_app/lib/features/search/search_page.dart", "reason": "SSE + future cancel"}
```

## 8. check.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md", "reason": "master report"}
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-flutter-features.md", "reason": "Wave 2B"}
{"file": ".trellis/tasks/05-20-fix-roadmap/plan/batches/BATCH-21-rss-search-reactivity-perf.md", "reason": "本批次自身验收清单"}
```
