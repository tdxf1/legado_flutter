# BATCH-19: Reader 状态机 controller 化 + rebuild 链解耦 + 滚动定位精度

**Stage**: P1
**Slug**: `reader-state-machine-controller`
**Effort**: L (≤800 行)
**Depends on**: BATCH-18 (settings IO 抽象 + fontSize 单源已就位)

## 1. 范围

把 reader 模块 8 条 P1（状态机 / 性能 / 进度恢复）一次性重构进一个 `ReaderController` class，UI 层只 watch derived state。是 reader 后续所有 P1（包括 P2/P3 的 reader 性能问题）的共同前置——所以单独成批。

## 2. 包含的 findings

- [F-W2A-004] replaceRuleGenerationProvider 多 isolate 撞值风险 — `flutter_app/lib/core/providers.dart:189-211`
- [F-W2A-005] ReaderPage build 内 addPostFrameCallback 改 provider — `flutter_app/lib/features/reader/reader_page.dart:1722-1731`
- [F-W2A-006] _onScroll 每次回调创建 Timer 但早退检查不严 — `flutter_app/lib/features/reader/reader_page.dart:1093-1123`
- [F-W2A-007] _fetchSourceInfo mounted 通过后多次 await — `flutter_app/lib/features/reader/reader_page.dart:418-444`
- [F-W2A-011] ReaderPage build watch 多 provider 引发 rebuild 链 — `flutter_app/lib/features/reader/reader_page.dart:1722-1781`
- [F-W2A-012] AnimatedBuilder 合并 listenable，每帧重建 — `flutter_app/lib/features/reader/page/page_view.dart:329-348`
- [F-W2A-013] _measureChapter 与 loadChapter 多次相互触发 — `flutter_app/lib/features/reader/page/page_view_controller.dart:438-449`
- [F-W2A-014] 滚动模式段高估算误差 — `flutter_app/lib/features/reader/reader_page.dart:1300-1337`

## 3. 影响文件

- `flutter_app/lib/features/reader/state/reader_controller.dart` (新增) — 集中 ReaderController class（chapter loader / progress restore / append/prepend / 替换规则 / 滚动跟踪 / 阅读时长）
- `flutter_app/lib/features/reader/reader_page.dart` — 拆分（ ≤800 行约束下不一次性拆完，至少把 `_loadChapterContent` / `_openChapter` / `_preloadAdjacent*` 抽到 controller）
- `flutter_app/lib/features/reader/page/page_view_controller.dart:438-449` — measure + notifyListeners 改同步 + 配合 R66 setState wrap，删除 postFrame 假象
- `flutter_app/lib/features/reader/page/page_view.dart:329-348` — `Listenable.merge` 拆"内层 controller-only" + "外层 anim-only"
- `flutter_app/lib/core/providers.dart:189-211` — generation 升级为 `(processSalt, monotonicCounter)` 或 Rust 端加 startup-uuid
- `flutter_app/lib/features/reader/reader_page.dart` 各处 — `ReaderSettings` 加 `==` / `hashCode`（推荐 freezed 或 Object.hashAll）；`ref.watch(readerSettingsProvider.select(...))` 拆细订阅；保存 paragraph index 改用 GlobalKey 反查与恢复对称；`_fetchSourceInfo` 内 mounted 检查与 setState 修复

## 4. 修复方向

按 master findings-flutter-core.md 主题 6 "Reader 状态机 / 渲染性能问题"集体建议：
- 引入 Riverpod selector 拆分；reader 状态机 controller 化（专门一个 ReaderController class），UI 层只 watch derived state；常用 list view 加 const + key 复用
- F-W2A-014 保存路径用 GlobalKey 反查（cap 内）+ fallback 估算

## 5. 测试策略

- Widget test：fontSize 改变只 rebuild 必要子树（不全树重建）
- Widget test：滚动模式保存 paragraph index → 再次打开恢复后 ensureVisible 落在正确位置
- Widget test：仿真翻页期间 controller-only 变更不重绘 painter
- 阅读 1000 章测试书的 fps 与之前对比（数据贴 PR）
- 现有 Flutter 测试套件回归

## 6. 验收

- [ ] master finding F-W2A-004/005/006/007/011/012/013/014 全部消解
- [ ] 滚动 / 翻页 fps 不回退（数据 PR 中给出）

## 7. implement.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-flutter-core.md", "reason": "本批次涉及的 wave 2A findings"}
{"file": "flutter_app/lib/features/reader/reader_page.dart", "reason": "reader 主体"}
{"file": "flutter_app/lib/features/reader/page/page_view.dart", "reason": "AnimatedBuilder 拆分"}
{"file": "flutter_app/lib/features/reader/page/page_view_controller.dart", "reason": "_measureChapter 同步化"}
{"file": "flutter_app/lib/features/reader/page/page_measure.dart", "reason": "段高估算 / GlobalKey 配合"}
{"file": "flutter_app/lib/core/providers.dart", "reason": "ReaderSettings + replaceRuleGeneration"}
{"file": "core/bridge/src/api.rs", "reason": "replaceRuleGeneration cache key 加 startup-uuid（如选 Rust 端方案）"}
```

## 8. check.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md", "reason": "master report 主题：Reader 状态机"}
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-flutter-core.md", "reason": "Wave 2A 详细"}
{"file": ".trellis/tasks/05-20-fix-roadmap/plan/batches/BATCH-19-reader-state-machine-controller.md", "reason": "本批次自身验收清单"}
```
