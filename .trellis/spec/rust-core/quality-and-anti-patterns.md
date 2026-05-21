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
