/// 批次 5 (05-18): 长按文字菜单的纯函数 helper。
///
/// 抽出来便于单测：调用方提供 controller + settings，
/// 返回当前页可分享 / 复制的纯文本（去段首缩进，段间换行）。
library;

import '../../../core/providers.dart';
import '../page/page_view_controller.dart';

/// 拼接当前页所有 paragraphText 为纯文本，去掉段首缩进字符。
/// 如果 controller 为 null / currentPage 为 null / paragraphTexts 为空，
/// 返回空串。
///
/// 设计语义：用户 tap 长按时拷贝/分享/朗读的应该是"用户当前看到的内容"，
/// 因此 paragraphIndent（如全角空格）作为视觉装饰应被剥掉，避免复制到
/// 剪贴板的文字带奇怪缩进。
String getCurrentPageText(
  PageViewController? controller,
  ReaderSettings settings,
) {
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
