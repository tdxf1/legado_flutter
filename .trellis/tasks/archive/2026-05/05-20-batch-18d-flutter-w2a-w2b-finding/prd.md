# BATCH-18d: F-W2A-008 fontSize 派生统一 source of truth

## Goal

闭环 F-W2A-008：把 `flutter_app/lib/core/providers.dart:18` 的 `fontSizeProvider` 从独立 `StateProvider<double>` 改为 `Provider<double>` 派生自 `readerSettingsProvider.fontSize`，消除"双 source of truth"bug —— 当前 settings 页改字号 → 写顶级 `fontSize` key，reader 实际读 `readerSettings.fontSize` 子对象 key，两者完全分离，互不同步。

同时整删配套死代码：`loadFontSizeFromDisk` / `saveFontSizeToDisk` 两个 wrapper（已是 BATCH-18c 后的 1-3 行 helper 调用）+ `main.dart` 启动时灌 `fontSizeProvider` 的 override。

F-W2B-022（features 层 documents 路径残余）+ F-W2B-016（bookshelf PopupMenu 重组）拆到 BATCH-18e/18f 独立批次。

## What I already know

### 来自 explore 审计（2026-05-20，本批次）

**1. fontSize 双 source of truth 现状**

```dart
// flutter_app/lib/core/providers.dart:18
final fontSizeProvider = StateProvider<double>((ref) => 18.0);
```

```dart
// flutter_app/lib/core/providers.dart:432, 541, 686, 748, 814
class ReaderSettings {
  final double fontSize;  // L432
  // L541: this.fontSize = 18.0,
  // L686: 'fontSize': fontSize,
  // L748: fontSize: (json['fontSize'] as num?)?.toDouble() ?? 18.0,
}
final readerSettingsProvider = StateProvider<ReaderSettings>(
  (ref) => const ReaderSettings(),
);  // L814
```

**关键事实**：两者落到 settings.json 的**不同 key**：
- `fontSizeProvider` → 顶级 `fontSize` key（通过 `loadFontSizeFromDisk` / `saveFontSizeToDisk`）
- `ReaderSettings.fontSize` → `readerSettings.fontSize` 子对象 key（通过 `loadReaderSettingsFromDisk`）

完全分离，互不同步。

**2. caller 全清单**（共 5 处）

```dart
// flutter_app/lib/main.dart:49,53
final fontSize = await loadFontSizeFromDisk();
runApp(ProviderScope(
  overrides: [
    themeModeProvider.overrideWith((ref) => themeMode),
    fontSizeProvider.overrideWith((ref) => fontSize),
    // ...
```

```dart
// flutter_app/lib/features/settings/settings_page.dart:136-148
'${ref.watch(fontSizeProvider).round()}',                            // L136
value: ref.watch(fontSizeProvider),                                  // L141
label: '${ref.watch(fontSizeProvider).round()}',                     // L145
onChanged: (value) {
  ref.read(fontSizeProvider.notifier).state = value;                 // L147
  saveFontSizeToDisk(value);                                          // L148
},
```

**reader 端**：`reader_page.dart` / `reader_settings_sheet.dart` / `page_view.dart` / `page_measure.dart` / `content_page.dart` 全部读 `_settings.fontSize`（即 `ReaderSettings.fontSize`）— **没有任何一处用 `fontSizeProvider`**。

**3. 改造目标形态**

```dart
// 派生自 readerSettings，单一 source of truth
final fontSizeProvider = Provider<double>(
  (ref) => ref.watch(readerSettingsProvider).fontSize,
);
```

settings 页改字号必须走 `readerSettingsProvider.notifier.state = state.copyWith(fontSize: value)` + `saveReaderSettingsToDisk`，自动通过派生流给 settings 页 + reader 端。

**4. 启动加载链路**

