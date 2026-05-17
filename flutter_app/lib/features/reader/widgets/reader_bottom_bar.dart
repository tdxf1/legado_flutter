/// 阅读器底部控制栏
///
/// 三层布局：
/// - 第一行：搜索 / 自动翻页 / 日夜间模式 / 替换规则 4 个 fab 按钮
/// - 第二行：上一章 / 章节进度 slider / 下一章
/// - 第三行：目录 / 朗读 / 界面设置 3 个 toolbar 按钮
library;

import 'package:flutter/material.dart';

import '../../../core/providers.dart';

class ReaderBottomBar extends StatelessWidget {
  final ReaderSettings settings;
  final int chapterCount;
  final int currentIndex;
  final double? sliderValue;
  final bool hasPrev;
  final bool hasNext;
  final bool isAutoScrolling;
  final bool isNightMode;

  final ValueChanged<double> onSliderChanged;
  final ValueChanged<int> onSliderChangeEnd;
  final VoidCallback onPrevChapter;
  final VoidCallback onNextChapter;
  final VoidCallback onStartSearch;
  final VoidCallback onToggleAutoScroll;
  final VoidCallback onToggleNightMode;
  final VoidCallback onOpenReplaceRules;
  final VoidCallback onShowDirectory;
  final VoidCallback onStartTts;
  final VoidCallback onShowReaderSettings;

  const ReaderBottomBar({
    super.key,
    required this.settings,
    required this.chapterCount,
    required this.currentIndex,
    required this.sliderValue,
    required this.hasPrev,
    required this.hasNext,
    required this.isAutoScrolling,
    required this.isNightMode,
    required this.onSliderChanged,
    required this.onSliderChangeEnd,
    required this.onPrevChapter,
    required this.onNextChapter,
    required this.onStartSearch,
    required this.onToggleAutoScroll,
    required this.onToggleNightMode,
    required this.onOpenReplaceRules,
    required this.onShowDirectory,
    required this.onStartTts,
    required this.onShowReaderSettings,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor =
        Color(settings.effectiveBackgroundColor).withValues(alpha: 0.85);
    final fgColor = Color(settings.effectiveTextColor);
    final maxChapter = (chapterCount - 1).toDouble();
    final maxChapterClamped = maxChapter < 0 ? 0.0 : maxChapter;
    final smallLabelStyle = TextStyle(
        color: fgColor.withValues(alpha: 0.7),
        fontSize: 10,
        decoration: TextDecoration.none);
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          color: bgColor,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _fabButton(Icons.search, '搜索', fgColor, smallLabelStyle,
                          onStartSearch),
                      _fabButton(
                          isAutoScrolling ? Icons.pause : Icons.play_arrow,
                          isAutoScrolling ? '暂停' : '自动',
                          fgColor,
                          smallLabelStyle,
                          onToggleAutoScroll),
                      _fabButton(
                          isNightMode
                              ? Icons.wb_sunny
                              : Icons.nightlight_round,
                          isNightMode ? '日间' : '夜间',
                          fgColor,
                          smallLabelStyle,
                          onToggleNightMode),
                      _fabButton(Icons.find_replace, '替换', fgColor,
                          smallLabelStyle, onOpenReplaceRules),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      IconButton(
                          icon: Icon(Icons.chevron_left, color: fgColor),
                          onPressed: hasPrev ? onPrevChapter : null,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 36, minHeight: 36)),
                      Expanded(
                        child: Slider(
                          value: (sliderValue ?? currentIndex.toDouble())
                              .clamp(0, maxChapterClamped),
                          min: 0,
                          max: maxChapterClamped,
                          divisions:
                              chapterCount > 1 ? chapterCount - 1 : 1,
                          activeColor: fgColor,
                          inactiveColor: fgColor.withValues(alpha: 0.25),
                          thumbColor: fgColor,
                          onChanged: onSliderChanged,
                          onChangeEnd: (v) {
                            final targetIndex =
                                v.round().clamp(0, chapterCount - 1);
                            onSliderChangeEnd(targetIndex);
                          },
                        ),
                      ),
                      SizedBox(
                        width: 44,
                        child: Text(
                          '${currentIndex + 1}/$chapterCount',
                          style: TextStyle(
                              color: fgColor,
                              fontSize: 11,
                              decoration: TextDecoration.none),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      IconButton(
                          icon: Icon(Icons.chevron_right, color: fgColor),
                          onPressed: hasNext ? onNextChapter : null,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 36, minHeight: 36)),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _toolbarButton(Icons.list, '目录', fgColor,
                          smallLabelStyle, onShowDirectory),
                      _toolbarButton(Icons.record_voice_over, '朗读', fgColor,
                          smallLabelStyle, onStartTts),
                      _toolbarButton(Icons.tune, '界面', fgColor, smallLabelStyle,
                          onShowReaderSettings),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _fabButton(IconData icon, String label, Color fgColor,
      TextStyle labelStyle, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: fgColor, size: 22),
            const SizedBox(height: 2),
            Text(label, style: labelStyle),
          ],
        ),
      ),
    );
  }

  Widget _toolbarButton(IconData icon, String label, Color fgColor,
      TextStyle labelStyle, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: fgColor, size: 20),
            const SizedBox(height: 1),
            Text(label, style: labelStyle),
          ],
        ),
      ),
    );
  }
}
