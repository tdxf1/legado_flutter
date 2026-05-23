import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/colors.dart';
import '../../core/persistence/json_store.dart';
import '../../core/providers.dart';
import '../../core/widgets/safe_setstate.dart';
import '../../src/rust/api.dart' as rust_api;

/// 书信息编辑页（批次 9 / 05-19）。
///
/// 对齐原 Legado `BookInfoEditActivity.kt`：5 字段编辑（书名 / 作者 / 分类 /
/// 简介 / 封面）。封面通过 [FilePicker] 选本地图片 → 复制到
/// `<documentsDir>/covers/<bookId>_<timestampMs>.<ext>` → 写入
/// `book.custom_cover_path`。保存后通过桥 [`saveBook`] upsert 到
/// SQLite，并 invalidate 书架相关 providers 让书架立刻刷新。
///
/// **入口**：GoRouter `/book-info-edit?bookId=xxx`。Bookshelf 长按 sheet
/// 加 "编辑信息" 项触发跳转。进页后通过 [bookByIdProvider] 拿到完整 book
/// Map（含批次 6 加的 dur_chapter_* / group_id 等），保存时按
/// [_buildSavedBookJson] 走 "复制旧 Map + 覆盖 5 字段" 路径，不会丢
/// 任何未编辑字段（与 reader_page.dart 同模式）。
class BookInfoEditPage extends ConsumerStatefulWidget {
  final String bookId;

  /// 测试钩子：直接注入完整 book Map，跳过 [bookByIdProvider]。生产代码
  /// 不传该参数。
  final Map<String, dynamic>? initialBook;

  /// 测试钩子：注入 fake saveBook（避免 widget test 调真 FRB 桥）。
  final Future<void> Function({required String dbPath, required String bookJson})?
      saveBookOverride;

  /// 测试钩子：注入假的 dbPath future（避免 widget test 走 path_provider）。
  final Future<String>? dbPathOverride;

  const BookInfoEditPage({
    super.key,
    required this.bookId,
    this.initialBook,
    this.saveBookOverride,
    this.dbPathOverride,
  });

  @override
  ConsumerState<BookInfoEditPage> createState() => _BookInfoEditPageState();
}

class _BookInfoEditPageState extends ConsumerState<BookInfoEditPage> {
  TextEditingController? _nameCtl;
  TextEditingController? _authorCtl;
  TextEditingController? _kindCtl;
  TextEditingController? _introCtl;

  /// 当前 custom_cover_path（本地文件路径）。点击封面区选图后即刻更新，
  /// 用于预览；`保存`时一并写入 book JSON。
  String? _customCoverPath;

