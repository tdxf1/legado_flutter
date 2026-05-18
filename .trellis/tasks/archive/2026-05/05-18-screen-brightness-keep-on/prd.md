# 屏幕亮度调节 + 屏幕常亮 (批次 1)

## Goal

在阅读器内提供**屏幕亮度调节滑杆**和**屏幕常亮开关**。亮度滑杆只影响阅读器场景（退出 reader 恢复系统亮度），常亮开关使用 wakelock 防止系统超时锁屏。对齐原 Legado MD3：
- `ReadMenu.kt:269-300 setScreenBrightness` 写入 `window.attributes.screenBrightness`
- `BaseReadBookActivity.kt:239 keepScreenOn(on: Boolean)` 切 `FLAG_KEEP_SCREEN_ON`

## What I already know

- **Flutter 现状**：完全缺失（参考 `feature-gap-reader-bookshelf-source.md` §1.3 / §1.4）
  - `grep "screenBrightness" lib/` 仅 `reader_page.dart:1683` 处用 `Brightness.light/dark` 设状态栏图标颜色
  - 无 `wakelock_plus` / `screen_brightness` 包依赖
- **schema**：`ReaderSettings` 字段集中在 `lib/core/providers.dart:554`，当前 v5（`kReaderSettingsCurrentVersion = 5`）；JSON 序列化路径 `toJson` / `fromJson` 完整
- **UI 入口**：阅读器底栏设置面板在 `lib/features/reader/widgets/reader_settings_sheet.dart`
- **ReaderPage 生命周期**：`reader_page.dart` initState / dispose 已含多个资源管理（_clockTimer / _scrollController 等）
- **包选择**：`screen_brightness: ^2.0.1` + `wakelock_plus: ^1.2.10`，两者都有 iOS / Desktop 支持，纯 Dart API

## Assumptions

- 用户默认期望进入 reader 自动开常亮（与原项目一致）；亮度默认 `-1` = 跟系统
- 退出 reader（dispose 或 push 到目录）需要恢复系统亮度，不能让 reader 设的亮度污染其它页面
- 亮度滑杆 0-100 整数（百分比），内部转换成 0.0-1.0 给 `screen_brightness`

## Requirements

1. **新增 ReaderSettings 字段**：
   - `double screenBrightness` 默认 `-1.0`（=跟系统亮度，不调节）
   - `bool keepScreenOn` 默认 `true`（进 reader 自动常亮）
2. **settingsVersion 升级 v5 → v6**，添加 v5→v6 迁移：缺字段时取默认值
3. **`reader_settings_sheet.dart` 加 UI**：
   - "屏幕亮度" 区域：滑杆 0-100 + "跟随系统" 复选框（勾上时把 `screenBrightness` 设回 -1）
   - "屏幕常亮" 开关
4. **`reader_page.dart` 接入硬件 API**：
   - `initState` 末尾根据 `_settings.keepScreenOn` 调 `WakelockPlus.enable()` / `disable()`
   - `_settings.screenBrightness >= 0` 时调 `ScreenBrightness().setApplicationScreenBrightness(value)`
   - `dispose` 必复位：`WakelockPlus.disable()` + `ScreenBrightness().resetApplicationScreenBrightness()`
   - settings 变化时（`_setReaderSettings`）跟随更新硬件状态
5. **依赖 pub get 后单测仍可跑**（不能因引入 native plugin 让 widget test 起不来）

## Acceptance Criteria

- [ ] 单测：`ReaderSettings.toJson / fromJson` round-trip 含新字段（screenBrightness / keepScreenOn）
- [ ] 单测：v5 旧 JSON 反序列化时 screenBrightness 默认 -1.0、keepScreenOn 默认 true
- [ ] 单测：`copyWith` 支持新字段
- [ ] 单测：settingsVersion 写出 == 6
- [ ] 实机：设置面板出现亮度滑杆 + 跟随系统勾选 + 常亮开关
- [ ] 实机：拖滑杆屏幕亮度立刻变；勾选跟随系统后亮度恢复系统值
- [ ] 实机：常亮开关关掉后系统超时正常熄屏
- [ ] 实机：从阅读器返回书架，系统亮度自动恢复（不留亮度污染）
- [ ] flutter analyze 0 issue
- [ ] flutter test 235+ 通过（继承当前基线 + 至少 +3 新单测）

## Definition of Done

- analyze 0 issue
- xvfb-run flutter test 全绿（不能因 plugin 引入降基线）
- debug APK 构建到 `dist/`（不主动推设备 — 决策 Q3）
- commit + archive 任务

## Technical Approach

### A. 新依赖

`flutter_app/pubspec.yaml` 加：
```yaml
screen_brightness: ^2.0.1
wakelock_plus: ^1.2.10
```

### B. ReaderSettings v6 改造

