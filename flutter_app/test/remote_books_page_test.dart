import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:legado_flutter/core/providers.dart';
import 'package:legado_flutter/features/remote_books/remote_books_page.dart';

/// BATCH-27c-1 (05-22): 远程书浏览页测试。
///
/// 6 testWidgets 覆盖：凭据缺失 → 列目录成功 → 下钻 → 上钻 → 单文件
/// 下载导入 → 下载失败。所有路径走 *Override 测试钩子，不依赖
/// path_provider / FRB / secure_storage / 真 webdav。
///
/// 测试目录用 `Directory.systemTemp.createTempSync` 拿唯一路径（同
/// BATCH-27a `bookshelf_menu_test.dart` 决策，避免 hardcoded `/tmp/...`
/// 并发跑冲突 + 跨平台写权限差异）。`addTearDown` 兜底清理。
void main() {
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
}
