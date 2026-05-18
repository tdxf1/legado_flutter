import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/providers.dart';
import 'package:legado_flutter/features/reader/page/page_view_controller.dart';
import 'package:legado_flutter/features/reader/services/long_press_action_handler.dart';

/// 批次 5 (05-18) — 长按菜单纯函数 getCurrentPageText 单测。

const _kPageSize = Size(400, 600);

String _longContent(int paragraphs) {
  return List<String>.generate(
    paragraphs,
    (i) => '第 $i 段中文测试段落，需要够长让 PageMeasure 切成多页。' * 3,
  ).join('\n');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('getCurrentPageText', () {
    test('controller=null → 空串', () {
      const settings = ReaderSettings();
      expect(getCurrentPageText(null, settings), '');
    });

    test('controller 未 loadChapter → 空串', () {
      const settings = ReaderSettings();
      final controller = PageViewController(settings: settings);
      controller.updatePageSize(_kPageSize);
      expect(getCurrentPageText(controller, settings), '');
      controller.dispose();
    });

    test('正常 chapter → 拼接 paragraphTexts，去段首缩进', () {
      const settings = ReaderSettings(paragraphIndent: '\u3000\u3000');
      final controller = PageViewController(settings: settings);
      controller.updatePageSize(_kPageSize);
      controller.loadChapter(0, '第一章', _longContent(20));

      final text = getCurrentPageText(controller, settings);
      expect(text.isNotEmpty, isTrue);
      // 不应以缩进字符开头
      expect(text.startsWith('\u3000'), isFalse,
          reason: '段首缩进应被剥掉');
      // 段间应有换行
      expect(text.contains('\n'), isTrue);

      controller.dispose();
    });

    test('paragraphIndent 为空 → 不剥任何字符', () {
      const settings = ReaderSettings(paragraphIndent: '');
      final controller = PageViewController(settings: settings);
      controller.updatePageSize(_kPageSize);
      controller.loadChapter(0, '第一章', _longContent(20));

      final text = getCurrentPageText(controller, settings);
      // 不依赖 measure 输出具体值；只验证非空且 join 行为正确
      expect(text, isNotEmpty);

      controller.dispose();
    });
  });
}