`main.dart` 启动时当前并行加载多项 settings 灌进 ProviderScope。需要确认 `readerSettingsProvider` 是否在启动时已经加载（`loadReaderSettingsFromDisk`）；如果是 lazy 加载（仅进 reader 时才跑），settings 页第一次打开会显示 default `18.0` 不是用户保存值。

**审计发现**：reader_page.dart 用 `_readerSettingsLoaded` flag 在 enter reader 时第一次 `loadReaderSettingsFromDisk`。settings 页当前用 `fontSizeProvider`（启动时已 override），所以显示对了 —— 改派生后 settings 页就需要 `readerSettingsProvider` 也启动时加载。

`main.dart` 必须改成启动时 `loadReaderSettingsFromDisk` + `readerSettingsProvider.overrideWith`，删 `loadFontSizeFromDisk` + `fontSizeProvider.overrideWith`。

**5. 测试现状**

- `widget_test.dart` 测的是 settings_page 通知 + 主题；**没测字号**，不会 break
- `reader_settings_v6_test.dart` / `reader_settings_anim_duration_test.dart` / `bookshelf_page_test.dart:210-220` / `page_view_controller_window_test.dart:310-345` 用 `ReaderSettings.fontSize` 字段做单元测，与 `fontSizeProvider` 无关 — **不会 break**
- 全仓 0 处测试调用 `loadFontSizeFromDisk` / `saveFontSizeToDisk` / `fontSizeProvider`

**新增 test 草稿**：
- `font_size_derived_test.dart`：在 `ProviderContainer` 内 override `readerSettingsProvider`，验证 `fontSizeProvider` 派生值 = `readerSettings.fontSize`
- 修改 `readerSettings.fontSize` 后再 read `fontSizeProvider` 拿到新值

**6. 顶级 `fontSize` key 历史遗留处理**

启用派生后 `settings.json` 顶级 `fontSize` key 变成历史死字段：
- 读：`loadFontSizeFromDisk` 删了，没人读
- 写：`saveFontSizeToDisk` 删了，没人写
- 已有用户的 settings.json 留着无害，新 settings.json 不会再写

**保守做法**：不做迁移，不清理顶级 key。理由：
- json_store helper 不删除 key 不是问题
- 用户体验：第一次启动时如果用户之前调过字号（顶级 fontSize 是 22），但 readerSettings.fontSize 是 18（默认），用户会看到 reader 字号回退 — **真实场景下用户调过字号时 readerSettings.fontSize 也会同步变更**，因为 reader 改字号是 `state.copyWith(fontSize)` + `saveReaderSettingsToDisk`，所以 readerSettings.fontSize 不会比顶级 fontSize 旧。
- 唯一例外：用户**只**在 settings 页调过字号（写顶级 fontSize），从未进过 reader（不会写 readerSettings.fontSize）。这种场景下用户的字号偏好会丢失。

**风险评估**：极小（settings 页 slider 是文字大小，但 reader 端才是核心展示场景）。如果用户反馈丢字号，可补一次性迁移：启动加载时如果 readerSettings.fontSize == default (18.0) 且顶级 fontSize 存在 != default，把顶级 fontSize 灌进 readerSettings。本批不做，留观察。

## Open Questions

（已收敛）

## Requirements (final)

### MVP scope（5 项）

1. **改 `flutter_app/lib/core/providers.dart:18`**
   - `final fontSizeProvider = StateProvider<double>((ref) => 18.0);`
   - 改为 `final fontSizeProvider = Provider<double>((ref) => ref.watch(readerSettingsProvider).fontSize);`

2. **删 `flutter_app/lib/core/providers.dart:248-255` 两个 wrapper**
   - `loadFontSizeFromDisk` 整删
   - `saveFontSizeToDisk` 整删

