# Task 4 — tap 翻页动画时长可配置

## Goal

把 `page_view.dart:97` 的 `Duration(milliseconds: 300)` 与 `:176-177` 的
hardcoded 300ms 抽成 ReaderSettings 字段 `tapAnimDurationMs`，可由设置面板
Slider 在 200-1000ms 范围内调整，默认 **300ms 不变**（对齐 Legado MD3 原版
体感）。

理由：用户原话"点击仿真翻页太快看不到动画"。Phase A 三轮已经把仿真贝塞尔
跟手感修好（Task 3+5），但单帧动画时长仍是 300ms，部分用户希望放慢到 500/700ms
看清折角弹起过程。给个滑块让用户自己选 — 默认仍 MD3 标准 300ms 不强迫所有人。

属于 MD3 体感复刻 7 任务序列的第 4 个（Phase C 配置项）。

## What I already know

### Hardcoded 300ms 落点

```dart
// page_view.dart:95-99 (AnimationController 构造)
_animController = AnimationController(
  vsync: this,
  duration: const Duration(milliseconds: 300),
);

// page_view.dart:175-177 (tap 调用入口)
ctrl.onTapNext = () => _delegate.nextPageByAnim(300);
ctrl.onTapPrev = () => _delegate.prevPageByAnim(300);
```

注意：drag 路径**不调** nextPageByAnim/prevPageByAnim，drag 走的是
`_runAnimation` → `animController.forward(from: animController.value)`，
所以也受 `_animController.duration` 影响。如果想"只改 tap 不改 drag"，
需要更精细的控制（在 tap 调用前临时改 duration、调完恢复）。

PRD 的设计方向：**tap 和 drag fling 都用同一个 duration**，简化心智模型。
用户感觉"tap 太快"时拉长 duration，drag fling 也跟着变长——通常用户期望
两者一致而不是强行解耦。

### ReaderSettings 当前结构

`flutter_app/lib/core/providers.dart:500-712` 是 ReaderSettings 类：
- 21 个字段 + copyWith + toJson + fromJson + 多版本迁移（v1→v4）
- `kReaderSettingsCurrentVersion = 4`
- 设置面板：`flutter_app/lib/features/reader/widgets/reader_settings_sheet.dart`

### 现有 Slider 模式

`reader_settings_sheet.dart:86 / 126 / 133 / 140` 已经有 Slider 范例：
```dart
Text('字号: ${_s.fontSize.round()}', style: label),
Slider(value: _s.fontSize, min: 12, max: 32, ...),
```

可以直接照搬这个样式新增"翻页动画时长"行。

## Requirements

- **R4.1**：ReaderSettings 加新字段 `pageAnimDurationMs`（int，默认 300）
- **R4.2**：copyWith / toJson / fromJson 同步加该字段
- **R4.3**：JSON migration version 升 v5：v4 旧数据 fromJson 时 pageAnimDurationMs 缺省 300（无破坏性迁移）
- **R4.4**：page_view.dart `_createDelegate()` 用 `widget.settings.pageAnimDurationMs` 替换 hardcoded 300（AnimationController duration + nextPageByAnim/prevPageByAnim 实参）
- **R4.5**：page_view.dart `didUpdateWidget` 在 pageAnimDurationMs 变化时重建 delegate 或更新 controller duration
- **R4.6**：reader_settings_sheet.dart 加一行 Slider「翻页动画时长 (ms)」，min=200 / max=1000 / divisions=16（每档 50ms）
- **R4.7**：测试：JSON 旧版本（v4）migrate 进来 pageAnimDurationMs == 300（默认值）；新版本 round-trip 正确
- **R4.8**：测试：page_view AnimationController 实际 duration 跟随 ReaderSettings.pageAnimDurationMs

## Acceptance Criteria

- [ ] ReaderSettings.pageAnimDurationMs 字段 + copyWith + toJson + fromJson
- [ ] kReaderSettingsCurrentVersion = 5，v4 旧数据 fromJson 默认值 300
- [ ] page_view.dart 全部 hardcoded 300 替换成 settings.pageAnimDurationMs
- [ ] reader_settings_sheet.dart 加 Slider，名称"翻页动画时长 (ms)"
- [ ] JSON migration test：v4 旧 JSON 缺省值；v5 round-trip
- [ ] AnimationController duration 跟 settings 同步测试（didUpdateWidget 时刷新）
- [ ] analyze 0 issue
- [ ] xvfb-run flutter test 全绿（130 baseline + 新增）

## Definition of Done

- 测试新增 + 既有测试不退化
- analyze 全绿
- 单一 commit message，"第二十四批"格式
- libbridge.so / Rust / FRB 零改动

## Technical Approach

### 1. ReaderSettings 加字段

```dart
// providers.dart:500
class ReaderSettings {
  // ... existing 21 fields ...
  final int pageAnimDurationMs;  // ← 新增

  const ReaderSettings({
    // ... existing ...
    this.pageAnimDurationMs = 300,  // ← 默认 300，对齐 MD3 原版
  });

  ReaderSettings copyWith({
    // ... existing 21 ...
    int? pageAnimDurationMs,  // ← 新增
  }) {
    return ReaderSettings(
      // ... existing ...
      pageAnimDurationMs: pageAnimDurationMs ?? this.pageAnimDurationMs,
    );
  }

  Map<String, dynamic> toJson() => {
    // ... existing ...
    'pageAnimDurationMs': pageAnimDurationMs,
  };

  factory ReaderSettings.fromJson(Map<String, dynamic> json) {
    // ... existing migration chain ...
    return ReaderSettings(
      // ... existing 21 fields ...
      pageAnimDurationMs: (json['pageAnimDurationMs'] as int?) ?? 300,
    );
  }
}

const int kReaderSettingsCurrentVersion = 5;  // ← 升版本
```

