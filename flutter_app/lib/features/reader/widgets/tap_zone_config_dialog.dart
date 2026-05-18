/// 批次 3 (05-18) — 阅读器 3×3 点击区域配置对话框。
///
/// UI 结构：
/// - 3×3 GridView，每格显示当前动作（图标 + 文字）。点击格子循环切换：
///   prev → next → menu → nothing → prev …
/// - 底部 3 个 ChoiceChip 预设：默认 / 经典 / 全屏菜单（一键覆盖整张 9 格）。
/// - 取消 / 确定按钮。确定后通过 [Navigator.pop] 返回 List<int>（length=9）。
///
/// 不持久化、不读 Riverpod；`initialZones` 是初值，`onChanged` 通过 pop 回调。
library;

import 'package:flutter/material.dart';

import '../../../core/providers.dart';

/// 单个 zone 的当前动作枚举（int 0..3）映射到的图标 + 文字 + 颜色调色板。
class _TapZoneActionMeta {
  final IconData icon;
  final String label;
  const _TapZoneActionMeta(this.icon, this.label);
}

const Map<int, _TapZoneActionMeta> _kActionMeta = {
  0: _TapZoneActionMeta(Icons.arrow_back, '上一页'),
  1: _TapZoneActionMeta(Icons.arrow_forward, '下一页'),
  2: _TapZoneActionMeta(Icons.menu, '菜单'),
  3: _TapZoneActionMeta(Icons.do_not_disturb_on_outlined, '无'),
};

/// 4 个预设值循环顺序（点击格子时下一档）。
const List<int> _kCycleOrder = [0, 1, 2, 3];

class TapZoneConfigDialog extends StatefulWidget {
  /// 初始 9 槽位值（length 必须为 9，每个值 0..3）。
  final List<int> initialZones;

  const TapZoneConfigDialog({super.key, required this.initialZones});

  @override
  State<TapZoneConfigDialog> createState() => _TapZoneConfigDialogState();
}

class _TapZoneConfigDialogState extends State<TapZoneConfigDialog> {
  late List<int> _zones;

  @override
  void initState() {
    super.initState();
    // 拷贝一份避免 mutate 外部 list（外部传 const tapZonesDefault 会爆 unmodifiable）。
    _zones = _normalize(widget.initialZones);
  }

  static List<int> _normalize(List<int> raw) {
    if (raw.length != 9) {
      return List<int>.from(ReaderSettings.tapZonesDefault);
    }
    return List<int>.generate(9, (i) => raw[i].clamp(0, 3));
  }

  void _cycleZone(int idx) {
    setState(() {
      final cur = _zones[idx];
      final pos = _kCycleOrder.indexOf(cur);
      final next = _kCycleOrder[(pos + 1) % _kCycleOrder.length];
      _zones[idx] = next;
    });
  }

  void _applyPreset(List<int> preset) {
    setState(() {
      _zones = List<int>.from(preset);
    });
  }

  bool _matchesPreset(List<int> preset) {
    for (var i = 0; i < 9; i++) {
      if (_zones[i] != preset[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('点击区域'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '点击格子切换动作（上一页 / 下一页 / 菜单 / 无）',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            // 3×3 网格本体。用 SizedBox 限定宽度避免 GridView 把整个 dialog 撑爆。
            SizedBox(
              width: 240,
              height: 240,
              child: GridView.count(
                crossAxisCount: 3,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
                physics: const NeverScrollableScrollPhysics(),
                children: List.generate(9, (idx) {
                  final v = _zones[idx];
                  final meta = _kActionMeta[v] ?? _kActionMeta[2]!;
                  return _ZoneCell(
                    icon: meta.icon,
                    label: meta.label,
                    onTap: () => _cycleZone(idx),
                  );
                }),
              ),
            ),
            const SizedBox(height: 16),
            Text('预设', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('默认'),
                  selected: _matchesPreset(ReaderSettings.tapZonesDefault),
                  onSelected: (_) =>
                      _applyPreset(ReaderSettings.tapZonesDefault),
                ),
                ChoiceChip(
                  label: const Text('经典'),
                  selected: _matchesPreset(ReaderSettings.tapZonesClassic),
                  onSelected: (_) =>
                      _applyPreset(ReaderSettings.tapZonesClassic),
                ),
                ChoiceChip(
                  label: const Text('全屏菜单'),
                  selected: _matchesPreset(ReaderSettings.tapZonesFullMenu),
                  onSelected: (_) =>
                      _applyPreset(ReaderSettings.tapZonesFullMenu),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_zones),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

class _ZoneCell extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ZoneCell({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: theme.colorScheme.outlineVariant,
            width: 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: fg, size: 22),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(color: fg, fontSize: 10),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
