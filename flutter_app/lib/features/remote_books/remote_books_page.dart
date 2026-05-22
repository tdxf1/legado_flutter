import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/persistence/json_store.dart';
import '../../core/providers.dart';
import '../../core/security/secure_storage.dart';
import '../../core/util/platform_int64.dart';
import '../../core/util/time_format.dart';
import '../../core/widgets/safe_setstate.dart';
import '../../src/rust/api.dart' as rust_api;

/// BATCH-27c-1: 远程书浏览页（最小可用版）。
///
/// 入口：bookshelf PopupMenu「添加远程书」（27a 灰显占位 → 27c 改可点）。
/// 流程：复用 webdav_config_page 凭据（webdav.json url/user + secure_storage
/// `webdav_password`）→ PROPFIND 列目录 → ListView 文件夹 + 文件混排 →
/// 点文件夹下钻（[`_pathStack`] push + reload）→ 点文件下载到
/// `documents_dir/remote_books/<uuid_filename>` → 调
/// [`rust_api.importLocalBook`] 入书架 → invalidate providers + SnackBar。
///
/// 范围（PRD §Q1-Q7 锁定）：单 server / 单选 / 深度栈下钻；多选 / 排序
/// / 搜索 / multi-server / 已上架状态包 / origin = `webdav://<path>` 标记
/// 全部留 27c follow-up（PRD §Out of Scope O1-O9）。
///
/// 测试钩子（mirror BookshelfPage 27a/27b 同款）：6 个 *Override 字段
/// 让 widget test 不依赖 path_provider / secure_storage / FRB / 真 webdav。
class RemoteBooksPage extends ConsumerStatefulWidget {
  /// 测试钩子：注入假 dbPath（不走 path_provider 解析）。
  final String? dbPathOverride;

  /// 测试钩子：注入假 documents 目录（不走 [`resolvePersistenceDir`]）。
  /// 同时影响 webdav.json 读取目录与 remote_books/ 子目录创建位置。
  final String? documentsDirOverride;

  /// 测试钩子：注入 webdav 凭据，跳过 webdav.json + secure_storage 读取。
  /// 传 (`url:''`, `user:''`, `password:''`) 等价于"凭据缺失"路径，
  /// 让测试验证「请先配置 WebDAV」分支。
  final ({String url, String user, String password})? credentialsOverride;

  /// 测试钩子：替换 [`rust_api.webdavListDir`] FRB 调用。
  final Future<String> Function({
    required String url,
    required String user,
    required String password,
    required String path,
  })? listDirOverride;

  /// 测试钩子：替换 [`rust_api.webdavDownloadFile`] FRB 调用。返回
  /// 写入字节数（int 而非 PlatformInt64，方便测试）。
  final Future<int> Function({
    required String url,
    required String user,
    required String password,
    required String remotePath,
    required String targetLocalPath,
  })? downloadFileOverride;

  /// 测试钩子：替换 [`rust_api.importLocalBook`] FRB 调用。
  final Future<String> Function({
    required String dbPath,
    required String filePath,
    required String documentsDir,
  })? importLocalBookOverride;

  const RemoteBooksPage({
    super.key,
    this.dbPathOverride,
    this.documentsDirOverride,
    this.credentialsOverride,
    this.listDirOverride,
    this.downloadFileOverride,
    this.importLocalBookOverride,
  });

  @override
  ConsumerState<RemoteBooksPage> createState() => _RemoteBooksPageState();
}

/// 单个 webdav 目录条目。`name` 为 displayname / `isDir` 标识 collection /
/// `size` 字节数（dir 时为 0）/ `lastModified` 为 unix 秒（缺时为 null）。
/// 对应 Rust `core_net::webdav::DirEntry` 序列化为 JSON 后的形状。
class _RemoteEntry {
  final String name;
  final bool isDir;
  final int size;
  final int? lastModified;
  const _RemoteEntry({
    required this.name,
    required this.isDir,
    this.size = 0,
    this.lastModified,
  });
}

class _RemoteBooksPageState extends ConsumerState<RemoteBooksPage> {
  /// 当前路径栈：根目录时为空 list；进入 `books/小说` 后为 `['books', '小说']`。
  /// AppBar leading IconButton + OS back 都靠这个栈做上钻。
  final List<String> _pathStack = [];

  // 凭据状态
  String? _credentialsUrl;
  String? _credentialsUser;
  String? _credentialsPassword;
  bool _credentialsLoading = true;
  String? _credentialsError;

  // 列目录状态
  bool _entriesLoading = false;
  String? _entriesError;
  List<_RemoteEntry> _entries = const [];

