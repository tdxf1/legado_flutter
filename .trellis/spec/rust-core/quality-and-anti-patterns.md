# Quality and Anti-Patterns

Patterns the workspace explicitly accepts or rejects, with traceable history.

## Lints

`core/Cargo.toml` declares the workspace-level lints (BATCH-06):

```toml
[workspace.lints.rust]
unsafe_code = "forbid"   # No unsafe outside generated FFI surface.

[workspace.lints.clippy]
# Deny only what we already pass cleanly. Avoid mass deny that breaks builds.
```

Each sub-crate inherits via `[lints] workspace = true`. Do not add `#[allow(...)]` on a struct or module without a comment explaining the rationale.

## Cargo Workspace Hygiene

- Centralized dependency versions live in `[workspace.dependencies]`. New shared deps go there. Crate-local `[dependencies]` should declare them as `serde = { workspace = true }` style.
- Two known exceptions (md5 vs md-5, zip 0.6 vs 2.x) are deliberately left unsynced; see comments in `core/Cargo.toml` and `findings-cross-config.md::F-W3-024`. Track future unification batches via roadmap.
- Never bump a `[workspace.dependencies]` major version without checking that every dependent crate compiles cleanly — `cargo build --workspace` is the gate.

## Forbidden Patterns

| Pattern | Why | Reference |
|---|---|---|
| `Connection::open` outside `database::get_connection` | Skips PRAGMA setup including WAL. | `findings-rust-data.md::F-W1A-055`, BATCH-08c |
| `let _ = result;` to ignore errors | Hides actionable failures. | BATCH-23 sweep |
| Logging full WebDAV password / api-server token | Credential leak to log files. | `findings-rust-data.md::F-W1A-023/030/040/047` |
| Calling `encrypt_legado_aes` outside Legado-compat path | The algorithm is weak by design (ECB+MD5). | `legado_aes.rs` doc + [backup-aes guide](../guides/backup-aes-thinking-guide.md) |
| Holding `REPLACE_RULES_CACHE.lock()` while running SQL or `replace_all` | Serialises reader main thread. | `findings-rust-data.md::F-W1A-019`, BATCH-09 |
| `HashMap` keyed lookups inside hot loops without considering `entry()` API | Double-hash overhead. | `regex_entries::entry().or_insert_with()` is the local pattern. |
| Reading entire backup-zip entries without size cap | zip-bomb OOM risk. | BATCH-09 added `MAX_ZIP_ENTRY_SIZE` + `MAX_ZIP_TOTAL_SIZE`. |

## Performance Traps

