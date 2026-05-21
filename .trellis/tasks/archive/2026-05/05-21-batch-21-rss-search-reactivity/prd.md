# BATCH-21: RSS / search 反应式性能 + 时序（6 finding，方案 A 仅 Flutter 层）

> Roadmap：`.trellis/tasks/archive/2026-05/05-20-fix-roadmap/plan/batches/BATCH-21-rss-search-reactivity-perf.md`
> Master report：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md` 主题 6: Reader 状态机 / 渲染性能（rss/search 子集）

## Goal

收紧 RSS / search 6 个反应式性能 + 时序问题，全部走 Flutter 层不动 Rust：immutable map update / KeepAlive / 旧 future 序号 token / mounted check 一致性 / detail 并行化 / mark_read 时序契约文档化。

清理 6 条 finding（实测）：

1. **F-W2B-009 [P1][B-正确性][rss/article_detail]** 找文章用全数组遍历 — 缩范围：仅并行化（`Future.wait`），不加 FRB 桥
2. **F-W2B-012 [P1][B-正确性][rss/article_list]** Optimistic mark_read 与 detail 写库时序软一致 — 缩范围：仅文档化
3. **F-W2B-013 [P1][C-性能][rss/article_list]** setState 整 `_articlesBySort` map 触发 TabBarView 全 tab rebuild — `AutomaticKeepAliveClientMixin` 退而求其次方案
4. **F-W2B-014 [P1][B-正确性][rss/source_manage]** `_records[idx]['enabled'] = newValue` 原地修改 → `List.of` immutable update
5. **F-W2B-019 [P1][B-正确性][search]** 多 future 旧值幽灵覆盖 → `int _searchSeq` token
6. **F-W2B-032 [P1][B-正确性][rss/article_list]** `_loadArticles` catch 中 ScaffoldMessenger 缺 mounted check → catch 开头 early-return

不做：
- **F-W2B-018** SSE 流式搜索 List.unmodifiable — **已被 BATCH-18b 处理**：search_page 中 `_doSearchViaSse` 已删除（grep 全文 0 命中），`List.unmodifiable` 也无残留；transport / SSE 整组在 BATCH-18b 已删 ~700 行（finding F-W2A-002 Resolution）。
- F-W2B-009 加 FRB 桥 `rss_article_get_by_origin_link`（rust_api 已有 dao 但缺 FRB 桥）— PRD Out of Scope（跨层 binary contract 变更，回归风险大；并行化已能消除 list + isStarred + fetchHtml 三个 await 的串行 latency）— 留 BATCH-21b
- F-W2B-013 `StateProvider.family((sort))` 完整重构 — PRD Out of Scope（roadmap 推荐方案，~150 行重写 article_list_page.dart）；`AutomaticKeepAliveClientMixin` 是 finding 提到的"退而求其次"方案，最小改动消除 tab 切换 scroll position 丢失 + ListView state 重建

## Decision (ADR-lite)

**Context**：roadmap 列 7 finding（实测有效 6 条；F-W2B-018 已被 BATCH-18b 隐式 Resolved）。其中 F-W2B-009 可加 FRB 桥（Rust `rss_article_dao::get_by_origin_link` 已 line 147 + 单测 line 464），但需要 codegen + .so 重打包 + cargo + flutter 全面验证。F-W2B-013 推荐 StateProvider.family per-tab 重构，但风险大。

**Decision**：方案 A — 仅 Flutter 层 6 finding，最小风险。
- F-W2B-009：detail _bootstrap 内 list + isStarred + fetchHtml 改 `Future.wait` 并行（消除 3 个 await 的串行 latency；list 本身仍走全数组遍历但只是这一次比之前 + 2 个并行的串行成本低）。FRB 桥留 BATCH-21b。
- F-W2B-012：优先级软一致，**文档化**：article_list_page._onArticleTap 内加注释说明"optimistic mark_read 在列表立即变灰，真写库由 detail 页 init 完成；若 detail 写失败仅本次显示 stale，下次 _loadArticles 自然修正"。不引入回调通知机制（rollback 复杂度高 ROI 低）。
- F-W2B-013：`_BookListView` 改用 `AutomaticKeepAliveClientMixin`（roadmap 写 `_BookListView` 在 bookshelf；本批同模式应用到 article_list 的每个 tab body）。**注**：实测 article_list_page.dart 当前结构 TabBarView children 是 `_buildArticleList(sortName)` 直接调用 method 返回 widget；改 KeepAlive 需要把每个 tab body 抽成 ConsumerStatefulWidget。
- F-W2B-014：`_records = List.of(_records)..[idx] = {...record, 'enabled': newValue}` immutable update + 不再持原 record map 引用（避免 caller 拿到 stale 引用）。
- F-W2B-019：search_page `_searchSeq` 自增 token，`_doSearch` 入口记录当前 seq，await 完成后判 `mounted && currentSeq == _searchSeq` 才 setState。
- F-W2B-032：`_loadArticles` catch 块开头 `if (!mounted) return;` early-return 替代尾部分散 mounted check。

**理由**（vs 方案 B 含 FRB 桥）：
- 方案 B 需要 `cargo build --workspace` + `flutter_rust_bridge_codegen generate` + `cd flutter_app && flutter analyze && flutter test`（验 Dart binding 同步）+ `.so` 重打包。BATCH-13 的 `quickjs runtime pool` 同样跨 Rust，跑了 4 commit（fix + spec + archive + .so），耗时大。
- 方案 A 只跑 `flutter analyze + flutter test`，~10 秒验证，回归风险全部在 Dart 层 widget test 覆盖。
- 收益对比：detail 打开 latency 从 list (~50ms) + isStarred (~10ms) + fetchHtml (~200ms 网络) = 串行 260ms 改并行 max(50, 10, 200) = 200ms，消减 ~60ms；FRB 桥进一步把 list 从 50ms 全数组遍历 → 1 行查询 ~5ms（净 -45ms）。BATCH-21b 单独做这个 optimization 收益清晰。

**Consequences**：
- ✅ 6 条 finding 全部消解
- ✅ Rust 完全不动，FRB 不 regen，`.so` 不重打包
- ✅ search 旧 future 幽灵覆盖（用户切关键词时可能撞到的 race）彻底消除
- ✅ source manage `_records` 持有 immutable list（mutation aliasing 类风险消除）
- ⚠️ F-W2B-009 detail latency 仅消减 ~60ms，未做最优；BATCH-21b 留 placeholder
- ⚠️ F-W2B-012 不引入持久化机制；mark_read 写库失败仍依赖下次 _loadArticles 修正（与原行为一致，仅文档化）
- ⚠️ F-W2B-013 走 KeepAlive 而非 family，scroll position 保留 + 未激活 tab 不参与 build；但同 sort 下 _articlesBySort map setState 仍会触发当前 tab build（只是不像之前 4-5 tab 同时 build）

## Requirements

### F-W2B-009 — RSS detail 并行化

文件：`flutter_app/lib/features/rss/rss_article_detail_page.dart`

实测：`_bootstrap()` 当前依次 await `rssListArticles` (line 154-167) + `rssMarkRead` + `rssStarIsStarred` + `rssFetchArticleContent`（4 个 await，串行）。其中 `rssMarkRead` 必须在 list 之后（拿到 article.read_time 才知是否要 mark），但 `rssStarIsStarred` + `rssFetchArticleContent` 可与 list 并行。

改动：把 list + isStarred + fetchHtml 三个独立调用包成 `Future.wait`：

```dart
final dbPath = await _dbPath();
final results = await Future.wait([
  // 1. list（找 article）— widget.articleOverride 优先
  if (widget.articleOverride == null)
    Future(() async {
      final json = await rust_api.rssListArticles(...);
      // 全数组遍历找 widget.link — 留给 BATCH-21b 加 FRB 桥优化
      final List<dynamic> arr = jsonDecode(json);
      for (final e in arr) {
        final m = e as Map<String, dynamic>;
        if (m['link'] == widget.link) return m;
      }
      return null;
    })
  else Future.value(widget.articleOverride),
  // 2. isStarred
  ...,
  // 3. fetchHtml
  ...,
]);
final article = results[0] as Map<String, dynamic>?;
final isStarred = results[1] as bool;
final fetched = results[2] as Map<String, dynamic>;
// 然后顺序：mark_read（依赖 article.read_time）→ webview init
```

**注意**：sourceOverride / articleOverride 优先级保留；fetchHtmlOverride / isStarredOverride 走 Future.value 包装；任一 future 抛错走外层 try-catch 设 `_error`。

### F-W2B-012 — Optimistic mark_read 文档化

文件：`flutter_app/lib/features/rss/rss_article_list_page.dart::_onArticleTap`（line 262-277）

仅加注释（不改行为）。当前注释说 "optimistic 已读 dot — 点击立刻消失；mark_read 真正写入由 detail 页 init 完成（避免列表 + 详情双写）"，扩充为：

```dart
// 批次 18 (05-19): optimistic 已读 dot — 点击立刻消失；mark_read
// 真正写入由 detail 页 init 完成（避免列表 + 详情双写）。
//
// 软一致语义（BATCH-21）：
// - 用户体验上 read_time 在列表 + detail 两处独立维护
// - 若 detail 写库成功（绝大多数情况）：返回 list 时已读状态正确
// - 若 detail 写库失败（FRB 异常 / 网络 / db lock）：本次返回 list 仍
//   显示已读 dot 消失（optimistic），但下次 _loadArticles 拉取时会
//   恢复 stale 状态（read_time = 0）；用户再次点击会重试
// - 这是 trade-off：避免双写 + 立即视觉反馈，代价是失败时下次自然修正
//   而不是立即 rollback
```

### F-W2B-013 — RSS article_list KeepAlive

文件：`flutter_app/lib/features/rss/rss_article_list_page.dart`

实测：`_buildArticleList(sortName)` (line 342-364) 是 method 返回 widget，被 TabBarView children `[for (final t in _tabs) _buildArticleList(t.name)]` 调用（实测在 line 332 附近）。改动：把每个 tab 的 RefreshIndicator + ListView.builder 抽出 `_ArticleTabView extends ConsumerStatefulWidget` + State with `AutomaticKeepAliveClientMixin`。`wantKeepAlive => true`，build 内调 `super.build(context)`。

```dart
class _ArticleTabView extends ConsumerStatefulWidget {
  final String sortName;
  final List<Map<String, dynamic>>? articles;  // null = loading; empty = empty; non-empty = data
  final Future<void> Function() onRefresh;
  final void Function(Map<String, dynamic>) onTap;
  const _ArticleTabView({...});
  @override
  ConsumerState<_ArticleTabView> createState() => _ArticleTabViewState();
}

