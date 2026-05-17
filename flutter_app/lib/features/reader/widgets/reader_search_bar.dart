/// 阅读器顶部搜索栏
///
/// 依赖：
/// - 当前 [ReaderSettings]（用于背景色 / 前景色）
/// - 一个 [TextEditingController]（由父级 [ReaderSearchController] 提供）
/// - 当前匹配项数量与索引（[matchCount] / [currentIndex]）
/// - [onChanged] 输入变化、[onPrev] / [onNext] 跳转、[onClose] 关闭
///
/// 不直接依赖 reader_page.dart 的私有状态，便于测试。
library;

import 'package:flutter/material.dart';

import '../../../core/providers.dart';

class ReaderSearchBar extends StatelessWidget {
  final ReaderSettings settings;
  final TextEditingController controller;
  final int matchCount;
  final int currentIndex;
  final ValueChanged<String> onChanged;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onClose;

  const ReaderSearchBar({
    super.key,
    required this.settings,
    required this.controller,
    required this.matchCount,
    required this.currentIndex,
    required this.onChanged,
    required this.onPrev,
    required this.onNext,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor =
        Color(settings.effectiveBackgroundColor).withValues(alpha: 0.95);
    final fgColor = Color(settings.effectiveTextColor);
    final hasMatches = matchCount > 0;
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
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: controller,
                      autofocus: true,
                      spellCheckConfiguration:
                          const SpellCheckConfiguration.disabled(),
                      style: TextStyle(color: fgColor, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: '搜索...',
                        hintStyle:
                            TextStyle(color: fgColor.withValues(alpha: 0.4)),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 10),
                      ),
                      onChanged: onChanged,
                    ),
                  ),
                  if (hasMatches)
                    Text(
                      '${currentIndex + 1}/$matchCount',
                      style: TextStyle(
                          color: fgColor.withValues(alpha: 0.6), fontSize: 12),
                    ),
                  IconButton(
                    icon: Icon(Icons.chevron_left, color: fgColor, size: 20),
                    onPressed: hasMatches ? onPrev : null,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 32, minHeight: 32),
                  ),
                  IconButton(
                    icon: Icon(Icons.chevron_right, color: fgColor, size: 20),
                    onPressed: hasMatches ? onNext : null,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 32, minHeight: 32),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, color: fgColor, size: 20),
                    onPressed: onClose,
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