  /// 本地缓存当前正在编辑的 book Map。初始化后 [_initFromBook] 写入；
  /// 保存时复制此 Map + 覆盖编辑过的字段（不丢 dur_chapter_* / group_id
  /// 等系统字段）。
  Map<String, dynamic>? _bookSnapshot;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialBook != null) {
      _initFromBook(widget.initialBook!);
    }
  }

  void _initFromBook(Map<String, dynamic> book) {
    _bookSnapshot = book;
    _nameCtl?.dispose();
    _authorCtl?.dispose();
    _kindCtl?.dispose();
    _introCtl?.dispose();
    _nameCtl = TextEditingController(text: (book['name'] as String?) ?? '');
    _authorCtl =
        TextEditingController(text: (book['author'] as String?) ?? '');
    _kindCtl = TextEditingController(text: (book['kind'] as String?) ?? '');
    _introCtl = TextEditingController(text: (book['intro'] as String?) ?? '');
    _customCoverPath = book['custom_cover_path'] as String?;
    // 触发 "name 是否为空" 重渲染（保存按钮 disabled 状态依赖此值）。
    _nameCtl!.addListener(() {
      safeSetState(() {});
    });
  }

  @override
  void dispose() {
    _nameCtl?.dispose();
    _authorCtl?.dispose();
    _kindCtl?.dispose();
    _introCtl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 没有 initialBook 时通过 bookByIdProvider 拉书，拉到后再初始化 controllers。
    if (_bookSnapshot == null) {
      final bookAsync = ref.watch(bookByIdProvider(widget.bookId));
      return bookAsync.when(
        loading: () => _buildLoadingScaffold(),
        error: (e, _) => _buildErrorScaffold('加载失败: $e'),
        data: (book) {
          if (book == null) {
            return _buildErrorScaffold('书籍不存在: ${widget.bookId}');
          }
          // 在下一帧 setState 初始化（避免在 build 过程中调 setState）。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() => _initFromBook(book));
          });
          return _buildLoadingScaffold();
        },
      );
    }
    return _buildEditScaffold();
  }

  Widget _buildLoadingScaffold() {
    return Scaffold(
      appBar: AppBar(title: const Text('编辑书籍信息')),
      body: const Center(child: CircularProgressIndicator()),
    );
  }

  Widget _buildErrorScaffold(String msg) {
    return Scaffold(
      appBar: AppBar(title: const Text('编辑书籍信息')),
      body: Center(child: Text(msg)),
    );
  }

  Widget _buildEditScaffold() {
    final canSave = (_nameCtl?.text.trim().isNotEmpty ?? false) && !_saving;
    return Scaffold(
      appBar: AppBar(
        title: const Text('编辑书籍信息'),
        actions: [
          TextButton(
            onPressed: canSave ? _onSave : null,
            child: const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildCoverSection(context),
          const SizedBox(height: 24),
          TextField(
            controller: _nameCtl,
            decoration: const InputDecoration(
              labelText: '书名',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _authorCtl,
            decoration: const InputDecoration(
              labelText: '作者',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _kindCtl,
            decoration: const InputDecoration(
              labelText: '分类',
              hintText: '例如：玄幻 / 都市 / 科幻',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _introCtl,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: '简介',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCoverSection(BuildContext context) {
    return Center(
      child: InkWell(
        onTap: _saving ? null : _pickCover,
        child: SizedBox(
          width: 120,
          height: 180,
          child: _buildCoverPreview(),
        ),
      ),
    );
  }

  /// 封面预览。优先 [_customCoverPath] → 网络封面 → 占位 icon。
  /// 与 [`bookshelf_page.dart`] `_buildCover` 同思路（本地优先，损坏回落
  /// 网络 / 占位），但 editor 单独写一个简化版避免依赖 cached_network_image
  /// （编辑页只在选图时短暂展示，不需要 cache）。
  Widget _buildCoverPreview() {
    final localPath = _customCoverPath;
    if (localPath != null && localPath.isNotEmpty) {
      return Image.file(
        File(localPath),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildCoverPlaceholder(),
      );
    }
    final coverUrl = _bookSnapshot?['cover_url'] as String?;
    if (coverUrl != null && coverUrl.isNotEmpty) {
      return Image.network(
        coverUrl,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildCoverPlaceholder(),
      );
    }
    return _buildCoverPlaceholder();
  }

  Widget _buildCoverPlaceholder() {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.add_a_photo_outlined,
              size: 36, color: context.al.onSurface),
          const SizedBox(height: 4),
          Text(
            '点击选择封面',
            style: TextStyle(color: context.al.onSurface, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Future<void> _pickCover() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;
      final picked = result.files.single;
      final src = picked.path;
      if (src == null || src.isEmpty) return;
      final bookId = widget.bookId;
      if (bookId.isEmpty) return;
      final saved = await _copyCoverToCoversDir(srcPath: src, bookId: bookId);
      if (!mounted) return;
      setState(() => _customCoverPath = saved);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('封面选择失败: $e')),
      );
    }
  }

  /// 把选中的图片复制到 `<documentsDir>/covers/<bookId>_<timestampMs>.<ext>`。
  /// `covers/` 目录不存在时 mkdir。返回新文件路径。
  ///
  /// 用 timestamp 而非覆盖原文件名是为了：
  /// 1. 同一本书换多次封面时旧文件不立即被覆盖（删除策略留 GC 批次做）
  /// 2. 避免源文件名带特殊字符（中文 / 空格）引发跨平台路径问题
  Future<String> _copyCoverToCoversDir({
    required String srcPath,
    required String bookId,
  }) async {
    // BATCH-18e (F-W2B-022)：走统一的 resolvePersistenceDir。
    final dir = await resolvePersistenceDir();
    final coversDir = Directory('$dir/covers');
    if (!await coversDir.exists()) {
      await coversDir.create(recursive: true);
    }
    // 拿原扩展名（带点），找不到默认 .jpg。
    final dotIdx = srcPath.lastIndexOf('.');
    final ext = (dotIdx >= 0 && dotIdx < srcPath.length - 1)
        ? srcPath.substring(dotIdx)
        : '.jpg';
    final ts = DateTime.now().millisecondsSinceEpoch;
    final destPath = '${coversDir.path}/${bookId}_$ts$ext';
    await File(srcPath).copy(destPath);
    return destPath;
  }

  Future<void> _onSave() async {
    if (_saving) return;
    if (_bookSnapshot == null) return;
    setState(() => _saving = true);
    try {
      final Future<String> dbPathFuture =
          widget.dbPathOverride ?? ref.read(dbPathProvider.future);
      final String dbPath = await dbPathFuture;
      if (!mounted) return;
      final bookJson = _buildSavedBookJson();
      final override = widget.saveBookOverride;
      if (override != null) {
        await override(dbPath: dbPath, bookJson: bookJson);
      } else {
        await rust_api.saveBook(dbPath: dbPath, bookJson: bookJson);
      }
      if (!mounted) return;
      // 让书架重新拉书 + bookByIdProvider 拿到最新 book Map。
      ref.invalidate(allBooksProvider);
      ref.invalidate(booksByGroupProvider);
      final bookId = widget.bookId;
      if (bookId.isNotEmpty) {
        ref.invalidate(bookByIdProvider(bookId));
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('保存成功')),
      );
      if (context.canPop()) {
        context.pop();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: $e')),
      );
    } finally {
      safeSetState(() => _saving = false);
    }
  }

  /// 用 "复制旧 Map + 覆盖编辑过的 5 字段" 模式构造 Book JSON：
  /// 这样不会丢 batch 6 加的 dur_chapter_* / group_id 等字段，也不会
  /// 无意中重置 created_at / order_time / source_id 等系统维护字段。
  /// 与 reader_page.dart::_replaceSourceAndRefreshChapters 同模式。
  String _buildSavedBookJson() {
    final updated = Map<String, dynamic>.from(_bookSnapshot!);
    updated['name'] = _nameCtl?.text.trim() ?? '';
    updated['author'] = _emptyToNull(_authorCtl?.text ?? '');
    updated['kind'] = _emptyToNull(_kindCtl?.text ?? '');
    updated['intro'] = _emptyToNull(_introCtl?.text ?? '');
    updated['custom_cover_path'] = _customCoverPath;
    updated['updated_at'] = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return jsonEncode(updated);
  }

  String? _emptyToNull(String s) {
    final t = s.trim();
    return t.isEmpty ? null : t;
  }
}
