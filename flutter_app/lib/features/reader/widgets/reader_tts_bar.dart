/// 阅读器 TTS 顶部控制栏
///
/// 朗读期间显示。提供上一段/播放或暂停/下一段/进度文本/速度切换/设置入口/停止 7 个按钮。
///
/// 依赖父级提供的回调与状态字段，本 widget 不持引擎实例。
library;

import 'package:flutter/material.dart';

import '../../../core/providers.dart';

class ReaderTtsBar extends StatelessWidget {
  final ReaderSettings settings;
  final bool isSpeaking;
  final bool isPaused;
  final int paragraphIndex;
  final int paragraphTotal;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onCycleSpeed;
  final VoidCallback onShowSettings;
  final VoidCallback onStop;

  const ReaderTtsBar({
    super.key,
    required this.settings,
    required this.isSpeaking,
    required this.isPaused,
    required this.paragraphIndex,
    required this.paragraphTotal,
    required this.onPrev,
    required this.onNext,
    required this.onPause,
    required this.onResume,
    required this.onCycleSpeed,
    required this.onShowSettings,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor =
        Color(settings.effectiveBackgroundColor).withValues(alpha: 0.95);
    final fgColor = Color(settings.effectiveTextColor);
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          color: bgColor,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.skip_previous, color: fgColor, size: 20),
                    onPressed: onPrev,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 32, minHeight: 32),
                  ),
                  IconButton(
                    icon: Icon(
                        isSpeaking && !isPaused
                            ? Icons.pause
                            : Icons.play_arrow,
                        color: fgColor,
                        size: 20),
                    onPressed: isSpeaking && !isPaused ? onPause : onResume,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 32, minHeight: 32),
                  ),
                  IconButton(
                    icon: Icon(Icons.skip_next, color: fgColor, size: 20),
                    onPressed: onNext,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 32, minHeight: 32),
                  ),
                  Expanded(
                    child: Text(
                      '朗读中 ${paragraphIndex + 1}/$paragraphTotal',
                      style: TextStyle(
                          color: fgColor.withValues(alpha: 0.6),
                          fontSize: 12,
                          decoration: TextDecoration.none),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  GestureDetector(
                    onTap: onCycleSpeed,
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        border:
                            Border.all(color: fgColor.withValues(alpha: 0.3)),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'x${settings.ttsSpeed.toStringAsFixed(1)}',
                        style: TextStyle(color: fgColor, fontSize: 11),
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  IconButton(
                    icon: Icon(Icons.settings, color: fgColor, size: 18),
                    onPressed: onShowSettings,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                  ),
                  IconButton(
                    icon: Icon(Icons.stop, color: fgColor, size: 20),
                    onPressed: onStop,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 32, minHeight: 32),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
