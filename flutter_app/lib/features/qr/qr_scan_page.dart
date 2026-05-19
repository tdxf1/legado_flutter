import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'legado_qr_protocol.dart';
import 'qr_import_handler.dart';

/// QR 扫码导入页（批次 20 / 05-19）。
///
/// 入口：bookshelf_page PopupMenu / source_page / rss_source_manage_page /
/// rule_sub_page 各 AppBar IconButton(qr_code_scanner) → `context.push('/qr-scan')`。
///
/// 渲染：
/// - 真实模式：[MobileScanner] 全屏 + 中间 240x240 透明扫码框遮罩
/// - 测试模式（[scanResultOverride] 非 null）：跳过相机，[Container] 占位
///   + initState 后立即调 [_onDetect]
///
/// AppBar.actions：
/// - 手电筒 IconButton（toggleTorch）
/// - 切换前后摄像头 IconButton（switchCamera）
///
/// 检测流程：
/// 1. 防重复：[_detected] flag，第一条二维码就停后续 onDetect 回调
/// 2. parseLegadoQrPayload(rawValue)
///    - null → AlertDialog "未识别为 Legado 协议"，附原始内容（可手动复制）
///    - 否则 → AlertDialog "确认导入" 显示类型 + URL → 用户点"导入"
///      → [QrImportHandler.handle] → SnackBar 反馈 → context.pop()
class QrScanPage extends ConsumerStatefulWidget {
  /// 测试钩子：注入假扫码结果。非 null 时不启动相机，initState 立即走
  /// [_onDetect](scanResultOverride)。生产代码不传。
  final String? scanResultOverride;

  /// 测试钩子：注入假 dbPath，绕过 [dbPathProvider]。
  final String? dbPathOverride;

  /// 测试钩子：注入假 fetchUrl 实现，绕过 dio。
  final Future<String> Function(String url)? fetchUrlOverride;

  /// 测试钩子：注入假 importBookSources（FRB）。
  final Future<int> Function(String dbPath, String json)?
      importBookSourcesOverride;

  /// 测试钩子：注入假 importRssSources（FRB）。
  final Future<String> Function(String dbPath, String json)?
      importRssSourcesOverride;

  /// 测试钩子：注入假 createRuleSub（FRB）。
  final Future<String> Function(
    String dbPath,
    String name,
    String url,
    int subType,
  )? createRuleSubOverride;

  /// 测试钩子：注入假 refreshRuleSub（FRB）。
  final Future<String> Function(String dbPath, String id)?
      refreshRuleSubOverride;

  const QrScanPage({
    super.key,
    this.scanResultOverride,
    this.dbPathOverride,
    this.fetchUrlOverride,
    this.importBookSourcesOverride,
    this.importRssSourcesOverride,
    this.createRuleSubOverride,
    this.refreshRuleSubOverride,
  });

