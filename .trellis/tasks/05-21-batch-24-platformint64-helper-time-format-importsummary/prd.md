# BATCH-24: PlatformInt64 helper + time_format + ImportSummary 抽取

## Goal

抽 3 个公共 helper 消除 Flutter features 层的重复模板：
1. `core/util/platform_int64.dart::platformInt64ToInt` — 6 处 `raw is int ? raw : raw.toInt() as int` 重复
2. `core/util/time_format.dart::formatRelativeTime` — bookshelf + read_stats 两处 `_formatRelativeTime` 重复（顺手统一 `sec <= 0 → '从未'` 边界 — 修 bookshelf 隐含 bug）
3. `core/util/import_summary_label.dart::formatImportSummaryLabel` — backup_page 两处 ImportSummary 解析重复

每个 caller 行为不变（除 bookshelf `_formatRelativeTime` 在 sec=0 时从"刚刚"改"从未"，是修 bug），加 4-6 个单测验证 helper 边界。

## What I already know

### 来自 BATCH-23 后扫描 audit + 主对话精确核实（2026-05-21）

**1. F-W2B-007 PlatformInt64 重复 — 6 处全清单**

```dart
// 模板（每处都一样）：
final n = await rust_api.someCall(...);  // n: PlatformInt64（io = int / web = BigInt）
// ignore: unnecessary_cast
final dynamic raw = n;
return raw is int ? raw : raw.toInt() as int;
```

实际位置（grep 验证）：
- `lib/features/rule_sub/rule_sub_page.dart:138-144` (deleteOverride fallback)
- `lib/features/rule_sub/rule_sub_page.dart:148-156` (updateOverride fallback)
- `lib/features/rss/rss_source_manage_page.dart:182-188` (rssSourceSetEnabled fallback)
- `lib/features/rss/rss_source_manage_page.dart:228-234` (rssSourceDelete fallback)
- `lib/features/settings/cache_management_page.dart:140-146` (clearAllCache fallback)
- `lib/features/settings/cache_management_page.dart:200-206` (clearBookCache fallback)

**注**：sub-agent 报告的 `read_stats × 1` 命中不存在（grep 确认 read_stats 无此模式）— 实际 6 处。

**2. F-W2B-030 _formatRelativeTime 重复 + 隐含 bug**

`lib/features/bookshelf/bookshelf_page.dart:472-484`：
```dart
String _formatRelativeTime(int sec) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final delta = now - sec;
  if (delta < 60) return '刚刚';
  if (delta < 3600) return '${(delta / 60).floor()} 分钟前';
  if (delta < 86400) return '${(delta / 3600).floor()} 小时前';
  if (delta < 86400 * 30) return '${(delta / 86400).floor()} 天前';
  return DateTime.fromMillisecondsSinceEpoch(sec * 1000)...
}
```

`lib/features/settings/read_stats_page.dart:170-186`：
```dart
String _formatRelativeTime(int sec) {
  if (sec <= 0) return '从未';   // ← 比 bookshelf 多一行 early-return
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  // ... 其余完全一样
}
```

**关键差异**：read_stats 版多 `if (sec <= 0) return '从未';` 早返回。bookshelf 版输入 `sec=0` 会算 `delta = now`（很大数）→ 走到末尾 `DateTime.fromMillisecondsSinceEpoch(0)` 显示 "1970-01-01"。这在"用户从未读过这本书"场景下会被显示成 "1970-01-01 · 章节标题" — **隐含 bug**。

抽 helper 时统一用 read_stats 版（`<= 0 → '从未'` 边界），顺手修 bookshelf 端 bug。

read_stats 注释写"与 bookshelf 同名 helper 保持语义一致 — 抽公用 lib 的话需要跨 feature 包，本批次先复制一份避免无谓抽象" — 注释作者预知会有这一天，本批正是抽公共 lib。

**3. F-W2B-024 ImportSummary 解析重复**

`lib/features/settings/backup_page.dart`：

L363-382（本地导入路径）：
```dart
try {
  final Map<String, dynamic> summary = jsonDecode(summaryJson) as Map<String, dynamic>;
  final books = summary['books'] ?? 0;
  final groups = summary['groups'] ?? 0;
  final bookmarks = summary['bookmarks'] ?? 0;
  final rules = summary['replace_rules'] ?? 0;
  final sources = summary['sources'] ?? 0;
  final errors = summary['errors'];
  final errorCount = (errors is List) ? errors.length : 0;
  label = '导入完成: $books 本书 / $groups 个分组 / '
      '$bookmarks 条书签 / $rules 条替换规则 / $sources 个书源'
      '${errorCount > 0 ? '（$errorCount 项错误）' : ''}';
} catch (_) {
  label = '导入完成';
}
```

