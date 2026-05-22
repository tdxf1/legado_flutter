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

### RuleContext clone 复用模式（BATCH-13b）

`parse_chapters_from_page` 4 个串行 closure（`is_vip` / `is_volume` / `is_pay` / `update_time`）共享 1 个 outer-mutable `RuleContext`，每个 closure 内只重写 `result` 字段。原实现每章 4 次 `RuleContext::clone`（含整页 HTML `String` + 多个 String 字段 + `HashMap<String, LegadoValue>`），重构后整批 1 次 clone（4N → 1）。

```rust
// 适用：4 个 closure 串行不重入；inner 仅写 ctx.result
let mut shared_ctx = context.clone();
let vips = rules.is_vip.as_deref().map(|rule| {
    item_contexts.iter().map(|item| {
        shared_ctx.result = vec![LegadoValue::String(item.clone())];
        self.run_rule_first(rule, item, &shared_ctx).map(...)
    }).collect()
}).unwrap_or_else(|| vec![None; len]);
let is_volumes = rules.is_volume.as_deref().map(|rule| { /* 用 shared_ctx */ });
// is_pay / update_time 同上
```

适用条件：

- 多个 closure 串行不重入（每个 `Option::map` 立刻 evaluate 后释放借用，下一个再借）
- inner closure 只对 ctx 写一个字段（如 `result`），不依赖前一个 closure 的写入
- caller `run_rule_first(rule, html=item, &ctx)` 用 html 参数为源；`ctx.src` 在 `legado/js_runtime.rs::build_runtime_vars` 中 `if context.src.is_empty() { html } else { &context.src }` fallback——无论 `ctx.src` 是空（`for_search`）还是被 `for_toc(&url, &html)` 设为整页 html，都不被这 4 个 closure 写入，行为完全等价

不适用：

- closure 间有数据依赖（前一个 closure 写入需要后一个读取）
- closure 涉及异步跨 await（borrow lifetime 跨 await 边界不安全）
- 写入字段非"局部覆盖"（如 append 到 `Vec` 而不是替换）

Borrow checker 通过点：rust 把每个 `Option::map` 的 closure body 当 expression 立刻 evaluate，闭包内 `shared_ctx.result = ...`（mutable 借用）+ `&shared_ctx`（shared 借用）在调用 `run_rule_first` 后即 drop，下一个 `Option::map` 再次借用即可。canonical 实现：`core-source/parser.rs::parse_chapters_from_page`（line ~1369）。


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

## JS 沙箱安全边界 (BATCH-04)

**所有从 JS 桥接发出的 outbound HTTP 请求必须经过 `ssrf_guard::is_url_safe_for_fetch`**。canonical 入口：`java.ajax` / `java.downloadFile` / `java.queryTtf` / `LegadoHttpClient::request`。

### SSRF 防护 (`core-source/legado/ssrf_guard.rs`)

```rust
use super::ssrf_guard;

// 在 HTTP 请求入口处：
if let Err(e) = ssrf_guard::is_url_safe_for_fetch(&url) {
    tracing::warn!("SSRF blocked: {e}");
    return String::new(); // 或 Err(...)
}
```

拒绝规则：
- scheme 非 http/https → `SsrfError::ForbiddenScheme`
- host 是 loopback / RFC1918 / link-local / CGNAT / multicast / cloud metadata → `SsrfError::PrivateHost`
- URL 解析失败 → `SsrfError::InvalidUrl`

**不做 DNS rebinding 防护**（需要 async resolve，留 BATCH-10）。入口 URL 检查 + redirect 限制（`Policy::limited(5)`）是当前防线。

### 新增 outbound HTTP caller 的 checklist

1. 调 `ssrf_guard::is_url_safe_for_fetch(&url)` 在 `send()` 之前
2. 设 `redirect(Policy::limited(5))`（或更少）
3. 设 response body 上限（流式累计 or `take(max+1)`）
4. 如果 URL 来自 untrusted JS 输入，加 `tracing::warn!` 记录拒绝

### QuickJS 嵌套 Runtime 必须设 memory/stack limit

```rust
// 嵌套路径（QUICKJS_POOL_BUSY == true）
let runtime = Runtime::new()?;
runtime.set_memory_limit(QUICKJS_MEMORY_LIMIT);   // 64 MiB
runtime.set_max_stack_size(QUICKJS_STACK_LIMIT);   // 1 MiB
```

BATCH-13 池化时主路径已设；BATCH-04 补嵌套路径。任何新建 `Runtime::new()` 的代码路径都必须设这两个 limit。

### Font parsing 必须 catch_unwind

`ttf-parser` crate 不保证 panic-free。所有调 `font_mappings_json` / `Face::parse` 的路径用 `catch_unwind(AssertUnwindSafe(|| ...))` 包裹，panic 时返回 `"null"`。

### 文件桥 (`java.downloadFile` / `getFile` / `deleteFile` / `unzipFile`)

