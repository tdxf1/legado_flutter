# BATCH-13b: parse_chapters_from_page RuleContext clone 复用（4N → 1）

**Stage**: P1 (follow-up of BATCH-13)
**Slug**: `rulecontext-clone-perf`
**Effort**: S (~30 行 + 1 测)
**Depends on**: BATCH-13 ✅（QuickJS Runtime 池化已落地，本批是 RuleContext 端 clone 的 follow-up）

## 1. 范围

收尾 F-W1B-025 — `parse_chapters_from_page` 4 个 `Option::map` 闭包内 N 次 `context.clone()` 改为复用 outer-mutable ctx。

**核心机会**：4 个闭包（`is_vip` / `is_volume` / `is_pay` / `update_time`）**串行执行不重入**；`run_rule_first(rule, html, &ctx)` 第二参 `html` 是源，`ctx.src` 在该 path 上**不参与**（从 `build_runtime_vars` line 281-285 看 `if context.src.is_empty() { html } else { &context.src }`，闭包传的 `html` 与 `context.src` 同源情况下结果完全等价）。可以把 `let mut ctx = context.clone()` 提到 outer scope，inner 只覆盖 `ctx.result`，行为完全等价。

clone 量：4N → 1 次。每次 clone 含 1 个整页 HTML `String` + 4 个 `String` + 1 个 `HashMap<String, LegadoValue>`，省的不是边角料。

## 2. 包含的 finding

| Finding | 状态 | 实施 |
|---------|------|------|
| F-W1B-025 RuleContext::clone 大重构 | BATCH-13 标 "部分 resolved" 留 BATCH-13b | 4 闭包共享 outer-mutable ctx（4N→1）|

## 3. 影响文件

### `core/core-source/src/parser.rs::parse_chapters_from_page`

当前 4 处闭包结构（line 1370-1429）：
```rust
let is_vips = rules.is_vip.as_deref().map(|rule| {
    item_contexts.iter().map(|item| {
        let mut ctx = context.clone();           // 4N 次 clone 之一
        ctx.result = vec![LegadoValue::String(item.clone())];
        self.run_rule_first(rule, item, &ctx).map(|v| ...)
    }).collect()
}).unwrap_or_else(|| vec![None; len]);
let is_volumes = rules.is_volume.as_deref().map(|rule| { /* 同上 */ });
let is_pays = rules.is_pay.as_deref().map(|rule| { /* 同上 */ });
let update_times = rules.update_time.as_deref().map(|rule| { /* 同上 */ });
```

改造为：
```rust
// BATCH-13b (F-W1B-025): 4 个 closure 串行不重入，共享 outer-mutable ctx
// 把每章 4 次 RuleContext::clone（含整页 HTML String）降到 1 次。
// Inner 只重写 result 字段，run_rule_first(rule, html=item, &ctx) 用
// html 参数为源，ctx.src 不参与该 path（验证：build_runtime_vars 在
// context.src.is_empty() 时 fallback html 参数）。
let mut shared_ctx = context.clone();

let is_vips = rules.is_vip.as_deref().map(|rule| {
    item_contexts.iter().map(|item| {
        shared_ctx.result = vec![LegadoValue::String(item.clone())];
        self.run_rule_first(rule, item, &shared_ctx).map(|v| ...)
    }).collect()
}).unwrap_or_else(|| vec![None; len]);
let is_volumes = rules.is_volume.as_deref().map(|rule| { /* 同上用 shared_ctx */ });
// ...
```

注意：rust borrow checker 对 `&mut shared_ctx` 在 4 个闭包间复用要求顺序的，但 4 个 `let _ = ...` 之间 `shared_ctx` 不被借用（每个闭包 evaluate 完就 drop 借用），实际编译应通过。如果借用检查失败，改为 `Cell` / `RefCell` 包 result 字段（下策）。

**测试覆盖确认**：现有 5 个 chapter parsing test（grep `parse_chapters_from_page\|test_*chapter`）必须 PASS，加 1 个 sanity test 验证 4 closure 都能跑通且结果正确。

## 4. 测试策略

- `cargo build --workspace` 0 error（首要：验证 borrow checker 通过）
- `cargo test --workspace` 全 PASS（baseline 421 + 8 ignored）—— 现有 chapter parsing 测试覆盖回归
- 新单测（如 borrow check 通过）：`test_parse_chapters_from_page_4_closures_share_ctx` 构造 BookSource 全 4 rule（is_vip/is_volume/is_pay/update_time）+ 多 chapters，断言所有 4 个闭包结果与原实现一致
- 不需要 perf benchmark（行为完全等价，clone 减少属"对的优化"，不付正确性代价就值得做）

## 5. 验收

- [ ] master finding F-W1B-025 标 Resolved by BATCH-13 + BATCH-13b
- [ ] cargo build --workspace 0 error / cargo test --workspace PASS
- [ ] flutter analyze 0 / flutter test 536 PASS（不动 Flutter 端）
- [ ] spec `.trellis/spec/rust-core/quality-and-anti-patterns.md` "RuleContext clone 复用" 模式说明（如已有性能段就追加）

## 6. 不在范围

- `RuleContext::clone` 全局重构（每个字段 reuse buffer）：影响面太大，只在 hot path 收益清晰
- `RuleContext::shallow_clone` 新方法：4 闭包共享 outer ctx 后已无需 shallow_clone，避免 API surface 扩大
- 其他 `parser.rs` clone 点（line 621 / 1693 / 1810+）：各自调用频率低 + scope 大，独立评估

## 7. 风险点

- **Borrow checker**：`&mut shared_ctx` 在 closure 间复用，每个 `Option::map` 完成后借用 drop，但 closure 内 `shared_ctx.result = ...` + `&shared_ctx` 同帧借用要求 mut → shared 生命周期管理。如果不通过，**回退方案**：4 段独立 inner block（不用 closure 串）+ shared_ctx 借用。
- **`run_rule_first` 异步性**：grep `is_blocking_rule` + `block_in_place` 显示 `run_rule_first` 内部用 `tokio::task::block_in_place` 包裹 JS 规则——这是**同步阻塞**调用（不是 spawn），closure 内 `&shared_ctx` 借用 lifetime 不会跨越 await，**安全**。
- **行为等价性证明**：闭包内对 `ctx` 的唯一写入是 `ctx.result = vec![item]`；闭包间不读 `ctx.result`；`run_rule_first` 读 `ctx.result` 通过 `build_runtime_vars`（line 293 `vars.insert("result", context.get_variable("result"))`，不是 `result` 字段）。**等价。**
- **Rust 1.x edition**：本仓 edition 2021/2024 都支持 closure 内 `&mut` 字段重写。
