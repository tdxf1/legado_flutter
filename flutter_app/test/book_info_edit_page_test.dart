import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/features/bookshelf/book_info_edit_page.dart';

/// 批次 9 (05-19): 书信息编辑页 widget 测试。
///
/// 这两个测试都通过 `BookInfoEditPage.initialBook` / `saveBookOverride` /
/// `dbPathOverride` 测试钩子绕过真实 FRB 桥与 path_provider，在纯
/// widget 层面验证：
/// 1. 5 字段 TextField 渲染并显示正确初始值
/// 2. "保存" 按钮在 name 为空时 disabled
void main() {
  Map<String, dynamic> _sampleBook({
    String name = '三体',
    String? author = '刘慈欣',
    String? kind = '科幻',
    String? intro = '一段简介',
  }) {
    return <String, dynamic>{
      'id': 'book-1',
      'source_id': 'src-1',
      'source_name': null,
      'name': name,
      'author': author,
      'cover_url': null,
      'chapter_count': 0,
      'latest_chapter_title': null,
      'intro': intro,
      'kind': kind,
      'book_url': null,
      'toc_url': null,
      'last_check_time': null,
      'last_check_count': 0,
      'total_word_count': 0,
      'can_update': true,
      'order_time': 0,
      'latest_chapter_time': null,
      'custom_cover_path': null,
      'custom_info_json': null,
      // 批次 6 加的 5 字段（构造时必须保留以验证保存路径不会丢字段）。
      'dur_chapter_index': 0,
      'dur_chapter_pos': 0,
      'dur_chapter_title': null,
      'dur_chapter_time': 0,
      'group_id': 0,
      'created_at': 1700000000,
      'updated_at': 1700000000,
    };
  }

  testWidgets(
      'BookInfoEditPage renders 5 TextFields with correct initial values',
      (WidgetTester tester) async {
    final book = _sampleBook();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: BookInfoEditPage(
            bookId: book['id'] as String,
            initialBook: book,
            saveBookOverride: ({required String dbPath, required String bookJson}) async {},
            dbPathOverride: Future.value('/tmp/legado-test.db'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 4 个 TextField + 标题 / 占位文字。
    // labelText 出现在 page 上即可证明 TextField 已渲染。
    expect(find.text('书名'), findsOneWidget);
    expect(find.text('作者'), findsOneWidget);
    expect(find.text('分类'), findsOneWidget);
    expect(find.text('简介'), findsOneWidget);

    // controller 初始值正确（直接通过 EditableText 找渲染出的字符串）。
    expect(find.text('三体'), findsOneWidget);
    expect(find.text('刘慈欣'), findsOneWidget);
    expect(find.text('科幻'), findsOneWidget);
    expect(find.text('一段简介'), findsOneWidget);

    // 顶栏 "保存" 按钮渲染。
    expect(find.text('保存'), findsOneWidget);
  });

  testWidgets('BookInfoEditPage save button is disabled when name is empty',
      (WidgetTester tester) async {
    final book = _sampleBook(name: '');
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: BookInfoEditPage(
            bookId: book['id'] as String,
            initialBook: book,
            saveBookOverride: ({required String dbPath, required String bookJson}) async {},
            dbPathOverride: Future.value('/tmp/legado-test.db'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 找到 "保存" 文字所在 TextButton，检查 onPressed 是否为 null（disabled）。
    final saveBtn = tester.widget<TextButton>(
      find.ancestor(of: find.text('保存'), matching: find.byType(TextButton)),
    );
    expect(saveBtn.onPressed, isNull,
        reason: 'name 为空时保存按钮必须 disabled');

    // 输入书名后保存按钮应启用。
    final nameField = find.widgetWithText(TextField, '书名');
    expect(nameField, findsOneWidget);
    // 直接找 EditableText / TextField 输入。
    await tester.enterText(
      find.byType(TextField).first,
      '新书名',
    );
    await tester.pump();

    final saveBtn2 = tester.widget<TextButton>(
      find.ancestor(of: find.text('保存'), matching: find.byType(TextButton)),
    );
    expect(saveBtn2.onPressed, isNotNull,
        reason: '输入 name 后保存按钮应启用');
  });

  testWidgets(
      'BookInfoEditPage save calls saveBookOverride with edited fields preserved',
      (WidgetTester tester) async {
    final book = _sampleBook();
    String? capturedJson;
    String? capturedDbPath;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: BookInfoEditPage(
            bookId: book['id'] as String,
            initialBook: book,
            saveBookOverride: ({required String dbPath, required String bookJson}) async {
              capturedDbPath = dbPath;
              capturedJson = bookJson;
            },
            dbPathOverride: Future.value('/tmp/legado-test.db'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 改作者字段（第 2 个 TextField）。
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(1), '新作者');
    await tester.pump();

    // 点保存。
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(capturedDbPath, '/tmp/legado-test.db');
    expect(capturedJson, isNotNull);
    expect(capturedJson, contains('"author":"新作者"'));
    expect(capturedJson, contains('"name":"三体"'));
    // 批次 6 加的 group_id / dur_chapter_* 字段不能丢。
    expect(capturedJson, contains('"group_id"'));
    expect(capturedJson, contains('"dur_chapter_index"'));
  });
}
