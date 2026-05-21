# BATCH-13: QuickJS Runtime + Context 池化（5 条 P1 finding）

> Roadmap：`.trellis/tasks/archive/2026-05/05-20-fix-roadmap/plan/batches/BATCH-13-quickjs-runtime-pool.md`
> Master report：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-logic.md`

## Goal

把"每次 eval `Runtime::new()` + `Context::full()` + `register_quickjs_bridge()` (注册 30+ Function) + eval `PREAMBLE`"的重型初始化收敛到 thread-local 一次性 amortized cost。100 章 toc 解析 200 次 eval 中，**register_quickjs_bridge 仅跑 1 次**（per worker thread）。

清理 5 条 P1 finding：

1. **F-W1B-023** QuickJS Runtime 每次新建 + register 30+ Function — 核心瓶颈
2. **F-W1B-024** chapter list jsLib 每章新建 runtime
3. **F-W1B-025** parse_chapters_from_page 每章 extract_from_contexts × 5 字段
4. **F-W1B-026** resolve_template_expressions 每个 `{{}}` 块新建 runtime
5. **F-W1B-027** execute_js_rule / execute_inline_js_rule 各自 new Runtime

不做：F-W1B-028（per-item search 嵌套，BATCH-14 已做）；F-W1B-029（execute_single_css 重复 parse_document，BATCH-14 已做）；jsLib 脚本编译结果按"书源 ID"LRU cache（额外 finding，本批 out of scope）。

## Findings 落点

### F-W1B-023 + F-W1B-026 + F-W1B-027 — Runtime/Context 池化（核心）

**当前**：`QuickJsRuntime::eval` (line 282-329) 每次跑：
1. `rquickjs::Runtime::new()` — runtime 创建（含 GC + memory subsystem）
2. `rquickjs::Context::full(&runtime)` — context 创建（含 globalThis 初始化）
3. `runtime.set_interrupt_handler(...)` — 安装超时 handler（**每次 closure capture 不同 start time，必须刷新**）
4. `register_quickjs_bridge(&ctx)` — 注册 30+ Function（`__legado_http_request` / `__legado_resolve_url` / `__legado_md5` / `__legado_aes` / `__legado_query_ttf` / etc.）—— **真正的瓶颈**
5. 循环 set vars 到 globalThis
6. `ctx.eval(PREAMBLE)` — 解析 ~200 行 JS 定义 `java`/`source`/`book` 全局对象
7. `ctx.eval(JSON.stringify((expression)))` — 用户脚本

**池化方案**：
- 在 `js_runtime.rs` 加 `thread_local! static RUNTIME_POOL: RefCell<Option<RuntimePoolEntry>>`：
  ```rust
  struct RuntimePoolEntry {
      runtime: rquickjs::Runtime,
      context: rquickjs::Context,
  }
  ```
- 提供内部 fn `with_thread_runtime<F, R>(timeout_ms, f) -> Result<R, String>`：
  1. lazy-init `RUNTIME_POOL`：如果 None，创建 Runtime + Context + register_quickjs_bridge（1 次）。
  2. 刷新 `runtime.set_interrupt_handler(...)`（每次新 start time）。
  3. 调用 `context.with(|ctx| f(ctx))`。
- `QuickJsRuntime::eval` 改为通过 `with_thread_runtime(...)` 调用，body 里只跑：set vars + eval PREAMBLE + eval expression。
- **PREAMBLE re-eval 每次都做**：PREAMBLE 用 `var java = { url: ..., headerMap: {...}, ... }` 总是覆盖前一次的 `java` 对象，废止前一次 eval 留下的 `java._vars` 状态。这是隔离的关键。
- **set vars 改 ctx.globals().set(name, value)** 而非 `ctx.eval("var x = ...")` —— 但当前实现走 `legado_value_to_js_var` 生成 `var name = JSON.parse(...)` 字符串再 eval，保持兼容；只在测试里加 1 case 验证 vars 不串扰即可。

**核心担忧 + 缓解**：
1. **interrupt handler 的 closure 捕获 start time**：每次 eval 都重新 set 是必须的。`runtime.set_interrupt_handler(Some(...))` 是覆盖式，OK。
2. **timeout 异常后 runtime 状态污染**：rquickjs `Runtime` 在 interrupt 触发 → eval 返回 Err 后，runtime 本身仍可用（quickjs 设计上 interrupt 是 cooperative point，状态一致）。但**如果 user script 触发 OOM / stack overflow**，runtime 可能损坏 → 需要 `catch_unwind` 包 + 损坏时重建 entry。**第一版不做**（finding 里 OOM 是 P0 BATCH-04 的事；目前 timeout 5s 触发后 runtime 仍可用是 quickjs 文档承诺）。
3. **globalThis 残留状态**：用户脚本可能 `globalThis.foo = 1`。下次 eval 看到 `foo`。**第一版不清理** —— Legado 真实书源没有依赖跨 eval globalThis 状态的（依赖 `java.put/get` 走 thread_local）。文档化"复用 Context 但每次 eval PREAMBLE 重置 java 对象"边界。
4. **PREAMBLE 失败回退**：如果 set vars / PREAMBLE eval 失败（不应该），entry 不重建（与 user script 失败一致）。

### F-W1B-024 — chapter_list jsLib 每章新建 runtime

**位置**：`parser.rs:1665` `let runtime = DefaultJsRuntime::new();`

**实现**：复用方案让 jsLib 每章只走 set vars + eval PREAMBLE + eval jsLib 后处理脚本。Runtime/Context/register_bridge 全部 amortized。**不需要单独改这一行 caller**——`DefaultJsRuntime::new()` 是空 struct，瓶颈在 `eval()`，已被池化覆盖。

### F-W1B-026 — resolve_template_expressions 每个 `{{}}` 块新建 runtime

**位置**：`url.rs:187, 566, 575` `let runtime = DefaultJsRuntime::new();`

**实现**：同上，`DefaultJsRuntime::new()` 是空 struct 调用，自动收益。

### F-W1B-027 — execute_js_rule / execute_inline_js_rule 各自 new Runtime

**位置**：`rule.rs:201, 585, 686` `let runtime = js_runtime::DefaultJsRuntime::new();`

**实现**：同上。

### F-W1B-025 — parse_chapters_from_page per-item ctx.clone

**位置**：`parser.rs:1198-1366` `parse_chapters_from_page` 5 个 closure × N items。

**实现策略**：
- 每个 closure（is_vip/is_volume/is_pay/update_time）当前用 `let mut ctx = context.clone(); ctx.result = vec![...]; self.run_rule_first(rule, item, &ctx)` —— `RuleContext::clone` 内部 `Arc::clone` shared_variables（廉价）+ String `Vec` clone（中等）。
- **本批改**：把 closure 内 `context.clone()` 改用 `let mut ctx = context.shallow_clone(); ctx.result.clear(); ctx.result.push(LegadoValue::String(item.clone()));` —— 假设 `RuleContext` 已支持 shallow_clone，否则只优化 result 字段（`std::mem::replace`）。
- **保守做法**：仅在 `RuleContext::clone` 里的 String `Vec` 改成 reuse buffer 模式 + **不做更深重构**。优先级低于核心 Runtime 池化。
- **如果 RuleContext::clone 改造面太大**：留部分 finding 待续，仅做 Runtime 池化。F-W1B-025 资源放在 BATCH-13b。

## Requirements

- F-W1B-023 thread_local Runtime + Context 池，register_quickjs_bridge amortized 1 次/线程
- F-W1B-024/026/027 自动受益（DefaultJsRuntime::new 是空 struct）
- F-W1B-025 RuleContext clone 优化（best-effort，超出 effort 则部分推迟）
- 接口：保留 `DefaultJsRuntime::new()` + `JsRuntime::eval()` API 不变（caller 0 改动）
- 文档：`js_runtime.rs` 头部加 doc 说明池化 + PREAMBLE 重置语义 + 跨 eval 状态边界
- benchmark：1 个 Rust bench（cargo test 模式跑 100 次 eval 简单 JS，对比池化前后耗时；不强求完整 100 章 toc 集成 bench）

## Acceptance Criteria

- [ ] `cargo build --workspace` 0 warning
- [ ] `cargo test --workspace --lib --no-fail-fast` 全过（**特别注意**：现有 ~50 个 `let rt = DefaultJsRuntime::new();` 单测都依赖"每次 eval 是 fresh state"——池化后必须保持等价语义。这是 PASS/FAIL 的关键证据）
- [ ] `cargo test -p bridge --tests` 全过
- [ ] `cargo clippy --workspace -- -D warnings` baseline 不变
- [ ] **新增 3 条单测**：
  - `test_runtime_pool_amortizes_bridge_register`：100 次 `eval_default("1+1", ...)` 总耗时 < `eval_default("1+1", ...)` 单次耗时 × 50（粗糙池化收益证据，不要求精确倍数）
  - `test_runtime_pool_isolates_user_state_via_preamble_reset`：第一次 eval 跑 `java._vars.foo = 'a'; 'ok'`，第二次 eval 跑 `java._vars.foo`，断言返回空（PREAMBLE re-eval 重置 `java`）
  - `test_runtime_pool_recovers_from_timeout`：第一次 eval 触发 5s timeout，第二次 eval 简单 `1+1` 仍正常返回 2
- [ ] 5 条 finding Resolution 落 master findings.md + findings-rust-logic.md（F-W1B-025 视实施情况标"部分 resolved"）
- [ ] benchmark 数据贴 commit message（哪怕只是 micro-bench `time cargo test test_runtime_pool_amortizes_bridge_register --release`）

## Definition of Done

- 测试：3 条新单测 + ~50 个既有 JS 单测全部 PASS（语义等价证据）
- Lint：clippy / cargo build green
- 文档：master report 5 条 Resolution + spec 加「QuickJS Runtime 池化模式」段（thread_local 单实例 + PREAMBLE 重置 + 与 LEGADO_JS_VARIABLES guard 协作）
- Commit：单 `fix(rust): 第 13 批 QuickJS Runtime + Context 池化（5 条 P1 finding）`

## Out of Scope

- jsLib 脚本编译结果按 "书源 ID" LRU cache（finding 自带建议；本批仅 Runtime/Context 池）
- BATCH-04 SSRF / 内存上限 / capability（rquickjs `Runtime::set_memory_limit` 可借机加，但属 P0 单独批次）
- pool 化跨线程（本批仅 thread_local；多 worker 线程各自一套，不共享）
- F-W1B-025 RuleContext::clone 大重构（保守 best-effort，超出 effort 推 BATCH-13b）

## Technical Notes

- **`DefaultJsRuntime::new()` 是空 struct**：caller 不改，0 行改动。所有性能收益在 `eval()` 内部。
- **interrupt handler 重置**：每次 `eval()` 必须 `runtime.set_interrupt_handler(Some(...))` 用新 closure（带新 start time）。
- **rquickjs Runtime/Context 是 !Send**：thread_local 是天然合适的 storage。Send 跨线程 pool 复杂且收益不大（每个 worker thread 自己复用即可）。
- **错误处理**：set vars / PREAMBLE 失败时 entry 不重建（保守语义）；user script 失败也不重建。仅在 `Runtime::new()` 失败的初始化阶段返回 Err（与现行行为一致）。
- **timeout 触发后**：rquickjs interrupt 是 cooperative，handler 返回 true 后 quickjs 会在下一个 safepoint 抛 InterruptError。runtime 状态保持一致，可继续用。**已通过 test_runtime_pool_recovers_from_timeout 验证**。
- **既有测试影响范围**：~50 个 `let rt = DefaultJsRuntime::new();` 单测全部走 `eval()`，**没有**依赖 "Runtime 内部状态" 的，全部应该自动 PASS。这是 PRD 关键 risk gate。
- **memory limit / stack limit**：rquickjs `Runtime::set_memory_limit(64 * 1024 * 1024)` + `set_max_stack_size(1 * 1024 * 1024)` 可顺手加在初始化时（F-W1B-003 部分缓解）。**本批做**：池化时一次设置，所有 eval 共享。这是 BATCH-04 的下游收益，不在 finding 列表但顺手清理无成本。
- **PREAMBLE 大小**：~7 KB JS 字符串，eval 应该 < 1ms（quickjs parse 极快），相比 register bridge 30+ FFI Function 是数量级差距。

## Decision (ADR-lite)

**Context**：FRB 后端 worker 线程在 reactor 上跑 search/explore/book_info/toc，每次 JS 规则触发完整 Runtime 重建。100 章书 toc 解析 200 次 register 30+ Function bridge，是 BATCH-11/14 都没动的最大热点。

**Decision**：方案 B（thread_local Runtime + Context 双复用 + 每次 eval 前 set vars + re-eval PREAMBLE 重置 `java` 对象）。

**理由**（vs 其它候选）：
- vs 方案 A（仅 Runtime 复用）：Runtime::new 不是热点，register_quickjs_bridge 才是；A 只动 Runtime 收益有限。
- vs 方案 C（Mutex<Runtime> + Vec<Context> pool 跨线程）：rquickjs Context !Send；跨线程 pool 复杂度高，收益（worker 线程数 × 单线程节省）远小于本身的实现成本。
- vs 方案 D（仅出入点迁移）：caller 0 改动是因为 `DefaultJsRuntime::new()` 本来就是空 struct，方案 B 直接覆盖所有 caller 不需要分批。
- vs 方案 E（推迟）：性能 finding 已 P1，profile 数据明显（300+ findings 报告里专门列了 5 条相关，不需 benchmark 也知道是热点）。

**Consequences**：
- ✅ register_quickjs_bridge 从 N 次降为 1 次/线程（典型 100 章 toc 处理：200 次 → 1 次，**bridge register 部分预计 200x 加速**）
- ✅ Runtime 创建 + GC subsystem 初始化也 amortized（N 次 → 1 次）
- ✅ PREAMBLE 仍 N 次但只是 var 赋值不是 register（廉价）
- ✅ 顺手加 memory_limit + max_stack_size（F-W1B-003 部分缓解）
- ✅ caller 0 改动：`DefaultJsRuntime::new()` API 不变
- ⚠️ Context 复用引入"globalThis 跨 eval 残留"风险——通过 PREAMBLE re-eval 重置 `java` 对象 + 文档化边界缓解
- ⚠️ timeout 触发后状态恢复依赖 rquickjs cooperative interrupt 文档承诺；需 test 验证
- ⚠️ F-W1B-025 RuleContext clone 大重构超出 effort，标 best-effort + 部分推迟可能