- `LEGADO_FILE_ROOT` env var 未设 = 文件桥禁用（`resolve_file_path` / `resolve_write_path` 返回 None）
- `MAX_ZIP_DOWNLOAD` = 10 MiB（BATCH-04 从 50 MiB 缩小）
- `java_unzip_file` 拒绝符号链接条目（`unix_mode & 0o170000 == 0o120000`）
- `java_download_file` 入口走 SSRF guard

### Android WebView bridge capability gate

`evaluateAndFinish` 在 `finish(payload)` 前调 `webView.removeJavascriptInterface("legadoNative")`。JS bridge 仅在 webJs 执行期间暴露；eval 完成后立即 detach，防止恶意页面在 result 回传后利用 bridge。

### Forbidden 反向

| Pattern | Why | Reference |
|---|---|---|
| `reqwest::blocking::Client::builder().build()` 不经 SSRF guard 发 outbound 请求 | 任何 untrusted URL 可访问内网 / 元数据服务 | BATCH-04 (F-W1B-001) |
| 新建 `Runtime::new()` 不设 `set_memory_limit` / `set_max_stack_size` | 恶意 JS 可 OOM 整个进程 | BATCH-04 (F-W1B-003) |
| `font_mappings_json` / `Face::parse` 不包 `catch_unwind` | 畸形 TTF 可 panic 整个线程 | BATCH-04 (F-W1B-004) |
| `addJavascriptInterface` 后不在 eval 完成时 `removeJavascriptInterface` | 恶意页面 JS 可调用 50+ bridge 方法 | BATCH-04 (F-W3-015) |
| `archive.by_name(path)` 不预先校验 `path` 含 `..` / 绝对路径 | zip-slip 可读到 archive 外文件 | BATCH-10 (F-W1B-005) |
| `LEGADO_FILE_ROOT.join(path).canonicalize()` 不预先 reject `..` 段 | symlink 解析窗口可绕 root 边界 | BATCH-10 (F-W1B-005) |
| 新建 `ureq::Agent` 不设 `max_redirects` | 恶意 redirect 链可暴露内部跳转 | BATCH-10 (F-W1B-007) |
| `serde_json::from_str` 解析 untrusted JSON 不设输入大小 / 条目数 / 单字段长度上限 | OOM / parser DoS | BATCH-10 (F-W1B-009) |

### F-W1B-006 业务边界（BATCH-10）

`java._vars` 与 PREAMBLE 写入的全局对象会跨同一线程的多次 eval **共享**，但跨 source / cross-thread 不会泄漏，亦非引入 key 白名单可解决的问题。结论 **Resolved-by-Design**，理由：

1. **Per-Context 隔离已就位**：`RuleContext::new` 为每个书源单独构造，`shared_variables`（`Arc<Mutex<HashMap<...>>>`）也是每书源独立。`_vars` 的"跨脚本可见"窗口仅限于同一 source、同一 OS 线程内连续 eval，正是 Legado 业务模型 `java.put('cookie', ...)` 在 `search → bookInfo → toc → content` 之间传递所必需。
2. **Thread-local RAII 已就位**：`JsVariablesOverride`（BATCH-11，`js_runtime.rs`）在 `eval_default_with_http_state` 入帧时快照、出帧时恢复 `LEGADO_JS_VARIABLES`，框定了"持久化窗口"。BATCH-13 的 QuickJS 池化进一步把 `Runtime + Context` 的复用与 PREAMBLE 重新执行解耦：每次 eval 都重建 `var java = { ... }`，user-script 写入 `java._vars` 的内容由 PREAMBLE 重置（参见 [`test_runtime_pool_isolates_user_state_via_preamble_reset`]）。
3. **写穿透是业务必需**：BATCH-11 配对的 `__legado_js_put` / `__legado_js_get` 桥（write-through + read-fallback）刚好让"`put` 在 eval A，`get` 在 eval B"在同 OS 线程内成立。这是 Legado 真实书源（如登录态、CSRF token）依赖的契约。
4. **Key 白名单不能加**：`java._vars` 的 key 来自书源作者；引入"`__` 开头拒收"之类规则无业务收益（外部 JS 写不到 `__legado_xxx_*`，那是 Rust 端注入的 free-standing function 名，不是 `_vars` 桶里的 key），反而会破坏现有书源对 `java.put('__cache_xxx', ...)` 这类命名的使用。
5. **跨线程持久化路径单独**：业务侧若需 cross-thread 状态，走 `RuleContext::shared_variables`（`Arc<Mutex>`），不要试图扩 `_vars`/`LEGADO_JS_VARIABLES`（thread_local，按设计跨线程不见）。

新代码不要为 `_vars` 加 key 白名单或 deny-list；如果发现真实泄漏，先核实是不是 RAII guard 范围错位（看 `JsVariablesOverride` 是否 wrap 了 entry function），再考虑重构。

## JS 模板表达式与 import 上限 (BATCH-10)

