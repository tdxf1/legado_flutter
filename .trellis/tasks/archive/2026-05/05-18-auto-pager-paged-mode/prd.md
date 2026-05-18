# 分页模式自动翻页 + 速度可调 (批次 4)

## Goal

让所有翻页模式（cover / slide / simulation / fade / noAnim / scroll）都支持**自动翻页**：
- **滚动模式**：每 50ms 推进 N 像素（速度 1-10 档）
- **分页模式**：每 N 秒触发一次 `onTapNext` （间隔 1-30 秒）
- 设置面板可调速度
- 阅读菜单加"自动翻页"按钮，长按出速度调整

对齐原 Legado MD3 `AutoPager.kt` + `AutoReadDialog.kt`。

## What I already know

- **Flutter 现状**：`ReaderAutoScroller` 已存在但**仅滚动模式**：`controller() == null` 时直接 `_stop()`（reader_auto_scroller.dart:69-72）
- 速度硬编码：`stepPx = 1.0` / `stepInterval = 50ms` ≈ 20 px/s，无配置
- `_toggleAutoScroll()` 在 reader_page.dart:2440 暴露给底栏按钮
- 用户在分页模式下点"自动翻页"会瞬间停（`controller=null` 路径）
- 翻页入口：`_pageViewController?.onTapNext?.call()` 已经在批次 2/3 用过

## Decision

**统一 ReaderAutoScroller**：增加一个 `onPageTick` callback 和 `pageIntervalMs`，分页模式由调用方注入。
- 滚动模式：现有路径不变，速度档位用 `stepPx` 1.0..5.0 (10 档)
- 分页模式：每 `pageIntervalMs` 触发 `onPageTick`，由 reader_page 调 `_pageViewController.onTapNext`

ReaderSettings 加 2 个字段：
- `int autoScrollSpeed`：1..10（滚动模式 stepPx 倍率），默认 1（保持现有体感）
- `int autoPageIntervalSeconds`：1..30（分页模式触发间隔），默认 10

## Requirements

1. **`ReaderAutoScroller` 改造**：
   - 加 `pageIntervalMs` 参数 + `onPageTick` callback
   - 加 `pixelsPerStep` 参数（覆盖默认 stepPx）
   - 自动检测：若 `controller()` 返回 null 但 `onPageTick` 非 null，走分页路径（按 `pageIntervalMs` 计时）
   - 抽 `start(scroll: bool)` 方法允许动态选择
2. **ReaderSettings 加 2 字段**：`autoScrollSpeed` (默认 1) / `autoPageIntervalSeconds` (默认 10)，仍 v6
3. **reader_page.dart 改造**：
   - `ReaderAutoScroller` 实例化时传入新参数
   - `_toggleAutoScroll` 时根据 `_settings.isScrollMode` 启动正确路径
4. **设置面板加速度调节**：
   - "自动滚动速度"滑杆 1-10 档（仅滚动模式可见 / 始终可见）
   - "自动翻页间隔"滑杆 1-30 秒（仅分页模式可见 / 始终可见）

简化方案：两个滑杆始终显示，不按 mode 隐藏（用户改完模式后立即生效）。

## Acceptance Criteria

- [ ] 单测：ReaderSettings round-trip + fromJson 缺字段 fallback（autoScrollSpeed=1 / autoPageIntervalSeconds=10）
- [ ] 单测：`ReaderAutoScroller` 在 onPageTick 模式下按 pageIntervalMs 触发 callback（用 fakeAsync 模拟时钟）
- [ ] 单测：滚动模式仍按 stepPx 推进
- [ ] flutter analyze 0 issue
- [ ] flutter test 全绿（≥ 322，317 baseline + 至少 5+ 新单测）
- [ ] 实机：分页模式点自动翻页，每 10s 翻一页；滚动模式按速度推进

## Definition of Done

- analyze 0 issue / test 全绿
- debug APK 到 dist/
- commit + archive

## Technical Approach

### A. ReaderAutoScroller 改造

