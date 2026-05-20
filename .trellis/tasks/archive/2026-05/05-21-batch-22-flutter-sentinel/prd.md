# BATCH-22: Flutter 死代码 + 调试 sentinel 清扫（候选 A）

## Goal

Flutter 端散落的调试 sentinel、装饰性死字段、墓志铭注释一次性清理。零行为变化、零回归风险，提升代码可读性 + 新人 onboarding 体验。一批清 5 条 finding。

## What I already know

### 来自 explore 扫描审计（2026-05-21）+ 主对话精确核实

**1. F-W2A-073 main.dart 6 个 debugPaint flag 显式置 default**

`flutter_app/lib/main.dart:17-22`：
```dart
debugRepaintTextRainbowEnabled = false;
debugRepaintRainbowEnabled = false;
debugPaintSizeEnabled = false;
debugPaintBaselinesEnabled = false;
debugPaintTextLayoutBoxes = false;
debugPaintLayerBordersEnabled = false;
```

这 6 个 flag 默认就是 false，显式赋值 = 噪音。`import 'package:flutter/rendering.dart';` (L2) 仅为这 6 个 flag 而 import，删后也可一并删除（如果文件其它地方不用 rendering.dart）。

**核实**：grep 后确认 main.dart 仅这 6 处用 `debug*Enabled`，删除 6 行 + 1 个 import = -7 行。

**2. F-W2A-031 调试 sentinel `print("ZZZZ ...")`**

`flutter_app/lib/features/reader/change_source_dialog.dart`（注：sub-agent 报告路径 `features/source/` 不对，实际在 `features/reader/`）：
- L69: `print("ZZZZ changeSource _startSearch: bookName=${widget.bookName}");`
- L120: `print("ZZZZ changeSrc: name='$name' book='$bookName' accepted=true");`

两处典型调试残留 `print("ZZZZ ...")`，一旦 release build 会污染 stdout。直接删，-2 行。

**3. F-W2A-032 死包裹 `nameMatch=true && authorMatch=true`**

`flutter_app/lib/features/reader/change_source_dialog.dart:118-121`：
```dart
final nameMatch = true;
final authorMatch = true;
print("ZZZZ changeSrc: name='$name' book='$bookName' accepted=true");  // 同上 F-W2A-031
if (nameMatch && authorMatch) { ... }
```

`nameMatch` / `authorMatch` 都硬编码 `true`，`if (true && true)` 永真。注释解释"接受所有搜索结果，让用户决定用哪个源"— **意图是不做匹配过滤**，但保留两个 final 变量 + if 包裹纯粹是历史遗留。

清理：删 2 个 final 变量 + 把 if 块去包裹（直接执行 body）。

**4. F-W2A-050 `providers.dart:55` 墓志铭注释**

```dart
// one-shot search test (runs during app init)
// Removed in code review: hardcoded sourceId, print() logs, fired by `watch`
// would also issue a stray search request. If you need to re-add a smoke,
// gate it behind kDebugMode and use debugPrint.
```

代码已删，注释还说"Removed in code review..."。删除整段 4 行注释。**核实**：sub-agent 报告 L114-117 不对，实际在 L54-57。

**5. F-W2A-047 `simulation_page_delegate.dart` 装饰性死字段**

`flutter_app/lib/features/reader/page/delegate/simulation_page_delegate.dart:56-57` + L828-834：
```dart
final Offset _bezierStart1 = const Offset(0, 0);
final Offset _bezierStart2 = const Offset(0, 0);
// ...
// 借助 [bezierStart1] / [bezierStart2] 字段去消静态分析未使用警告：
// 二者的具体值在 _bs1x/y、_bs2x/y 中存放，保留 const 字段是为了让阅读者
// 直观看到点位组织。
// ignore: unused_element
Offset get _start1 => _bezierStart1;
// ignore: unused_element
Offset get _start2 => _bezierStart2;
```

两个 const 字段 + 两个 unused getter（带 `// ignore: unused_element`）— 完全为骗 linter 而存在。删字段 + 删 getter + 删 7 行注释 = -10 行。

**6. F-W3-027 build.gradle.kts 模板注释**（**降级，本批不做**）

sub-agent 报告 L30-32 有 `// TODO:` 模板注释，主对话核实**没有 TODO**，仅 L46-47 有 `// You can update the following values to match your application needs.` / `// For more information, see: https://flutter.dev/to/review-gradle-config.` 两条 Flutter 模板生成的提示注释。这两条在所有 Flutter 项目里都有，删除它们的价值 < 维护信号，**本批不做**。

### 完整改动清单

| # | finding | 文件 | 行号 | 改动 |
|---|---|---|---|---|
| 1 | F-W2A-073 | `lib/main.dart` | L2 + L17-22 | 删 6 个 debugPaint 赋值 + 1 个 import |
| 2 | F-W2A-031 | `lib/features/reader/change_source_dialog.dart` | L69 | 删 1 行 print |
| 3 | F-W2A-031 | `lib/features/reader/change_source_dialog.dart` | L120 | 删 1 行 print |
| 4 | F-W2A-032 | `lib/features/reader/change_source_dialog.dart` | L118-121 | 删 2 个死变量 + 解 if 包裹 |
| 5 | F-W2A-050 | `lib/core/providers.dart` | L54-57 | 删 4 行墓志铭注释 |
| 6 | F-W2A-047 | `lib/features/reader/page/delegate/simulation_page_delegate.dart` | L55-57 + L828-834 | 删 2 个 const 字段 + 2 个 getter + 7 行注释 |