class _ArticleTabViewState extends ConsumerState<_ArticleTabView>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);  // 必须调，否则 KeepAlive 失效
    // ... 原 _buildArticleList body
  }
}
```

TabBarView children 改 `[for (final t in _tabs) _ArticleTabView(sortName: t.name, articles: _articlesBySort[t.name], onRefresh: () => _loadArticles(t.name, refresh: true), onTap: _onArticleTap)]`。

### F-W2B-014 — RSS source_manage immutable update

文件：`flutter_app/lib/features/rss/rss_source_manage_page.dart::_onToggleEnabled` (line 177-202)

```dart
// 旧（line 193-195）
setState(() {
  record['enabled'] = newValue;  // mutation aliasing 风险
});

// 新
final idx = _records.indexOf(record);
if (idx < 0) return;  // record 已不在 list 里，可能被 import/delete 替换
setState(() {
  _records = List.of(_records)
    ..[idx] = {...record, 'enabled': newValue};
});
```

**注意**：`_records.indexOf(record)` 用 reference equality（Map 的 == 是 identity）；若 record 已被替换 idx = -1 早返回，不抛错。

### F-W2B-019 — search 旧 future token

文件：`flutter_app/lib/features/search/search_page.dart::_doSearch` (line 324-)

加 `int _searchSeq = 0;` State 字段，`_doSearch` 入口记录 `final seq = ++_searchSeq;`，每次 `if (!mounted) return;` 检查后改 `if (!mounted || seq != _searchSeq) return;`：

```dart
Future<void> _doSearch() async {
  final keyword = _searchCtrl.text.trim();
  if (keyword.isEmpty) return;
  final seq = ++_searchSeq;  // 自增并记录本次序号
  _lastSearchKeyword = keyword;
  setState(() => _loading = true);
  try {
    if (_onlineMode) {
      final dbPath = await ref.read(dbPathProvider.future);
      if (!mounted || seq != _searchSeq) return;
      // ... 原代码，每个 await 后判 mounted && seq == _searchSeq
      ...
      final allResults = await Future.wait(futures);
      if (!mounted || seq != _searchSeq) return;
      // ... 之后 _results.value = ... 安全
    } else { ... 同样 pattern }
  } catch (e) {
    if (!mounted || seq != _searchSeq) return;
    // ...
  } finally {
    if (mounted && seq == _searchSeq) {
      setState(() => _loading = false);
    }
  }
}
```

**注意**：原 `setState(() => _loading = true)` 早于 `seq` 记录（`_lastSearchKeyword` 也早），但 setState 本身在新 seq 之前不会被新 seq 干扰（因为 _doSearch 是顺序执行同 isolate）。简化方案保持 _searchSeq 在 setState(_loading) 之前 OK，等价。

### F-W2B-032 — _loadArticles catch mounted

文件：`flutter_app/lib/features/rss/rss_article_list_page.dart::_loadArticles` (line 197-260)

实测：catch 块（line 253-259）当前是 `if (!mounted) return; setState(...); ScaffoldMessenger.of(context).showSnackBar(...)`。`if (!mounted) return;` 已经在 line 254（catch 块第一行），后面 setState + ScaffoldMessenger 都安全；但代码读起来 mounted check 与 ScaffoldMessenger 中间隔了 setState，风格上不直观。

改动：保持现有逻辑（行为已正确），仅抽 catch 块开头注释明确："早返回保护后续 setState + ScaffoldMessenger 都安全；ScaffoldMessenger 在 unmounted 时虽 no-op 但 assertion 仍可能 fire（特定 framework 版本），early-return 是更稳的契约"。**或**改为统一方法开头 `if (!mounted) return;` 风格（finding 推荐）— PRD 选后者更彻底。

新写法（catch 已正确，主要是清理代码风格）：

```dart
} catch (e) {
  if (!mounted) return;          // 已存在
  setState(() => _refreshingSort = null);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('拉取失败: $e')),
  );
}
```

实际无需改（已 OK），但 PRD 标记 **Resolution = "verified clean，已是 early-return 风格"**，与 finding 描述偏差小（finding 写"没有 if (!mounted) return; 保护"，但代码 254 行就有）。决定：扫一遍其它 catch 块（line 130 区域 `_loadInitial`，line 168 `setState` 后 ScaffoldMessenger）补 early-return；不改 _loadArticles 主路径。

## Acceptance Criteria

- [ ] `flutter analyze` 0 issues
- [ ] `flutter test` 全过（含本批新增 ~4-6 单测：F-W2B-013 KeepAlive scroll 保留 / F-W2B-014 immutable update 验 _records 不被原地改 / F-W2B-019 旧 future 不覆盖新结果 / F-W2B-009 并行化 latency 不显著回归）
- [ ] grep `record\['enabled'\] = ` 在 `flutter_app/lib/features/rss/rss_source_manage_page.dart` 0 命中
- [ ] grep `_searchSeq` 在 search_page 入口 + 每次 await 后都校验
- [ ] master finding F-W2B-009/012/013/014/019/032 全部消解（写 master findings.md + findings-flutter-features.md）
- [ ] F-W2B-018 在 master findings 加注「已 Resolved by BATCH-18b（删除 Transport / SSE）」明确归档

## Definition of Done

- 测试：~4-6 新单测 + 既有全过
- Lint：flutter analyze 0 issues；flutter test green
- 文档：master report 6 条 Resolution + F-W2B-018 标 Resolved-by-BATCH-18b；spec 加「列表 reactivity 模式（KeepAlive + immutable update + future seq token）」段
- Commit：3 个（fix + spec + archive，BATCH-13/15/03/05 模式）

## Out of Scope

- F-W2B-009 加 FRB 桥 `rss_article_get_by_origin_link`（已有 dao + 单测，缺 FRB pub fn + binding regen + .so 重打包）— BATCH-21b
- F-W2B-013 完整 StateProvider.family per-tab 重构 — PRD 选 KeepAlive 方案
- F-W2B-012 真持久化时序契约（detail 失败回调 list rollback）— BATCH-21c future work，需要 GoRouter `state.extra` 或 Riverpod 通信机制
- search SSE 路径优化 — 已被 BATCH-18b 删除，无需做
- F-W2B-013 ListView memCacheWidth 优化 — F-W2B-033 是独立 P2 finding，不在本批
- replace_rule_page / settings_page 同模式扫荡 — 本批仅限 RSS / search 主题

## Technical Notes

- **Future.wait error semantics**：`Future.wait([a, b, c])` 任一 throw 时其它 future 仍跑（不会取消，FRB 无 cancel API），但整体 await throw 第一个错误。已有外层 try-catch 设 `_error`，符合预期。
- **AutomaticKeepAliveClientMixin 与 ConsumerStatefulWidget**：`State<ConsumerStatefulWidget>` 直接 `with AutomaticKeepAliveClientMixin` OK；build 内必须 `super.build(context)` 才生效。
- **`List.of(_records)..[idx] = ...`**：cascade `..[idx] =` 在 `List.of` 复制后改新 list；旧 _records 引用不变。
- **`int _searchSeq` 与 ValueListenableBuilder**：`_results` 是 `ValueNotifier<List<Map>>`，`_results.value = ...` 触发监听；seq 校验放在 setState / `_results.value` 之前即可，不需要包到 ValueNotifier 内部。
- **测试钩子**：本批不引入新 fake；F-W2B-013 KeepAlive 测试用 widget test 验证 tab 切换后 scroll position 不丢；F-W2B-019 测试构造两次 `_doSearch` 调用，第二次 await 慢于第一次（顺序 reverse），验证第二次的结果不覆盖第一次（实际反之：第一次旧的不覆盖第二次新的）。
- **F-W2B-014 idx 查询**：`_records.indexOf(record)` 是 O(N)，列表通常 < 100，可接受；用 reference equality 默认行为（Map 没 override `==`），符合"找到 record 自身"语义。
- **F-W2B-032 实测**：roadmap 行号 line 255-256 指向 catch 块，但 254 line 已有 `if (!mounted) return;`，finding 描述略不准；本批"清理"主要是巩固已正确逻辑 + 扫姊妹 catch 块（_loadInitial / 其它路径）。

## 范围内具体改动

### 修改

- `flutter_app/lib/features/rss/rss_article_detail_page.dart`：
  - `_bootstrap()` 中 list + isStarred + fetchHtml 三段改 Future.wait 并行
  - mark_read 仍依赖 article.read_time，保留串行（在 Future.wait 之后）
- `flutter_app/lib/features/rss/rss_article_list_page.dart`：
  - 抽 `_ArticleTabView` ConsumerStatefulWidget + KeepAlive
  - `_onArticleTap` 加扩充注释（软一致语义）
  - `_loadArticles` catch 维持现状；扫姊妹 catch 块 mounted check 一致性
- `flutter_app/lib/features/rss/rss_source_manage_page.dart`：
  - `_onToggleEnabled` 改 immutable update
- `flutter_app/lib/features/search/search_page.dart`：
  - 加 `int _searchSeq` State 字段
  - `_doSearch` 入口 + 每个 await 后 + finally 都判 `seq == _searchSeq`

### 测试新增

- `rss_article_detail_page_test.dart`：1 case 验证 _bootstrap 内 fetchHtml + isStarred 与 list 并行（用 stopwatch 量化 latency 大致下降，或仅验调用顺序）
- `rss_article_list_page_test.dart`：1 case 验 KeepAlive 切换 tab 回来 scroll position 保留
- `rss_source_manage_page_test.dart`：1 case 验 toggle 后原 record map 不被修改（持原引用对比）
- `search_page_test.dart`：1 case 验旧 future 不覆盖新结果（`_searchSeq` token 工作）

总改动估算：修改 ~120 行 + 新建 0 + 测试 ~80 行 = ~200 行（roadmap 估 ≤500，符合 effort M）。
