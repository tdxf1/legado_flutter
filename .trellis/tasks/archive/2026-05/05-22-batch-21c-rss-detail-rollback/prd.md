# BATCH-21c: RSS detail → list rollback 通信（GoRouter result）

**Stage**: P1 (follow-up of BATCH-21)
**Slug**: `rss-detail-rollback`
**Effort**: S (~80 行 + 2 单测)
**Depends on**: BATCH-21 ✅（detail _bootstrap 并行化 + 软一致语义已文档化；rollback 通信留 BATCH-21c）

## 1. 范围

收尾 F-W2B-012 — list 端 optimistic read_time 在 detail mark_read 失败时**主动 rollback**，而非等下次 _loadArticles 自然修正。

## 2. 设计

### 通信模式

GoRouter `context.push(...)` 返回 `Future<T?>`。detail 端通过 `context.pop(result)` 携带 mark_read 结果回传，list 端 `context.push(...).then((result) { ... })` 接收并 rollback。

### MarkReadResult 枚举

```dart
enum MarkReadResult {
  success,  // detail 真正调 mark_read 成功（包括 article 原本已读跳过的情况）
  failed,   // detail mark_read 抛异常（FRB / 网络 / db lock）
  skipped,  // detail 未走到 mark_read（_error 早返回 / link 空 / article 缺）
}
```

`skipped` 与 `failed` 区分：list 仅在 `failed` 时 rollback；`skipped` 不能确定 db 状态，留给下次 _loadArticles 自然修正（与现有"软一致"语义一致）。

### detail 端

`_RssArticleDetailPageState`：
1. 加 `MarkReadResult _markReadResult = MarkReadResult.skipped;` 字段（默认 skipped 兜底）
2. `_bootstrap` mark_read try/catch 块：成功路径设 `success`；catch 路径设 `failed`；不进 if 分支（readTime != 0 / link 空）保持 `skipped`
3. **AppBar back / 系统 back / detail 内代码主动 pop** 都需要 result 携带：用 `PopScope` 包 Scaffold（Flutter 3.12+ 推荐 API，替代 `WillPopScope`）+ `onPopInvokedWithResult`
4. `_buildBody` 内 `_retry` 重试也走 _bootstrap 重置 _markReadResult（保持单一来源）

具体代码：
```dart
@override
Widget build(BuildContext context) {
  // ...
  return PopScope(
    // canPop: true 让默认 back 行为不变（不阻止 pop）
    canPop: true,
    // onPopInvokedWithResult: 在 pop 真正发生时携带 result
    onPopInvokedWithResult: (didPop, _) {
      // didPop == true 说明 pop 已经发生；这里 router 内部 pop 已处理完毕
      // GoRouter 用 context.pop(result) 传 result 给 push 的调用方；但 OS
      // back / AppBar back 走 Navigator.pop()，不带 result。
      // 解决方式：替换 AppBar 默认 leading 为 IconButton onPressed:
      //   () => context.pop(_markReadResult)
      // OS back（手势 / 物理 back）由 onPopInvokedWithResult 统一处理。
    },
    child: Scaffold(
      appBar: AppBar(
        title: ...,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(_markReadResult),
        ),
        actions: [...],
      ),
      body: _buildBody(context),
    ),
  );
}
```

注意：GoRouter 在 OS back 时会触发 PopScope 的 `onPopInvokedWithResult`（`didPop=true` 表示 pop 已发生），但**不能在该回调里调 `context.pop(result)`**——pop 已经发生。OS back 路径上 list 收到的 result 是 null。这是已知 limitation，**仅 AppBar back / detail 内代码主动 pop 能携带 result**。OS back 走老的"软一致"路径（list 不 rollback，等下次刷新自愈）——可接受。

### list 端

`_RssArticleListPageState::_onArticleTap`（line 282-286）：
```dart
// BATCH-21c：等 detail 返回 mark_read 结果，失败时 rollback optimistic
final result = await context.push<MarkReadResult?>(
  '/rss-articles-detail?sourceUrl=$encodedSource&link=$encodedLink',
);
if (!mounted) return;
if (result == MarkReadResult.failed) {
  // detail 真正写库失败，回滚 optimistic
  setState(() {
    article['read_time'] = 0;
  });
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('已读状态同步失败，下次刷新会重试')),
  );
}
// success / skipped / null（OS back）→ 保留 optimistic，下次 _loadArticles
// 自然修正
```

### 路由更新

`flutter_app/lib/core/router.dart::/rss-articles-detail`：声明 GoRoute 的 type 不需要改（`context.push<T?>` 自动推断）；保持现状即可。

