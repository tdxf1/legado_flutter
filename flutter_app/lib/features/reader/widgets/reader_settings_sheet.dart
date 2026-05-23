/// 阅读器设置面板（底部 sheet 样式）
///
/// 让用户调整字号、字重、字距、行距、段距、边距、段首缩进、阅读信息显示、
/// 背景色 / 背景图、翻页方式与翻页动画等参数。
///
/// 与 [ReaderSettings] 强耦合：
/// - [initial] 是初值（一般传当前 reader_page 的 _settings）
/// - 用户每次调整都通过 [onChanged] 回调把最新值告知父级；父级通常会调用
///   `_setReaderSettings(s, persist: true)`
///
/// 该 widget 自身不持久化也不读 Riverpod，便于在不同 host 中复用。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../core/colors.dart';
import '../../../core/persistence/json_store.dart';
import '../../../core/providers.dart';
import 'tap_zone_config_dialog.dart';

class ReaderSettingsSheet extends StatefulWidget {
  final ReaderSettings initial;
  final ValueChanged<ReaderSettings> onChanged;

  const ReaderSettingsSheet({
    super.key,
    required this.initial,
    required this.onChanged,
  });

  @override
  State<ReaderSettingsSheet> createState() => _ReaderSettingsSheetState();
}

class _ReaderSettingsSheetState extends State<ReaderSettingsSheet> {
  late ReaderSettings _s;

  @override
  void initState() {
    super.initState();
    _s = widget.initial;
  }

  void _update(ReaderSettings s) {
    setState(() => _s = s);
    widget.onChanged(s);
  }

  Future<void> _pickBackgroundImage() async {
    try {
      final result = await FilePicker.pickFiles(type: FileType.image);
      if (result == null || result.files.isEmpty) return;
      final sourcePath = result.files.single.path;
      if (sourcePath == null) return;
      // BATCH-18e (F-W2B-022)：走统一的 resolvePersistenceDir，
      // 与 json_store 保持单一 Android/桌面平台路径策略。
      final dir = await resolvePersistenceDir();
      final bgDir = Directory('$dir/reader_backgrounds');
      if (!await bgDir.exists()) await bgDir.create(recursive: true);
      final filename = 'bg_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final destPath = '${bgDir.path}/$filename';
      await File(sourcePath).copy(destPath);
      _update(_s.copyWith(backgroundImagePath: destPath));
    } catch (e) {
      debugPrint('[ReaderSettings] copy background image failed: $e');
    }
  }

  void _clearBackgroundImage() {
    _update(_s.copyWith(backgroundImagePath: null));
  }

