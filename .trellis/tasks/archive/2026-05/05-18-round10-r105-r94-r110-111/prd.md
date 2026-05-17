# 第十轮复审修复批 — R105 / R94 / R110-R111

## 背景

第十轮全面复审在 commit 15 落地后捞出 15 项新问题（R93-R113）。其中 1 项 high、6 项 med、其余 low。本任务挑最高 ROI 的 4 项一次性落地：

- **R105 (high)** — Reader 首章规则可能漏应用：`_fetchBookName` / `_fetchSourceInfo` 是 async，与第一章 `_loadChapter` 并发；如果章节加载先完成，`_applyReplaceRulesViaRust` 拿到的 `_bookName=""`、`_sourceUrl=""`，scope 非空规则全部跳过（"empty caller context"），用户看到第一章规则没生效但第二章生效。
- **R94 (med)** — build.rs Rust funcId 解析过宽：`        N =>` 8-space-indent 模式不区分文件位置，未来 codegen 在别处插同 indent 的 `match` arm（enum 解码）会被错抓进 funcId 集合，触发"Rust 多余 funcId" warning（不致命，但噪声）。
- **R110 (med)** — replace_rule_page UI 缺 edit 功能：只能添加 + 删除。R24 后 scope/exclude_scope/scope_title/scope_content 字段更复杂、更易填错，没有 edit 就只能删了重建。
- **R111 (med)** — `_showRuleActions` dialog 只显示 pattern + 删除按钮：scope / exclude_scope / scope_content / scope_title 详情看不到，要去列表 subtitle 里挤压看。

## 目标

1. **R105**：reader_page 在首次 chapter content `applyReplaceRules` 之前确保 `_bookName` 与 `_sourceUrl` 已就位
2. **R94**：build.rs `extract_rust_func_ids` 限定扫描范围在 `pde_ffi_dispatcher_primary_impl` / `pde_ffi_dispatcher_sync_impl` 函数体内
3. **R110**：`_showRuleActions` 增加"编辑"按钮，复用已有的对话框逻辑（抽出 `_showRuleEditDialog(BuildContext, [Map? existing])`），existing 非空时预填字段、保存时走 `saveReplaceRule` upsert
4. **R111**：`_showRuleActions` dialog 内容从单 Text 改成结构化展示（pattern / replacement / scope / exclude_scope / 作用对象 checkboxes 状态）

## 实现要点

### R105 修复策略

`_loadChapterContent` (line ~360) 是首次章节加载入口，`_applyReplaceRulesViaRust` 在其内部被调。两条路径：

**路径 A**（推荐）：在 `_applyReplaceRulesViaRust` 内部 `await ref.read(bookByIdProvider(widget.bookId).future)` 兜底，确保 metadata 在用之前一定就位。一行改动，定位精确。

**路径 B**：在 `initState` 阶段把 `_fetchBookName` + `_fetchSourceInfo` 改成 `await` 串行 + 阻塞首次 `_loadChapterContent`。改动大、影响 reader 启动时间。

选 A。`bookByIdProvider` 是 Riverpod FutureProvider，已经做了缓存——重复 await 拿到的是同一 Future 不会重复请求。

### R94 修复策略

把 Rust funcId 提取逻辑改成"先找 `fn pde_ffi_dispatcher_primary_impl` 函数体起止，再在范围内扫 `        N =>` 模式"。

简单方案：line-based 状态机，遇到 `fn pde_ffi_dispatcher_primary_impl(` 设 in_dispatcher=true，遇到匹配的 `^}` 设 false。两个 dispatcher 都参与扫描。

### R110/R111 修复策略

`_showAddRuleDialog` 重命名为 `_showRuleEditDialog(BuildContext context, [Map<String, dynamic>? existing])`：
- existing == null：行为同原 add（id 现生成）
- existing != null：预填 controllers + checkboxes，save 时复用同 id（schema upsert）

`_showRuleActions` dialog content 改成 Column 显示完整字段，bottom 加 "编辑"按钮调 `_showRuleEditDialog(ctx, rule)`。

## 验收标准

- cargo check --workspace: clean
- cargo test --workspace: 至少 259 passed（无新单测）
- flutter analyze: 0 issue
- flutter test: 至少 112 passed（无新测）
- 手动 trace（无法跑）：
  - R105：reader 启动时即使 `_fetchBookName` race 慢，scope 限定规则也能在第一章生效
  - R94：build.rs 跑过 `cargo build` 不报"Rust 多余 funcId" warning
  - R110：替换规则列表点击规则 → "编辑"按钮可改 pattern/scope/replacement 等
  - R111：替换规则 dialog 显示完整字段而非仅 pattern

## 不在本任务范围

- R107（token 常量时间比较）：需引入 subtle crate 或手写，单独 land
- R103/R98/R108/R93/R95/R96/R99/R101/R104/R106/R113：trivial doc 或生产路径不可达，留 backlog
