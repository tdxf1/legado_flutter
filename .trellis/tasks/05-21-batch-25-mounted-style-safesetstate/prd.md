# BATCH-25: features `mounted` 风格统一 + safeSetState extension + reader_page bug fix

## Goal

把 `flutter_app/lib/features/` 层的 `if (mounted) setState(...)` 模式（B 模式 31 处）机械替换为 `safeSetState(() => ...)` 调用，新加 `core/widgets/safe_setstate.dart` 提供 extension。顺手修 `reader_page.dart:2388` 真实 bug（_replaceBookSource 在双 await 后漏 mounted 检查导致 setState-after-dispose 风险）。

C 模式 57 处（`if (mounted) <非 setState>`）**不在本批范围**：含复合条件 (`if (mounted && X)`)、Navigator.pop、ScaffoldMessenger、showDialog 多种异质语义，机械替换风险高 ROI 低，留给后续按需重构。

## What I already know

### Audit 结果（来自 explore sub-agent，2026-05-21）

`/tmp/opencode/batch25-audit.md` 全 features 层 241 处 `mounted` 使用：

| 模式 | 含义 | 数量 | 范围 |
|---|---|---|---|
| A | `if (!mounted) return;` | 132 | **保留**（推荐风格） |
| B | `if (mounted) setState(...)` | 31 | **本批替换** → `safeSetState(...)` |
| C | `if (mounted) <非 setState>` | 57 | **本批不动**（复合条件 / 异质语义） |
| D | `context.mounted` / `ctx.mounted` | 21 | **保留**（Builder 内 BuildContext，非 State.mounted） |
| E | 三元 / 其它 | 0 | n/a |

#### 真实 bug

`flutter_app/lib/features/reader/reader_page.dart:2388` — `_replaceBookSource` 在最后一次 mounted 检查 (L2317) 后连续 `await replaceBookChapters` (L2353) + `await saveBook` (L2380)，紧接着 L2388 直接 `setState({...})`，缺 mounted check。换源 dialog 关闭后用户立即返回会触发 setState-after-dispose。

#### B 模式 31 处全清单（按文件分组）

| 文件 | 行 | 调用 |
|---|---|---|
| bookshelf_page.dart | 66 | `if (mounted) setState(() => _isGridView = value);` |
| bookshelf/book_info_edit_page.dart | 91 | `if (mounted) setState(() {});` |
| bookshelf/book_info_edit_page.dart | 339 | `if (mounted) setState(() => _saving = false);` |
| bookshelf/widgets/book_group_dialogs.dart | 54 | `if (mounted) setState(() {});` |
| bookshelf/widgets/book_group_dialogs.dart | 96 | `if (mounted) setState(() {});` |
| bookshelf/widgets/book_group_dialogs.dart | 131 | `if (mounted) setState(() {});` |
| reader/page/page_view.dart | 97 | `if (mounted) setState(() {});` |
| reader/page/page_view.dart | 147 | `if (mounted) setState(() {});` |
| reader/page/page_view.dart | 260 | `if (mounted) setState(() {});` |
| reader/reader_page.dart | 197 | `if (mounted) setState(() {});` |
| reader/reader_page.dart | 203 | `if (mounted) setState(() {});` |
| reader/reader_page.dart | 251 | `if (mounted) setState(() {});` |
| reader/reader_page.dart | 836 | `if (mounted) setState(() => _isAppendingChapter = false);` |
| reader/reader_page.dart | 878 | `if (mounted) setState(() => _isPrependingChapter = false);` |
| reader/reader_page.dart | 2089 | `if (mounted) setState(() => _isLoadingContent = false);` |
| reader/reader_page.dart | 2094 | `if (mounted) setState(() {});` |
| rss/rss_article_detail_page.dart | 265 | `if (mounted) setState(() => _isStarred = false);` |
| rss/rss_article_detail_page.dart | 283 | `if (mounted) setState(() => _isStarred = true);` |
| rss/rss_article_detail_page.dart | 297 | `if (mounted) setState(() => _starBusy = false);` |
| search/search_page.dart | 81 | `if (mounted) setState(() => _searchHistory = history);` |
| search/search_page.dart | 86 | `if (mounted) setState(() => _precisionMode = v);` |
| search/search_page.dart | 145 | `if (mounted) setState(() {});` |
| search/search_page.dart | 151 | `if (mounted) setState(() {});` |
| settings/backup_page.dart | 281 | `if (mounted) setState(() => _exporting = false);` |
| settings/backup_page.dart | 327 | `if (mounted) setState(() => _importing = false);` |
| settings/backup_page.dart | 394 | `if (mounted) setState(() => _importing = false);` |
| settings/backup_page.dart | 537 | `if (mounted) setState(() => _webdavBusy = false);` |
| settings/backup_page.dart | 635 | `if (mounted) setState(() => _webdavBusy = false);` |
| settings/webdav_config_page.dart | 127 | `if (mounted) setState(() => _loaded = true);` |
| settings/webdav_config_page.dart | 160 | `if (mounted) setState(() => _testing = false);` |
| settings/webdav_config_page.dart | 208 | `if (mounted) setState(() => _saving = false);` |

