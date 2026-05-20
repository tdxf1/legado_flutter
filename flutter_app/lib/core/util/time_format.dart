/// Unix 秒级时间戳 → 中文相对时间字符串（BATCH-24, 2026-05-21）。
///
/// 把秒级 unix 时间戳格式化成"从未 / 刚刚 / N 分钟前 / N 小时前 / N 天前 /
/// yyyy-MM-dd"风格的相对时间字符串。
///
/// 历史上 bookshelf_page.dart 与 read_stats_page.dart 各自有一份私有
/// `_formatRelativeTime`，read_stats 版多一行 `if (sec <= 0) return '从未';`
/// early-return；bookshelf 版**没有**，导致 sec=0（书从未读过）会显示
/// "1970-01-01" — 隐含 bug。
///
/// 本 helper 沿用 read_stats 版语义（含 `<= 0 → '从未'` 边界），合并两处
/// caller 后顺手修复 bookshelf 端的显示 bug。
///
/// 见 finding F-W2B-030 in `findings-flutter-features.md`。
String formatRelativeTime(int sec) {
  if (sec <= 0) return '从未';
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final delta = now - sec;
  if (delta < 60) return '刚刚';
  if (delta < 3600) return '${(delta / 60).floor()} 分钟前';
  if (delta < 86400) return '${(delta / 3600).floor()} 小时前';
  if (delta < 86400 * 30) return '${(delta / 86400).floor()} 天前';
  return DateTime.fromMillisecondsSinceEpoch(sec * 1000)
      .toLocal()
      .toString()
      .split(' ')
      .first;
}
