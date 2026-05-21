# Cross-Layer Data Flow

Every important user action in this app crosses 4 layers: UI page → Riverpod provider → FRB bridge → Rust crate (DAO / parser / network). Bugs concentrate at layer joins. Use this checklist before implementing a feature that crosses them.

## The Five Layers

```
1. Page widget          features/<area>/*_page.dart
2. Riverpod providers   core/providers.dart  +  per-feature providers (rare)
3. Generated FRB        flutter_app/lib/src/rust/api.dart
4. bridge::api::*       core/bridge/src/api.rs
5. core-storage / core-source / core-parser / core-net
```

Read state flows top-to-bottom (`ref.watch` → `FutureProvider` → `rust_api.foo()` → `dao.get(...)`). Write state flows the same direction, but the **invalidation** flows back up: after writing, the page must `ref.invalidate(...)` the providers it just dirtied.

## Audit Recipe (Before Implementing)

Walk the chain forward, then backward.

### Forward Walk (Read Path)

For each layer, ask:

- **Page**: Which provider does this widget watch? What shape does the page expect?
- **Provider**: What does this `FutureProvider` await? Does it transform the FRB result? Where do its parameters come from?
- **FRB**: What does the Dart wrapper return — `String` (JSON), `int`, `List<dynamic>`? Is there a parse step?
- **bridge::api**: What's the JSON-encoded shape? Does the function read more than one DAO?
- **DAO**: Which columns? Which migrations may have changed them?

If any layer transforms shape, write down the input → output. Two transformations touching the same field are a smell.

### Backward Walk (Write/Invalidation Path)

After a write, every layer must report back:

- **DAO**: Returns affected row count or `Result<(), Error>`.
- **bridge::api**: Returns `i64` (count) or `()`. Errors propagate.
- **FRB**: Returns Dart `int` / `void`. PlatformInt64 needs `platformInt64ToInt`.
- **Provider**: The page should `ref.invalidate(...)` *every* affected provider (not just the obvious one). Backups invalidate 5; deletes invalidate 3+.
- **Page**: After invalidation, does the watch re-fire? Is the loading state observable to the user?

## Real Example: Delete a Book

Forward read:
- `bookshelf_page.dart` watches `allBooksProvider`.
- `allBooksProvider` is a `FutureProvider<List<Map<String, dynamic>>>` that awaits `rust_api.getAllBooks(dbPath: ..., sortOrder: ...)` and `jsonDecode`s the result.
- `bridge::api::get_all_books` calls `BookDao::get_all_sorted` and `serde_json::to_string`.

Backward write:
- User taps delete. Page calls `rust_api.deleteBook(dbPath: ..., id: bookId)`.
- `bridge::api::delete_book` runs `with_transaction` to delete book + chapters + bookmarks + read records (multi-DAO) atomically.
- After `await`, page calls:
  ```dart
  ref.invalidate(allBooksProvider);
  ref.invalidate(booksByGroupProvider);
  ref.invalidate(bookChaptersProvider(bookId));
  ```
- Riverpod re-runs `allBooksProvider`, the bookshelf grid rebuilds, the deleted book is gone.

Missing any step in the backward walk produces "ghost" rows in the UI until the user navigates away.

## Cross-Layer Bug Patterns

| Symptom | Likely cause | Where to look |
|---|---|---|
| Stale row in list after delete | Provider not invalidated | The page that performs the mutation. |
| "1970-01-01" timestamps | Timestamp not run through `ms_to_seconds_smart` | `legado_field_map.rs` |
| `null` field in Dart map | Rust serializer omits the field with `#[serde(skip)]` | `core-storage::models` |
| FRB call returns `BigInt` and Dart casts to `int` panics | Missing `platformInt64ToInt` | `core/util/platform_int64.dart` |
| Concurrent writes blast each other's settings | Missed `_Mutex` in `json_store` | `core/persistence/json_store.dart` |
| Reader main thread stutters during chapter switch | SQL or work inside a global lock | `bridge::api::apply_replace_rules_impl` (already fixed) |

The Reader chapter-switch case was the canonical multi-layer bug: page state machine → provider → FRB → bridge mutex → SQL. Each layer added a small amount of overhead until the reader visibly stuttered. The fix in BATCH-09 moved SQL out of the lock; that change required understanding all five layers in this list.

## Tooling

- For ad-hoc tracing, set `RUST_LOG=info` and add temporary `info!` logs in `bridge::api::*`. Remove before commit.
- `flutter logs` shows both Flutter `print`/`debugPrint` and Rust `tracing` output (FRB pipes them).
- For DB-level inspection, the test setup pattern in `core-storage` (TempDir + init_database) makes one-off probing easy. The `api-server` debug binary is the heavier alternative when you need REST-style inspection.

## Reference Reading

- [field-mapping](./field-mapping.md) — what changes shape, and where.
- [frb-bridge](./frb-bridge.md) — how the seam is glued together.
- [../guides/cross-layer-thinking-guide](../guides/cross-layer-thinking-guide.md) — the broader thinking template.
- [../guides/code-reuse-thinking-guide](../guides/code-reuse-thinking-guide.md) — when to lift a helper across layers.
