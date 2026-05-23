/// 阅读器顶部控制栏
///
/// 显示书名、章节标题、书源信息，以及"返回 / 换源 / 刷新 / 缓存 / 书签"等操作。
/// 不感知 reader_page.dart 的私有状态，所有数据通过参数传入。
library;

import 'package:flutter/material.dart';

import '../../../core/colors.dart';
import '../../../core/providers.dart';

class ReaderTopBar extends StatelessWidget {
  final ReaderSettings settings;
  final String bookName;
  final String currentChapterTitle;
  final String sourceName;
  final String sourceUrl;
  final String chapterUrl;
  final bool hasBookmark;
  final VoidCallback onBack;
  final VoidCallback onChangeSource;
  final VoidCallback onRefreshChapter;
  final VoidCallback onStartDownload;
  final VoidCallback onToggleBookmark;

  const ReaderTopBar({
    super.key,
    required this.settings,
    required this.bookName,
    required this.currentChapterTitle,
    required this.sourceName,
    required this.sourceUrl,
    required this.chapterUrl,
    required this.hasBookmark,
    required this.onBack,
    required this.onChangeSource,
    required this.onRefreshChapter,
    required this.onStartDownload,
    required this.onToggleBookmark,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor =
        Color(settings.effectiveBackgroundColor).withValues(alpha: 0.85);
    final fgColor = Color(settings.effectiveTextColor);
    final titleText =
        bookName.isNotEmpty ? bookName : currentChapterTitle.isNotEmpty
            ? currentChapterTitle
            : '阅读';
    final titleStyle = TextStyle(
        color: fgColor, fontSize: 14, decoration: TextDecoration.none);
    final infoSmall = TextStyle(
        color: fgColor.withValues(alpha: 0.6),
        fontSize: 11,
        decoration: TextDecoration.none);
    final effectiveSourceName = sourceName.isNotEmpty ? sourceName : '书源';
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    IconButton(
                        icon: Icon(Icons.arrow_back, color: fgColor),
                        onPressed: onBack),
                    const SizedBox(width: 4),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Text(titleText, style: titleStyle, maxLines: 1),
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: Icon(Icons.swap_horiz, color: fgColor),
                      onPressed: onChangeSource,
                      tooltip: '换源',
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 36, minHeight: 36),
                    ),
                    IconButton(
                      icon: Icon(Icons.refresh, color: fgColor),
                      onPressed: onRefreshChapter,
                      tooltip: '刷新',
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 36, minHeight: 36),
                    ),
                    IconButton(
                      icon: Icon(Icons.download, color: fgColor),
                      onPressed: onStartDownload,
                      tooltip: '缓存',
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 36, minHeight: 36),
                    ),
                    PopupMenuButton<String>(
                      icon: Icon(Icons.more_vert, color: fgColor),
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 36, minHeight: 36),
                      onSelected: (v) {
                        if (v == 'bookmark') {
                          onToggleBookmark();
                        }
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'bookmark',
                          child: Row(
                            children: [
                              Icon(
                                  hasBookmark
                                      ? Icons.bookmark
                                      : Icons.bookmark_border,
                                  color: fgColor,
                                  size: 20),
                              const SizedBox(width: 8),
                              Text('书签',
                                  style: TextStyle(
                                      color: fgColor,
                                      decoration: TextDecoration.none)),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'more',
                          enabled: false,
                          child: Text('更多设置…',
                              style: TextStyle(color: context.al.textSecondary)),
                        ),
                      ],
                    ),
                  ],
                ),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              currentChapterTitle.isNotEmpty
                                  ? currentChapterTitle
                                  : '...',
                              style: infoSmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              sourceUrl.isNotEmpty
                                  ? sourceUrl
                                  : chapterUrl.isNotEmpty
                                      ? chapterUrl
                                      : '',
                              style: infoSmall.copyWith(fontSize: 10),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        child: Text(
                          effectiveSourceName,
                          style: infoSmall.copyWith(
                              color: fgColor, fontWeight: FontWeight.w500),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