  /// seq token：路径快速切换时让旧 future 不覆盖新结果。
  /// 对齐 [`async-and-mounted.md`] + [`列表 reactivity 模式`] BATCH-21
  /// (F-W2B-019) 防"幽灵覆盖"模板。
  int _loadSeq = 0;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  /// 启动流程：先加载凭据，凭据齐则继续 [`_loadCurrentDir`]。
  Future<void> _bootstrap() async {
    final creds = widget.credentialsOverride;
    if (creds != null) {
      // 测试钩子直接注入凭据
      if (creds.url.isEmpty || creds.user.isEmpty || creds.password.isEmpty) {
        safeSetState(() {
          _credentialsError = '请先配置 WebDAV';
          _credentialsLoading = false;
        });
        return;
      }
      _credentialsUrl = creds.url;
      _credentialsUser = creds.user;
      _credentialsPassword = creds.password;
      safeSetState(() => _credentialsLoading = false);
      await _loadCurrentDir();
      return;
    }

    try {
      final dir = widget.documentsDirOverride ?? await resolvePersistenceDir();
      final cfg = await readJsonFile(
        'webdav.json',
        directory: dir,
      );
      final url = (cfg?['url'] as String?)?.trim() ?? '';
      final user = (cfg?['user'] as String?)?.trim() ?? '';
      final pwd = (await readSecret('webdav_password')) ?? '';
      if (url.isEmpty || user.isEmpty || pwd.isEmpty) {
        if (!mounted) return;
        safeSetState(() {
          _credentialsError = '请先配置 WebDAV';
          _credentialsLoading = false;
        });
        return;
      }
      _credentialsUrl = url;
      _credentialsUser = user;
      _credentialsPassword = pwd;
      if (!mounted) return;
      safeSetState(() => _credentialsLoading = false);
      await _loadCurrentDir();
    } catch (e) {
      if (!mounted) return;
      safeSetState(() {
        _credentialsError = '加载凭据失败: $e';
        _credentialsLoading = false;
      });
    }
  }