### Override 兼容性

测试 override 钩子（`markReadOverride` / `articleOverride` 等）保留不动；新加的 `_markReadResult` 状态由 _bootstrap 路径自身管理，不影响 override 行为。新单测可直接构造 `RssArticleDetailPage` + `markReadOverride` 抛异常验证 result == failed。

## 3. 影响文件

### 新文件 / 新枚举

`flutter_app/lib/features/rss/rss_article_detail_page.dart`：
- 顶部加 `enum MarkReadResult { success, failed, skipped }`（top-level，public，list 端引用）
- `_RssArticleDetailPageState` 加 `MarkReadResult _markReadResult = MarkReadResult.skipped;` 字段
- `_bootstrap` mark_read try/catch 设值（PRD §2 detail 端 step 2）
- `build` 加 `PopScope` + 自定义 `leading` IconButton（PRD §2 detail 端 step 3）

`flutter_app/lib/features/rss/rss_article_list_page.dart`：
- import `rss_article_detail_page.dart` 拿 `MarkReadResult` enum
- `_onArticleTap` (line 262-287)：`context.push` 改 await + 接 result + rollback 分支
- 删 line 265-276 注释段中"留 future work"段（已实施）；保留 trade-off 说明改为"BATCH-21c 已收尾"

### 测试

`flutter_app/test/rss_article_detail_test.dart`（如已存在）+ `flutter_app/test/rss_article_list_page_test.dart`：

新加 case：
1. `detail_test`: markReadOverride 抛异常 → AppBar back 后 result == failed
2. `detail_test`: markReadOverride 正常 → result == success
3. `list_test`: detail 返回 failed → article['read_time'] 回滚到 0 + SnackBar 显示
4. `list_test`: detail 返回 success → article['read_time'] 保留 optimistic ts

(grep 现有 rss test 文件结构后决定具体路径)

## 4. 测试策略

- `flutter analyze` 0 issue
- `flutter test` baseline 536 + 4 新 ≈ 540 PASS
- `cargo build/test --workspace` 不动 Rust，全 PASS

## 5. 验收

- [ ] master finding F-W2B-012 标 Resolved by BATCH-21 + BATCH-21c（联合收尾：BATCH-21 文档化软一致语义；BATCH-21c 加 rollback 通信）
- [ ] `MarkReadResult` enum 定义在 detail page 顶部 + list 端引用
- [ ] `_bootstrap` mark_read 三路径设 `_markReadResult` (success / failed / skipped)
- [ ] AppBar leading IconButton + `context.pop(_markReadResult)` 传 result
- [ ] list `_onArticleTap` await result + 仅 failed 时 rollback
- [ ] flutter analyze 0 / flutter test 540 PASS / cargo 全 PASS
- [ ] spec 「凭据保险柜」等已有段下方 / 凭据存储后增「跨页通信模式 (BATCH-21c)」小节

## 6. 不在范围

- **OS back / 手势 back 的 result 携带**：Flutter PopScope 在 `onPopInvokedWithResult` 时 pop 已发生，无法携带 result。本批仅 AppBar back / 主动 pop 路径携带 result；OS back 路径走老软一致（保持现有行为）。
- **rss_favorites_page → detail 路径的 rollback**：favorites 页没有 optimistic 改 read_time（grep 验证），不存在 rollback 需求。
- **per-article StateProvider**：路线图原方案之一，破坏 `_articlesBySort` 简单结构 + 跨页面 state 复杂。GoRouter result 是更轻方案。

## 7. 风险点

- **PopScope `onPopInvokedWithResult` API 版本**：Flutter 3.22+ 推荐；`pubspec.yaml` 检查 sdk constraint，如 < 3.22 改用 `onPopInvoked`（旧 API，只有 didPop 参数）
- **leading IconButton 替换默认 back**：iOS 风格的 swipe back 仍走 OS back 路径（result 为 null）；这是已知 limitation，文档化即可
- **`context.push<MarkReadResult?>`**：T 类型推断；GoRouter 文档说 type-safe push 需要明确类型参数，否则返回 `Object?`。本批显式声明
- **`enum` 改命名**：F-W2B-012 提议的"实际持久化结果"语义匹配 `MarkReadResult`；不与 detail 其他 result 字段冲突
- **测试 stub PopScope**：widget test 触发 OS back 用 `tester.pageBack()`（走 `Navigator.maybePop`），AppBar back 用 `tester.tap(find.byType(IconButton).first)`（leading button）。两条路径 result 不同需要分别测
