import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:legado_flutter/core/providers.dart';
import 'package:legado_flutter/core/remote_book_runner.dart';
import 'package:legado_flutter/features/remote_books/remote_books_page.dart';

/// BATCH-27c-1 (05-22): 远程书浏览页测试。
///
/// 6 testWidgets 覆盖：凭据缺失 → 列目录成功 → 下钻 → 上钻 → 单文件
/// 下载导入 → 下载失败。所有路径走 *Override 测试钩子，不依赖
/// path_provider / FRB / secure_storage / 真 webdav。
///
/// BATCH-27c-3 (05-22) 追加 6 个 testWidgets：长按进选择模式 / Checkbox /
/// 全选只勾文件 / 取消 / 下钻清 selection / OS back 优先级 / 批量下载 5
/// 本 + 总结 SnackBar / 部分失败总结 SnackBar。共计 ≥12 testWidgets。
///
/// 测试目录用 `Directory.systemTemp.createTempSync` 拿唯一路径（同
/// BATCH-27a `bookshelf_menu_test.dart` 决策，避免 hardcoded `/tmp/...`
/// 并发跑冲突 + 跨平台写权限差异）。`addTearDown` 兜底清理。
void main() {
  // BATCH-27c-3: runner 是 singleton；每 test 间 reset 防止 progress 状态
  // 跨 test 污染。
  setUp(() {
    RemoteBookRunner().resetForTest();
  });

  /// 构造一个最小 GoRouter，把 RemoteBooksPage 作为根路由 + 注册
  /// `/webdav-config` 占位（凭据缺失 SnackBar 跳转 button 测）。
  Widget buildPage({
    String? dbPath,
    String? docsDir,
    ({String url, String user, String password})? credentials,
    Future<String> Function({
      required String url,
      required String user,
      required String password,
      required String path,
    })? listDirFn,
    Future<int> Function({
      required String url,
      required String user,
      required String password,
      required String remotePath,
      required String targetLocalPath,
    })? downloadFn,
    Future<String> Function({
      required String dbPath,
      required String filePath,
      required String documentsDir,
    })? importFn,
  }) {
    final router = GoRouter(
      initialLocation: '/remote-books',
      routes: [
        GoRoute(
          path: '/remote-books',
          builder: (context, state) => RemoteBooksPage(
            dbPathOverride: dbPath,
            documentsDirOverride: docsDir,
            credentialsOverride: credentials,
            listDirOverride: listDirFn,
            downloadFileOverride: downloadFn,
            importLocalBookOverride: importFn,
          ),
        ),
        // /webdav-config 路由 stub —— 仅注册防 ContextNotFound；测试不
        // 触发 navigation（webdav-config 真页面会调 secure_storage 平台
        // 通道，widget test 下抛异常）。
        GoRoute(
          path: '/webdav-config',
          builder: (_, __) =>
              const Scaffold(body: Center(child: Text('webdav-config stub'))),
        ),
      ],
    );
    return ProviderScope(
      overrides: [
        // 不让 _onTapFile 走 ref.read(dbPathProvider.future) 真实解析；
        // 但仅在没传 dbPath override 时才需要 fallback。
        if (dbPath != null)
          dbPathProvider.overrideWith(
            (ref) async => dbPath,
          ),
      ],
      child: MaterialApp.router(routerConfig: router),
    );
  }

  /// 1. 凭据缺失（credentialsOverride 传空字段）→ 显示「请先配置 WebDAV」+
  /// 跳转按钮存在。
  ///
  /// 不执行实际跳转：webdav-config 页 _loadConfig 会触发 secure_storage
  /// 平台通道（widget test 下 MissingPluginException）+ readJsonFile 走
  /// path_provider；测试隔离层走不通。仅验按钮 + 错误文案足以保证 UX
  /// 信号；点击跳转的实际行为由 router 集成测试覆盖（rss_article_*_test
  /// 同款决策：单元测试不组装跨页面 router 链路）。
  testWidgets(
      'BATCH-27c: 凭据缺失 → 显示请先配置 WebDAV + 跳转 button',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildPage(
      credentials: (url: '', user: '', password: ''),
    ));
    await tester.pumpAndSettle();

    expect(find.text('请先配置 WebDAV'), findsOneWidget);
    expect(find.text('去配置 WebDAV'), findsOneWidget);
    // 按钮在但不点：避免触发 webdav-config 页 platform channel
    expect(find.byType(FilledButton), findsOneWidget);
  });

  /// 2. 列目录成功 → ListView 显示 entries（文件夹 + 文件混排，
  /// 文件夹排前），icon 区分。
  testWidgets('BATCH-27c: 列目录成功 → ListView 显示 entries',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildPage(
      credentials: (url: 'https://x/dav/', user: 'u', password: 'p'),
      listDirFn: ({
        required String url,
        required String user,
        required String password,
        required String path,
      }) async {
        return '[{"name":"books","isDir":true,"size":0,"lastModified":1735732496},'
            '{"name":"a.txt","isDir":false,"size":2048,"lastModified":1735732490}]';
      },
    ));
    await tester.pumpAndSettle();

    // 文件夹与文件都展示
    expect(find.text('books'), findsOneWidget);
    expect(find.text('a.txt'), findsOneWidget);

    // 文件夹用 folder_outlined / 文件用 book_outlined（leading）
    expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
    expect(find.byIcon(Icons.book_outlined), findsOneWidget);
    // trailing：文件夹 chevron_right / 文件 download_outlined
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    expect(find.byIcon(Icons.download_outlined), findsOneWidget);
  });

  /// 3. 点文件夹下钻 → AppBar 显示新 path + 二次 listDirFn 调用 path 参数
  testWidgets('BATCH-27c: 点文件夹下钻 → AppBar 路径变 + listDir 二次调用',
      (WidgetTester tester) async {
    String? capturedPath;
    var calls = 0;
    await tester.pumpWidget(buildPage(
      credentials: (url: 'https://x/dav/', user: 'u', password: 'p'),
      listDirFn: ({
        required String url,
        required String user,
        required String password,
        required String path,
      }) async {
        calls++;
        capturedPath = path;
        if (path.isEmpty) {
          return '[{"name":"books","isDir":true,"size":0}]';
        }
        return '[{"name":"deep.epub","isDir":false,"size":1024}]';
      },
    ));
    await tester.pumpAndSettle();

    // 第一次调用 path = ''
    expect(calls, 1);
    expect(capturedPath, '');
    // AppBar subtitle 是 '/'
    expect(find.text('/'), findsOneWidget);

    // 点 books 文件夹
    await tester.tap(find.text('books'));
    await tester.pumpAndSettle();

    // 第二次调用 path = 'books'
    expect(calls, 2);
    expect(capturedPath, 'books');
    // AppBar subtitle 变 '/books'
    expect(find.text('/books'), findsOneWidget);
    // 子目录内容
    expect(find.text('deep.epub'), findsOneWidget);
  });

  /// 4. 系统 back（点 AppBar leading back IconButton）→ 上钻一层 →
  /// 重新 listDir，AppBar 路径回退。
  testWidgets('BATCH-27c: AppBar leading back → 上钻一层 + listDir 重调',
      (WidgetTester tester) async {
    final captured = <String>[];
    await tester.pumpWidget(buildPage(
      credentials: (url: 'https://x/dav/', user: 'u', password: 'p'),
      listDirFn: ({
        required String url,
        required String user,
        required String password,
        required String path,
      }) async {
        captured.add(path);
        if (path.isEmpty) {
          return '[{"name":"books","isDir":true,"size":0}]';
        }
        return '[{"name":"a.epub","isDir":false,"size":1024}]';
      },
    ));
    await tester.pumpAndSettle();

    // 进入 books
    await tester.tap(find.text('books'));
    await tester.pumpAndSettle();
    expect(captured, ['', 'books']);
    expect(find.text('/books'), findsOneWidget);

    // 点 leading back
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    // path 回到 root，listDir 重调
    expect(captured, ['', 'books', '']);
    expect(find.text('/'), findsOneWidget);
    expect(find.text('books'), findsOneWidget);
  });

  /// 5. 点文件 → SnackBar「下载中」→ download + import → SnackBar「导入成功」
  testWidgets('BATCH-27c: 点文件 → 下载导入 → SnackBar「导入成功」',
      (WidgetTester tester) async {
    final dir = Directory.systemTemp
        .createTempSync('legado_flutter_test_remote_books_27c_5_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    var downloadCalls = 0;
    String? downloadedRemotePath;
    String? downloadedLocalPath;
    var importCalls = 0;
    String? importedFilePath;

    // hanging completer 让下载在 SnackBar 出现后才完成；保证测试观察到
    // 「下载中」中间态后再观察「导入成功」终态
    final downloadGate = Completer<int>();

    await tester.pumpWidget(buildPage(
      dbPath: '/fake/db.sqlite',
      docsDir: dir.path,
      credentials: (url: 'https://x/dav/', user: 'u', password: 'p'),
      listDirFn: ({
        required String url,
        required String user,
        required String password,
        required String path,
      }) async {
        return '[{"name":"a.epub","isDir":false,"size":1024}]';
      },
      downloadFn: ({
        required String url,
        required String user,
        required String password,
        required String remotePath,
        required String targetLocalPath,
      }) async {
        downloadCalls++;
        downloadedRemotePath = remotePath;
        downloadedLocalPath = targetLocalPath;
        return downloadGate.future;
      },
      importFn: ({
        required String dbPath,
        required String filePath,
        required String documentsDir,
      }) async {
        importCalls++;
        importedFilePath = filePath;
        return '{"book_id":"abc123"}';
      },
    ));
    await tester.pumpAndSettle();

    // 点击 a.epub 文件
    await tester.tap(find.text('a.epub'));
    // pump 让 SnackBar「下载中」先 schedule，downloadGate 还没 complete
    await tester.pump();
    expect(find.text('下载中: a.epub'), findsOneWidget);

    // 完成下载（mock 返字节数）→ 异步链继续走 import
    downloadGate.complete(1024);
    await tester.pumpAndSettle();

    expect(downloadCalls, 1);
    expect(importCalls, 1);
    // remote_path 应等于 '${path stack}/${name}' = 'a.epub'
    expect(downloadedRemotePath, 'a.epub');
    // 本地路径包含 remote_books/ 子目录 + 原文件名
    expect(downloadedLocalPath, isNotNull);
    expect(downloadedLocalPath!.contains('remote_books'), isTrue);
    expect(downloadedLocalPath!.endsWith('a.epub'), isTrue);
    // import 用的 file_path 与 download target 同
    expect(importedFilePath, downloadedLocalPath);
    // SnackBar 切到「导入成功」
    expect(find.text('《a.epub》导入成功'), findsOneWidget);
  });

  /// 6. 下载失败 → SnackBar「下载失败」+ 不破坏页面（仍展示 ListView）
  testWidgets('BATCH-27c: 下载失败 → SnackBar「下载失败」',
      (WidgetTester tester) async {
    final dir = Directory.systemTemp
        .createTempSync('legado_flutter_test_remote_books_27c_6_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    await tester.pumpWidget(buildPage(
      dbPath: '/fake/db.sqlite',
      docsDir: dir.path,
      credentials: (url: 'https://x/dav/', user: 'u', password: 'p'),
      listDirFn: ({
        required String url,
        required String user,
        required String password,
        required String path,
      }) async {
        return '[{"name":"x.epub","isDir":false,"size":2048}]';
      },
      downloadFn: ({
        required String url,
        required String user,
        required String password,
        required String remotePath,
        required String targetLocalPath,
      }) async {
        throw Exception('网络错误');
      },
      importFn: ({
        required String dbPath,
        required String filePath,
        required String documentsDir,
      }) async {
        // 不应被调用
        throw StateError('import_local_book 不应在 download 失败时被调');
      },
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('x.epub'));
    await tester.pumpAndSettle();

    // SnackBar 提示失败（contains 「下载失败」）
    expect(
      find.byWidgetPredicate(
        (w) => w is SnackBar &&
            w.content is Text &&
            ((w.content as Text).data ?? '').contains('下载失败'),
      ),
      findsOneWidget,
    );
    // 页面仍展示 x.epub（ListView 没破坏）
    expect(find.text('x.epub'), findsOneWidget);
  });

  // ============================================================
  // BATCH-27c-3 (05-22): 多选模式 + 批量下载（≥6 testWidgets）
  // ============================================================

  /// 7. 长按文件项进入选择模式 → AppBar 显示「选择 1 项」+ Checkbox 出现
  /// （文件夹仍为 Folder icon，不会变 Checkbox）。
  testWidgets(
      'BATCH-27c-3: 长按文件 → 选择模式启动 + Checkbox + 文件夹仍 Folder icon',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildPage(
      credentials: (url: 'https://x/dav/', user: 'u', password: 'p'),
      listDirFn: ({
        required String url,
        required String user,
        required String password,
        required String path,
      }) async {
        return '[{"name":"books","isDir":true,"size":0},'
            '{"name":"a.epub","isDir":false,"size":1024},'
            '{"name":"b.epub","isDir":false,"size":2048}]';
      },
    ));
    await tester.pumpAndSettle();

    // 默认非选择模式：AppBar 标题「远程书」+ 路径「/」
    expect(find.text('远程书'), findsOneWidget);
    expect(find.text('/'), findsOneWidget);

    // 长按 a.epub
    await tester.longPress(find.text('a.epub'));
    await tester.pumpAndSettle();

    // AppBar 标题切到「选择 1 项」+ leading 变 close icon
    expect(find.text('选择 1 项'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
    // 文件项 leading 是 Checkbox（books 是 Folder 不变）
    expect(find.byType(Checkbox), findsNWidgets(2),
        reason: '2 个文件 → 2 个 Checkbox（文件夹不可勾）');
    // 文件夹仍 Folder icon
    expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
    // 全选 + 下载选中 actions 出现
    expect(find.byIcon(Icons.select_all), findsOneWidget);
    expect(find.byIcon(Icons.download_outlined), findsOneWidget);
  });

  /// 8. 全选 action → 只勾文件不勾文件夹。
  testWidgets('BATCH-27c-3: 全选 → 只勾文件不勾文件夹',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildPage(
      credentials: (url: 'https://x/dav/', user: 'u', password: 'p'),
      listDirFn: ({
        required String url,
        required String user,
        required String password,
        required String path,
      }) async {
        return '[{"name":"books","isDir":true,"size":0},'
            '{"name":"a.epub","isDir":false,"size":1024},'
            '{"name":"b.epub","isDir":false,"size":2048},'
            '{"name":"c.epub","isDir":false,"size":3072}]';
      },
    ));
    await tester.pumpAndSettle();

    // 长按 a.epub 进选择模式
    await tester.longPress(find.text('a.epub'));
    await tester.pumpAndSettle();
    expect(find.text('选择 1 项'), findsOneWidget);

    // 点全选
    await tester.tap(find.byIcon(Icons.select_all));
    await tester.pumpAndSettle();

    // 应显示「选择 3 项」（3 个文件，跳 books 文件夹）
    expect(find.text('选择 3 项'), findsOneWidget);
    // 3 个 Checkbox 全勾上：value=true
    final checkboxes = tester.widgetList<Checkbox>(find.byType(Checkbox));
    expect(checkboxes.length, 3);
    for (final cb in checkboxes) {
      expect(cb.value, true);
    }
  });

  /// 9. 取消选择（点 close）→ AppBar 复原 + 退出选择模式。
  testWidgets('BATCH-27c-3: 取消选择 → AppBar 复原',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildPage(
      credentials: (url: 'https://x/dav/', user: 'u', password: 'p'),
      listDirFn: ({
        required String url,
        required String user,
        required String password,
        required String path,
      }) async {
        return '[{"name":"a.epub","isDir":false,"size":1024}]';
      },
    ));
    await tester.pumpAndSettle();

    // 长按进选择模式
    await tester.longPress(find.text('a.epub'));
    await tester.pumpAndSettle();
    expect(find.text('选择 1 项'), findsOneWidget);

    // 点 close（取消）
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    // 标题回「远程书」+ Checkbox 消失
    expect(find.text('远程书'), findsOneWidget);
    expect(find.text('选择 1 项'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
    // download trailing icon 回来（文件项 trailing）
    expect(find.byIcon(Icons.download_outlined), findsOneWidget);
  });

  /// 10. 选择模式下点文件夹 → 下钻 + 清空 selection + 退出选择模式。
  testWidgets('BATCH-27c-3: 下钻文件夹 → 清空 selection + 退出选择模式',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildPage(
      credentials: (url: 'https://x/dav/', user: 'u', password: 'p'),
      listDirFn: ({
        required String url,
        required String user,
        required String password,
        required String path,
      }) async {
        if (path.isEmpty) {
          return '[{"name":"books","isDir":true,"size":0},'
              '{"name":"a.epub","isDir":false,"size":1024}]';
        }
        return '[{"name":"deep.epub","isDir":false,"size":2048}]';
      },
    ));
    await tester.pumpAndSettle();

    // 长按 a.epub 进选择模式
    await tester.longPress(find.text('a.epub'));
    await tester.pumpAndSettle();
    expect(find.text('选择 1 项'), findsOneWidget);

    // 点 books 文件夹（选择模式下文件夹仍下钻）
    await tester.tap(find.text('books'));
    await tester.pumpAndSettle();

    // 退出选择模式 + 路径变 /books + 子目录文件展示
    expect(find.text('选择 1 项'), findsNothing);
    expect(find.text('/books'), findsOneWidget);
    expect(find.text('deep.epub'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
  });

  /// 11. 5 文件批量下载 → enqueue 5 + 退选择模式 + done 后总结 SnackBar。
  testWidgets('BATCH-27c-3: 批量下载 5 本 → 总结 SnackBar 「成功 5 / 失败 0」',
      (WidgetTester tester) async {
    final dir = Directory.systemTemp
        .createTempSync('legado_flutter_test_remote_27c3_5_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    var downloadCalls = 0;
    var importCalls = 0;
    // hanging gate 让 worker 在「已开始下载 5」SnackBar 出现后才完成；
    // 不然 worker 立即跑完，start SnackBar 被 done SnackBar 替换，
    // 测试两个 SnackBar 状态不可分。
    final downloadGate = Completer<int>();
    await tester.pumpWidget(buildPage(
      dbPath: '/fake/db.sqlite',
      docsDir: dir.path,
      credentials: (url: 'https://x/dav/', user: 'u', password: 'p'),
      listDirFn: ({
        required String url,
        required String user,
        required String password,
        required String path,
      }) async {
        return '[{"name":"a.epub","isDir":false,"size":1024},'
            '{"name":"b.epub","isDir":false,"size":1024},'
            '{"name":"c.epub","isDir":false,"size":1024},'
            '{"name":"d.epub","isDir":false,"size":1024},'
            '{"name":"e.epub","isDir":false,"size":1024}]';
      },
      downloadFn: ({
        required String url,
        required String user,
        required String password,
        required String remotePath,
        required String targetLocalPath,
      }) async {
        downloadCalls++;
        return downloadGate.future;
      },
      importFn: ({
        required String dbPath,
        required String filePath,
        required String documentsDir,
      }) async {
        importCalls++;
        return '{"book_id":"abc"}';
      },
    ));
    await tester.pumpAndSettle();

    // 长按 a 进选择模式
    await tester.longPress(find.text('a.epub'));
    await tester.pumpAndSettle();
    // 全选
    await tester.tap(find.byIcon(Icons.select_all));
    await tester.pumpAndSettle();
    expect(find.text('选择 5 项'), findsOneWidget);

    // 点「下载选中」action
    await tester.tap(find.byIcon(Icons.download_outlined));
    // pump 让 SnackBar + state setState 落帧；workers 因 hanging gate 仍挂起
    await tester.pump();

    // 立即退出选择模式 + SnackBar「已开始下载 5 本远程书」
    expect(find.text('远程书'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
    expect(
      find.byWidgetPredicate(
        (w) => w is SnackBar &&
            w.content is Text &&
            ((w.content as Text).data ?? '').contains('已开始下载 5'),
      ),
      findsOneWidget,
    );
    // workers 在等 gate；下载调用数 = 1（concurrency=1，串行第一个）
    expect(downloadCalls, 1);
    expect(importCalls, 0);

    // 释放 gate → workers 走完 5 本
    downloadGate.complete(1024);
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    expect(downloadCalls, 5);
    expect(importCalls, 5);
    // 总结 SnackBar
    expect(
      find.byWidgetPredicate(
        (w) => w is SnackBar &&
            w.content is Text &&
            ((w.content as Text).data ?? '')
                .contains('批量下载完成：成功 5 / 失败 0'),
      ),
      findsOneWidget,
    );
  });

  /// 12. 部分失败：4 成功 + 1 失败 → 总结显示「成功 4 / 失败 1」。
  testWidgets(
      'BATCH-27c-3: 批量下载部分失败 → 总结 SnackBar 「成功 4 / 失败 1」',
      (WidgetTester tester) async {
    final dir = Directory.systemTemp
        .createTempSync('legado_flutter_test_remote_27c3_6_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    await tester.pumpWidget(buildPage(
      dbPath: '/fake/db.sqlite',
      docsDir: dir.path,
      credentials: (url: 'https://x/dav/', user: 'u', password: 'p'),
      listDirFn: ({
        required String url,
        required String user,
        required String password,
        required String path,
      }) async {
        return '[{"name":"a.epub","isDir":false,"size":1024},'
            '{"name":"b.epub","isDir":false,"size":1024},'
            '{"name":"FAIL.epub","isDir":false,"size":1024},'
            '{"name":"d.epub","isDir":false,"size":1024},'
            '{"name":"e.epub","isDir":false,"size":1024}]';
      },
      downloadFn: ({
        required String url,
        required String user,
        required String password,
        required String remotePath,
        required String targetLocalPath,
      }) async {
        if (remotePath.contains('FAIL')) {
          throw Exception('网络错误');
        }
        return 1024;
      },
      importFn: ({
        required String dbPath,
        required String filePath,
        required String documentsDir,
      }) async {
        return '{"book_id":"abc"}';
      },
    ));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('a.epub'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.select_all));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.download_outlined));
    await tester.pump();
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    // 总结 SnackBar 「成功 4 / 失败 1」
    expect(
      find.byWidgetPredicate(
        (w) => w is SnackBar &&
            w.content is Text &&
            ((w.content as Text).data ?? '')
                .contains('批量下载完成：成功 4 / 失败 1'),
      ),
      findsOneWidget,
    );
  });
}