  /// 列当前 [`_pathStack`] 对应路径。每次 path 变更（下钻 / 上钻）都
  /// 调一次。seq token 防旧 future 覆盖新结果。
  Future<void> _loadCurrentDir() async {
    if (_credentialsUrl == null) return;
    final seq = ++_loadSeq;
    safeSetState(() {
      _entriesLoading = true;
      _entriesError = null;
    });
    try {
      final fn = widget.listDirOverride ??
          ({
            required String url,
            required String user,
            required String password,
            required String path,
          }) =>
              rust_api.webdavListDir(
                url: url,
                user: user,
                password: password,
                path: path,
              );
      final pathArg = _pathStack.join('/');
      final json = await fn(
        url: _credentialsUrl!,
        user: _credentialsUser!,
        password: _credentialsPassword!,
        path: pathArg,
      );
      if (!mounted || seq != _loadSeq) return;
      final raw = jsonDecode(json) as List<dynamic>;
      final list = <_RemoteEntry>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final m = item;
        final name = (m['name'] as String?) ?? '';
        if (name.isEmpty) continue;
        final isDir = m['isDir'] == true;
        final size = (m['size'] is num) ? (m['size'] as num).toInt() : 0;
        final lm = m['lastModified'];
        final lastModified = lm is num ? lm.toInt() : null;
        list.add(_RemoteEntry(
          name: name,
          isDir: isDir,
          size: size,
          lastModified: lastModified,
        ));
      }
      // 文件夹排前面，再按 name 排
      list.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.compareTo(b.name);
      });
      safeSetState(() {
        _entries = list;
        _entriesLoading = false;
      });
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      safeSetState(() {
        _entriesError = '列目录失败: $e';
        _entriesLoading = false;
      });
    }
  }

  /// 上钻一层。栈非空时 pop + reload 返 true（表示已处理，OS 不再 pop 页面）；
  /// 栈空时返 false 让默认 pop 流程处理（关闭页面）。
  bool _popPathOrPage() {
    if (_pathStack.isEmpty) return false;
    setState(() {
      _pathStack.removeLast();
    });
    // 上钻后立即重 list
    _loadCurrentDir();
    return true;
  }

  Future<void> _onTapEntry(_RemoteEntry e) async {
    if (e.isDir) {
      setState(() {
        _pathStack.add(e.name);
      });
      await _loadCurrentDir();
      return;
    }
    await _onTapFile(e);
  }

  /// 单文件下载 + 导入。失败 catch + SnackBar 不向上抛。
  Future<void> _onTapFile(_RemoteEntry e) async {
    if (_credentialsUrl == null) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text('下载中: ${e.name}'),
        duration: const Duration(seconds: 30),
      ),
    );
    try {
      final docsDir =
          widget.documentsDirOverride ?? await resolvePersistenceDir();
      if (!mounted) return;
      final remoteDir = Directory('$docsDir/remote_books');
      if (!remoteDir.existsSync()) {
        remoteDir.createSync(recursive: true);
      }
      final safeName = _safeFileName(e.name);
      final localPath = '${remoteDir.path}/$safeName';
      final remotePath = [..._pathStack, e.name].join('/');
      final downloadFn = widget.downloadFileOverride ??
          ({
            required String url,
            required String user,
            required String password,
            required String remotePath,
            required String targetLocalPath,
          }) async {
            final n = await rust_api.webdavDownloadFile(
              url: url,
              user: user,
              password: password,
              remotePath: remotePath,
              targetLocalPath: targetLocalPath,
            );
            return platformInt64ToInt(n);
          };
      await downloadFn(
        url: _credentialsUrl!,
        user: _credentialsUser!,
        password: _credentialsPassword!,
        remotePath: remotePath,
        targetLocalPath: localPath,
      );
      if (!mounted) return;
      final String dbPath =
          widget.dbPathOverride ?? await ref.read(dbPathProvider.future);
      if (!mounted) return;
      final importFn = widget.importLocalBookOverride ??
          ({
            required String dbPath,
            required String filePath,
            required String documentsDir,
          }) =>
              rust_api.importLocalBook(
                dbPath: dbPath,
                filePath: filePath,
                documentsDir: documentsDir,
              );
      await importFn(
        dbPath: dbPath,
        filePath: localPath,
        documentsDir: docsDir,
      );
      if (!mounted) return;
      // invalidate 让书架重拉
      ref.invalidate(allBooksProvider);
      ref.invalidate(booksByGroupProvider);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(content: Text('《${e.name}》导入成功')),
      );
    } catch (err) {
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(content: Text('下载失败: $err')),
      );
    }
  }

  /// 生成本地文件名：避免重名 + 防特殊字符。
  /// 项目无 uuid 包，用 millisecondsSinceEpoch + Random hex 拼短串
  /// （PRD §技术注意条注明）。原文件名经 sanitize 保留扩展名 + 中文字。
  String _safeFileName(String name) {
    final ts = DateTime.now().millisecondsSinceEpoch.toRadixString(16);
    final rand = Random.secure().nextInt(0xFFFFFF).toRadixString(16);
    // 替换 path separator + 控制字符 + 引号空格特殊字符；保留 . - _ 中文 字母数字
    final sanitized = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_');
    return '${ts}_${rand}_$sanitized';
  }

  @override
  Widget build(BuildContext context) {
    final pathDisplay =
        _pathStack.isEmpty ? '/' : '/${_pathStack.join('/')}';
    return PopScope(
      canPop: _pathStack.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // _pathStack 非空 → 上钻一层（同 leading back 行为）
        _popPathOrPage();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              if (!_popPathOrPage()) {
                if (context.canPop()) {
                  context.pop();
                } else {
                  Navigator.of(context).pop();
                }
              }
            },
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('远程书'),
              Text(
                pathDisplay,
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        body: _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_credentialsLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_credentialsError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_credentialsError!),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => context.push('/webdav-config'),
              child: const Text('去配置 WebDAV'),
            ),
          ],
        ),
      );
    }
    if (_entriesLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_entriesError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_entriesError!),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _loadCurrentDir,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (_entries.isEmpty) {
      return const Center(child: Text('此目录为空'));
    }
    return ListView.builder(
      itemCount: _entries.length,
      itemBuilder: (context, index) {
        final e = _entries[index];
        return ListTile(
          leading: Icon(
            e.isDir ? Icons.folder_outlined : Icons.book_outlined,
          ),
          title: Text(e.name),
          subtitle: e.isDir ? null : Text(_subtitleFor(e)),
          trailing: Icon(
            e.isDir ? Icons.chevron_right : Icons.download_outlined,
          ),
          onTap: () => _onTapEntry(e),
        );
      },
    );
  }

  String _subtitleFor(_RemoteEntry e) {
    final parts = <String>[];
    parts.add(_formatBytes(e.size));
    if (e.lastModified != null && e.lastModified! > 0) {
      parts.add(formatRelativeTime(e.lastModified!));
    }
    return parts.join(' · ');
  }

  /// 简易字节单位格式化。`KB`/`MB`/`GB`，对齐 OS 文件管理器常用呈现。
  /// 项目无统一文件大小 helper，inline 实现 6 行不引新文件。
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