  @override
  Widget build(BuildContext ctx) {
    final fg = Color(_s.effectiveTextColor);
    final label = TextStyle(color: fg, fontSize: 14);
    final chipStyle = const TextStyle(fontSize: 12);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: SingleChildScrollView(
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('字号: ${_s.fontSize.round()}', style: label),
              Slider(
                  value: _s.fontSize,
                  min: 12,
                  max: 30,
                  divisions: 18,
                  onChanged: (v) => _update(_s.copyWith(fontSize: v))),
              const SizedBox(height: 12),
              Text('字重', style: label),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(
                      value: 0,
                      label: Text('细', style: TextStyle(fontSize: 12))),
                  ButtonSegment(
                      value: 1,
                      label: Text('正常', style: TextStyle(fontSize: 12))),
                  ButtonSegment(
                      value: 2,
                      label: Text('粗', style: TextStyle(fontSize: 12))),
                ],
                selected: {_s.fontWeightIndex},
                onSelectionChanged: (v) =>
                    _update(_s.copyWith(fontWeightIndex: v.first)),
              ),
              const SizedBox(height: 12),
              Text('字距: ${_s.letterSpacing.toStringAsFixed(1)}', style: label),
              Slider(
                  value: _s.letterSpacing,
                  min: -1,
                  max: 5,
                  divisions: 60,
                  onChanged: (v) => _update(_s.copyWith(letterSpacing: v))),
              Text('行距: ${_s.lineHeight.toStringAsFixed(1)}', style: label),
              Slider(
                  value: _s.lineHeight,
                  min: 1.0,
                  max: 3.5,
                  divisions: 25,
                  onChanged: (v) => _update(_s.copyWith(lineHeight: v))),
              Text('段距: ${_s.paragraphSpacing.round()}', style: label),
              Slider(
                  value: _s.paragraphSpacing,
                  min: 0,
                  max: 30,
                  divisions: 30,
                  onChanged: (v) => _update(_s.copyWith(paragraphSpacing: v))),
              Text('左右边距: ${_s.horizontalPadding.round()}', style: label),
              Slider(
                  value: _s.horizontalPadding,
                  min: 0,
                  max: 60,
                  divisions: 30,
                  onChanged: (v) => _update(_s.copyWith(horizontalPadding: v))),
              Text('上下边距: ${_s.verticalPadding.round()}', style: label),
              Slider(
                  value: _s.verticalPadding,
                  min: 0,
                  max: 60,
                  divisions: 30,
                  onChanged: (v) => _update(_s.copyWith(verticalPadding: v))),
              const SizedBox(height: 12),
              Text('段首缩进', style: label),
              const SizedBox(height: 4),
              Row(children: [
                ChoiceChip(
                    label: Text('无', style: chipStyle),
                    selected: _s.paragraphIndent.isEmpty,
                    onSelected: (_) =>
                        _update(_s.copyWith(paragraphIndent: ''))),
                const SizedBox(width: 8),
                ChoiceChip(
                    label: Text('2全角', style: chipStyle),
                    selected: _s.paragraphIndent == '\u3000\u3000',
                    onSelected: (_) =>
                        _update(_s.copyWith(paragraphIndent: '\u3000\u3000'))),
                const SizedBox(width: 8),
                ChoiceChip(
                    label: Text('4半角', style: chipStyle),
                    selected: _s.paragraphIndent == '    ',
                    onSelected: (_) =>
                        _update(_s.copyWith(paragraphIndent: '    '))),
              ]),
              const SizedBox(height: 12),
              Text('阅读信息', style: label),
              SwitchListTile(
                title: Text('显示阅读信息', style: label),
                value: _s.showReadingInfo,
                dense: true,
                onChanged: (v) => _update(_s.copyWith(showReadingInfo: v)),
              ),
              SwitchListTile(
                title: Text('章节标题', style: label),
                value: _s.showChapterTitle,
                dense: true,
                onChanged: (v) => _update(_s.copyWith(showChapterTitle: v)),
              ),
              SwitchListTile(
                title: Text('时间', style: label),
                value: _s.showClock,
                dense: true,
                onChanged: (v) => _update(_s.copyWith(showClock: v)),
              ),
              SwitchListTile(
                title: Text('进度', style: label),
                value: _s.showProgress,
                dense: true,
                onChanged: (v) => _update(_s.copyWith(showProgress: v)),
              ),
              const SizedBox(height: 12),
              Text('背景图片', style: label),
              const SizedBox(height: 4),
              Row(children: [
                ElevatedButton.icon(
                  onPressed: _pickBackgroundImage,
                  icon: const Icon(Icons.image, size: 18),
                  label: const Text('选择'),
                ),
                const SizedBox(width: 8),
                if (_s.backgroundImagePath != null)
                  OutlinedButton(
                    onPressed: _clearBackgroundImage,
                    child: const Text('清除'),
                  ),
              ]),
              const SizedBox(height: 12),
              Text('背景色', style: label),
              const SizedBox(height: 4),
              Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: ReaderSettings.presetColors
                      .map((c) => GestureDetector(
                            onTap: () => _update(_s.copyWith(
                                backgroundColor: c.toARGB32(),
                                backgroundImagePath: null)),
                            child: Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: c,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                    color: _s.backgroundColor == c.toARGB32() &&
                                            _s.backgroundImagePath == null
                                        ? Theme.of(ctx).primaryColor
                                        : ctx.al.outline,
                                    width: 2),
                              ),
                            ),
                          ))
                      .toList()),
              const SizedBox(height: 12),
              Text('翻页动画', style: label),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final entry in ReaderPageAnim.labels.entries)
                    ChoiceChip(
                      label: Text(entry.value, style: chipStyle),
                      selected: _s.pageAnim == entry.key,
                      onSelected: (sel) {
                        if (sel) _update(_s.copyWith(pageAnim: entry.key));
                      },
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text('翻页动画时长: ${_s.pageAnimDurationMs} ms', style: label),
              Slider(
                value: _s.pageAnimDurationMs.toDouble(),
                min: 200,
                max: 1000,
                divisions: 16,
                label: '${_s.pageAnimDurationMs} ms',
                onChanged: (v) =>
                    _update(_s.copyWith(pageAnimDurationMs: v.round())),
              ),
              const SizedBox(height: 12),
              // 批次 1 (05-18): 屏幕亮度 + 屏幕常亮。亮度 -1.0 = 跟随系统
              // （不主动调节）；勾选"跟随系统"时把值还原到 -1.0；不勾选
              // 时显示 0..100 滑杆，对应 0.0..1.0 给 ScreenBrightness。
              Text('屏幕', style: label),
              const SizedBox(height: 4),
              SwitchListTile(
                title: Text('跟随系统亮度', style: label),
                value: _s.screenBrightness < 0,
                dense: true,
                onChanged: (v) {
                  if (v) {
                    _update(_s.copyWith(screenBrightness: -1.0));
                  } else {
                    // 取消跟随系统时给一个合理的默认值（70%），避免刚关掉
                    // 就跳到 0% 整个屏幕全黑。
                    _update(_s.copyWith(screenBrightness: 0.7));
                  }
                },
              ),
              if (_s.screenBrightness >= 0) ...[
                Text(
                  '屏幕亮度: ${(_s.screenBrightness * 100).round()}%',
                  style: label,
                ),
                Slider(
                  value: (_s.screenBrightness * 100).clamp(0.0, 100.0),
                  min: 0,
                  max: 100,
                  divisions: 100,
                  label: '${(_s.screenBrightness * 100).round()}%',
                  onChanged: (v) =>
                      _update(_s.copyWith(screenBrightness: v / 100.0)),
                ),
              ],
              SwitchListTile(
                title: Text('屏幕常亮', style: label),
                subtitle: Text(
                  '阅读时不熄屏（退出阅读器恢复系统超时）',
                  style: TextStyle(color: fg.withValues(alpha: 0.6), fontSize: 12),
                ),
                value: _s.keepScreenOn,
                dense: true,
                onChanged: (v) => _update(_s.copyWith(keepScreenOn: v)),
              ),
              const SizedBox(height: 12),
              // 批次 2 (05-18): 物理按键翻页开关。"音量键翻页"对齐原 Legado
              // MD3 `AppConfig.volumeKeyPage` 默认开启；"朗读时音量键也翻页"
              // 对齐 `volumeKeyPageOnPlay` 默认关闭（朗读时让系统调音量）。
              // PageUp/PageDown/Space/方向键不受这两个开关影响（无系统冲突）。
              Text('按键', style: label),
              const SizedBox(height: 4),
              SwitchListTile(
                title: Text('音量键翻页', style: label),
                subtitle: Text(
                  '音量+ 上一页 / 音量- 下一页',
                  style: TextStyle(color: fg.withValues(alpha: 0.6), fontSize: 12),
                ),
                value: _s.enableVolumeKeyPage,
                dense: true,
                onChanged: (v) => _update(_s.copyWith(enableVolumeKeyPage: v)),
              ),
              SwitchListTile(
                title: Text('朗读时音量键也翻页', style: label),
                subtitle: Text(
                  '默认关闭，朗读中音量键控制系统音量',
                  style: TextStyle(color: fg.withValues(alpha: 0.6), fontSize: 12),
                ),
                value: _s.volumeKeyPageOnTts,
                dense: true,
                onChanged: (v) => _update(_s.copyWith(volumeKeyPageOnTts: v)),
              ),
              const SizedBox(height: 12),
              // 批次 3 (05-18): 点击区域 3×3 配置入口。dialog 弹出后用户编辑
              // 9 个格子的动作，确定时返回 List<int> 写回 settings.tapZones。
              Text('点击区域', style: label),
              const SizedBox(height: 4),
              ListTile(
                title: Text('自定义点击区域', style: label),
                subtitle: Text(
                  '阅读区 9 格各自的点击行为（上一页 / 下一页 / 菜单 / 无）',
                  style: TextStyle(
                      color: fg.withValues(alpha: 0.6), fontSize: 12),
                ),
                trailing: const Icon(Icons.chevron_right),
                contentPadding: EdgeInsets.zero,
                dense: true,
                onTap: () async {
                  final result = await showDialog<List<int>>(
                    context: ctx,
                    builder: (_) =>
                        TapZoneConfigDialog(initialZones: _s.tapZones),
                  );
                  if (result != null) {
                    _update(_s.copyWith(tapZones: result));
                  }
                },
              ),
              const SizedBox(height: 16),
              // 批次 4 (05-18): 自动翻页速度 / 间隔。两条滑杆始终可见，
              // 用户切换 pageAnim 后立即生效（reader_page._toggleAutoScroll
              // 根据当前 isScrollMode 选 path）。
              Text('自动翻页', style: label),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  '滚动速度: ${_s.autoScrollSpeed} 档（约 ${_s.autoScrollSpeed * 20} px/s）',
                  style: label,
                ),
              ),
              Slider(
                min: 1,
                max: 10,
                divisions: 9,
                value: _s.autoScrollSpeed.toDouble(),
                label: '${_s.autoScrollSpeed}',
                onChanged: (v) =>
                    _update(_s.copyWith(autoScrollSpeed: v.round())),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  '分页间隔: 每 ${_s.autoPageIntervalSeconds} 秒翻一页',
                  style: label,
                ),
              ),
              Slider(
                min: 1,
                max: 30,
                divisions: 29,
                value: _s.autoPageIntervalSeconds.toDouble(),
                label: '${_s.autoPageIntervalSeconds}s',
                onChanged: (v) => _update(
                    _s.copyWith(autoPageIntervalSeconds: v.round())),
              ),
              const SizedBox(height: 16),
              // 批次 5 (05-18): 长按文字菜单开关。MVP 整页粒度，
              // 提供复制 / 分享 / 朗读三个动作。
              Text('长按菜单', style: label),
              const SizedBox(height: 4),
              SwitchListTile(
                title: Text('启用长按菜单', style: label),
                subtitle: Text(
                  '长按阅读区弹复制 / 分享 / 朗读，关闭后避免长按误触',
                  style: TextStyle(
                      color: fg.withValues(alpha: 0.6), fontSize: 12),
                ),
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _s.enableLongPressMenu,
                onChanged: (v) =>
                    _update(_s.copyWith(enableLongPressMenu: v)),
              ),
            ]),
      ),
    );
  }
}
