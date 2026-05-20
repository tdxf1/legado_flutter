// BATCH-18d (F-W2A-008)：fontSizeProvider 派生自 readerSettingsProvider 验证。
//
// 历史背景：早先是独立 StateProvider<double>，与 ReaderSettings.fontSize 双
// source of truth — settings 页改字号写顶级 fontSize key，reader 实际读
// readerSettings.fontSize 子对象，互不同步。本文件验证派生后两端共用同一
// 字段。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/core/providers.dart';

void main() {
  test('fontSizeProvider 默认派生自 readerSettings 默认值 (18.0)', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(fontSizeProvider), 18.0);
    expect(
      container.read(fontSizeProvider),
      container.read(readerSettingsProvider).fontSize,
    );
  });

  test('fontSizeProvider 反映 readerSettingsProvider 启动 override', () {
    final container = ProviderContainer(overrides: [
      readerSettingsProvider
          .overrideWith((ref) => const ReaderSettings(fontSize: 24)),
    ]);
    addTearDown(container.dispose);
    expect(container.read(fontSizeProvider), 24.0);
  });

  test('修改 readerSettingsProvider state 后，fontSizeProvider 立即同步', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(fontSizeProvider), 18.0);

    final notifier = container.read(readerSettingsProvider.notifier);
    notifier.state = notifier.state.copyWith(fontSize: 22);
    expect(container.read(fontSizeProvider), 22.0);

    notifier.state = notifier.state.copyWith(fontSize: 16);
    expect(container.read(fontSizeProvider), 16.0);
  });

  test('readerSettings 其它字段变更不会触发 fontSizeProvider 重新计算同值',
      () {
    // Riverpod 自动 dedup 同值：readerSettings 的 lineHeight 变化不影响
    // fontSizeProvider 派生值（fontSize 没变）。这是性能保证 — 派生
    // provider 不会因为父 state 不相关字段变化而频繁触发 listener。
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final initial = container.read(fontSizeProvider);

    final notifier = container.read(readerSettingsProvider.notifier);
    notifier.state = notifier.state.copyWith(lineHeight: 2.0);
    expect(container.read(fontSizeProvider), initial);
  });
}