  @override
  ConsumerState<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends ConsumerState<QrScanPage> {
  /// 仅生产模式下创建。测试模式 / web 留 null（[MobileScanner] 不渲染）。
  MobileScannerController? _controller;

  /// 防重复扫码：第一条二维码触发后置 true，后续 onDetect 直接 return。
  bool _detected = false;

  /// 真实运行模式（非测试钩子模式 + 平台支持）。
  bool get _isRealCameraMode =>
      !kIsWeb && widget.scanResultOverride == null;

  @override
  void initState() {
    super.initState();
    if (_isRealCameraMode) {
      _controller = MobileScannerController(
        // 防快速重复扫码
        detectionTimeoutMs: 1000,
      );
    }
    // 测试模式：跳过相机直接走假扫码结果。在第一帧后调，避免 initState
    // 直接弹 dialog 时上下文还没准备好。
    if (widget.scanResultOverride != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onDetect(widget.scanResultOverride!);
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  /// 二维码解析 + 弹窗 + import 处理。所有路径都不要直接 return without
  /// 重置 _detected — 用户取消导入应该可以再扫；但成功导入后 page 会 pop，
  /// 不需要重置。失败也保持 _detected=true 防止抖动连续弹 dialog；用户
  /// 可以返回再进。
  Future<void> _onDetect(String raw) async {
    if (_detected) return;
    _detected = true;
    final parsed = parseLegadoQrPayload(raw);
    if (!mounted) return;
    if (parsed == null) {
      await _showUnrecognizedDialog(raw);
      return;
    }
    final confirmed = await _showConfirmDialog(parsed);
    if (confirmed != true) {
      // 用户取消，允许继续扫
      _detected = false;
      return;
    }
    if (!mounted) return;
    // 提示"正在导入"
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('正在导入...')),
    );
    String result;
    try {
      result = await QrImportHandler.handle(
        ref,
        parsed,
        dbPathOverride: widget.dbPathOverride,
        fetchUrlOverride: widget.fetchUrlOverride,
        importBookSourcesOverride: widget.importBookSourcesOverride,
        importRssSourcesOverride: widget.importRssSourcesOverride,
        createRuleSubOverride: widget.createRuleSubOverride,
        refreshRuleSubOverride: widget.refreshRuleSubOverride,
      );
    } catch (e) {
      result = '导入失败: $e';
    }
    if (!mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(result)));
    // 成功 / 失败都返回上一页（用户可以再次进入扫码页重试）
    if (context.canPop()) {
      context.pop();
    }
  }

  Future<void> _showUnrecognizedDialog(String raw) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('未识别为 Legado 协议'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('扫到的内容：'),
              const SizedBox(height: 8),
              SelectableText(raw),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: raw));
            },
            child: const Text('复制'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    // 返回上一页（避免持续扫到同一个无效二维码反复弹窗）
    if (mounted && context.canPop()) {
      context.pop();
    }
  }

  Future<bool?> _showConfirmDialog(ParsedLegadoQr parsed) async {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认导入'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('类型：${legadoQrTypeLabel(parsed.type)}'),
              const SizedBox(height: 8),
              const Text('源 URL：'),
              const SizedBox(height: 4),
              SelectableText(parsed.fetchUrl),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
  }

  void _toggleTorch() {
    final c = _controller;
    if (c == null) return;
    c.toggleTorch();
  }

  void _switchCamera() {
    final c = _controller;
    if (c == null) return;
    c.switchCamera();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('扫码导入'),
        actions: [
          if (_isRealCameraMode)
            IconButton(
              icon: const Icon(Icons.flash_on),
              tooltip: '手电筒',
              onPressed: _toggleTorch,
            ),
          if (_isRealCameraMode)
            IconButton(
              icon: const Icon(Icons.cameraswitch),
              tooltip: '切换摄像头',
              onPressed: _switchCamera,
            ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (!_isRealCameraMode) {
      // 测试 / web fallback：占位即可，实际扫码结果靠 scanResultOverride
      return const ColoredBox(
        color: Colors.black,
        child: Center(
          child: Text(
            '相机不可用',
            style: TextStyle(color: Colors.white70),
          ),
        ),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          controller: _controller,
          onDetect: (capture) {
            if (_detected) return;
            for (final b in capture.barcodes) {
              final raw = b.rawValue;
              if (raw != null && raw.isNotEmpty) {
                _onDetect(raw);
                break;
              }
            }
          },
        ),
        // 半透明遮罩 + 中间镂空扫码框
        const _ScanOverlay(),
      ],
    );
  }
}

/// 半透明遮罩 + 中间 240x240 透明扫码框 + 4 个 L 角装饰。
class _ScanOverlay extends StatelessWidget {
  const _ScanOverlay();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: Colors.black.withValues(alpha: 0.4)),
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white70, width: 2),
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          const Positioned(
            bottom: 64,
            left: 0,
            right: 0,
            child: Center(
              child: Text(
                '将二维码对准框内',
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
