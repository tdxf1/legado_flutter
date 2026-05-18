# 音量键 + 物理键翻页 (批次 2)

## Goal

阅读器内监听**物理按键**触发翻页，对齐原 Legado 的 `volumeKeyPage` / `keyPage` 行为：
- 音量上 / PageUp → 上一页
- 音量下 / PageDown / Space → 下一页
- 用户可在设置里关闭"音量键翻页"
- 朗读时音量键只控音量，不翻页（原项目 `AppConfig.volumeKeyPageOnPlay` 默认 false）

## What I already know

- **原项目**：`ReadBookActivity.kt:682-738 onKeyDown/onKeyUp` + `:927 volumeKeyPage`
  - keys：`KEYCODE_VOLUME_UP/DOWN`, `KEYCODE_PAGE_UP/DOWN`, `KEYCODE_SPACE`
  - 守卫：`AppConfig.volumeKeyPage`（开关）+ `volumeKeyPageOnPlay`（朗读时是否翻页）
  - 长按 debounce：`keyPageDebounce` 600ms
- **Flutter 现状**：完全无键盘监听 — `grep RawKeyboard/HardwareKeyboard/KeyboardListener` 0 命中
- **翻页入口**：`PageViewController` 已注入 `onTapNext` / `onTapPrev`（`page_view.dart:191-192`），ReaderPage 在 `_handleTap` 直接调用即可
- **Settings**：`ReaderSettings` v6 刚迭代过；本批继续 v6（不动 schema 版本，只加字段）—— **决定**：**升级到 v7**，避免老用户存的 v6 没有新字段时不触发 fromJson 默认值（其实 fromJson 已经兜底默认值，可以保 v6）

## Decision

保 settingsVersion=v6。新字段都在 `fromJson` 路径走"缺字段 fallback 默认值"模式（与 batch01 的 screenBrightness/keepScreenOn 同模式），不强升 schema。

## Requirements

1. **新增 ReaderSettings 字段**：
   - `bool enableVolumeKeyPage` 默认 `true`（启用音量键翻页）
   - `bool volumeKeyPageOnTts` 默认 `false`（朗读中不翻页 — 与 MD3 行为一致）
2. **`reader_page.dart` 接入按键监听**：用 `Focus(autofocus: true, onKeyEvent: ...)` 包裹 reader 的渲染区
   - keys：VOLUME_UP / VOLUME_DOWN / PAGE_UP / PAGE_DOWN / SPACE / ARROW_UP / ARROW_DOWN
   - 控件可见时（`_controlsVisible`）/ 选词菜单可见时 / 设置 sheet 打开时不拦截（让系统正常处理）
   - TTS 朗读中：若 `volumeKeyPageOnTts == false`，音量键放给系统（不翻页、不消费）
3. **设置面板加开关**：
   - "音量键翻页" SwitchListTile
   - "朗读时音量键也翻页" SwitchListTile（subtitle 说明默认关闭）
4. **菜单可见 / sheet 可见时不拦截**：`_controlsVisible == true` 时按键事件不拦截

## Acceptance Criteria

- [ ] 单测：`ReaderSettings.toJson / fromJson / copyWith` 含两新字段；缺字段时 fallback 默认值
- [ ] 单测：模拟 KeyDownEvent(volumeDown) → 调用 onTapNext 一次
- [ ] 单测：`_controlsVisible == true` 时 KeyDownEvent(volumeDown) → 不调 onTapNext
- [ ] 单测：`enableVolumeKeyPage == false` 时音量键不翻页（让事件传过）
- [ ] flutter analyze 0 issue
- [ ] flutter test 全绿（≥ 252，248 baseline + 4+ 新单测）
- [ ] 实机：硬件音量下/上键翻页；菜单可见时不翻页；设置关闭后不翻页

## Definition of Done

- analyze 0 issue / test 全绿
- debug APK 到 dist/
- commit + archive

## Technical Approach

### A. ReaderSettings 字段

`lib/core/providers.dart`:
```dart
final bool enableVolumeKeyPage;        // default true
final bool volumeKeyPageOnTts;         // default false
```
toJson / fromJson / copyWith 三处加。

### B. ReaderPage 按键监听