共 **31 处**，跨 12 个文件。

### extension 设计

`flutter_app/lib/core/widgets/safe_setstate.dart`:

```dart
import 'package:flutter/widgets.dart';

/// 包装 `setState` 加 `mounted` 检查的扩展（BATCH-25, F-W2B-021）。
///
/// 把样板代码：
/// ```dart
/// if (mounted) setState(() { _foo = bar; });
/// ```
/// 统一成：
/// ```dart
/// safeSetState(() { _foo = bar; });
/// ```
///
/// 保持与原 `setState` 完全等价的语义（仅在 mounted 时调用），
/// 但读者不需要每次扫"if (mounted)"。
extension SafeSetState<T extends StatefulWidget> on State<T> {
  /// 仅在 widget 仍然 mounted 时调用 setState。dispose 后调用是 no-op。
  void safeSetState(VoidCallback fn) {
    if (mounted) {
      // ignore: invalid_use_of_protected_member
      setState(fn);
    }
  }
}
```

注：`setState` 是 protected（仅 State 子类内部可调），extension 内部调用需要 `// ignore: invalid_use_of_protected_member` 抑制 lint（这是社区惯例）。

### 改动清单（一对一）

每处 caller 改动量：1 行 → 1 行（`if (mounted) setState(() => X);` → `safeSetState(() => X);`）。

涉及文件 12 个：
1. `bookshelf_page.dart` (1 处)
2. `bookshelf/book_info_edit_page.dart` (2 处)
3. `bookshelf/widgets/book_group_dialogs.dart` (3 处)
4. `reader/page/page_view.dart` (3 处)
5. `reader/reader_page.dart` (7 处) + bug fix 1 处 (L2388 加 mounted check)
6. `rss/rss_article_detail_page.dart` (3 处)
7. `search/search_page.dart` (4 处)
8. `settings/backup_page.dart` (5 处)
9. `settings/webdav_config_page.dart` (3 处)

每个文件加 1 行 import：`import '../../core/widgets/safe_setstate.dart';`

### Reader bug fix 细节

`reader_page.dart` 函数 `_replaceBookSource`（约 L2280-2400）：
- L2317: 已有 `if (!mounted) return;`
- L2353: `await replaceBookChapters(...)`
- L2380: `await saveBook(...)`
- L2388: `setState({...})` ← **缺 mounted check**

修：在 L2388 前加 `if (!mounted) return;`。这是 audit 报告 §3 唯一一条真实潜在 bug。

## Open Questions

（已收敛）

## Requirements (final)

### MVP scope

1. **新建** `flutter_app/lib/core/widgets/safe_setstate.dart` 含 `SafeSetState` extension（约 25 行 + doc-comment）
2. **改 31 处 caller** 走 `safeSetState(...)` API（机械 1:1 替换）
3. **修 reader_page.dart:2388 bug**：在 setState 前加 `if (!mounted) return;`
4. **加单测** `test/safe_setstate_test.dart`：3 case
   - mounted=true 时 setState 被调用
   - mounted=false 时 setState 不被调用（no crash）
   - rebuild 触发实际 UI 更新
5. **回归**：flutter analyze 0 issue + flutter test 全过（基线 418 + 新 3 = 421）
6. **master report 同步** F-W2B-021 标 Resolution

### 不在范围

- C 模式 57 处（`if (mounted) <非 setState>`，复合条件 / Navigator.pop / ScaffoldMessenger / showDialog 异质语义）
- D 模式 21 处（`context.mounted`，Builder 内 BuildContext，与 State.mounted 不同）
- A 模式 132 处（已是推荐风格，不动）
- core/ 目录内可能存在的 mounted 模式（不是本批范围）