`lib/core/providers.dart`：
```dart
const int kReaderSettingsCurrentVersion = 6;

class ReaderSettings {
  ...existing fields...

  /// 批次 1 (05-18): 屏幕亮度 0.0..1.0；-1.0 表示"跟随系统"（不调节）。
  /// 进 reader 时由 [_ReaderPageState] 同步给 [ScreenBrightness]，
  /// 退出 reader 自动 reset 回系统值。
  final double screenBrightness;

  /// 批次 1 (05-18): 进 reader 时是否启用 [WakelockPlus]，防止系统
  /// 超时锁屏。dispose 一定 disable。
  final bool keepScreenOn;

  const ReaderSettings({
    ...
    this.screenBrightness = -1.0,
    this.keepScreenOn = true,
  });

  // 同步更新 toJson / fromJson / copyWith。fromJson 兼容旧 v5 JSON：缺字段
  // 时分别 fallback 到 -1.0 / true。
}
```

文档头加 v6 说明：
```
/// - settingsVersion == 6：新增 screenBrightness（double，-1.0 = 跟随系统）
///   + keepScreenOn（bool，默认 true）。
```

### C. ReaderPage 生命周期改造

`lib/features/reader/reader_page.dart`：
```dart
import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

@override
void initState() {
  super.initState();
  ...existing init...
  loadReaderSettingsFromDisk().then((s) {
    if (mounted) {
      _setReaderSettings(s, markLoaded: true);
      _applyHardwareSettings(s);  // 新增
    }
  })...;
}

void _applyHardwareSettings(ReaderSettings s) {
  // wakelock
  if (s.keepScreenOn) {
    WakelockPlus.enable();
  } else {
    WakelockPlus.disable();
  }
  // brightness — 仅当 >= 0 时主动设置；-1 留给系统
  if (s.screenBrightness >= 0) {
    ScreenBrightness().setApplicationScreenBrightness(s.screenBrightness);
  } else {
    ScreenBrightness().resetApplicationScreenBrightness();
  }
}

@override
void dispose() {
  // 关键：reader 退出一定复位
  try {
    WakelockPlus.disable();
  } catch (_) {}
  try {
    ScreenBrightness().resetApplicationScreenBrightness();
  } catch (_) {}
  ...existing dispose...
  super.dispose();
}

// _setReaderSettings 内部检测 brightness/keepScreenOn 变化时 → _applyHardwareSettings
```

### D. UI 改造

`lib/features/reader/widgets/reader_settings_sheet.dart`：在底栏添加 "屏幕" 一段：
```
┌─────────────────────────────────────┐
│ 屏幕亮度                              │
│ ☐ 跟随系统    ━━━━━●━━━━━ 70%        │
│                                       │
│ 屏幕常亮          [✓]                 │
└─────────────────────────────────────┘
```

### E. 测试

`test/reader_settings_v6_test.dart`：
1. round-trip 含新字段
2. v5 旧 JSON 反序列化默认值
3. copyWith 新字段
4. settingsVersion 写出 6

## Decision (ADR-lite)

**Context**: reader 没有亮度调节、不主动 wakelock，体验比原版差一截。

**Decision**:
1. `screenBrightness = -1.0` 作"跟随系统"哨兵值（避免 nullable 增加 JSON 复杂度）
2. dispose 必 reset 应用级亮度（不影响系统亮度，从 reader 回书架立即恢复）
3. wakelock 默认 true（与原项目对齐 — 阅读时主流期望）
4. 不动 BackgroundColor / nightMode 现有逻辑（独立轴）
5. 不接入 Android 自动亮度光感传感器（原项目也是手动滑杆）

**Consequences**:
- 用户立刻享受常亮 + 亮度调节，体感对齐原 Legado
- 跨平台：iOS 这俩包都有 native impl；Desktop（Linux）`screen_brightness` 暂不支持 Linux，但 `wakelock_plus` Linux OK；Linux 调亮度调用走 try-catch 不抛
- 退出 reader 必复位，避免亮度污染其它页面
- 增加 2 个 native plugin 依赖，APK 体积 +~500KB，可接受

## Out of Scope

- 自动亮度（光感传感器）
- 屏幕超时自定义时长（30s/60s/不超时 — 原 `screen_time_out_value`）
- 亮度跨章节记忆（只一份全局值）
- 屏幕方向锁定（批次 1 不动）

## Technical Notes

### 关键文件
- `flutter_app/pubspec.yaml` — 加 2 个依赖
- `flutter_app/lib/core/providers.dart` — ReaderSettings v6
- `flutter_app/lib/features/reader/reader_page.dart` — 生命周期接入硬件
- `flutter_app/lib/features/reader/widgets/reader_settings_sheet.dart` — UI
- `flutter_app/test/reader_settings_v6_test.dart` — 新单测

### 风险
1. iOS 在 dispose 时 reset 亮度可能被 application background 状态影响 — try-catch 兜底
2. wakelock 在某些 ROM 不生效（小米某些机型熄屏后仍按 ROM 默认行为）— 原项目同样问题，不在本批解决
3. 单测环境 plugin 不可用 → ReaderSettings 单测不依赖 plugin（只测 JSON / copyWith），生命周期相关用 try-catch 隔离
4. flutter_test pumpWidget(ReaderPage) 不能跑 wakelock；现有 reader_page_test 已 mock 部分依赖，本批的硬件调用都包 try-catch，pump 不会崩

## Research References

不需要 — 改动小且自包含；feature-gap 报告 §1.3 / §1.4 已给出 MD3 对照。
