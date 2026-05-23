import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/persistence/json_store.dart';
import '../../core/providers.dart';
import '../../core/remote_book_runner.dart';
import '../../core/util/platform_int64.dart';
import '../../core/util/time_format.dart';
import '../../core/widgets/safe_setstate.dart';
import '../../src/rust/api.dart' as rust_api;
import 'remote_servers.dart';
import 'servers_picker.dart';

/// BATCH-27c-1: 远程书浏览页（最小可用版）。
/// BATCH-27c-3: 加多选模式 + 批量下载（[`RemoteBookRunner`] singleton 范本）。
/// BATCH-27c-4: 加排序（名称/时间 × 升/降）+ 搜索（debounce 300ms + 文件名
/// case-insensitive contains 过滤）。AppBar 三态切换：普通 / 选择 / 搜索。
///
/// 入口：bookshelf PopupMenu「添加远程书」（27a 灰显占位 → 27c 改可点）。
/// 流程：复用 webdav_config_page 凭据（webdav.json url/user + secure_storage
/// `webdav_password`）→ PROPFIND 列目录 → ListView 文件夹 + 文件混排 →
/// 点文件夹下钻（[`_pathStack`] push + reload）→ 点文件下载到
/// `documents_dir/remote_books/<uuid_filename>` → 调
/// [`rust_api.importLocalBook`] 入书架 → invalidate providers + SnackBar。
///
/// 多选模式（27c-3）：长按文件项进入选择模式 → AppBar 替换为「选择 N 项 /
/// 全选 / 取消 / 下载选中」→ 点击 ListTile = toggle 勾选 → 「下载选中」
/// → enqueue 全选项到 [`RemoteBookRunner`] singleton → 立即退出选择模式 →
/// AppBar transient badge 显示进度 → 完成 SnackBar。
///
/// 排序 + 搜索（27c-4）：
/// - 普通模式 AppBar actions 顺序：搜索 IconButton + 排序 PopupMenu 4 项
///   ((名称/时间)×(升/降)) + transient badge。
/// - 排序键 + 升降序持久化到 settings.json（key `remoteBookSortKey` /
///   `remoteBookSortAsc`），跨启动保留用户偏好；与 27a `_isGridView` 同款。
/// - 搜索模式：title 改 TextField + leading 改 close + actions 全清；输入
///   debounce 300ms 后过滤 `_visibleEntries`；空 query 立即清 filter。
/// - 三 mode 互斥（普通/选择/搜索）：进选择模式自动清搜索；进搜索模式自
///   动清选择。
/// - 下钻文件夹：保留排序偏好；清空搜索 query + 退搜索模式（每个目录独
///   立搜索语境，对齐 PRD §R7）。
///
/// 范围（PRD §Q1-Q5 锁定）：单 server / 多选仅当前目录（不跨目录递归）。
/// multi-server / 失败重试 / book.origin 标记 webDavTag 全部留 27c
/// follow-up（PRD §Out of Scope）。
///
/// 测试钩子（mirror BookshelfPage 27a/27b 同款）：8 个 *Override 字段
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

  /// BATCH-27c-3: 测试钩子，注入 [`RemoteBookRunner`] 替身。生产路径走
  /// `RemoteBookRunner()` 全局单例；测试每个用例 setUp 调
  /// `RemoteBookRunner().resetForTest()` 即可，无需多个实例。该字段保留
  /// 以便未来若 runner 改成可注入 ctor 时无缝切换。
  final RemoteBookRunner? remoteBookRunnerOverride;

  /// BATCH-27c-4: 测试钩子，注入排序键初值（'name' / 'time'）。生产路径
  /// initState 异步从 settings.json 读取；测试注入避免触 path_provider。
  final String? sortKeyOverride;

  /// BATCH-27c-4: 测试钩子，注入排序方向初值（true=升序 / false=降序）。
  final bool? sortAscOverride;

  /// BATCH-27c-2 测试钩子：注入 servers 列表 + selectedId，跳过
  /// servers.json IO。生产路径 initState 异步加载。
  final List<RemoteServer>? serversOverride;
  final int? selectedRemoteServerIdOverride;

  const RemoteBooksPage({
    super.key,
    this.dbPathOverride,
    this.documentsDirOverride,
    this.credentialsOverride,
    this.listDirOverride,
    this.downloadFileOverride,
    this.importLocalBookOverride,
    this.remoteBookRunnerOverride,
    this.sortKeyOverride,
    this.sortAscOverride,
    this.serversOverride,
    this.selectedRemoteServerIdOverride,
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

  // BATCH-27c-2: 多 server 状态。serversOverride 优先 → 初始读 disk →
  // 用户 CRUD 后内存里持有，关 BottomSheet 时 ref 与 disk 都同步。
  List<RemoteServer> _servers = const <RemoteServer>[];
  int _selectedRemoteServerId = kDefaultRemoteServerId;

  // 列目录状态
  bool _entriesLoading = false;
  String? _entriesError;
  List<_RemoteEntry> _entries = const [];

  /// seq token：路径快速切换时让旧 future 不覆盖新结果。
  /// 对齐 [`async-and-mounted.md`] + [`列表 reactivity 模式`] BATCH-21
  /// (F-W2B-019) 防"幽灵覆盖"模板。
  int _loadSeq = 0;

  // BATCH-27c-3: 多选模式状态
  /// 选择模式开关。长按文件 → true；下钻 / 「取消」/「下载选中」/ OS back
  /// 都退出（false）。
  bool _selectionMode = false;

  /// 已选中的文件 remotePath 集合（含路径前缀，如 `books/小说/foo.epub`）。
  /// 用 remotePath 而非 file name：跨目录概念上不可能（下钻 clear），但
  /// remotePath 与 RemoteBookJob 的 dedup key 一致，enqueue 时不需重新组
  /// 装。
  final Set<String> _selectedPaths = <String>{};

  /// runner 进度监听 + 最近一帧的 progress 快照。`_lastProgress` 用于
  /// AppBar transient badge 渲染条件 + 文案。
  StreamSubscription<RemoteBookProgress>? _progressSub;
  RemoteBookProgress? _lastProgress;

  // BATCH-27c-4: 排序 state（持久化到 settings.json `remoteBookSortKey` /
  // `remoteBookSortAsc`）。'time' / 'name'，default 'time' 对齐原 legado
  // RemoteBookSort.Default。下钻时**保留**（跨目录持久），跨启动从 disk
  // 加载用户偏好。
  String _sortKey = 'time';
  bool _sortAsc = true;

  // BATCH-27c-4: 搜索 state。三 mode 互斥（普通/选择/搜索）；进搜索 = 清
  // selection；进选择 = 清搜索。下钻 = 清搜索 query + 退搜索模式（每个目
  // 录独立搜索语境，PRD §R7）。
  bool _searchMode = false;
  String _searchQuery = '';
  Timer? _searchDebounce;
  final TextEditingController _searchController = TextEditingController();

  RemoteBookRunner get _runner =>
      widget.remoteBookRunnerOverride ?? RemoteBookRunner();

  /// BATCH-27c-4: 派生 visible entries —— 排序 + 搜索过滤后的视图。
  /// 不缓存（每帧 build 重算）：N 通常 ≤ 数百，sort + filter 开销 µs 级；
  /// 缓存反而要在每个 set state 路径维护一致性，得不偿失。
  /// 文件夹永远在前（对齐原 legado `compareBy { !it.isDir }` 优先级）。
  List<_RemoteEntry> get _visibleEntries {
    // 先 sort 一份完整副本（不动 _entries 自身）
    final sorted = List<_RemoteEntry>.of(_entries);
    sorted.sort((a, b) {
      // 1. 文件夹永远在前
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      // 2. 按 sortKey + sortAsc
      int cmp;
      if (_sortKey == 'name') {
        cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      } else {
        // 'time'：lastModified 缺时按 0 比，缺的项排到前/后由升降决定
        final at = a.lastModified ?? 0;
        final bt = b.lastModified ?? 0;
        cmp = at.compareTo(bt);
      }
      return _sortAsc ? cmp : -cmp;
    });
    // 再 filter（query 空时跳过）
    if (_searchQuery.isEmpty) return sorted;
    final q = _searchQuery.toLowerCase();
    return sorted.where((e) => e.name.toLowerCase().contains(q)).toList();
  }

  @override
  void initState() {
    super.initState();
    // BATCH-27c-2: 优先读 *Override → 默认 -1 / 空列表，实际加载在
    // _loadServersAndSelectedIdThenBootstrap 内异步走 disk。生产路径
    // main.dart 启动时已 load selectedRemoteServerId provider，这里
    // 仅 fallback。
    _selectedRemoteServerId =
        widget.selectedRemoteServerIdOverride ?? kDefaultRemoteServerId;
    _servers = widget.serversOverride ?? const <RemoteServer>[];
    _loadServersAndSelectedIdThenBootstrap();
    _loadSortPrefs();
    // BATCH-27c-3: 挂 progress 监听。runner 是 singleton —— 即使其它入口
    // （未来 batch-deep-cache 等）也能共享同一进度通道。dispose 时 cancel
    // 避免旧 page 的 setState 在 unmount 后被触发。
    _progressSub = _runner.onProgress.listen((p) {
      if (!mounted) return;
      safeSetState(() {
        _lastProgress = p;
      });
      if (p.isDone) {
        // invalidate 让书架重新拉书
        ref.invalidate(allBooksProvider);
        ref.invalidate(booksByGroupProvider);
        if (mounted) {
          final messenger = ScaffoldMessenger.of(context);
          messenger.hideCurrentSnackBar();
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                '批量下载完成：成功 ${p.success} / 失败 ${p.fail}',
              ),
            ),
          );
          // done 后清掉 transient badge（下次 enqueue 会重新挂上）
          safeSetState(() => _lastProgress = null);
        }
      }
    });
  }

  /// BATCH-27c-4: initState 异步加载排序偏好。测试钩子优先级最高：传了
  /// override 直接写 plain field，跳过 disk IO。
  Future<void> _loadSortPrefs() async {
    if (widget.sortKeyOverride != null || widget.sortAscOverride != null) {
      _sortKey = widget.sortKeyOverride ?? 'time';
      _sortAsc = widget.sortAscOverride ?? true;
      return;
    }
    try {
      final dir = widget.documentsDirOverride;
      final key = await loadRemoteBookSortKeyFromDisk(directory: dir);
      final asc = await loadRemoteBookSortAscFromDisk(directory: dir);
      if (!mounted) return;
      safeSetState(() {
        _sortKey = key;
        _sortAsc = asc;
      });
    } catch (_) {
      // 损坏文件已被 helper 兜底为 default；catch 仅防极端 IO 异常
    }
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  /// BATCH-27c-2: 异步加载 servers.json + selectedRemoteServerId 然后触发
  /// _bootstrap。`*Override` 注入时跳过 disk 直接 _bootstrap。生产路径走
  /// disk → 同步到 provider state → _bootstrap。
  Future<void> _loadServersAndSelectedIdThenBootstrap() async {
    if (widget.credentialsOverride != null ||
        widget.serversOverride != null ||
        widget.selectedRemoteServerIdOverride != null) {
      // 测试路径：注入 credentialsOverride 跳过 servers / 凭据 IO；
      // 注入 serversOverride / selectedRemoteServerIdOverride 也直接走
      // _bootstrap 用 initState 已设的值。
      await _bootstrap();
      return;
    }
    try {
      final dir = widget.documentsDirOverride ?? await resolvePersistenceDir();
      final servers = await loadRemoteServersFromDisk(directory: dir);
      // selectedRemoteServerIdProvider 在 main.dart 启动时已 load，这里
      // 直接读 provider 拿值（避免再次 IO）。
      final selectedId = ref.read(selectedRemoteServerIdProvider);
      if (!mounted) return;
      safeSetState(() {
        _servers = servers;
        _selectedRemoteServerId = selectedId;
      });
      await _bootstrap();
    } catch (_) {
      // load 失败 fallback 走默认凭据路径
      await _bootstrap();
    }
  }

  /// BATCH-27c-2: 切 server / CRUD 后整页 reset 重新走 _bootstrap。
  /// 「进了不同世界」语义：清 _pathStack / _selectedPaths / _searchQuery /
  /// _credentialsXxx，跳到 loading 态再重新加载凭据 + 根目录。
  Future<void> _resetAndReloadForServerSwitch() async {
    safeSetState(() {
      _pathStack.clear();
      _selectedPaths.clear();
      _selectionMode = false;
      _searchQuery = '';
      _searchController.clear();
      _searchMode = false;
      _entries = const <_RemoteEntry>[];
      _credentialsUrl = null;
      _credentialsUser = null;
      _credentialsPassword = null;
      _credentialsLoading = true;
      _credentialsError = null;
    });
    await _bootstrap();
  }

  /// BATCH-27c-2: AppBar server IconButton 点击 → 弹 ServersBottomSheet。
  /// CRUD 全部走 disk + secure_storage + 同步 provider state；选中 id
  /// 变化时 _resetAndReloadForServerSwitch。
  Future<void> _onPickServer() async {
    final picked = await showServersBottomSheet(
      context: context,
      servers: _servers,
      selectedId: _selectedRemoteServerId,
      onCreate: (server, password) async {
        final next = [..._servers, server];
        await saveRemoteServersToDisk(next,
            directory: widget.documentsDirOverride);
        await saveRemoteServerPassword(server.id, password);
        if (!mounted) return;
        safeSetState(() => _servers = next);
      },
      onUpdate: (server, password) async {
        final next = _servers
            .map((e) => e.id == server.id ? server : e)
            .toList(growable: false);
        await saveRemoteServersToDisk(next,
            directory: widget.documentsDirOverride);
        if (password != null) {
          await saveRemoteServerPassword(server.id, password);
        }
        if (!mounted) return;
        safeSetState(() => _servers = next);
      },
      onDelete: (server) async {
        final next = _servers.where((e) => e.id != server.id).toList();
        await saveRemoteServersToDisk(next,
            directory: widget.documentsDirOverride);
        await saveRemoteServerPassword(server.id, null);
        if (!mounted) return;
        var fallback = false;
        if (server.id == _selectedRemoteServerId) {
          fallback = true;
          await saveSelectedRemoteServerIdToDisk(kDefaultRemoteServerId);
        }
        safeSetState(() {
          _servers = next;
          if (fallback) {
            _selectedRemoteServerId = kDefaultRemoteServerId;
          }
        });
        if (fallback) {
          ref.read(selectedRemoteServerIdProvider.notifier).state =
              kDefaultRemoteServerId;
          // 不在此处 _resetAndReloadForServerSwitch — BottomSheet 关闭后
          // 由 picked 路径或保留 -1 路径决定。删的不是当前 selected 时
          // 仅 _servers 变。删的是 selected 时 picked 取最后一个值仍是
          // 旧 id；下面统一处理：BottomSheet 关闭后若 _selected 已
          // fallback 到 -1 也要重走 bootstrap。
        }
      },
    );
    // BottomSheet 关闭后处理选中 id 变化
    if (!mounted) return;
    if (picked != null && picked != _selectedRemoteServerId) {
      safeSetState(() => _selectedRemoteServerId = picked);
      ref.read(selectedRemoteServerIdProvider.notifier).state = picked;
      await saveSelectedRemoteServerIdToDisk(picked);
      await _resetAndReloadForServerSwitch();
      return;
    }
    // picked == null 但 onDelete 把 _selectedRemoteServerId 改成 -1 →
    // 也需要重走 bootstrap
    final currentProviderId = ref.read(selectedRemoteServerIdProvider);
    if (picked == null && currentProviderId != _selectedRemoteServerId) {
      // 同步并重走
      safeSetState(() => _selectedRemoteServerId = currentProviderId);
      await _resetAndReloadForServerSwitch();
    } else if (picked == null && _selectedRemoteServerId == kDefaultRemoteServerId) {
      // onDelete fallback 路径：_selected 已写为 -1，但用户没新选 server，
      // 进 BottomSheet 前的 selected 可能不是 -1。简化逻辑：永远比对
      // provider 与 local state 不一致就重走。
    }
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
      // BATCH-27c-2: 凭据源按 selectedRemoteServerId 决定。
      // - id == -1 → 走旧 webdav.json + secure_storage:webdav_password
      //   （27c-1 兼容路径）
      // - id > 0 → 从 _servers 找对应 RemoteServer + secure_storage:
      //   webdav_password_<id>
      String url;
      String user;
      String pwd;
      if (_selectedRemoteServerId == kDefaultRemoteServerId) {
        final cfg = await readJsonFile(
          'webdav.json',
          directory: dir,
        );
        url = (cfg?['url'] as String?)?.trim() ?? '';
        user = (cfg?['user'] as String?)?.trim() ?? '';
        pwd = await loadRemoteServerPassword(kDefaultRemoteServerId);
      } else {
        final server =
            _servers.where((s) => s.id == _selectedRemoteServerId).firstOrNull;
        if (server == null) {
          // 选中 server 已被删 / servers.json 损坏 → fallback id=-1
          if (!mounted) return;
          safeSetState(() {
            _selectedRemoteServerId = kDefaultRemoteServerId;
          });
          await saveSelectedRemoteServerIdToDisk(kDefaultRemoteServerId);
          return _bootstrap(); // 用默认凭据重走
        }
        url = server.url.trim();
        user = server.user.trim();
        pwd = await loadRemoteServerPassword(server.id);
      }
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
      // BATCH-27c-4: 不再在此处 sort —— 排序由 [_visibleEntries] getter
      // 按 _sortKey / _sortAsc 派生。保留 _entries 为加载顺序原样，让
      // 排序切换无需 reload。
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
  ///
  /// BATCH-27c-3: 下钻 / 上钻都清空 `_selectedPaths` + 退出选择模式（PRD
  /// §Q1 1b 决策 — 跨目录的 selected 概念混乱）。
  /// BATCH-27c-4: 同步清空 `_searchQuery` + 退出搜索模式（PRD §R7 — 每个
  /// 目录独立搜索语境）；保留排序偏好。
  bool _popPathOrPage() {
    if (_pathStack.isEmpty) return false;
    setState(() {
      _pathStack.removeLast();
      _exitSelectionMode();
      _exitSearchMode();
    });
    // 上钻后立即重 list
    _loadCurrentDir();
    return true;
  }

  /// 当前路径下某 entry 对应的 remotePath（含目录前缀 + 文件名）。
  String _remotePathFor(_RemoteEntry e) =>
      [..._pathStack, e.name].join('/');

  void _exitSelectionMode() {
    _selectionMode = false;
    _selectedPaths.clear();
  }

  /// BATCH-27c-4: 退搜索模式 + 清 query + cancel debounce + 清空 controller。
  /// 不调 setState（caller 用 setState 包），允许多 path 复合（_popPathOrPage
  /// 一次 setState 同时 reset selection + search）。
  void _exitSearchMode() {
    _searchMode = false;
    _searchQuery = '';
    _searchDebounce?.cancel();
    _searchDebounce = null;
    _searchController.clear();
  }

  /// BATCH-27c-4: 进搜索模式（mode 互斥 — 自动清 selection）。
  void _enterSearchMode() {
    setState(() {
      _exitSelectionMode();
      _searchMode = true;
    });
  }

  /// BATCH-27c-4: 进选择模式（mode 互斥 — 自动清 search）。caller 在 setState
  /// 内自己加入 _selectedPaths 项。
  void _enterSelectionMode() {
    _exitSearchMode();
    _selectionMode = true;
  }

  void _toggleSelected(_RemoteEntry e) {
    if (e.isDir) return; // 文件夹不可勾（PRD §Q1 1b）
    final path = _remotePathFor(e);
    setState(() {
      if (_selectedPaths.contains(path)) {
        _selectedPaths.remove(path);
      } else {
        _selectedPaths.add(path);
      }
      // 全部取消时退出选择模式
      if (_selectedPaths.isEmpty) {
        _selectionMode = false;
      }
    });
  }

  /// 长按 entry → 进入选择模式 + 勾上当前项（仅文件项）。
  /// BATCH-27c-4: 搜索模式下长按忽略（mode 互斥；用户先关搜索再多选）。
  void _onLongPressEntry(_RemoteEntry e) {
    if (e.isDir) return; // 文件夹长按忽略（PRD §Q1 1b）
    if (_searchMode) return; // BATCH-27c-4: 搜索模式不支持长按选择
    final path = _remotePathFor(e);
    setState(() {
      _enterSelectionMode();
      _selectedPaths.add(path);
    });
  }

  /// 全选：勾上当前目录所有文件项（跳过文件夹）。
  void _selectAllFiles() {
    setState(() {
      for (final e in _entries) {
        if (!e.isDir) {
          _selectedPaths.add(_remotePathFor(e));
        }
      }
    });
  }

  /// 取消所有勾选 + 退出选择模式。
  void _cancelSelection() {
    setState(_exitSelectionMode);
  }

  Future<void> _onTapEntry(_RemoteEntry e) async {
    // 选择模式下：点 ListTile = toggle 选中（文件夹仍下钻）
    if (_selectionMode) {
      if (e.isDir) {
        // 下钻清空 selection + 清搜索（PRD §Q1 1b + R7）
        setState(() {
          _pathStack.add(e.name);
          _exitSelectionMode();
          _exitSearchMode();
        });
        await _loadCurrentDir();
        return;
      }
      _toggleSelected(e);
      return;
    }
    // 非选择模式
    if (e.isDir) {
      // BATCH-27c-4: 下钻保留排序偏好；清空搜索 query + 退搜索模式（PRD §R7）
      setState(() {
        _pathStack.add(e.name);
        _exitSearchMode();
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
      final remotePath = _remotePathFor(e);
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

  /// BATCH-27c-3: 「下载选中」批量入口。把 `_selectedPaths` 中的文件项构
  /// 成 [`RemoteBookJob`] 列表 → enqueue 到 [`RemoteBookRunner`] singleton
  /// → 立即退出选择模式。runner 后台串行下载 + 入库；进度通过 progress
  /// listener 写到 `_lastProgress` 触发 transient badge 渲染。
  Future<void> _onDownloadSelected() async {
    if (_selectedPaths.isEmpty) return;
    if (_credentialsUrl == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final docsDir =
          widget.documentsDirOverride ?? await resolvePersistenceDir();
      if (!mounted) return;
      final remoteDir = Directory('$docsDir/remote_books');
      if (!remoteDir.existsSync()) {
        remoteDir.createSync(recursive: true);
      }
      final String dbPath =
          widget.dbPathOverride ?? await ref.read(dbPathProvider.future);
      if (!mounted) return;

      // 把 selected paths（remotePath 集合）映射到 _entries 的 file 项，
      // 拿到原 name 用于 _safeFileName。entries 中不在的 path 跳过（理论
      // 上不可能 — selectionMode 下只勾 _entries 里的文件）。
      final pathToName = <String, String>{
        for (final e in _entries)
          if (!e.isDir) _remotePathFor(e): e.name,
      };
      final jobs = <RemoteBookJob>[];
      for (final path in _selectedPaths) {
        final name = pathToName[path];
        if (name == null) continue;
        final safeName = _safeFileName(name);
        final localPath = '${remoteDir.path}/$safeName';
        jobs.add(RemoteBookJob(
          url: _credentialsUrl!,
          user: _credentialsUser!,
          password: _credentialsPassword!,
          remotePath: path,
          targetLocalPath: localPath,
          dbPath: dbPath,
          documentsDir: docsDir,
        ));
      }
      if (jobs.isEmpty) return;

      // ignore: discarded_futures — enqueue 内部 fire-and-forget 启 worker，
      // 调用方靠 onProgress 监听完成；此处不能 await，否则 SnackBar 在跑
      // 完前不会弹。
      _runner.enqueue(
        jobs,
        downloadOverride: widget.downloadFileOverride,
        importOverride: widget.importLocalBookOverride,
      );
      final count = jobs.length;
      // 立即退出选择模式让 AppBar 复原 + transient badge 显现
      setState(_exitSelectionMode);
      messenger.showSnackBar(
        SnackBar(content: Text('已开始下载 $count 本远程书')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('启动下载失败: $e')),
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
    return PopScope(
      // 选择模式 / 搜索模式 / 路径栈非空 → 拦默认 pop
      canPop:
          !_selectionMode && !_searchMode && _pathStack.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // 优先级：选择模式 → 搜索模式 → path 栈 → 页面（默认）
        if (_selectionMode) {
          _cancelSelection();
          return;
        }
        if (_searchMode) {
          setState(_exitSearchMode);
          return;
        }
        if (_pathStack.isNotEmpty) {
          _popPathOrPage();
        }
      },
      child: Scaffold(
        appBar: _buildAppBar(context),
        body: _buildBody(context),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    if (_selectionMode) {
      return AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: '取消',
          onPressed: _cancelSelection,
        ),
        title: Text('选择 ${_selectedPaths.length} 项'),
        actions: [
          IconButton(
            icon: const Icon(Icons.select_all),
            tooltip: '全选',
            onPressed: _selectAllFiles,
          ),
          IconButton(
            icon: const Icon(Icons.download_outlined),
            tooltip: '下载选中',
            onPressed:
                _selectedPaths.isEmpty ? null : _onDownloadSelected,
          ),
        ],
      );
    }
    if (_searchMode) {
      // BATCH-27c-4: 搜索模式 AppBar — title 改 TextField + close leading +
      // actions 全清（避免 AppBar 拥挤；transient badge 让位）。
      return AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: '关闭搜索',
          onPressed: () => setState(_exitSearchMode),
        ),
        title: TextField(
          controller: _searchController,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '搜索文件名',
            border: InputBorder.none,
          ),
          onChanged: _onSearchChanged,
        ),
      );
    }
    final pathDisplay =
        _pathStack.isEmpty ? '/' : '/${_pathStack.join('/')}';
    return AppBar(
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
      actions: [
        // BATCH-27c-2: server 切换 IconButton（普通模式 only）。优先级
        // 最高（actions[0]），点击弹 ServersBottomSheet 切 server / CRUD。
        IconButton(
          icon: const Icon(Icons.dns_outlined),
          tooltip: '切换 WebDAV 服务器',
          onPressed: _onPickServer,
        ),
        // BATCH-27c-4: 搜索 IconButton —— 切到搜索模式
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: '搜索',
          onPressed: _enterSearchMode,
        ),
        // BATCH-27c-4: 排序 PopupMenu —— 4 项（名称/时间 × 升/降），trailing
        // check 标当前选中。对齐原 legado `menu_sort` 子菜单 + isChecked。
        PopupMenuButton<String>(
          icon: const Icon(Icons.sort),
          tooltip: '排序',
          onSelected: _onSortSelected,
          itemBuilder: (_) => _buildSortMenuItems(),
        ),
        // BATCH-27c-3: 批量下载进度 transient badge —— 仅 isRunning 时
        // 渲染，跑完自动消失。点击不取消（cancel UX 留 follow-up）。
        if (_lastProgress != null && _lastProgress!.isRunning)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Tooltip(
              message:
                  '远程书下载中 ${_lastProgress!.processed}/${_lastProgress!.total}',
              child: SizedBox(
                width: 40,
                child: Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    Positioned(
                      right: -8,
                      top: -2,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${_lastProgress!.processed}/${_lastProgress!.total}',
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.surface,
                              fontSize: 10,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// BATCH-27c-4: 排序 PopupMenu 4 项 + trailing check 标当前选中。值用
  /// `key|asc` 复合 String（'name|true' / 'name|false' / 'time|true' /
  /// 'time|false'），onSelected 反解。
  List<PopupMenuEntry<String>> _buildSortMenuItems() {
    PopupMenuItem<String> item(String label, String key, bool asc) {
      final selected = _sortKey == key && _sortAsc == asc;
      return PopupMenuItem<String>(
        value: '$key|$asc',
        child: Row(
          children: [
            Expanded(child: Text(label)),
            if (selected) const Icon(Icons.check, size: 18),
          ],
        ),
      );
    }

    return [
      item('按名称（升）', 'name', true),
      item('按名称（降）', 'name', false),
      item('按时间（升）', 'time', true),
      item('按时间（降）', 'time', false),
    ];
  }

  void _onSortSelected(String value) {
    final parts = value.split('|');
    if (parts.length != 2) return;
    final key = parts[0];
    final asc = parts[1] == 'true';
    if (_sortKey == key && _sortAsc == asc) return;
    setState(() {
      _sortKey = key;
      _sortAsc = asc;
    });
    // fire-and-forget 持久化；失败 helper 静默处理（errorTag debugPrint）
    final dir = widget.documentsDirOverride;
    saveRemoteBookSortKeyToDisk(key, directory: dir);
    saveRemoteBookSortAscToDisk(asc, directory: dir);
  }

  /// BATCH-27c-4: 搜索 onChanged —— TextField 立即视觉反馈（controller 自
  /// 带），debounce 300ms 后才写 _searchQuery + setState 重排 ListView。
  /// 空 query 立即清 filter（不走 debounce），避免清空时还要等 300ms。
  void _onSearchChanged(String text) {
    _searchDebounce?.cancel();
    if (text.isEmpty) {
      setState(() => _searchQuery = '');
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _searchQuery = text);
    });
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
    // BATCH-27c-4: 渲染 _visibleEntries（排序 + 搜索过滤后的派生视图）。
    // 当 _entries 非空但搜索 query 过滤光时，_visibleEntries 可能为空 —
    // 单独提示「无匹配项」让用户知道是搜索没命中而非目录空。
    final view = _visibleEntries;
    if (view.isEmpty) {
      return Center(
        child: Text(_searchQuery.isEmpty ? '此目录为空' : '无匹配项'),
      );
    }
    return ListView.builder(
      itemCount: view.length,
      itemBuilder: (context, index) {
        final e = view[index];
        final selected =
            !e.isDir && _selectedPaths.contains(_remotePathFor(e));
        return ListTile(
          leading: _selectionMode && !e.isDir
              ? Checkbox(
                  value: selected,
                  // ListTile.onTap 已 toggle；Checkbox 自身的 onChanged
                  // 仅为视觉响应（点 checkbox 时也走 toggle）。
                  onChanged: (_) => _toggleSelected(e),
                )
              : Icon(
                  e.isDir ? Icons.folder_outlined : Icons.book_outlined,
                ),
          title: Text(e.name),
          subtitle: e.isDir ? null : Text(_subtitleFor(e)),
          trailing: _selectionMode
              ? null
              : Icon(
                  e.isDir ? Icons.chevron_right : Icons.download_outlined,
                ),
          selected: selected,
          onTap: () => _onTapEntry(e),
          onLongPress: () => _onLongPressEntry(e),
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
