# R120 / R115 / R116 UI 收尾批

## 背景

第十一轮全面复审捞出的剩余 med/low 项里的 UI / UX 三件：

- **R120 (med)** — `_showRuleEditDialog` 内 5 个 `TextEditingController` (nameCtrl / patternCtrl / replacementCtrl / scopeCtrl / excludeCtrl) 不 dispose。每次 add/edit dialog 关闭后留泄漏。Flutter 规范要求 controller 拥有者负责 dispose。改动之前是 commit 14 / 16 沿用的 pattern。
- **R115 (low)** — R105 backfill 直接赋值 `_bookName` / `_sourceUrl` 而不用 setState，但这两个字段在 build 树有读用（top-bar / change source dialog）。注释说"不需要 setState"误导未来 maintainer。
- **R116 (low)** — R105 backfill 失败时只 `debugPrint`，永久性 db 错会让规则不应用却无 UI 反馈。reader_page 已经有 `_replaceRuleErrorShown` toast guard，可以复用。

## 目标

1. **R120**：让 dialog 的 controller 在 dialog dismiss 时被 dispose
2. **R115**：把直接赋值改成 `setState`，注释更新；不影响 R105 race 修复语义
3. **R116**：backfill 失败时复用 `_replaceRuleErrorShown` 路径给 toast

## 实现策略

### R120 修复策略

Flutter dialog 内的 controller 通常有几种 ownership pattern：
1. 把 controller 做成 dialog widget 的 State 字段，在 `dispose()` 释放（最规范）
2. 用 `useTextEditingController`（hooks_riverpod 提供）— 项目里已经用 riverpod，但没有引 `flutter_hooks`
3. 在 `showDialog().then((_) { ctrl.dispose(); ... })` 链中显式释放

最干净是 (1)。把 `_showRuleEditDialog` 内 StatefulBuilder 替换为一个 **私有 StatefulWidget** `_RuleEditDialog`，5 个 controller 作为它的 State 字段，`initState` 初始化（含预填），`dispose` 释放。

工作量约 60 行（添加 stateful widget），但消除 5 个 controller 的潜在泄漏并对齐 Flutter 规范。

### R115 修复策略

R105 内部 `_bookName = book['name']` / `_sourceUrl = book['source_url']` 直接赋值。改成：

```dart
if (book != null && mounted) {
  setState(() {
    if (_bookName.isEmpty) _bookName = book['name'] as String? ?? '';
    if (_sourceUrl.isEmpty) _sourceUrl = book['source_url'] as String? ?? '';
  });
}
```

注释里把"无需 setState"段改成 "用 setState 同步 widget tree（top-bar 标题 / change source dialog 等读取这两个字段）"。

### R116 修复策略

backfill 的 catch 块新增同样的 once-per-session toast 守卫（复用现有 `_replaceRuleErrorShown` 字段）。注意区分两种失败：(a) backfill 自身失败（DB 出错 / book 被并发删除）vs (b) `applyReplaceRules` 失败（regex panic 等）。Toast 文案分开：

- backfill 失败：`无法读取书籍信息，替换规则可能不生效`
- applyReplaceRules 失败：`替换规则执行失败，已显示原始章节内容`（已有）

或者只显示一次 toast 但 message 跟随原因区分。简单起见，复用同一个 guard 但首条命中决定文案。具体：

```dart
} catch (e) {
  debugPrint('[Reader] R105 backfill book metadata failed: $e');
  if (mounted && !_replaceRuleErrorShown) {
    _replaceRuleErrorShown = true;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('无法读取书籍信息，替换规则可能未按作用范围生效'),
        duration: Duration(seconds: 4),
      ),
    );
  }
  // Fall through — rule call still proceeds with whatever is populated.
}
```

## 验收标准

- cargo check / test --workspace: 不变（260 passed）
- flutter analyze: 0 issue
- flutter test: 至少 112 passed
- 手动 trace（无法跑）：
  - R120：opening + closing replace rule dialog 多次后无 controller 泄漏（内部行为，但 lint 不再 flag）
  - R115：reader 启动并发 race 时，回填后 AppBar 立即显示书名（不再等下次自然 rebuild）
  - R116：backfill 永久失败时 user 看到 toast

## 不在范围

- R117-R119/R121/R122/R124：trivial 或 nano，留 backlog
- R107（token 常量时间）：单独 land，需 dep