L624-643（WebDAV 恢复路径）— 完全一样的 7 字段解析 + 完全一样的拼接 logic，**仅前缀文案 + 兜底文案不同**：
- 本地：`'导入完成:'` + 兜底 `'导入完成'`
- WebDAV：`'从 WebDAV 恢复:'` + 兜底 `'从 WebDAV 恢复完成'`

抽 helper：
```dart
String formatImportSummaryLabel(
  String summaryJson, {
  required String prefix,    // '导入完成' / '从 WebDAV 恢复'
}) {
  try {
    // ... 7 字段解析 + 拼接 → '$prefix: $books 本书 / ...'
  } catch (_) {
    return prefix.endsWith(':') ? prefix.substring(0, prefix.length - 1) : '$prefix完成';
  }
}
```

或更简单：caller 自己传 `prefix` 和 `fallback`：
```dart
String formatImportSummaryLabel(
  String summaryJson, {
  required String prefix,    // '导入完成' / '从 WebDAV 恢复'
  required String fallback,  // '导入完成' / '从 WebDAV 恢复完成'
}) { ... }
```

后者更清晰，但增加 1 个参数。两可，PRD 选后者（caller 显式传 fallback 让兜底文案集中可见）。

### 改动清单

| # | 文件 | 改动 | 行 |
|---|---|---|---|
| 1 | `lib/core/util/platform_int64.dart` (新建) | `platformInt64ToInt(dynamic raw) → int` + doc-comment | +25 |
| 2 | `lib/core/util/time_format.dart` (新建) | `formatRelativeTime(int sec) → String` + doc-comment | +30 |
| 3 | `lib/core/util/import_summary_label.dart` (新建) | `formatImportSummaryLabel(...)` + doc-comment | +30 |
| 4 | `lib/features/rule_sub/rule_sub_page.dart` | 2 处 caller 改用 helper | +2 / -8 = -6 |
| 5 | `lib/features/rss/rss_source_manage_page.dart` | 2 处 caller 改用 helper | +2 / -8 = -6 |
| 6 | `lib/features/settings/cache_management_page.dart` | 2 处 caller 改用 helper | +2 / -8 = -6 |
| 7 | `lib/features/bookshelf/bookshelf_page.dart` | 删 `_formatRelativeTime` 私有 fn (15 行) + caller import & call helper | +1 / -14 = -13 |
| 8 | `lib/features/settings/read_stats_page.dart` | 删 `_formatRelativeTime` 私有 fn (17 行) + caller import & call helper | +1 / -16 = -15 |
| 9 | `lib/features/settings/backup_page.dart` | 2 处 ImportSummary 解析改用 helper | +4 / -34 = -30 |
| 10 | `test/platform_int64_test.dart` (新建) | 3 case：int 直传 / BigInt-like .toInt() / null 异常 | +30 |
| 11 | `test/time_format_test.dart` (新建) | 5 case：sec=0 → '从未' / 30s → '刚刚' / 90s → '1 分钟前' / 2h → '小时前' / 5d → '天前' | +35 |
| 12 | `test/import_summary_label_test.dart` (新建) | 3 case：完整 JSON / errors > 0 / 解析失败 fallback | +35 |
| **总计** | **+147 行新代码 + -76 行 caller** | **净 +71 行**（其中 +100 行 helper/test 是质量增量） |

实际**生产代码净 -27 行**（helper +85 + caller -76 ≈ -76/+85 = +9 line 看代码层；测试 +100 是新增 — explore 估 ~+10 行净不准，但符合"消除 ~50 行重复 + 加测试"的方向）。

## Open Questions

（已收敛）

## Requirements (final)

### MVP scope（4 项）

1. **新建 3 个 helper 文件**
   - `flutter_app/lib/core/util/platform_int64.dart`：`int platformInt64ToInt(dynamic raw)`
   - `flutter_app/lib/core/util/time_format.dart`：`String formatRelativeTime(int sec)` — 用 read_stats 版语义（`sec <= 0 → '从未'` 边界）
   - `flutter_app/lib/core/util/import_summary_label.dart`：`String formatImportSummaryLabel(String json, {required String prefix, required String fallback})`
   - 每个 helper 含完整 doc-comment 说明用法 + caller 列表 + BATCH-24 reference

2. **改 8 处 caller** 走新 helper：
   - PlatformInt64 6 处：rule_sub × 2 + rss_source_manage × 2 + cache_management × 2
   - _formatRelativeTime 2 处：bookshelf + read_stats（**顺手修 bookshelf 端 sec=0 隐含 bug**）
   - ImportSummary 2 处：backup_page (本地导入 + WebDAV 恢复)

3. **新建 3 个 test 文件** 覆盖 helper 边界
   - `test/platform_int64_test.dart`：3 case
   - `test/time_format_test.dart`：5 case
   - `test/import_summary_label_test.dart`：3 case

4. **master report 同步** F-W2B-007/030/024 标 Resolution by BATCH-24

### 不在范围内

