# Error Handling

How errors are produced, propagated, and surfaced across the workspace.

## Layered Convention

| Layer | Error type | Why |
|---|---|---|
| `core-storage` DAOs | `rusqlite::Result<T>` (`SqlResult<T>`) | Keeps DB-specific context for callers that want to inspect codes. |
| `core-source` / `core-parser` / `core-net` | `Result<T, String>` | These crates already mix multiple error origins; collapsing to `String` keeps the public surface flat. |
| `bridge::api::*` | `Result<T, String>` (T is `()` or JSON `String`) | flutter_rust_bridge encodes Err as a Dart exception. The Flutter side reads only the message. |
| `api-server::routes` | `Result<T, AppError>` mapped to JSON | `error.rs` converts to `{"error": "..."}` with appropriate HTTP status. |

There is no shared `Error` enum across the workspace. The collapse to `String` happens at the crate boundary into `bridge` or `api-server`.

## Mapping at the Bridge

Every `bridge::api::*` `?` that crosses out of `core-storage` must include a context prefix:

```rust
// Good
let book = book_dao.get_by_id(&id)
    .map_err(|e| format!("查询书 {id}: {e}"))?;

// Bad
let book = book_dao.get_by_id(&id).map_err(|e| e.to_string())?;
```

Why: error messages reach the Flutter SnackBar verbatim. A user-readable Chinese context line plus the underlying error gives operators enough to act. The codebase mixes Chinese context strings (`"查询书"`, `"加载替换规则失败"`) with English variable substitution (`{e}` / `{}`); follow the local file's existing language when adding a new mapping.

## Silent Errors Are Forbidden

BATCH-23 swept the workspace and removed every `let _ = ...?`, `match Err(_) => Ok(())`, and `unwrap_or_default` that hid an actionable error. Before adding any of these patterns, ask:

- Is the failure recoverable for the caller? If yes, propagate it.
- Is it cosmetic (e.g. log file rotation)? If yes, log at `warn!` with full context, do not silence.
- Is it a known external invariant (e.g. WebDAV server returning 404 for a missing file)? If yes, branch on the specific error variant, not on `Err(_)`.

The audit list with file:line references for each fixed silent error is in `findings-rust-data.md` (look for entries marked `Resolved by BATCH-23`).

## Logging Errors

When the same error is both returned and logged, log at `warn!` (one line) **before** returning. Do not log at `error!` from a function that also returns `Err`; that double-counts incidents in observability dashboards. See [logging.md](./logging.md) for the full ladder.

## `bridge` Sync vs Async

flutter_rust_bridge entry points are sync. When the underlying work needs `tokio` (HTTP, async file IO), use `tokio::runtime::Runtime::new().block_on(...)` only inside the bridge fn. Do **not** stash a global `Runtime` — that would conflict with FRB's own runtime in some configurations and was the root cause of `findings-rust-data.md::F-W1A-002`. Keep the runtime construction local to the call.

## Error Surface Audit

The `api-server` follows a different convention: handlers return `Result<T, AppError>` where `AppError` is a typed enum with `IntoResponse`. When adding a new route, return early via `?` and let the converter pick the HTTP status. Do not write inline `(StatusCode::INTERNAL_SERVER_ERROR, body).into_response()`; this hides the error from `error.rs`'s tracing layer.

## Anti-Patterns

- `unwrap()` / `expect()` outside tests and `LazyLock::new` initialization. The two existing legitimate uses are tagged with comments.
- Returning `Result<String, String>` where the success `String` is itself JSON, but failing to call `serde_json::to_string` once at the boundary (callers shouldn't see different formats per fn).
- Catching panics with `catch_unwind` in production paths. None exist today; do not add them — let the panic propagate to FRB which converts it into a Dart exception.
