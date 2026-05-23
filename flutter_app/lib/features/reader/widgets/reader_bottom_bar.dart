/// 阅读器底部控制栏 — MD3 风格，对齐 uihtml 阅读器正文改3 设计
///
/// 三层布局：
/// - 第一行：搜索 / 自动翻页 / 界面设置 3 个居中圆形 fab 按钮
/// - 第二行：上一章 / 章节进度条 / 下一章
/// - 第三行：目录 / 朗读 / 夜间 / 更多 4 个底部导航按钮
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
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Row 1: Center circle FAB buttons
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(width: 8),
                      _circleButton(context, Icons.search, '搜索', fgColor,
                          onStartSearch),
                      const SizedBox(width: 20),
                      _circleButton(
                          context,
                          isAutoScrolling ? Icons.pause : Icons.autorenew,
                          isAutoScrolling ? '暂停' : '自动',
                          fgColor,
                          onToggleAutoScroll),
                      const SizedBox(width: 20),
                      _circleButton(context, Icons.tune, '界面', fgColor,
                          onShowReaderSettings),
                      const SizedBox(width: 8),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // Row 2: Prev / Progress slider / Next
                  Row(
                    children: [
                      _textButton('上一章', fgColor,
                          hasPrev ? onPrevChapter : null),
                      Expanded(
                        child: Row(
                          children: [
                            Expanded(
                              child: Slider(
                                value: (sliderValue ?? currentIndex.toDouble())
                                    .clamp(0, maxChapterClamped),
                                min: 0,
                                max: maxChapterClamped,
                                divisions: chapterCount > 1
                                    ? chapterCount - 1
                                    : 1,
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
                                  color: fgColor.withValues(alpha: 0.6),
                                  fontSize: 11,
                                  decoration: TextDecoration.none,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ],
                        ),
                      ),
                      _textButton('下一章', fgColor,
                          hasNext ? onNextChapter : null),
                    ],
                  ),
                  // Row 3: Bottom nav row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _navButton(
                          context, Icons.list, '目录', fgColor, onShowDirectory),
                      _navButton(
                          context, Icons.headphones, '朗读', fgColor, onStartTts),
                      _navButton(
                          context,
                          isNightMode
                              ? Icons.wb_sunny
                              : Icons.nightlight_round,
                          isNightMode ? '日间' : '夜间',
                          fgColor,
                          onToggleNightMode),
                      _navButton(context, Icons.more_horiz, '更多', fgColor,
                          onOpenReplaceRules),
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

  Widget _circleButton(BuildContext context, IconData icon, String label,
      Color fgColor, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: fgColor.withValues(alpha: 0.08),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: fgColor, size: 22),
            Text(label,
                style: TextStyle(
                  color: fgColor.withValues(alpha: 0.7),
                  fontSize: 9,
                  decoration: TextDecoration.none,
                )),
          ],
        ),
      ),
    );
  }

  Widget _navButton(BuildContext context, IconData icon, String label,
      Color fgColor, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: fgColor, size: 24),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(
                  color: fgColor.withValues(alpha: 0.6),
                  fontSize: 10,
                  decoration: TextDecoration.none,
                )),
          ],
        ),
      ),
    );
  }

  Widget _textButton(
      String label, Color fgColor, VoidCallback? onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Text(label,
            style: TextStyle(
              color: onTap != null
                  ? fgColor
                  : fgColor.withValues(alpha: 0.3),
              fontSize: 12,
              decoration: TextDecoration.none,
            )),
      ),
    );
  }
}
