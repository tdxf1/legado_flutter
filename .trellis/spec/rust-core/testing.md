# Testing

Tests live alongside the module they cover. The repository ships ~378 cargo tests in five crates. There is no integration test crate at the workspace root.

## Layout

```
core-storage/src/<dao>.rs              -> #[cfg(test)] mod tests at the bottom
core-storage/src/database.rs           -> migration tests live here, not in dao files
core-source/src/...                    -> rule-engine + parser tests next to source
bridge/src/api.rs                      -> regex_cache_tests, scope_filter_tests, cache_concurrency_tests
bridge/tests/*.rs                      -> 8 integration tests using temp DBs
api-server/tests/*.rs                  -> 4 integration tests with axum::Router::into_make_service
```

Module-level tests are preferred over a separate `tests/` directory because most of the public APIs are crate-private.

## Common Fixtures

`core-storage` test setup is the canonical pattern:

```rust
fn setup() -> (TempDir, Connection) {
    let dir = TempDir::new().unwrap();
    let db_path = dir.path().join("test.db");
    let conn = crate::database::init_database(db_path.to_str().unwrap()).unwrap();
    (dir, conn)
}
```

- `tempfile::TempDir` is the only blessed temp-dir source. Hold it in the test scope so `Drop` deletes the file.
- Every test calls `init_database` to get the latest schema. Do not hand-roll `CREATE TABLE` in tests.
- For DAO-specific seed data, write a typed builder near the test (`make_book(id, source_id, name, author)` style) instead of inline `Book { ... }` literals. See `backup_dao.rs::tests::make_book` and `book_dao.rs::tests::make_book`.

## Concurrency Tests

`bridge::api::cache_concurrency_tests::unified_cache_keeps_generations_isolated` is the **must-pass** invariant for any change to `ReplaceRulesCache`. The test simulates two threads with different `cache_generation` values hammering the cache and asserts each thread sees only its own generation's compiled regex. If you refactor lock placement, run this test first.

The test pattern:

```rust
let cache = Arc::new(std::sync::Mutex::new(ReplaceRulesCache::new()));
let t_a = thread::spawn(move || { ... cache.lock().unwrap() ... });
let t_b = thread::spawn(move || { ... });
t_a.join().unwrap();
t_b.join().unwrap();
```

When introducing new shared state with similar semantics, follow this template instead of `tokio::test`. The bridge crate is sync; `tokio::test` would force unnecessary async wrapping.

## Test Naming

Tests use snake_case descriptive names, often Chinese-mixed:

- `test_encrypt_decrypt_roundtrip`
- `test_import_zip_rejects_oversized_single_entry`
- `test_try_decrypt_rejects_non_array_after_successful_decrypt`
- `unified_cache_keeps_generations_isolated`

Names should describe the behaviour and the expected outcome, not the implementation. `test_foo_bar_internal_helper_returns_42` is an anti-pattern; prefer `helper_returns_zero_on_empty_input`.

## When to Add a Test

Mandatory:

- New DAO method.
- New migration step (replicate the `test_migration_from_v1_to_v2` template).
- New `bridge::api::*` function (at least one happy-path test invoking through the public `pub fn`).
- New security boundary (zip size cap, AES validation, etc.). Pair every new defensive check with at least one negative test.

Optional but encouraged:

- Refactors that alter lock scopes or cache invalidation semantics. Add a stress test (multiple threads + 200 iterations is the local norm).
- Bug fixes — regression tests use the bug's symptom as the test name.

## Running Subsets Quickly

```bash
cd core
cargo test -p core-storage --lib backup_dao        # one DAO module
cargo test -p bridge --lib cache_concurrency_tests # one test mod
cargo test --workspace --lib --no-fail-fast        # whole sweep
```

API-server integration tests are slower because they compile a full axum app; do not include them in tight feedback loops unless the change touches `api-server`.

## What Tests Do **Not** Cover (and Why)

- FRB-generated bindings (`bridge/src/frb_generated.rs`). The file is regenerated; testing it is a tautology.
- Real network calls in `core-net`. Use `httpmock` or hand-rolled local servers; the workspace currently uses local async listeners in 3 places. Live network tests are flaky and not run in CI.
- Real WebDAV server. The `webdav.rs` tests stub the server with `mockito` style local listeners.