3. **改 `flutter_app/lib/main.dart`**
   - 删 `final fontSize = await loadFontSizeFromDisk();`（约 L49）
   - 删 `fontSizeProvider.overrideWith((ref) => fontSize),`（约 L53）
   - 加 `final readerSettings = await loadReaderSettingsFromDisk();`
   - 加 `readerSettingsProvider.overrideWith((ref) => readerSettings),` override
   - 注意：reader_page.dart 内的 `_readerSettingsLoaded` flag 仍会在进 reader 时跑一次 `loadReaderSettingsFromDisk`（重复调用，但 helper 是幂等的，无副作用） — 可考虑顺手让 reader_page 直接用 `readerSettingsProvider` 不再重新加载，但**本批保守不动 reader_page**（涉及更多 caller，本批专注消除 double source）

4. **改 `flutter_app/lib/features/settings/settings_page.dart:147-148`**
   - 改 `ref.read(fontSizeProvider.notifier).state = value;` → `final notifier = ref.read(readerSettingsProvider.notifier); notifier.state = notifier.state.copyWith(fontSize: value);`
   - 改 `saveFontSizeToDisk(value);` → `saveReaderSettingsToDisk(notifier.state);`
   - L136/141/145 的 `ref.watch(fontSizeProvider)` 保留不动（派生 provider 仍然 readable）

5. **新增 `flutter_app/test/font_size_derived_test.dart`**
   - case 1: `ProviderContainer` 默认 `fontSizeProvider` == 18.0（readerSettings 默认）
   - case 2: override `readerSettingsProvider` 为 `ReaderSettings(fontSize: 24)`，`fontSizeProvider` == 24
   - case 3: 修改 `readerSettingsProvider.notifier.state = copyWith(fontSize: 22)`，read `fontSizeProvider` == 22

6. **master report 同步**
   - F-W2A-008 标 "Resolved by BATCH-18d"

### 不在范围内

- F-W2B-016 bookshelf PopupMenu 重组（拆到 BATCH-18e）
- F-W2B-022 features 层 documents 路径（拆到 BATCH-18f）
- 顶级 `fontSize` key 一次性迁移（保守不做，留观察）
- reader_page `_readerSettingsLoaded` flag 重构（本批专注 fontSize 派生）
- 引入 `ChangeNotifierProvider` / `Notifier` 风格重构

## Acceptance Criteria

- [ ] `providers.dart:18` `fontSizeProvider` 改为 `Provider<double>` 派生自 `readerSettingsProvider`
- [ ] `providers.dart` 内 `loadFontSizeFromDisk` / `saveFontSizeToDisk` 整删
- [ ] `main.dart` 启动时不再调 `loadFontSizeFromDisk`，改为 `loadReaderSettingsFromDisk` + override `readerSettingsProvider`
- [ ] `settings_page.dart` slider onChanged 改为 update `readerSettingsProvider.notifier` + `saveReaderSettingsToDisk`
- [ ] 新增 `test/font_size_derived_test.dart` 至少 3 case
- [ ] grep `loadFontSizeFromDisk\|saveFontSizeToDisk\|fontSizeProvider\.notifier` 在 `flutter_app/lib/` 下 0 命中（caller 全部更新）
- [ ] grep `fontSizeProvider` 在 `flutter_app/lib/` 下仅 1 处（providers.dart 派生定义）
- [ ] `flutter analyze` 0 warning
- [ ] `flutter test` 全部 PASS（widget_test / json_store_test / 新增 font_size_derived_test / 现有 reader_settings 系列测试）
- [ ] master report `findings-flutter-core.md` F-W2A-008 标 "Resolution (BATCH-18d)"
- [ ] master report `findings.md` 主索引同步

## Definition of Done

- fontSize 单一 source of truth（readerSettings.fontSize）
- settings 页改字号 → reader 自动同步；反之亦然
- 死代码（`loadFontSizeFromDisk` + `saveFontSizeToDisk` + 顶级 fontSize key 写入）移除
- 测试套件全 PASS

## Decision (ADR-lite)