- Refactor `formatReadDuration`（read_stats_page.dart::190 已 @visibleForTesting，跨 feature 不需要）
- 抽 BackupApiClient 大重构（F-W2B-004）
- 其它跨 feature 重复模板

## Acceptance Criteria

- [ ] `flutter_app/lib/core/util/platform_int64.dart` 存在含 `platformInt64ToInt` + doc-comment
- [ ] `flutter_app/lib/core/util/time_format.dart` 存在含 `formatRelativeTime` + doc-comment
- [ ] `flutter_app/lib/core/util/import_summary_label.dart` 存在含 `formatImportSummaryLabel` + doc-comment
- [ ] grep `raw is int \? raw : raw\.toInt`(去掉 helper 内部) 在 `flutter_app/lib/features/` 下 0 命中
- [ ] grep `_formatRelativeTime` 在 `flutter_app/lib/` 下 0 命中（caller 全部改 helper）
- [ ] grep `summary\['books'\]` 在 `flutter_app/lib/` 下 0 命中（ImportSummary 解析全部走 helper）
- [ ] 3 个新 test 文件存在，至少 3+5+3=11 个 case
- [ ] `flutter analyze` 0 warning
- [ ] `flutter test` 全部 PASS（旧 404 + 新约 11 ≈ 415）
- [ ] master report `findings-flutter-features.md` F-W2B-007/030/024 标 Resolution
- [ ] master report `findings.md` 主索引同步

## Definition of Done

- 3 个 helper 抽取完成
- 8 处 caller 走 helper（生产代码净减 ~30 行）
- 顺手修 bookshelf `_formatRelativeTime` sec=0 隐含 bug
- 11 个 helper 单测覆盖边界
- F-W2B-007/030/024 三条 finding 闭环

## Decision (ADR-lite)

**Context**: BATCH-22 死代码清扫 + BATCH-23 Rust silent error 后用户在候选 B/C 中选 B（PlatformInt64 helper 抽取）。explore audit 摸清 6+2+2 处重复模板。

**Decision**: 候选 B 完整版 — 3 个 helper 一批抽，单测覆盖边界，顺手修 bookshelf time_format bug。

**Consequences**:
- 净生产代码 ~-30 行（caller -76 + helper +85 + 注释 ~+20）+ test +100 行
- bookshelf "从未读" 场景显示 "1970-01-01" bug 被修
- 8 处 caller 改动量大（6+2+2）但每处都是 1 对 1 替换，回归风险低
- 加 11 个 helper 单测让边界行为可观测

## Technical Notes

### 风险点

- **`platformInt64ToInt` 输入 dynamic**：caller 传 `n`（PlatformInt64），但实际 io 平台是 int / web 平台是 BigInt（实际项目仅 Android 主线，0 web build）。helper 用 `dynamic raw` + `is int` type guard 确保 runtime 安全。
- **`formatRelativeTime` 行为统一**：bookshelf 当前 `sec=0` 行为是错的（显示 1970-01-01），统一 helper 后修复 → 用户在"未读章节"场景看到"从未"而非历史日期。**这是行为变化，但是 bug fix**，无回归风险。
- **`formatImportSummaryLabel` fallback 文案**：caller 传 `prefix` 和 `fallback` 两个参数，前者用于成功路径（含 `:`），后者用于 catch 路径。让兜底文案在 caller 处显式可见，避免 helper 内推断错误。

### 实施顺序

1. 新建 3 个 helper 文件（lib/core/util/）
2. 改 8 处 caller（按文件逐个改避免漏）
3. 新建 3 个 test 文件
4. `flutter analyze` 0 warning
5. `flutter test` 全过
6. 更新 master report

### 测试 case 设计

```dart
// platform_int64_test.dart
test('platformInt64ToInt: int 直传');
test('platformInt64ToInt: 假 BigInt-like (有 toInt() 的对象)');
test('platformInt64ToInt: null 抛异常');

// time_format_test.dart
test('formatRelativeTime: sec=0 返回 从未');
test('formatRelativeTime: 30s 前返回 刚刚');
test('formatRelativeTime: 90s 前返回 N 分钟前');
test('formatRelativeTime: 2h 前返回 N 小时前');
test('formatRelativeTime: 5 days 前返回 N 天前');

// import_summary_label_test.dart
test('formatImportSummaryLabel: 完整 JSON 拼接');
test('formatImportSummaryLabel: errors > 0 含错误数');
test('formatImportSummaryLabel: 解析失败 fallback');
```

## Research References

- 本任务沿用 BATCH-22 后 explore audit + 主对话精确核实
- BATCH-22/23 archive：`.trellis/tasks/archive/2026-05/05-21-batch-22-flutter-sentinel/` + `.trellis/tasks/archive/2026-05/05-21-batch-23-rust-silent-error-dep/`
- F-W2B-007/030/024 master entries：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-flutter-features.md`
