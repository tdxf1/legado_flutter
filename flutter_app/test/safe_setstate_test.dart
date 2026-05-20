/// `safeSetState` extension 测试（BATCH-25, F-W2B-021）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/widgets/safe_setstate.dart';

void main() {
  group('safeSetState', () {
    testWidgets('mounted=true 时触发 setState 重建 UI', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: _CounterPage()));
      // 初始 Text 显示 0
      expect(find.text('count: 0'), findsOneWidget);
      // tap 触发 safeSetState(() => _count++);
      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();
      expect(find.text('count: 1'), findsOneWidget);
    });

    testWidgets('mounted=false 时是 no-op，不抛异常', (tester) async {
      // 先 pump widget 拿到 State 引用
      await tester.pumpWidget(const MaterialApp(home: _CounterPage()));
      final state = tester.state<_CounterPageState>(find.byType(_CounterPage));
      expect(state.mounted, isTrue);
      // dispose widget（pump 一个空白 widget 替换）
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      expect(state.mounted, isFalse);
      // 在 unmounted state 上调 safeSetState 不应该抛
      expect(() => state.safeSetState(() {}), returnsNormally);
    });

    testWidgets('多次 safeSetState 累积更新', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: _CounterPage()));
      final btn = find.byType(ElevatedButton);
      await tester.tap(btn);
      await tester.tap(btn);
      await tester.tap(btn);
      await tester.pump();
      expect(find.text('count: 3'), findsOneWidget);
    });
  });
}

/// 测试辅助：暴露一个 State 用 safeSetState 改 _count，按钮触发递增。
class _CounterPage extends StatefulWidget {
  const _CounterPage();
  @override
  State<_CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<_CounterPage> {
  int _count = 0;

  void _bump() {
    safeSetState(() => _count++);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('count: $_count'),
            ElevatedButton(onPressed: _bump, child: const Text('bump')),
          ],
        ),
      ),
    );
  }
}
