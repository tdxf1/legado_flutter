import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/colors.dart';
import '../../core/security/webview_safety.dart';
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

  /// 测试钩子：直接置位"相机权限被拒"状态，跳过 mobile_scanner，UI 显示
  /// 拒绝引导文案 + 返回按钮。生产代码不传（默认 false）。
  /// 引入：BATCH-05 / F-W2B-058。
  final bool permissionDeniedOverride;

  const QrScanPage({
    super.key,
    this.scanResultOverride,
    this.dbPathOverride,
    this.fetchUrlOverride,
    this.importBookSourcesOverride,
    this.importRssSourcesOverride,
    this.createRuleSubOverride,
    this.refreshRuleSubOverride,
    this.permissionDeniedOverride = false,
  });

  @override
  ConsumerState<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends ConsumerState<QrScanPage> {
  /// 仅生产模式下创建。测试模式 / web 留 null（[MobileScanner] 不渲染）。
  MobileScannerController? _controller;

  /// 防重复扫码：第一条二维码触发后置 true，后续 onDetect 直接 return。
  bool _detected = false;

  /// 相机权限拒绝标志（BATCH-05 / F-W2B-058）。监听 controller 的
  /// [ValueNotifier]，[MobileScannerState.error] 含 [permissionDenied]
  /// errorCode 时翻 true，UI 切到 [_PermissionDeniedView]。
  bool _permissionDenied = false;

  /// 真实运行模式（非测试钩子模式 + 平台支持）。
  bool get _isRealCameraMode =>
      !kIsWeb && widget.scanResultOverride == null;

  @override
  void initState() {
    super.initState();
    // 测试钩子优先：直接置位拒绝状态，跳过 controller / 扫码路径。
    if (widget.permissionDeniedOverride) {
      _permissionDenied = true;
      return;
    }
    if (_isRealCameraMode) {
      _controller = MobileScannerController(
        // 防快速重复扫码
        detectionTimeoutMs: 1000,
      );
      // BATCH-05 (F-W2B-058): 监听 ValueNotifier，state.error 出现
      // permissionDenied 时切到拒绝 UI。controller 在 dispose 自带
      // removeListener 清理（ValueNotifier dispose 时会自动）。
      _controller!.addListener(_onScannerStateChanged);
    }
    // 测试模式：跳过相机直接走假扫码结果。在第一帧后调，避免 initState
    // 直接弹 dialog 时上下文还没准备好。
    if (widget.scanResultOverride != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onDetect(widget.scanResultOverride!);
      });
    }
  }

  void _onScannerStateChanged() {
    final c = _controller;
    if (c == null) return;
    final err = c.value.error;
    if (err == null) return;
    if (err.errorCode == MobileScannerErrorCode.permissionDenied) {
      if (mounted && !_permissionDenied) {
        setState(() => _permissionDenied = true);
      }
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_onScannerStateChanged);
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
    // BATCH-05 (F-W2B-002): host 风险分类，向用户透出 SSRF 警告。
    final hostClass = classifyHost(parsed.fetchUrl);
    final warningText = switch (hostClass) {
      HostClass.loopback ||
      HostClass.linkLocal ||
      HostClass.privateNetwork =>
        '⚠️ 警告：这是内网/本地地址，可能是 SSRF 攻击。仍要导入吗？',
      HostClass.invalid => '⚠️ 警告：URL 无法解析。',
      HostClass.public => null,
    };
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
              if (warningText != null) ...[
                const SizedBox(height: 12),
                Text(
                  warningText,
                  style: TextStyle(
                    color: Theme.of(ctx).colorScheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
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
    if (_permissionDenied) {
      return const _PermissionDeniedView();
    }
    if (!_isRealCameraMode) {
      // 测试 / web fallback：占位即可，实际扫码结果靠 scanResultOverride
      return ColoredBox(
        color: context.al.scrim,
        child: Center(
          child: Text(
            '相机不可用',
            style: TextStyle(color: Theme.of(context).colorScheme.surface.withAlpha(0xB2)),
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
          ColoredBox(color: context.al.scrim.withValues(alpha: 0.4)),
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(
                    color: Theme.of(context).colorScheme.surface.withAlpha(0xB2), width: 2),
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          Positioned(
            bottom: 64,
            left: 0,
            right: 0,
            child: Center(
              child: Text(
                '将二维码对准框内',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.surface.withAlpha(0xB2),
                    fontSize: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 相机权限被拒时的引导视图（BATCH-05 / F-W2B-058）。引导用户去系统设置
/// 手动开启权限；不引入 permission_handler / app_settings 包跳转 —— 用户
/// 自行操作。
class _PermissionDeniedView extends StatelessWidget {
  const _PermissionDeniedView();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.no_photography,
              size: 64,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              '相机权限被拒绝',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            const Text(
              '请到系统设置 → 应用 → 当前应用 → 权限 中开启相机权限，然后重新进入扫码页。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () {
                if (context.canPop()) {
                  context.pop();
                }
              },
              child: const Text('返回'),
            ),
          ],
        ),
      ),
    );
  }
}