```dart
class ReaderAutoScroller {
  ReaderAutoScroller({
    required this.controller,
    required this.onChanged,
    this.onPageTick,
    this.pixelsPerStep = 1.0,
    this.pageIntervalMs = 10000,
  });

  final ValueGetter<ScrollController?> controller;
  final VoidCallback onChanged;

  /// 分页模式回调；为 null 表示禁用分页路径。
  final VoidCallback? onPageTick;

  /// 滚动模式每 50ms 推进的像素数。
  double pixelsPerStep;

  /// 分页模式两次 onPageTick 之间的间隔。
  int pageIntervalMs;

  Timer? _timer;
  bool _running = false;

  static const Duration stepInterval = Duration(milliseconds: 50);

  bool get isRunning => _running;

  /// 切换运行状态。scroll=true 走滚动路径，false 走分页路径。
  void toggle({bool scroll = true}) {
    if (_running) { _stop(); } else { _start(scroll: scroll); }
  }

  void _start({required bool scroll}) {
    if (_running) return;
    _running = true;
    onChanged();
    if (scroll) {
      _scheduleNextScroll();
    } else {
      _scheduleNextPage();
    }
  }

  void _scheduleNextScroll() {
    _timer = Timer(stepInterval, _stepScroll);
  }

  void _stepScroll() { ... existing logic but use pixelsPerStep ... }

  void _scheduleNextPage() {
    _timer = Timer(Duration(milliseconds: pageIntervalMs), _stepPage);
  }

  void _stepPage() {
    if (!_running) return;
    final cb = onPageTick;
    if (cb == null) { _stop(); return; }
    cb();
    _scheduleNextPage();
  }
}
```

### B. ReaderSettings 加字段

```dart
final int autoScrollSpeed;          // 1..10，默认 1
final int autoPageIntervalSeconds;  // 1..30，默认 10
```

copyWith / toJson / fromJson 同步。fromJson 缺字段走默认值并 clamp 到合法范围。

### C. reader_page 接入

实例化时传 settings 派生的参数：
```dart
late final ReaderAutoScroller _autoScroller = ReaderAutoScroller(
  controller: () => _scrollController,
  onChanged: () { if (mounted) setState(() {}); },
  onPageTick: () {
    final pvc = _pageViewController;
    if (pvc?.onTapNext != null) {
      pvc!.onTapNext!();
    }
  },
  pixelsPerStep: _settings.autoScrollSpeed.toDouble(),
  pageIntervalMs: _settings.autoPageIntervalSeconds * 1000,
);
```

settings 变化时（_setReaderSettings）同步更新：
```dart
_autoScroller.pixelsPerStep = settings.autoScrollSpeed.toDouble();
_autoScroller.pageIntervalMs = settings.autoPageIntervalSeconds * 1000;
```

`_toggleAutoScroll` 改成：
```dart
void _toggleAutoScroll() {
  _autoScroller.toggle(scroll: _settings.isScrollMode);
}
```

### D. UI

`reader_settings_sheet.dart` 在"按键"段后加"自动翻页"段：
- Slider "自动滚动速度" 1..10 → settings.autoScrollSpeed
- Slider "自动翻页间隔" 1..30 秒 → settings.autoPageIntervalSeconds

### E. 测试

`test/reader_auto_scroller_test.dart`（如已存在则扩，否则新建）：
- onPageTick 模式：fakeAsync 推进 1×/2×/3× pageIntervalMs，验证回调次数
- 滚动模式：mock ScrollController.jumpTo 调用次数
- toggle 反复切换不泄漏 timer
- onPageTick = null 时 page 模式 _stop

`reader_settings_v6_test.dart` 加 case 验证新字段。

## Out of Scope

- 朗读+自动翻页联动（原项目朗读时翻页与 TTS 同步）— 留批次 17（TTS 后台）
- 自动翻页时屏蔽 tap（避免误触停止）— 用户可点击底栏按钮停止，足够
- 倒计时 UI（剩余 N 秒）— 不必要

## Notes

- 单测用 `fake_async: ^1.3.1` 模拟时钟（可能要加 dev_dependency）
- pixelsPerStep 由 int 派生 double，避免 double 字段引入精度问题
- 不动现有 `_isAutoScrolling` getter / `_toggleAutoScroll` 的对外签名