## Acceptance Criteria

- [ ] `flutter_app/lib/core/widgets/safe_setstate.dart` 存在 + extension 正确（`SafeSetState on State`）
- [ ] grep `if \(mounted\) setState` 在 `flutter_app/lib/features/` 下 0 命中
- [ ] grep `safeSetState\(` 在 `flutter_app/lib/features/` 下至少 31 命中
- [ ] reader_page.dart:2388 setState 之前有 `if (!mounted) return;` 行
- [ ] `test/safe_setstate_test.dart` 存在，3+ case PASS
- [ ] `flutter analyze` 0 warning
- [ ] `flutter test` 全过（基线 418 + 新 3 ≈ 421）
- [ ] master report `findings-flutter-features.md` F-W2B-021 标 Resolution by BATCH-25
- [ ] master report 主索引 `findings.md` 同步（如有）

## Definition of Done

- safeSetState extension + 31 处 caller 替换 + reader bug fix 全部完成
- 12 个文件 import + 替换都过 analyze
- 421+ 测试 PASS
- F-W2B-021 闭环

## Decision (ADR-lite)

**Context**: BATCH-24 helper 抽取后，audit 揭示 features 层 mounted 模式分布 132 / 31 / 57 / 21 / 0（A/B/C/D/E）。

**Decision**: 仅做 B 模式 31 处机械替换（最高 ROI、最低风险），加 1 处 reader bug fix。C 模式 57 处异质语义跳过留给后续按需。

**Consequences**:
- 31 行 1:1 机械替换 + 12 行 import + 25 行 extension + 30 行 test = 净 +60-70 行
- reader bug fix +1 行（防御性）
- 风格"if mounted setState" 模式在 features 层完全消失（grep 检验）
- C 模式 57 处保留 — 未来若做 v2 风格扫描可继续

## Technical Notes

### 风险点

- **`extension on State<T extends StatefulWidget>`**：`State` 自身已是泛型类，extension 写 `on State` 即可（不需要泛型参数）。但保留 `<T extends StatefulWidget>` 让扩展可在任何 `State<MyWidget>` 上调用。
- **`// ignore: invalid_use_of_protected_member`**：extension 内部调用 protected 的 setState 必须 ignore，社区惯例。
- **reader_page.dart 改动密集**：reader_page.dart 是项目最大文件之一（~2900 行），有 7 处 B 模式 + 1 处 bug fix。逐个 Edit + 全量 grep 验证 0 漏改。
- **search_page.dart line 81-86 在 initState 路径**：`safeSetState` 在 initState 阶段 mounted=true，行为不变。

### 实施顺序

1. 新建 `lib/core/widgets/safe_setstate.dart` extension
2. 新建 `test/safe_setstate_test.dart`（先跑确认绿，再 caller 替换）
3. 跑测试确认 extension 工作
4. 按文件逐个改 caller（每文件最多 7 处）：
   - bookshelf_page.dart (1)
   - book_info_edit_page.dart (2)
   - book_group_dialogs.dart (3)
   - page_view.dart (3)
   - reader_page.dart (7) + bug fix (1)
   - rss_article_detail_page.dart (3)
   - search_page.dart (4)
   - backup_page.dart (5)
   - webdav_config_page.dart (3)
5. 每改一文件 grep 验证 `if (mounted) setState` 已消失
6. 全量 `flutter analyze` 0 issue
7. 全量 `flutter test` 全过
8. 更新 master report

### 测试 case 设计

```dart
// safe_setstate_test.dart
testWidgets('safeSetState updates UI when mounted', (tester) async {
  // pump widget, tap button → 触发 safeSetState → expect counter 增加
});

testWidgets('safeSetState is no-op when unmounted', (tester) async {
  // pump widget, dispose, manually call State.safeSetState → no crash
});

testWidgets('safeSetState rebuild triggers actual UI refresh', (tester) async {
  // 验证 setState 实际触发 build
});
```

## Research References

- `/tmp/opencode/batch25-audit.md` — 完整 241 处 mounted audit
- F-W2B-021 master：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-flutter-features.md:290-298`
- BATCH-24 archive：`.trellis/tasks/archive/2026-05/05-21-batch-24-platformint64-helper-time-format-importsummary/`
