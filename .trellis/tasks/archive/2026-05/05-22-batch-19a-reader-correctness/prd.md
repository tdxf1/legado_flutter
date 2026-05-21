# BATCH-19a: Reader 正确性修复（4 P1 + ReaderSettings 等价性）

**Stage**: P1
**Slug**: `reader-correctness`
**Effort**: S (≤300 行)
**Depends on**: BATCH-18d ✅（fontSize 单源已统一）
**Splits from**: BATCH-19 reader 重构（路线图 L 尺寸拆 3 子批）

## 1. 范围

修 reader 模块 4 个 B-正确性 finding，捎带补 `ReaderSettings.==` / `hashCode` 这块所有 reader 性能优化都依赖的基础（F-W2A-005 建议直接提到）。

留给后续：
- **19b**：F-W2A-011（selector 拆订阅）+ F-W2A-014（GlobalKey 对称保存）
- **19c**：F-W2A-012（Listenable 拆层 + 仿真 painter 早退）+ F-W2A-013（measure 同步化）

## 2. 包含的 findings

| Finding | 当前行号 | 实施 |
|---------|---------|------|
| F-W2A-004 | `providers.dart:141-146`（不再是 189-211） | `replaceRuleGenerationProvider` 升级为 `(processSalt, monotonicCounter)` tuple，或加 spec assert "replace rule CRUD 必须 main isolate"（短期防御） |
| F-W2A-005 | `reader_page.dart:1722-1731` ✓ | `ReaderSettings` 加 `==` / `hashCode`（手写 `Object.hashAll`，免引 freezed 影响构建链）；build 内 `providerSettings != _settings` 改为命中等价性 short-circuit；考虑改 `ref.listen` 替代 build 内 watch+比较+postFrame |
| F-W2A-006 | `reader_page.dart:1094-1123` ✓ | 拆 `_onScroll` 防抖：visible chapter timer 与 backward detect / append-prepend 移到 debounce 早 return 之外 |
| F-W2A-007 | `reader_page.dart:428-446`（不再是 418-444） | `_fetchSourceInfo` 把 4 个 plain field 赋值移进 `setState` callback |

## 3. 影响文件

### `flutter_app/lib/core/providers.dart`

- `replaceRuleGenerationProvider`（line 141-146）：升级 cache key
  - **方案 A（推荐）**：改 `StateProvider<({String salt, int counter})>` 类型，`salt` 在第一次访问时 `Object.hashCode.toRadixString(16)` 一次（process-lifecycle scoped），`counter` 仍 monotonic。`bumpReplaceRuleGeneration` 仅自增 counter。Rust 端 cache key 接收完整 tuple 字符串。
  - **方案 B（保守）**：保持 `int`，加 spec assert + dart 端 `assert(Isolate.current.debugName == 'main')` 在 bump 时。理由：当前 download_runner 走 main isolate，没有真实漂移；改 cache key 类型有跨 FFI 影响。
  - 由 sub-agent 评估两案后选实施（PRD 倾向 B 节省风险，但若 Rust cache key 易改则 A 更彻底）。

### `flutter_app/lib/core/providers.dart`

- `class ReaderSettings`（line 425-790）：
  - 加 `@override bool operator ==(Object other)` 比较 38 个字段
  - 加 `@override int get hashCode => Object.hashAll([fontSize, fontWeightIndex, ...])`
  - **不引 freezed**（构建链增加 build_runner，ROI 低）

### `flutter_app/lib/features/reader/reader_page.dart`

- `build` (line 1722-1731)：
  - 加了 `==` 后 `providerSettings != _settings` 的相等性 short-circuit，第一帧后稳态不再 schedule postFrame
  - 保留 postFrame fallback 路径（向后兼容；`==` 命中即跳过）
- `_onScroll` (line 1094-1123)：
  - 拆为：「scrollPos save debounce（只此 early return）」+「visible chapter timer ??=」+「backward detect / append-prepend 总执行」
  - 修复后：连续滚动期间章节标题、追加/前置章节都正常触发
- `_fetchSourceInfo` (line 428-446)：
  - 4 个 `_sourceName` / `_sourceUrl` / `_sourceId` / `_chapterUrl` 赋值移进 `setState` 内
  - 删 `setState(() {})` 空 callback 反模式

## 4. 测试策略

新增 widget/unit test：
- `test/reader_settings_equality_test.dart`：构造两份相同字段的 `ReaderSettings`，断言 `==` true / `hashCode` 相等；改 1 字段断言 `!=`
- `test/reader_settings_set_dedup_test.dart`：`Set<ReaderSettings>` 加两份相同对象，size == 1
- `test/reader_page_scroll_debounce_test.dart`（如可行）：模拟 _onScroll 触发，断言 `_visibleChapterTimer` 在多次连续 scroll 内仍能启动（看现有 test 基础设施支不支持）

回归：
- `flutter analyze` 0 issue
- `flutter test` 全套 PASS（baseline 483/483）
- `cargo test --workspace` PASS（providers 改 cache key 时确认 Rust 端不受影响；保留方案 B 时无需）

## 5. 验收

- [ ] master finding F-W2A-004/005/006/007 标 Resolved by BATCH-19a
- [ ] `ReaderSettings.==` / `hashCode` 落地（38 字段全覆盖）
- [ ] build 内 watch+postFrame 链每帧触发降至稳态零次（log 抽样验证）
- [ ] `_onScroll` 滚动期间 visible chapter 更新 + append/prepend 不被 debounce 早 return 拦截
- [ ] `_fetchSourceInfo` setState 内赋值
- [ ] flutter analyze / flutter test / cargo build / cargo test 全 PASS

## 6. 不在范围

- F-W2A-011/012/013/014（性能 4 P1）→ BATCH-19b/19c
- ReaderController class 抽取（路线图原计划）→ 需要前置完成 settings 等价 + selector 拆订阅，再评估必要性
- freezed/build_runner 引入（ROI 低，手写够用）

## 7. 风险点

- `==` 字段顺序漏一个会导致 `==` true 但 hashCode 不等 → 等价 + 单测 pin 字段集合
- `_onScroll` 拆 timer 早 return 可能引入"空跑 visible chapter timer"的 micro overhead → 不超过 300ms × 1 timer，可忽略
- `replaceRuleGeneration` cache key 改类型可能影响 Rust FFI 序列化 → 选方案 B 规避