**Context**: BATCH-18 路线图含 F-W2A-008/W2B-016/W2B-022 三条 Flutter finding 待清。explore audit 确认三条互相独立。F-W2B-016 涉及产品决策（PopupMenu 拆分方案），F-W2B-022 涉及 json_store API 是否扩展（B 方案 vs A 方案），都需要单独 brainstorm。F-W2A-008 是纯技术修复（消除 double source bug），无决策点。

**Decision**: 选项 1（推荐方案）— 拆三批，本批 BATCH-18d 仅做 F-W2A-008 fontSize 派生。

**Consequences**:
- 单批 ~70 行净 diff，PR review 友好
- 0 产品决策，立即可推进
- F-W2B-022 / 016 留独立批次（BATCH-18e/18f）按各自 brainstorm 节奏推进
- 真实 bug 修复（settings 页改字号 reader 不同步是用户可感知的）

## Technical Notes

### 风险点

- **`main.dart` 加载链路改动**：从 `loadFontSizeFromDisk` 改为 `loadReaderSettingsFromDisk`。两者都是 BATCH-18c 后的 json_store helper wrapper，幂等且性能等价（一次 file read），唯一差别是返回 `ReaderSettings` 对象而非 `double`。reader_page 进入时仍会再次 `loadReaderSettingsFromDisk`（重复调用，但 helper 幂等无副作用）。**保守不重构 reader_page 加载流**。
- **顶级 `fontSize` key 历史遗留**：现有用户 settings.json 顶级 `fontSize` key 不再被读写，但残留无害。极小概率"用户只改过 settings 页字号、从未进过 reader" → 字号偏好丢失。本批不做迁移，留观察。
- **派生 provider 的 watch 性能**：`Provider<double>` watch `readerSettingsProvider` 后只 emit 当 readerSettings 整体变化时，不是仅 fontSize 变。Riverpod 自动 dedup 同值不重复触发，所以即使 readerSettings 其它字段变（lineHeight 等）也不会重复触发 fontSizeProvider 的 listener（因为 fontSize 值没变）— 性能等价。

### 实施顺序

1. read `providers.dart:18,248-255` 当前 `fontSizeProvider` + 两个 wrapper
2. read `main.dart` 启动加载段（约 L40-60）
3. read `settings_page.dart:130-160` slider 段
4. 改 `providers.dart:18` 派生 + 删 248-255
5. 改 `main.dart` 加载链路
6. 改 `settings_page.dart` slider onChanged
7. 新增 `test/font_size_derived_test.dart`
8. `flutter analyze` 验证
9. `flutter test` 验证（用户跑）
10. 更新 master report

### 测试 case 设计

```dart
test('fontSizeProvider derives from readerSettingsProvider default', () {
  final c = ProviderContainer();
  expect(c.read(fontSizeProvider), 18.0);
  c.dispose();
});

test('fontSizeProvider reflects overridden readerSettingsProvider', () {
  final c = ProviderContainer(overrides: [
    readerSettingsProvider.overrideWith((ref) => const ReaderSettings(fontSize: 24)),
  ]);
  expect(c.read(fontSizeProvider), 24.0);
  c.dispose();
});

test('fontSizeProvider updates when readerSettingsProvider state changes', () {
  final c = ProviderContainer();
  expect(c.read(fontSizeProvider), 18.0);
  final notifier = c.read(readerSettingsProvider.notifier);
  notifier.state = notifier.state.copyWith(fontSize: 22);
  expect(c.read(fontSizeProvider), 22.0);
  c.dispose();
});
```

## Research References

- 本任务 explore audit（in-context，未持久化到 research/）
- BATCH-18 路线图：`.trellis/tasks/archive/2026-05/05-20-fix-roadmap/plan/batches/BATCH-18-flutter-dead-code-and-io-abstract.md`
- BATCH-18c archive：`.trellis/tasks/archive/2026-05/05-20-fix-batch-18c-json-store-abstraction/`（建立 json_store helper）
- F-W2A-008 finding：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-flutter-core.md:132-140`