BATCH-04 把 SSRF / TTF / WebView 边界关上后，本批补三个未直接走 JS 沙箱、但同样是 untrusted-input 入口的边界。

### 模板变量白名单（F-W1B-008）

`core-source/legado/url.rs::resolve_template_expressions` 用 `TEMPLATE_VAR_WHITELIST: &[&str] = &["key", "keyword", "page", "encodeKey", "encode_keyword"]` 做 fast-path：

```rust
if TEMPLATE_VAR_WHITELIST.contains(&expr) {
    vars.get(expr).map(|v| v.as_string_lossy()).unwrap_or_default()
} else {
    // JS eval fallback for legitimate computations like (page-1)*20
    vars.get(expr).map(...).or_else(|| runtime.eval(expr, &vars).ok().map(...))
}
```

白名单命中的 `{{key}}` / `{{keyword}}` 类零 JS 注入风险（直接读 `HashMap`）；不在白名单的表达式（`{{(page-1)*20}}`、`{{java.base64Encode(key)}}`）继续走 `DefaultJsRuntime::eval`，由书源审核流程外的 trust 模型兜底。新加变量名时 **必须同步更新 `TEMPLATE_VAR_WHITELIST`**，否则就只能走 JS eval 慢路径（且失去白名单声明的安全性）。

### Import 大小 / 条目 / 单源字段上限（F-W1B-009）

`core-source/legado/import.rs` 顶部三常量：

```rust
const MAX_IMPORT_BYTES: usize = 5 * 1024 * 1024;     // 整个 JSON blob ≤ 5 MiB
const MAX_IMPORT_ENTRIES: usize = 5000;              // 单次 import ≤ 5000 个 source
const MAX_FIELD_BYTES: usize = 256 * 1024;           // 单字段基准
```

`import_legado_source` 入口先做 `json.len()` 检查，再 `serde_json::from_str`，再检查 `legado_sources.len()`；`legado_to_imported` 内部把 source 的"长字段"（`rule_search/explore/book_info/toc/content` JSON + `js_lib/header/login_url/login_check_js/search_url/explore_url/book_url_pattern/concurrent_rate/variable_comment/cover_decode_js/login_ui`）累加，超过 `MAX_FIELD_BYTES * 5 = 1.25 MiB` 就拒。规则字段是 `Option<JsonValue>`，长度走 `to_string()` 而非 `serialize`，避免给 `LegadoBookSource` 加 `Serialize`。

新增字段时记得：(a) 算长度时把它加到 `total` 里，(b) 加测覆盖（`test_import_rejects_oversized_per_source_fields` 是 canonical 模板）。

### Redirect 上限（F-W1B-007）

`core-source/legado/http.rs::LegadoHttpClient::new` 与 `proxy_agent` 的 `ureq::Agent::config_builder()` 链路加 `.max_redirects(5)`（ureq 3.x default 是 10，缩到 5）。配合 `ssrf_guard` 在入口做 SSRF 拒绝、`max_redirects` 限制跳转链长度，是当前对未知中间跳转的"两层防线"。**不要**在 `https_only(true)` 上做切换——中文小说源 http 仍是常态，BATCH-05 ADR 已记录该业务豁免。redirect 每跳的 SSRF 检查需要 ureq 暴露 redirect callback（3.x 没暴露），后续若升级再做。

### F-W1B-013 业务边界（决策路径）

`js_script_to_expression` 的 `needs_direct_eval` 分支保留 `eval(JSON_STRING)` 形式（**不**改为统一 IIFE 包装）。理由：

1. **本身不是安全洞**：`serde_json::to_string(script)` 产物是合法 JS 字符串字面量，正确转义 `'`/`"`/`\\`/`\n`/`</script>` 等 metacharacter；eval 内的内容是 user script byte-for-byte，不是 string concat 注入。`test_js_script_to_expression_eval_branch_escapes_meta_chars` 固化了这一契约。
2. **改 IIFE 会破坏 ~30 测试**：包装层 caller 是 `JSON.stringify(({}))`（参见 `js_runtime.rs::QuickJsRuntime::eval` line ~519、`BoaJsRuntime::eval` line ~582）；多语句脚本（`var x = 1; x`）的尾部 `x` 是 ExpressionStatement，QuickJS top-level eval 会把它当结果返回，但 IIFE 包装后函数 default return undefined。我们无法静态识别"最后一条表达式"自动注入 `return`，所以一刀切改 IIFE 后大量 bridge 测试会拿到 `null`。BATCH-10 实测 100+ 个测试中有 30+ 失败，回退此分支。
3. **`contains_return` 分支保留 IIFE**：脚本带显式 `return ` 时（`return foo` / `\nreturn foo`），裸顶层 return 在 QuickJS eval 模式触发 SyntaxError；对这一类必须 IIFE 包装让 return 合法。

新加的 PREAMBLE-internal eval 分支（如未来要做"检测尾部 ExpressionStatement 自动 return"）应当独立测试，不要破坏 `eval(JSON_STRING)` 这条已固化的兼容路径。


