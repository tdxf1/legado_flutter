# FRB Bridge

flutter_rust_bridge (FRB) at version 2.12.0 generates the Dart side from `core/bridge/src/api.rs`. Both sides need to stay in lock-step.

## API Surface Conventions

Every FRB-exposed function in `core/bridge/src/api.rs`:

- Lives in the top-level `mod api { }` (or `pub fn` directly in `api.rs`).
- Returns `Result<String, String>` (JSON payload), `Result<(), String>` (commands), or `Result<i64, String>` (counts).
- Takes primitive parameters: `String`, `i32`, `i64`, `bool`. Compound inputs are JSON strings parsed inside Rust (`serde_json::from_str`).

Reasons:

- JSON-string contracts make the FRB binding tiny — only primitives travel over the boundary.
- `Result<_, String>` lets every Rust error reach the Flutter side as a Dart exception with the message intact. See [error-handling](../rust-core/error-handling.md).

When adding a function, **never** return `Result<MyStruct, MyError>`. FRB v2 supports it but the project intentionally avoids it to keep `frb_generated.rs` patches small.

## funcId Table and Hand-Patched Bindings

`core/bridge/src/frb_generated.rs` is **partly hand-edited**. The codegen `flutter_rust_bridge_codegen generate` has timed out on this repo (300–600s); maintainers added wire impls by hand for ~6 funcIds. To prevent the next contributor from regenerating and silently overwriting the patches, `core/bridge/build.rs` enforces:

1. Each known-manual `wire__crate__api__*_impl` must still exist in `frb_generated.rs`. If missing → build fails.
2. Each funcId Dart calls must be dispatched by Rust. Cross-check is against `flutter_app/lib/src/rust/frb_generated.dart`. Mismatch → build fails. Extra Rust funcIds Dart never calls → build warns (not error).

Rules for adding a new function:

1. Add `pub fn foo(...)` in `core/bridge/src/api.rs`.
2. Try `flutter_rust_bridge_codegen generate` first. If it finishes, commit both sides together.
3. If codegen times out, hand-add the wire impl in `core/bridge/src/frb_generated.rs` AND register the funcId in the Dart `frb_generated.dart`. Then add the function name to the manual-wire list in `core/bridge/build.rs:27` (the `// funcId N — name` comments).
4. Run `cargo build -p bridge` to confirm the guard passes.

## Type Mapping Pitfalls

| Rust | Dart | Pitfall |
|---|---|---|
| `i64` | `PlatformInt64` (alias: `int` on native, `BigInt` on web) | Use `core/util/platform_int64.dart::platformInt64ToInt` to coerce. The native-int + web-BigInt split bit ~7 features in this repo. |
| `String` | `String` | Always UTF-8. Don't pass raw byte arrays as `String`. Use `Uint8List` ↔ `Vec<u8>` if needed. |
| `bool` | `bool` | Straightforward. |
| `Option<T>` | `T?` | FRB handles it; just be sure Dart caller checks for null. |
| Custom struct returned as JSON | `Map<String, dynamic>` after `jsonDecode` | The `_legado_field_map` rules apply (timestamp ms↔s, bitmask↔id). Write a parse helper in `flutter_app/lib/core/dto.dart` if 2+ pages parse the same shape. |

The PlatformInt64 rule was a 7-site refactor in BATCH-24. Don't reintroduce the inline pattern; use the helper.

## Async vs Sync Surface

All FRB entries today are `pub fn` (sync). To run `tokio`-only code from one of them, build a `Runtime` locally:

```rust
pub fn explore(db_path: String, source_id: String, params: String) -> Result<String, String> {
    let rt = tokio::runtime::Runtime::new()
        .map_err(|e| format!("tokio runtime: {e}"))?;
    rt.block_on(async {
        // ... reqwest, JS engine, etc.
    })
}
```

Do **not** stash a global `LazyLock<Runtime>`. It conflicts with FRB's own runtime in some configurations, captured in `findings-rust-data.md::F-W1A-002`.

If a function needs to stream progress to Dart (e.g. download progress), today the project uses a polling `FutureProvider.family` on the Flutter side that calls a `bridge::api::get_download_progress(task_id)` query. FRB's `Stream<Item>` support exists but isn't used yet; adopt it only if polling becomes a perf problem.

## Generated Artifacts

These files are generated and must not be hand-edited (except `frb_generated.rs` which has the maintenance contract above):

- `flutter_app/lib/src/rust/api.dart`
- `flutter_app/lib/src/rust/frb_generated.dart`
- `flutter_app/lib/src/rust/frb_generated.io.dart`
- `flutter_app/lib/src/rust/frb_generated.web.dart`

They are committed because the codegen is slow and reproducible runs are flaky; treat regenerations like dependency upgrades.

## Verification

```bash
cd core
cargo build -p bridge          # build.rs runs the funcId guard
flutter test                    # uses the generated Dart bindings
```

If the build fails with `funcId X dispatched by Dart but not registered in Rust`, the most common cause is a renamed function. Check that the `_impl` symbol still exists in `frb_generated.rs`.
