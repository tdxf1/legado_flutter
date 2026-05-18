/// 批次 5 (05-18): 长按文字菜单底部 sheet。
/// MVP 版本：整页粒度，三个动作 — 复制 / 分享 / 朗读。
library;

import 'package:flutter/material.dart';

class LongPressActionSheet extends StatelessWidget {
  /// 当前页文字。前 N 字会显示在 sheet 顶部作为预览。
  final String pageText;

  const LongPressActionSheet({super.key, required this.pageText});

  @override
  Widget build(BuildContext context) {
    final preview = _previewOf(pageText);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '当前页（${pageText.length} 字）',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                preview,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _ActionButton(
                  icon: Icons.copy,
                  label: '复制',
                  onPressed: () => Navigator.pop(context, 'copy'),
                ),
                _ActionButton(
                  icon: Icons.share,
                  label: '分享',
                  onPressed: () => Navigator.pop(context, 'share'),
                ),
                _ActionButton(
                  icon: Icons.record_voice_over,
                  label: '朗读',
                  onPressed: () => Navigator.pop(context, 'aloud'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _previewOf(String text) {
    if (text.length <= 80) return text;
    return '${text.substring(0, 80)}…';
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.filledTonal(
          onPressed: onPressed,
          icon: Icon(icon),
          iconSize: 28,
        ),
        const SizedBox(height: 4),
        Text(label, style: Theme.of(context).textTheme.labelMedium),
      ],
    );
  }
}
