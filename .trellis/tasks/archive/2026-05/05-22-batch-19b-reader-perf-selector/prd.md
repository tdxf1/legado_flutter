# BATCH-19b: Reader 性能修复（selector 拆订阅 + GlobalKey 对称保存）

**Stage**: P1
**Slug**: `reader-perf-selector`
**Effort**: M (≤300 行)
**Depends on**: BATCH-19a ✅（ReaderSettings == / hashCode 已落地）
**Splits from**: BATCH-19

## 1. 范围

修 reader 模块 2 个 C-性能 finding：build 树过宽 rebuild 链 + 滚动模式 paragraph index 保存/恢复不对称。

## 2. 包含的 findings

| Finding | 当前行号 | 实施 |
|---------|---------|------|
| F-W2A-011 | `reader_page.dart:1742+`（build 内 `ref.watch(readerSettingsProvider)`） | build 全量 watch 改为按需 select：把"是否有变更需 postFrame 回写"逻辑下沉到 `ref.listen`，build 顶层不再 watch 整个 settings；body 子树用专门 ConsumerWidget 拆分，按各自字段 select |
| F-W2A-014 | `reader_page.dart:1321-1358`（`_updateVisibleParagraph`） | 保存路径用 GlobalKey 反查（与 P2-13 已有的恢复路径对称）；超 cap 章再 fallback 估算 |

## 3. 影响文件

### `flutter_app/lib/features/reader/reader_page.dart`

**F-W2A-011 selector 拆订阅**：
- `build` 顶部 line 1744 `final providerSettings = ref.watch(readerSettingsProvider);` 改为 `ref.listen` 形式：
  ```dart
  ref.listen<ReaderSettings>(readerSettingsProvider, (prev, next) {
    if (_readerSettingsLoaded && next != _settings) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ref.read(readerSettingsProvider) != _settings) {
          _setReaderSettings(next);
        }
      });
    }
  });
  ```
- `_setReaderSettings` 内部仍 setState 触发本组件 rebuild（_settings 是 plain field，需要本 widget 的 setState 推动）
- `_buildPageBody(settings)` / `_buildContinuousBody(settings)` 调用处仍传 `_settings`（plain field，State 持有最新值）
- **核心改动**：build 顶层不再因 settings 变更 rebuild；只有 `_setReaderSettings` 内部 setState 显式触发时才 rebuild — 两条路径合一减少冗余

**F-W2A-014 GlobalKey 对称保存**：
- `_updateVisibleParagraph` line 1321：把 line 1346-1357 的"标题 dy + 估算"路径替换为：
  1. 拿 `_listViewKey` 视口顶部
  2. 遍历当前章前 `_kParagraphKeyCap` 个 `_paragraphKeys[(ch.index, idx)]`
  3. 找第一个 `key.currentContext?.findRenderObject().localToGlobal(Offset.zero, ancestor: listBox).dy >= 0` 的最小 idx
  4. 找不到（ch 内 idx >= cap）→ fallback 现有估算公式
- 保存与恢复对称后，paragraph index 误差从 ±1-2 段降到 0

## 4. 测试策略

- 新增 widget test `flutter_app/test/reader_settings_select_rebuild_test.dart`：构造 `ReaderPage`，改字段 A，断言 watch 字段 B 的子组件不重建（Stub Consumer 加计数器）
- 新增 widget test `flutter_app/test/reader_paragraph_save_symmetric_test.dart`：模拟章节渲染 → 滚动 → 保存 → 重开 → 恢复 → 断言 visibleParagraphIndex 与 saved 一致（如 widget test 框架支持）
- 现有 reader 测试套件回归
- `flutter analyze` 0 issue
- `flutter test` 全套 PASS

## 5. 验收

- [ ] master finding F-W2A-011 / F-W2A-014 标 Resolved by BATCH-19b
- [ ] build 顶层 settings watch 移除（改 listen + setState 单路径）
- [ ] `_updateVisibleParagraph` 保存路径用 GlobalKey 反查（cap 内）+ fallback 对称
- [ ] flutter analyze / flutter test / cargo build 全 PASS（baseline 523 + 任何新测）

## 6. 不在范围

- F-W2A-012/013（Listenable 拆层 + measure 同步化）→ BATCH-19c
  <!-- 19c 归档实际：F-W2A-012 子项 1 现状评估保留合并 listenable，子项 2 _calcPoints 早退 + 子项 3 shader 缓存评估为 RBD，详见 19c PRD § 8 -->
- ReaderController class 抽取（路线图原计划）→ 19c 后再评估必要性
- shader 缓存优化（F-W2A-012 子项）→ 19c
  <!-- 19c 归档实际：决策 RBD（drag/anim 热路径 cache key 每帧 miss + idle 期 shouldRepaint 已挡 paint），见 19c PRD § 8 / spec quality-and-anti-patterns.md「Reader 渲染边界」段 -->

## 7. 风险点

- **`ref.listen` 与 `ref.watch` 切换**：`ref.listen` 不会触发本组件 rebuild，所以本组件需要在 `_setReaderSettings` 里显式 setState 才能让 `_buildPageBody` 拿到新 `_settings`。`_setReaderSettings` 当前已是 setState 包裹（grep 验证），改为 listen 后仍正确。
- **`build` 第一帧的 `_readerSettingsLoaded == false` 路径**：listen 不在第一帧触发；如果 disk load 在 build 前完成，listen 拿不到首次值。实施时需要在 `initState` 加一次 `_setReaderSettings(ref.read(readerSettingsProvider), markLoaded: true)` 兜底（或确认现有 initState 已经有等价路径）。
- **GlobalKey 反查**：`localToGlobal` 在子节点未 layout 时返回 dummy 值；现有 P2-13 恢复路径已 postFrame，保存路径直接遍历可能命中未 layout 节点；需要 `if (renderBox?.hasSize != true) continue` 过滤。
- **遍历 200 key cap**：每次滚动 debounce 300ms 跑一次 200 key 遍历 ≈ µs 级，可忽略；但若用户在跨章长跳，需要遍历当前 ch 的 key（用 `(ch.index, idx)` keyId 过滤）而非全部 _paragraphKeys。
