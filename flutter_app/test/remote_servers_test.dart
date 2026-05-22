import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legado_flutter/core/security/secure_storage.dart';
import 'package:legado_flutter/features/remote_books/remote_servers.dart';
import 'package:legado_flutter/features/remote_books/servers_picker.dart';

import '_secure_storage_fake.dart';

/// BATCH-27c-2 (05-22): 远程书多 server 选择测试。
///
/// 6 testWidgets 覆盖：
/// 1. RemoteServer model toJson / fromJson round-trip
/// 2. saveRemoteServersToDisk + load round-trip / file 不存在 → 空列表
/// 3. webdavPasswordKey 命名 + load/save (id=-1 走 'webdav_password' /
///    id>0 走 'webdav_password_<id>')
/// 4. ServersBottomSheet 渲染默认行 + 各 server + 切 server 返回 id
/// 5. ServersBottomSheet 新建：弹 EditDialog → save → onCreate 触发
/// 6. ServersBottomSheet 删除：confirm → onDelete 触发 + 删当前选中
///    fallback id=-1
void main() {
  setUp(() => setSecureStorageOverrideForTest(InMemorySecureStorage()));
  tearDown(() => setSecureStorageOverrideForTest(null));

  test('BATCH-27c-2: RemoteServer.toJson / fromJson round-trip', () {
    const s = RemoteServer(
      id: 17158,
      name: '坚果云',
      url: 'https://dav.jianguoyun.com/dav/legado/',
      user: 'alice@example.com',
    );
    final json = s.toJson();
    expect(json['id'], 17158);
    expect(json['name'], '坚果云');
    expect(json['url'], 'https://dav.jianguoyun.com/dav/legado/');
    expect(json['user'], 'alice@example.com');

    final back = RemoteServer.fromJson(json);
    expect(back, s);
  });

  test('BATCH-27c-2: saveRemoteServersToDisk + load round-trip', () async {
    final tmp = Directory.systemTemp.createTempSync('legado_test_27c2_disk_');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    final servers = [
      const RemoteServer(
        id: 1,
        name: 'A',
        url: 'https://a/',
        user: 'au',
      ),
      const RemoteServer(
        id: 2,
        name: 'B',
        url: 'https://b/',
        user: 'bu',
      ),
    ];
    await saveRemoteServersToDisk(servers, directory: tmp.path);
    final back = await loadRemoteServersFromDisk(directory: tmp.path);
    expect(back, servers);

    // file 不存在 / 损坏 → 空列表
    final empty = Directory.systemTemp.createTempSync('legado_test_27c2_empty_');
    addTearDown(() {
      if (empty.existsSync()) empty.deleteSync(recursive: true);
    });
    final none = await loadRemoteServersFromDisk(directory: empty.path);
    expect(none, isEmpty);
  });

  test(
      'BATCH-27c-2: webdavPasswordKey + load/save (id=-1 走 webdav_password / id>0 走 webdav_password_<id>)',
      () async {
    expect(webdavPasswordKey(17158), 'webdav_password_17158');

    // id=-1 → 'webdav_password'（与 27c-1 兼容）
    await saveRemoteServerPassword(kDefaultRemoteServerId, 'pwd_default');
    expect(await loadRemoteServerPassword(kDefaultRemoteServerId), 'pwd_default');

    // id=42 → 'webdav_password_42'
    await saveRemoteServerPassword(42, 'pwd_42');
    expect(await loadRemoteServerPassword(42), 'pwd_42');
    // 与默认 key 隔离：读 -1 仍是 'pwd_default'
    expect(await loadRemoteServerPassword(kDefaultRemoteServerId), 'pwd_default');

    // 写 null 删除
    await saveRemoteServerPassword(42, null);
    expect(await loadRemoteServerPassword(42), '');
  });

  testWidgets(
      'BATCH-27c-2: ServersBottomSheet 渲染默认行 + 各 server + 切 server 返回 id',
      (tester) async {
    int? returnedId;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () async {
                returnedId = await showServersBottomSheet(
                  context: ctx,
                  servers: const [
                    RemoteServer(id: 100, name: 'A', url: 'https://a/', user: 'au'),
                    RemoteServer(id: 200, name: 'B', url: 'https://b/', user: 'bu'),
                  ],
                  selectedId: 100,
                  onCreate: (_, __) async {},
                  onUpdate: (_, __) async {},
                  onDelete: (_) async {},
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 默认行 + 2 server 都可见
    expect(find.text('默认'), findsOneWidget);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
    // 「+ 新建 WebDAV 服务器」 FilledButton 可见
    expect(find.text('新建 WebDAV 服务器'), findsOneWidget);

    // 当前选中 100=A → A 行的 leading 是 radio_button_checked
    final aTile = find.widgetWithText(ListTile, 'A');
    expect(
      find.descendant(
        of: aTile,
        matching: find.byIcon(Icons.radio_button_checked),
      ),
      findsOneWidget,
    );

    // 点 B → 返回 200
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    expect(returnedId, 200);
  });

  testWidgets(
      'BATCH-27c-2: ServersBottomSheet 新建 → EditDialog save → onCreate 触发',
      (tester) async {
    RemoteServer? createdServer;
    String? createdPassword;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () => showServersBottomSheet(
                context: ctx,
                servers: const [],
                selectedId: kDefaultRemoteServerId,
                onCreate: (s, pwd) async {
                  createdServer = s;
                  createdPassword = pwd;
                },
                onUpdate: (_, __) async {},
                onDelete: (_) async {},
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 点「新建」按钮 → EditDialog 弹
    await tester.tap(find.text('新建 WebDAV 服务器'));
    await tester.pumpAndSettle();
    expect(find.text('新建服务器'), findsOneWidget);

    // 填字段
    await tester.enterText(find.widgetWithText(TextField, '名称'), 'TestSrv');
    await tester.enterText(
        find.widgetWithText(TextField, 'URL'), 'https://test.example/');
    await tester.enterText(find.widgetWithText(TextField, '用户名'), 'tu');
    await tester.enterText(find.widgetWithText(TextField, '密码'), 'tp');

    // 点保存
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(createdServer, isNotNull);
    expect(createdServer!.name, 'TestSrv');
    expect(createdServer!.url, 'https://test.example/');
    expect(createdServer!.user, 'tu');
    expect(createdPassword, 'tp');
  });

  testWidgets(
      'BATCH-27c-2: ServersBottomSheet 删除当前选中 → confirm → onDelete 触发',
      (tester) async {
    RemoteServer? deletedServer;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () => showServersBottomSheet(
                context: ctx,
                servers: const [
                  RemoteServer(
                      id: 555, name: 'ToDelete', url: 'https://x/', user: 'xu'),
                ],
                selectedId: 555,
                onCreate: (_, __) async {},
                onUpdate: (_, __) async {},
                onDelete: (s) async => deletedServer = s,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 点 ToDelete 行的 delete IconButton
    final toDeleteTile = find.widgetWithText(ListTile, 'ToDelete');
    await tester.tap(
      find.descendant(
        of: toDeleteTile,
        matching: find.byIcon(Icons.delete_outline),
      ),
    );
    await tester.pumpAndSettle();

    // confirm dialog 显示「删除服务器？」+「删除」按钮
    expect(find.text('删除服务器？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(deletedServer, isNotNull);
    expect(deletedServer!.id, 555);
    // 删的是当前选中 → SnackBar「已切回默认服务器」
    expect(find.text('已切回默认服务器'), findsOneWidget);
  });
}
