# 长按文字菜单 MVP (批次 5)

## Goal

reader 内长按屏幕弹出底部菜单，提供三个高频动作：**复制当前页内容 / 分享 / 朗读**。对齐原 Legado MD3 `TextActionMenu.kt` 的核心动作（复制 / 分享 / 朗读），但简化为**整页粒度**而非字符级选区——避免破坏现有 ContentPagePainter 的 ui.Picture 仿真翻页机制。

## What I already know

- **原项目**：`TextActionMenu.kt` 长按选区菜单，含 menu_replace / copy / bookmark / aloud / dict / search_content / browser / share_str
- **Flutter 现状**：
  - `ContentPagePainter` 用 `Canvas.drawParagraph` 直接画文本，无法做字符级选择
  - `SelectableText` 路径会破坏 simulation/cover delegate 用 `ui.PictureRecorder` 预渲染翻页帧的机制
  - 没有 `share_plus` 包依赖
  - TTS 已有 `_tts.start()` / 段落级朗读链路
  - 复制：Flutter 内置 `Clipboard.setData`
- **关键设计取舍**：MVP 只做整页粒度，避免动 ContentPagePainter；保留后续做字符级选区的扩展空间

## Decision

整页粒度 MVP：
- 长按手势监听走 `GestureDetector(onLongPressStart)` 包裹现有 reader 区域
- 长按触发 → 显示底部 sheet（不阻塞翻页）
- Sheet 三个 action：复制 / 分享 / 朗读
- 复制 / 分享 内容 = 当前页所有 paragraph 文本拼接
- 朗读：从当前页开始（复用现有 TTS）
- 长按时不影响翻页动画 / 自动翻页 / 双击 / 单击区域配置

## Requirements

1. **依赖**：加 `share_plus: ^11.0.0`（或当前 stable）
2. **新增 ReaderSettings 字段**：`bool enableLongPressMenu`（默认 true，可关闭以免误触）
3. **reader_page.dart 改造**：现有 `GestureDetector(onTapUp: ...)` 加 `onLongPressStart` 回调
   - long-press 触发时显示底部 ModalBottomSheet，三个 action
   - 控件可见时 / 设置 sheet 打开时不触发
4. **复制 / 分享 / 朗读 实现**：
   - 复制：`Clipboard.setData(ClipboardData(text: pageText))` + SnackBar 提示
   - 分享：`Share.share(pageText, subject: bookName)`
   - 朗读：调用现有 `_tts.start(text: pageText)` 或类似入口
5. **设置面板加开关**：`enableLongPressMenu` SwitchListTile

## Acceptance Criteria

- [ ] 单测：`ReaderSettings.enableLongPressMenu` round-trip + fallback 默认 true
- [ ] 单测：纯函数 `getCurrentPageText(controller)` 拼接当前页文字（拼接所有 paragraphTexts，去段首缩进）
- [ ] flutter analyze 0 issue
- [ ] flutter test 全绿（≥ 332，330 baseline + 至少 2 新单测）
- [ ] 实机：长按 reader 弹底部菜单；复制 / 分享 / 朗读各按钮工作
- [ ] 实机：关闭 enableLongPressMenu 后长按无响应

## Technical Approach

### A. share_plus 加依赖

`pubspec.yaml` 加：
```yaml
share_plus: ^11.1.0   # 或当前 stable
```

### B. ReaderSettings.enableLongPressMenu

```dart
final bool enableLongPressMenu;  // 默认 true

const ReaderSettings({
  ...
  this.enableLongPressMenu = true,
});
```
copyWith / toJson / fromJson 同步。fromJson fallback true。

### C. 当前页文字辅助方法

新建 `lib/features/reader/services/long_press_action_handler.dart`:
```dart
/// 拼接当前页所有 paragraphText（去段首缩进），返回纯文本。
/// 如果 currentPage 为 null 或 paragraphTexts 为空，返回空串。
String getCurrentPageText(PageViewController? controller, ReaderSettings settings) {
  if (controller == null) return '';
  final page = controller.currentPage;
  if (page == null || page.paragraphTexts.isEmpty) return '';
  final indent = settings.paragraphIndent;
  return page.paragraphTexts.map((p) {
    if (indent.isNotEmpty && p.startsWith(indent)) {
      return p.substring(indent.length);
    }
    return p;
  }).join('\n');
}
```

### D. 长按 sheet UI

新建 `lib/features/reader/widgets/long_press_action_sheet.dart`:
- 显示当前页文字预览（前 100 字 + ... + 长度统计）
- 三个 IconButton：复制 / 分享 / 朗读
- 取消按钮

### E. reader_page 接入

现有 `GestureDetector(onTapUp: ...)`（reader_page.dart:1808 附近）改成同时支持 onLongPressStart：

```dart
GestureDetector(
  behavior: HitTestBehavior.opaque,
  onTapUp: (details) { ... 现有逻辑 ... },
  onLongPressStart: (details) {
    if (!_settings.enableLongPressMenu) return;
    if (_controlsVisible) return;
    final pageText = getCurrentPageText(_pageViewController, _settings);
    if (pageText.isEmpty) return;
    _showLongPressActionSheet(pageText);
  },
  child: ...
),
```

```dart
Future<void> _showLongPressActionSheet(String pageText) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => LongPressActionSheet(pageText: pageText),
  );
  if (action == null || !mounted) return;
  switch (action) {
    case 'copy':
      await Clipboard.setData(ClipboardData(text: pageText));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已复制当前页')),
        );
      }
      break;
    case 'share':
      await Share.share(pageText, subject: _bookName);
      break;
    case 'aloud':
      // TODO: 走现有 _tts 链路；先实现复制 + 分享，朗读保留 callback
      _tts.setChapterContent(pageText);
      _tts.start();
      break;
  }
}
```

### F. 设置面板开关

`reader_settings_sheet.dart` 加：
```dart
SwitchListTile(
  title: Text('长按文字菜单', style: label),
  subtitle: Text('长按阅读区弹复制 / 分享 / 朗读', ...),
  value: _s.enableLongPressMenu,
  onChanged: (v) => _update(_s.copyWith(enableLongPressMenu: v)),
),
```

## Out of Scope

- 字符级选区（破坏 ContentPagePainter）— 留 follow-up
- 字典查词（依赖 DictRule schema，后续批次）
- 翻译 / 浏览器跳转
- 替换规则编辑入口（依赖 4.1 完整规则编辑器）
- 书签从选区添加（章节级书签已存在）

## Notes

- TTS 接口 `_tts.start()` / `setChapterContent()` 看现有 ReaderTtsManager 实际签名，可能要 `_tts.startFromText(pageText)` 或类似
- `Share.share` 在 Android 必须从 Activity 上下文调用，pubspec 直接装 share_plus 即可
- 长按手势与现有 onTap 共存 — Flutter GestureDetector 默认不会冲突