### 2. page_view.dart 用 settings.pageAnimDurationMs

```dart
// _createDelegate()
_animController = AnimationController(
  vsync: this,
  duration: Duration(milliseconds: widget.settings.pageAnimDurationMs),
);
// ...
ctrl.onTapNext = () => _delegate.nextPageByAnim(widget.settings.pageAnimDurationMs);
ctrl.onTapPrev = () => _delegate.prevPageByAnim(widget.settings.pageAnimDurationMs);
```

`didUpdateWidget` 当 pageAnimDurationMs 变化时调 _createDelegate（与现有 pageAnim/effectiveTextColor/effectiveBackgroundColor 变更同样路径）：

```dart
@override
void didUpdateWidget(PageViewWidget oldWidget) {
  super.didUpdateWidget(oldWidget);
  if (oldWidget.pageAnim != widget.pageAnim ||
      oldWidget.settings.effectiveTextColor != widget.settings.effectiveTextColor ||
      oldWidget.settings.effectiveBackgroundColor != widget.settings.effectiveBackgroundColor ||
      oldWidget.settings.pageAnimDurationMs != widget.settings.pageAnimDurationMs) {
    _createDelegate();
  }
}
```

### 3. reader_settings_sheet.dart 加 Slider

参考已有 fontSize Slider 模板。位置：放在"翻页动画"选择器附近（如果 sheet 里有的话）或排在字号下面。

```dart
Row(
  children: [
    Text('翻页动画时长: ${_s.pageAnimDurationMs} ms', style: label),
  ],
),
Slider(
  value: _s.pageAnimDurationMs.toDouble(),
  min: 200,
  max: 1000,
  divisions: 16,  // 每档 50 ms
  label: '${_s.pageAnimDurationMs} ms',
  onChanged: (v) => _update(_s.copyWith(pageAnimDurationMs: v.round())),
),
```

### 4. 测试

新增 `flutter_app/test/reader_settings_anim_duration_test.dart`：

1. **默认值**: `const ReaderSettings()` → pageAnimDurationMs == 300
2. **copyWith 透传**: copyWith({pageAnimDurationMs: 500}).pageAnimDurationMs == 500
3. **JSON round-trip**: toJson + fromJson → 字段值保持
4. **v4 migration**: fromJson({"settingsVersion": 4, ...}) → pageAnimDurationMs == 300
5. **AnimationController duration 跟随**：构造 PageViewWidget(settings) → 改 settings.pageAnimDurationMs → pump → controller.duration 正确

### Risk & Mitigation

- **AnimationController 重建可能打断进行中的动画**：didUpdateWidget 的 _createDelegate 路径已经在 pageAnim 变化时存在，行为已知。如果在动画进行中 user 调 settings，动画会被打断重置——可接受（用户主动调整设置时翻页停下也合理）
- **JSON 缺省值**：新字段 fromJson 时用 `?? 300` fallback，v4 旧数据无 pageAnimDurationMs key 也安全
- **drag fling duration 同步变化**：Out-of-scope 决策——drag 路径用同一个 controller，duration 同步变也合理（用户调慢就两者都慢）。如果未来用户反馈"只想 tap 慢、drag 快"，再考虑分离

### Out of Scope

- 不分离 tap / drag fling 的 duration（同一 AnimationController.duration）
- 不改 cover/slide/fade/noAnim delegate 的内部动画几何
- 不动 simulation_page_delegate 的 _coverFallback 已删除（Task 5）
- 不动 Rust / FRB / libbridge.so
- 不加 SharedPreferences 单独存储（沿用 ReaderSettings JSON）

## Decision (ADR-lite)

**Context**: 用户原话"点击仿真翻页太快看不到动画"。MD3 默认 300ms 没问题，
但有用户希望可配。两个候选：A=分离 tap / drag duration（用户改 tap 不影响
drag），B=单一 duration 同时影响 tap+drag。

**Decision**: Plan B — 单一 duration。

**Consequences**:
- 优点：JSON / state / Slider 简单，UI 一行就够，没有"两个相关数字让用户困惑"
- 缺点：drag fling duration 也变长。用户预期 drag 是手指惯性，松手后 fling
  按距离比例算（page_delegate 已经如此），这里 controller.duration 实际不会
  影响 fling，因为 fling 用 `forward(from: x)` 自己算时长？审计：
  实际上 _runAnimation 用 `animController.forward(from: animController.value)`，
  duration 仍是 controller 的全局 duration。所以 drag 拖到 80% 松手，剩余
  20% 用 0.2 * duration ms。duration 拉长 drag 也变长。可接受。

**Migration cost**: kReaderSettingsCurrentVersion 4→5；v4 旧数据加 fallback
默认值。无破坏性。

## Out of Scope

（同 Technical Approach 同名小节）

## Technical Notes

### 命令前缀

- `flutter --no-version-check analyze`
- `xvfb-run -a flutter --no-version-check test`
- 工作目录 flutter_app/

### 关键 file:line

- `flutter_app/lib/core/providers.dart:498` — kReaderSettingsCurrentVersion
- `flutter_app/lib/core/providers.dart:500-712` — ReaderSettings 全部
- `flutter_app/lib/features/reader/page/page_view.dart:97` — duration
- `flutter_app/lib/features/reader/page/page_view.dart:176-177` — tap 调用
- `flutter_app/lib/features/reader/page/page_view.dart:47-54` — didUpdateWidget
- `flutter_app/lib/features/reader/widgets/reader_settings_sheet.dart:86-150` — 现有 Slider 模板

## Research References

无（纯本地配置项，无需外部研究）。