- **Per-call `Runtime::new()` inside FRB sync entries**: necessary, but only the entry function should construct the runtime. Helpers should accept `&Runtime` or be plain sync.
- **Re-compiling regex on each chapter**: `bridge::api::ReplaceRulesCache` is the canonical example of a scoped cache keyed by `cache_generation`. New regex caches should follow the same generation pattern.
- **`rules.iter().filter(...).filter(...).filter_map(...)` inside the cache lock**: keep the cache critical section to lookups + clones only. Regex evaluation runs lock-free after the closure releases the lock. See `apply_replace_rules_impl`.
- **Cloning `Arc<Vec<T>>`**: cheap, do not shy away. The cache returns `Arc<Vec<ReplaceRule>>` precisely so callers can clone-and-detach for iteration without keeping the lock.
- **`thread_local` micro-cache keyed by `&str` `(ptr, len)` MUST be cleared at every entry point**: `core-source/legado/rule.rs::LAST_PARSED_HTML` is the canonical example (BATCH-14, F-W1B-029). The pattern caches `Rc<scraper::Html>` so the 5 search fields + every `||` combinator branch share one parsed DOM. The `(ptr_addr, len)` key is collision-free **within a single parser entry-point call** (the html `String` keeps a stable address for the call's lifetime), but the allocator may reuse the same address across calls — so any new rule-evaluation entry-point function in `core-source` MUST call `clear_html_parse_cache()` (or its equivalent) up front. Today the 7 entry points are `parser::search` / `explore` / `get_book_info` / `get_chapters` / `get_chapter_content` and `rss::get_articles` / `rss::fetch_article_content_full`; if you add an 8th, add the clear there too.

## Resolved-by-Design Findings

When a `findings-*.md` entry has been substantively addressed by an earlier change but the original code still matches the literal "problem" description, document the mitigation in **two** places rather than touching code:

1. **Source code**: append a comment near the cited code pointing at the mitigation (e.g. `core-source/parser.rs::RATE_LIMITER` doc-comment references `should_run_sweep_now` for F-W1B-030).
2. **Master report**: append a `**Resolution**: BATCH-NN — verified mitigated by ...; intentional design.` line on the finding.

This prevents future audits from re-flagging the issue and reading the comment makes the intent clear without code archaeology. References: F-W3-030 (BATCH-23), F-W1B-030 (BATCH-14).

## JS PREAMBLE × Rust thread_local State Sharing

When state needs to flow across `eval()` calls in `core-source/legado/js_runtime`, neither side alone is enough — you need **paired write-through + read-fallback bridges**:

- **Write side**: PREAMBLE method writes to JS-local `_vars` (fast in-eval reads) AND calls `__legado_xxx_put` Rust bridge (writes thread_local `LEGADO_JS_VARIABLES`). Both ends, every put.
- **Read side**: PREAMBLE method first checks JS-local `_vars[k]` (covers same-eval put-then-get); on miss, calls `__legado_xxx_get` Rust bridge (covers cross-eval persistence).

Why both bridges, not one: each `eval()` builds a fresh QuickJS Runtime + Context with `_vars` reseeded from `__legado_variables__` (a snapshot, not a live binding). Write-through alone makes the next `eval()` see the value via `build_runtime_vars` reading the thread_local, but only if `JsVariablesOverride::install` was called at frame entry — that guard is installed by `eval_default_with_http_state` but **not** by raw `DefaultJsRuntime::new().eval(...)`. The read-fallback bridge fills that gap and makes the cross-eval contract work for all callers, including unit tests using raw `eval()`.

Canonical example: `java.put` / `java.get` (BATCH-11, F-W1B-011). The dual-bridge pair is `__legado_js_put` + `__legado_js_get`.

Boundary the pattern applies to: any `core-source/legado/js_runtime` PREAMBLE method that needs state visible across `eval()` calls within a single OS thread. Cross-thread state still belongs to `RuleContext::shared_variables` (Arc<Mutex<...>>), not thread_local.

## Selective `block_in_place` for Sync JS Evaluation in Async Reactor

Sync rule evaluation that **may** trigger long-running blocking work (QuickJS exec + synchronous `java.ajax` HTTP, 5s ~ 30s) inside a function called from an async reactor needs `tokio::task::block_in_place` wrapping — but **only** when the rule actually triggers blocking work, AND only when running in a tokio context with a multi-thread runtime. Always-wrap or never-wrap are both wrong:

- Always wrap: pure CSS / XPath / JSONPath / Regex rules are µs-scale; `block_in_place`'s scheduler-rebalance overhead would dominate hot paths.
- Never wrap: synchronous JS exec (incl. `java.ajax` 5s default HTTP timeout) on the reactor thread starves co-tenant tasks on the same worker.
- `spawn_blocking + .await`: requires turning the caller chain async; for `BookSourceParser::run_rule_first`, that's 11 sync callers in `parser.rs` (search / explore / book_info / toc) — full async migration is deferred (estimated +500 lines).

Detection helper lives in the module owning the rule taxonomy, NOT inline at the call site. For Legado rules: `legado::is_blocking_rule(rule)` in `core-source/legado/js_shim.rs` returns `is_js_rule(rule) || rule.contains("<js>")` (covers `@js:` / `js:` / `@js\n` prefixes plus inline `<js>...</js>`). Pub-used through `legado::*` (`legado/mod.rs:18`).

Runtime guard: wrap with `block_in_place` only when `tokio::runtime::Handle::try_current().is_ok()`. This prevents panic on `current_thread` runtime (e.g. sync `#[test]` not under tokio context). Outside tokio, just call the sync path — already on a non-reactor thread, no harm in blocking.

Canonical example: `BookSourceParser::run_rule_first` in `core-source/parser.rs:495` (BATCH-16, F-W1B-038):

```rust
fn run_rule_first(&self, rule: &str, html: &str, context: &RuleContext) -> Option<String> {
    if crate::legado::is_blocking_rule(rule)
        && tokio::runtime::Handle::try_current().is_ok()
    {
        tokio::task::block_in_place(|| {
            self.run_rule(rule, html, context).ok()?.into_iter().next()
        })
    } else {
        self.run_rule(rule, html, context).ok()?.into_iter().next()
    }
}
```

Production multi-thread guarantee: FRB 2.12 default handler (`flutter_rust_bridge::frb_generated_default_handler!()`) uses a multi-thread tokio runtime + `core/Cargo.toml:33 features = ["full"]`, so the gate always passes in production. The content-fetch path was already wrapped in `run_rule_first_blocking` (`parser.rs:1685`) via `spawn_blocking` since pre-BATCH-16; this batch closed the gap on search / explore / book_info / toc.

Boundary the pattern applies to: any sync evaluation of an external-author-controlled rule (i.e. user-imported book source) that might invoke synchronous HTTP/IO. Pure CPU-bound rules don't need it. New rule-evaluation entry-points should reuse `is_blocking_rule` (or extend it in `js_shim.rs`) — do not duplicate the `@js:` / `<js>` detection inline at the call site.

## QuickJS Runtime + Context Pooling (per-thread, BATCH-13)

`QuickJsRuntime::eval` reuses a single `rquickjs::Runtime` + `Context` per worker thread via the thread-local pool in `core-source/legado/js_runtime.rs::QUICKJS_POOL`. Bridge registration (`register_quickjs_bridge`, ~30 `__legado_*` `Function`s) runs **once per worker thread** instead of per call. The dominant cost on a Legado TOC parse (100 chapters × 2 evals = 200 register calls) collapses to 1.

### What is amortized vs what runs every call

| Per thread (init only) | Per call |
|---|---|
| `Runtime::new()` + `set_memory_limit(64 MiB)` + `set_max_stack_size(1 MiB)` | `set_interrupt_handler(Some(...))` (new `Instant::now()`) |
| `Context::full(&runtime)` | `delete globalThis.__legado_*` (5 PREAMBLE-guarded vars) |
| `register_quickjs_bridge(&ctx)` | Inject `vars` via `legado_value_to_js_var` + `ctx.eval` |
| | `ctx.eval(PREAMBLE)` (rebuilds `var java = { ... }`) |
| | User script |

### Isolation contract

- `java`, `cache`, `cookie`, `source`: fully reset by re-evaluating PREAMBLE — this is the mechanism that prevents user-script writes (`java._vars.X = ...`, `java.headerMap.put(...)`) from leaking into the next eval.
- PREAMBLE-guarded globals (`__legado_url__`, `__legado_headers__`, `__legado_default_headers__`, `__legado_variables__`, `__source_url__`): explicitly cleared via `delete globalThis.X` before var injection so `typeof X !== 'undefined'` checks behave the same as on a fresh runtime.
- User-script top-level globals (`var x = 1`): NOT cleared. Real Legado sources never depend on this; cross-eval state goes through `java.put` / `java.get` (the `LEGADO_JS_VARIABLES` thread-local bucket) or `RuleContext::shared_variables`.

### Re-entrancy

Bridge fns like `__legado_get_string` recursively call `execute_legado_rule`, which may eval another JS rule. Re-entering `Context::with` on the same `Context` would deadlock on the runtime mutex. The pool guards against this with `QUICKJS_POOL_BUSY: thread_local Cell<bool>`: nested calls fall back to a one-shot `Runtime + Context` (the pre-BATCH-13 path). The pool covers the common top-level case; nested evals are rare and pay the original cost. Don't paper over the busy flag — it's the deadlock fence.

### Error recovery

- `Runtime::new()` failure: propagate the error, leave the pool entry `None` so the next call retries init.
- Timeout interrupt: rquickjs leaves the runtime in a usable state (cooperative interrupts at safepoints); `test_runtime_pool_recovers_from_timeout` enforces this contract — if rquickjs ever changes, this test catches it before production.
- Per-eval failure (set vars / PREAMBLE / user script): entry stays alive. Matches pre-BATCH-13 contract; rebuilding the entry on every script error would defeat the point.

### Test invariants (don't delete)

- `test_runtime_pool_amortizes_bridge_register` — 100 warm evals must take less than 100× a cold eval. If somebody re-introduces `Runtime::new()` per call, this trips.
- `test_runtime_pool_isolates_user_state_via_preamble_reset` — writes to `java._vars.X` must not survive the next eval. If somebody removes the PREAMBLE re-eval (or skips var-clearing), this trips.
- `test_runtime_pool_recovers_from_timeout` — eval after a 5 s timeout must succeed. If rquickjs's interrupt contract regresses, or if our pool gets corrupted by Err paths, this trips.

### When NOT to extend the pool

- Cross-thread Runtime sharing: `rquickjs::Context` is `!Send`. `Mutex<Runtime> + Vec<Context>` was considered and rejected (per-thread pool already amortizes the dominant cost; cross-thread complexity buys little).
- Caching compiled jsLib bytecode: separate concern (per-source cache, keyed by source ID). Not implemented yet; track as a follow-up if profile data justifies it.

## Legado 规则单一执行路径 (BATCH-15)

`core-source` 的规则执行入口收口到 `crate::legado::execute_legado_rule(rule, html, context)`（`core-source/src/legado/rule.rs:122`）。`crate::rule_engine::RuleEngine::execute_rule` 路径 **deprecated**，新代码不允许调用 — 编译期由 `RuleEngine` 上的 `#[deprecated]` 阻挡，外部 crate 由 `lib.rs::pub use` 不再 re-export `RuleEngine`/`RuleError` 阻挡。

### 执行 vs 校验：模块职责切分

`rule_engine.rs` 模块整体保留，但用途收窄到 **规则字符串静态校验**：

| 来源 | 用途 | 谁用 |
|---|---|---|
| `rule_engine::RuleExpression::parse(rule_str)` | 解析规则字符串识别 type（CSS / XPath / Regex / JSONPath / JS） | `lib.rs::check_rule_expression`（导入 / 校验阶段） |
| `rule_engine::RuleType` | 规则类型枚举 | 同上 |
| `rule_engine::strip_legado_replace_rules` | 剥离 `##` 替换规则后缀 | 同上 |
| `rule_engine::strip_css_modifiers` | 剥离 `!1` / `@@-2` 修饰符 | 同上 |
| `rule_engine::split_css_alternatives` | `||` 分支拆分 | 同上 |
| `rule_engine::RuleEngine::execute_rule` | **deprecated** — 用 `legado::execute_legado_rule` 代替 | 仅 `rule_engine.rs` 自身的内部 test（已 `#[allow(deprecated)]`） |
| `rule_engine::RuleExpression::evaluate` | **deprecated** | 同上 |

新增校验 helper（如 `validate_xxx` 类）若需要规则的纯文本预处理，加在 `rule_engine.rs` 模块（pub(crate)）；新增执行 helper 加在 `legado::rule::*`。两者不要混淆。

### 删除 fallback 的行为变化

BATCH-15 之前 `BookSourceParser::run_rule` 是 "先试 legado/rule 再 fallback rule_engine" 的过渡形态：

```rust
// 旧（BATCH-15 之前）
match crate::legado::execute_legado_rule(rule, html, context) {
    Ok(results) if !results.is_empty() => return Ok(results),
    Ok(results) if !can_fallback_to_legacy_rule_engine(rule) => return Ok(results),
    _ => {}
}
self.rule_engine.execute_rule(rule, html).map_err(|e| e.to_string())
```

```rust
// 新（BATCH-15 之后）
crate::legado::execute_legado_rule(rule, html, context).map_err(|e| e.to_string())
```

行为差异：legado/rule 返回 `Ok(vec![])` 时不再 fallback 到 rule_engine。对真实书源意味着：

- 同一规则在 legado/rule 实际匹配为空时：用户立即看到结果列表为空（更好的可调试性）；不再被 rule_engine 兜底误以为有结果。
- 同一规则在 legado/rule 返回 `Err(...)` 时：错误直接上抛而不再被 fallback 吞掉。

如果未来发现某真实书源 case 在 legado/rule 上 fail 但在旧 rule_engine 上 work，**修 legado/rule（按真实规则语义）而不是恢复 fallback**。fallback 是历史债，不是 feature。

### `#[deprecated]` × `-D warnings` 配套

deprecated struct / fn 在工作区内部仍有少量调用点（`rule_engine.rs` 内部的 `impl RuleEngine` body / `impl Default` / `mod tests`），需要 `#[allow(deprecated)]` 覆盖以避免 `-D warnings` 触发。模式：

```rust
#[deprecated(note = "use legado::execute_legado_rule; rule_engine retained only for ...")]
pub struct RuleEngine { ... }

#[allow(deprecated)]
impl RuleEngine { pub fn new() -> Self { ... } }

#[allow(deprecated)]
impl Default for RuleEngine { fn default() -> Self { Self::new() } }

#[cfg(test)]
#[allow(deprecated)]
mod tests { ... }
```

不要在外部 caller 上加 `#[allow(deprecated)]` — 那是用毒。`#[allow]` 仅在 deprecated 项**自身定义所在模块**的 internal scaffold 上使用，让 deprecated 项保持工作但触不到 caller。新代码绝对不要新增 `RuleEngine::new()` / `RuleExpression::evaluate(...)` 调用点。

### `legado::execute_legado_rule` 空 rule_str 契约

`execute_legado_rule(rule_str, html, context)` 在 `rule_str.trim()` 为空时返回 `Ok(Vec::new())`（不是 `Ok(vec![html.to_string()])` 透传）。caller 用结果非空判定"是否匹配成功"是合法的。已有单测 `test_execute_legado_rule_empty_rule_returns_empty` 固化此契约。如果 caller 有"空 rule 表示透传整章 html"的特殊业务需求，应在 caller 层显式处理（None / "" 提前返回 html）而不是依赖 `execute_legado_rule` 的旧透传行为。

## Code Hygiene Checks

Before committing:

```bash
cd core
cargo build --workspace                # 0 warning required
cargo test --workspace --lib --no-fail-fast
cargo fmt --check                      # configured by .rustfmt? not used today; rely on rustfmt defaults
```

The repo does not run `cargo clippy` on every push because the workspace pre-dates many lint rules. When introducing new code, run clippy locally and fix obvious issues.

## When You Find an Anti-Pattern

1. Confirm it appears in more than one place. One-off accidents go in the same commit as the user-facing change.
2. Capture it as a `findings-*` entry under `.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/` if it warrants a roadmap batch.
3. Update **this file** with the rule and the reference.

The list above started empty in BATCH-22 and grew through audits. Adding an entry is part of the fix.