```dart
@override
Widget build(BuildContext context) {
  return Focus(
    autofocus: true,
    onKeyEvent: _handleKeyEvent,
    child: ...existing build...,
  );
}

KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
  if (event is! KeyDownEvent) return KeyEventResult.ignored;
  // 控件可见时不拦截
  if (_controlsVisible) return KeyEventResult.ignored;
  // 设置开关
  final isVolumeKey = event.logicalKey == LogicalKeyboardKey.audioVolumeUp
      || event.logicalKey == LogicalKeyboardKey.audioVolumeDown;
  if (isVolumeKey) {
    if (!_settings.enableVolumeKeyPage) return KeyEventResult.ignored;
    if (!_settings.volumeKeyPageOnTts && _tts.isSpeaking) {
      return KeyEventResult.ignored;
    }
  }

  if (_isPrevKey(event.logicalKey)) {
    _pageViewController?.onTapPrev?.call();
    return KeyEventResult.handled;
  }
  if (_isNextKey(event.logicalKey)) {
    _pageViewController?.onTapNext?.call();
    return KeyEventResult.handled;
  }
  return KeyEventResult.ignored;
}

bool _isPrevKey(LogicalKeyboardKey k) =>
    k == LogicalKeyboardKey.audioVolumeUp ||
    k == LogicalKeyboardKey.pageUp ||
    k == LogicalKeyboardKey.arrowUp;

bool _isNextKey(LogicalKeyboardKey k) =>
    k == LogicalKeyboardKey.audioVolumeDown ||
    k == LogicalKeyboardKey.pageDown ||
    k == LogicalKeyboardKey.arrowDown ||
    k == LogicalKeyboardKey.space;
```

注意：Flutter 的 audioVolume 键在 Android 默认会被系统拦截（系统会先吃掉音量调节）。需要在 Android 端拦截：实测 `Focus.onKeyEvent` 在前台 reader Activity 通常能拿到（特别是有焦点时），但稳妥起见也可以加 `RawKeyboardListener` 或在 native 端 `dispatchKeyEvent` 拦截。**先试纯 Dart `Focus`，跑不通再退到 platform channel**。

### C. UI

`reader_settings_sheet.dart` 在"屏幕"段后加"按键"段：
- SwitchListTile: 音量键翻页 → `enableVolumeKeyPage`
- SwitchListTile: 朗读时音量键也翻页 → `volumeKeyPageOnTts`

### D. TTS 状态判定

ReaderPage 已有 `_tts` (`ReaderTtsManager`)；用 `_tts.isSpeaking` getter（如果没有，加一个）。

### E. 测试

`test/key_event_page_turn_test.dart`：
- `_handleKeyEvent` 用 mock state + mock controller 单测：
  - 4 个核心场景验证按键 → 正确翻页

注意：测试时不能直接 pump ReaderPage（依赖 plugin），需要把 `_handleKeyEvent` 提取成可独立测试的纯函数 / 或者把判定逻辑拆出来：

```dart
// 提取成 static 方法或 top-level function
KeyEventResult handleReaderKeyEvent({
  required KeyEvent event,
  required ReaderSettings settings,
  required bool controlsVisible,
  required bool ttsSpeaking,
  required VoidCallback onPrev,
  required VoidCallback onNext,
}) { ... }
```

这样单测无需 widget tree。

## Out of Scope

- 自定义键码映射（原 `PageKeyDialog` 让用户绑定任意键码）
- 长按 debounce（原 600ms） — 看实测体验决定是否补
- 鼠标滚轮翻页（批次 1 范围外，对应批次 17 之后处理）

## Technical Notes

### 关键文件
- `lib/core/providers.dart` — 加两字段
- `lib/features/reader/reader_page.dart` — Focus 包裹 + onKeyEvent
- `lib/features/reader/widgets/reader_settings_sheet.dart` — UI
- `lib/features/reader/services/reader_tts_manager.dart` — 看 isSpeaking 是否已暴露
- `test/key_event_page_turn_test.dart` — 新测

### 风险
1. Android 音量键会被系统拦截调节音量；实机需验证 `Focus.onKeyEvent` 能不能拿到 `LogicalKeyboardKey.audioVolumeUp/Down`
   - 如不行，方案 B：自定义 `WidgetsBindingObserver` 用 `HardwareKeyboard.instance.addHandler`，或在 `MainActivity.kt` `dispatchKeyEvent` 拦截后转发到 Flutter
   - 本批次 PRD 先做纯 Dart 方案；如果实机失败，记 followup
2. 桌面平台不会有音量键，但有 PageUp/Down/Space —— Focus 路径正常拿到
3. 选词菜单 / 设置 sheet 可见时不能拦截 —— 通过 `_controlsVisible` 守卫；选词菜单暂未做，无需考虑

### 测试策略
- 抽 `handleReaderKeyEvent` 纯函数做单测（不 pump widget）
- 实机测：硬件音量键 + 设置面板开关 + 朗读时 / 菜单可见时

## Research References

- `feature-gap-reader-bookshelf-source.md` §1.8（点击区域 / 音量键 / 物理键）