总计净 diff：约 **-30 行**（纯减法）。

## Open Questions

（已收敛）

## Requirements (final)

### MVP scope（5 项 + 1 项 master report 同步）

1. 改 `lib/main.dart`：删 L17-22 6 个 debugPaint 赋值 + 顶部 `import 'package:flutter/rendering.dart';`
2. 改 `lib/features/reader/change_source_dialog.dart`：
   - 删 L69 `print("ZZZZ changeSource _startSearch: ...")`
   - 删 L120 `print("ZZZZ changeSrc: ...")`
   - 删 L118-119 `final nameMatch = true; final authorMatch = true;` + L121 `if (nameMatch && authorMatch)` 解包裹
3. 改 `lib/core/providers.dart`：删 L54-57 整段 "// one-shot search test ... // Removed in code review..." 4 行注释
4. 改 `lib/features/reader/page/delegate/simulation_page_delegate.dart`：
   - 删 L55-57 `_bezierStart1` / `_bezierStart2` 2 个 const 字段
   - 删 L828-834 7 行注释 + 2 个 unused getter `_start1` / `_start2`
5. master report 同步：5 条 finding（F-W2A-073 / 031 / 032 / 050 / 047）标 "Resolved by BATCH-22"，findings.md 主索引同步

### 不在范围内

- F-W3-027 build.gradle.kts Flutter 模板注释（本批降级，价值低）
- 任何业务逻辑变化（仅清调试 sentinel 与死字段）
- 添加新测试（5 处都是 0 行为变化，现有 test 已覆盖）

## Acceptance Criteria

- [ ] `lib/main.dart` 不再有 `debug.*Enabled = false` 显式赋值；不再 import `flutter/rendering.dart`
- [ ] `lib/features/reader/change_source_dialog.dart` grep `ZZZZ` → 0 命中
- [ ] `lib/features/reader/change_source_dialog.dart` grep `nameMatch.*=.*true` → 0 命中
- [ ] `lib/core/providers.dart` grep `Removed in code review` → 0 命中
- [ ] `lib/features/reader/page/delegate/simulation_page_delegate.dart` grep `_bezierStart1\|_bezierStart2` → 0 命中
- [ ] grep `_start1\|_start2` 在 simulation_page_delegate.dart 内 → 0 命中（2 个 unused getter 已删）
- [ ] `flutter analyze` 0 warning（确认 6 个 debugPaint 赋值删除后无 unused import 等告警）
- [ ] `flutter test` 全部 PASS（旧 404 维持）
- [ ] master report `findings-flutter-core.md` 5 条 finding 标 Resolution
- [ ] master report `findings.md` 主索引同步

## Definition of Done

- 5 条 finding 闭环（F-W2A-073/031/032/050/047）
- 6 个 file 改动，净 -30 行
- 0 业务行为变化，0 测试新增
- master report + 主索引同步

## Decision (ADR-lite)

**Context**: BATCH-18 路线图清完后用户选 scan + 合拼下一批。explore audit 给出 3 个候选（A 死代码清扫 / B PlatformInt64 helper / C Rust silent error），用户选 A — 最稳路线（纯减法、零产品决策、零回归风险）。

**Decision**: 选项 A — 5 条 Flutter 死代码 finding 一批清。

**Consequences**:
- 净 -30 行，纯减法
- 0 业务行为变化
- 5 条 P2/P3 finding 一次性闭环（提升 master report 完成度）
- 不动 F-W3-027（build.gradle 模板注释价值低）
- 不动 saveRefreshRateModeToDisk 0 caller（之前留观察，本批继续不动）

## Technical Notes

### 风险点

- **`change_source_dialog.dart::_startSearch`**：删 `if (nameMatch && authorMatch)` 包裹后，body 直接执行。需仔细看 body 内是否有 break/return 依赖该 if，确认行为完全等价。
- **`simulation_page_delegate.dart`**：两个 const 字段 + 两个 getter 一起删，确认无外部 caller（grep `_bezierStart1\|_bezierStart2\|_start1\|_start2` 全仓）。
- **`main.dart` import 删除**：如 `flutter/rendering.dart` 还导出别处用的类型（如某些 debug 类），删除会编译失败。`flutter analyze` 必跑。

### 实施顺序

1. read 5 个文件的精确 chunk
2. 改 `main.dart`
3. 改 `change_source_dialog.dart`（3 处合并改）
4. 改 `providers.dart`
5. 改 `simulation_page_delegate.dart`
6. `flutter analyze` 验证
7. 用户跑 `flutter test`
8. 更新 master report

### 净 diff 估算

| 文件 | -行 | 净 |
|---|---|---|
| `lib/main.dart` | 7 | -7 |
| `lib/features/reader/change_source_dialog.dart` | 4-5 | -4~-5 |
| `lib/core/providers.dart` | 4 | -4 |
| `lib/features/reader/page/delegate/simulation_page_delegate.dart` | ~12 | -12 |
| **合计** | **~28** | **-28** |

## Research References

- 本任务沿用 BATCH-18 后 scan audit（in-context，未持久化到 research/）
- BATCH-18 子序列 archive：`.trellis/tasks/archive/2026-05/05-2[01]-batch-18*/`
- F-W2A-073/031/032/050/047 master entry：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-flutter-core.md`
