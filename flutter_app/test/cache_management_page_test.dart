import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/features/settings/cache_management_page.dart';

/// 批次 15 (05-19): 缓存管理页 widget 测试。
///
/// 通过 [CacheManagementPage] 的 *Override 钩子注入 fake records +
/// clearBookCache / clearAllCache mock，绕过 FRB 桥 / path_provider，
/// 验证：
/// 1. 顶部 Card 显示总缓存数 + 总章节数。
/// 2. ListView 至少含 fake 书名 + "已缓存 X / Y 章" 字样。
/// 3. 单本清空：tap delete icon → AlertDialog "确定清空" → mock 被调一次。
/// 4. 全局清空：tap "全局清空" 按钮 → AlertDialog "确定清空" → mock 被调一次。
void main() {
  testWidgets('CacheManagementPage renders total + per-book entries',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: CacheManagementPage(
            dbPathOverride: '/tmp/legado-test.db',
            recordsOverride: const [
              {
                'book_id': 'b1',
                'book_name': '三体',
                'total_chapters': 30,
                'cached_chapters': 20,
              },
              {
                'book_id': 'b2',
                'book_name': '球状闪电',
                'total_chapters': 20,
                'cached_chapters': 10,
              },
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // AppBar 标题。
    expect(find.text('缓存管理'), findsOneWidget);
    // 顶部 Card：总缓存（20+10=30 / 30+20=50）。
    expect(find.text('缓存统计'), findsOneWidget);
    expect(find.text('总缓存: 30 章 / 50 章'), findsOneWidget);
    expect(find.text('全局清空'), findsOneWidget);
    // ListView：两本书都在 + subtitle 格式。
    expect(find.text('三体'), findsOneWidget);
    expect(find.text('球状闪电'), findsOneWidget);
    expect(find.text('已缓存 20 / 30 章'), findsOneWidget);
    expect(find.text('已缓存 10 / 20 章'), findsOneWidget);
  });

  testWidgets('CacheManagementPage shows empty state when records is empty',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: CacheManagementPage(
            dbPathOverride: '/tmp/legado-test.db',
            recordsOverride: const [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂无书架'), findsOneWidget);
    // 0 章 / 0 章
    expect(find.text('总缓存: 0 章 / 0 章'), findsOneWidget);
  });

  testWidgets('clear-book-cache flow calls override exactly once',
      (WidgetTester tester) async {
    int clearBookCalls = 0;
    String? lastClearedBookId;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: CacheManagementPage(
            dbPathOverride: '/tmp/legado-test.db',
            recordsOverride: const [
              {
                'book_id': 'b1',
                'book_name': '三体',
                'total_chapters': 30,
                'cached_chapters': 20,
              },
            ],
            clearBookCacheOverride: (dbPath, bookId) async {
              clearBookCalls++;
              lastClearedBookId = bookId;
              return 20;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 点单本删除按钮
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    expect(find.text('清空本书缓存'), findsOneWidget);
    // 确定
    await tester.tap(find.text('确定清空'));
    await tester.pumpAndSettle();

    expect(clearBookCalls, 1, reason: '清空一次单本应只触发一次 mock');
    expect(lastClearedBookId, 'b1');
  });

  testWidgets('clear-all-cache flow calls override exactly once',
      (WidgetTester tester) async {
    int clearAllCalls = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: CacheManagementPage(
            dbPathOverride: '/tmp/legado-test.db',
            recordsOverride: const [
              {
                'book_id': 'b1',
                'book_name': '三体',
                'total_chapters': 30,
                'cached_chapters': 20,
              },
              {
                'book_id': 'b2',
                'book_name': '球状闪电',
                'total_chapters': 20,
                'cached_chapters': 10,
              },
            ],
            clearAllCacheOverride: (dbPath) async {
              clearAllCalls++;
              return 30;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 点全局清空
    await tester.tap(find.text('全局清空'));
    await tester.pumpAndSettle();
    expect(find.text('全局清空缓存'), findsOneWidget);
    // 确定
    await tester.tap(find.text('确定清空'));
    await tester.pumpAndSettle();

    expect(clearAllCalls, 1, reason: '全局清空应只触发一次 mock');
  });

  testWidgets(
      'clear-all-cache when no cache exists shows snackbar without dialog',
      (WidgetTester tester) async {
    int clearAllCalls = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: CacheManagementPage(
            dbPathOverride: '/tmp/legado-test.db',
            recordsOverride: const [
              {
                'book_id': 'b1',
                'book_name': '三体',
                'total_chapters': 30,
                'cached_chapters': 0,
              },
            ],
            clearAllCacheOverride: (dbPath) async {
              clearAllCalls++;
              return 0;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('全局清空'));
    await tester.pumpAndSettle();
    // 不应弹确认对话框
    expect(find.text('全局清空缓存'), findsNothing);
    expect(clearAllCalls, 0, reason: '没缓存时不该真去调 clearAllCache');
    // 应该提示"没缓存可清"
    expect(find.text('当前没有缓存可清'), findsOneWidget);
  });
}
