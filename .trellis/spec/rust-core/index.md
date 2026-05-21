# Rust Core Workspace

Coding guidance for the `core/` cargo workspace. The workspace contains 6 crates that together implement the storage, parsing, and FFI layers consumed by the Flutter app.

## Workspace Layout

| Crate | Role | Public boundary |
|---|---|---|
| `core-storage` | SQLite schema, migrations, 21 DAOs, AES helper, backup/import. Owns `Connection` lifecycle. | Used by `bridge` and `api-server`. |
| `core-source` | Book-source rule engine (`legado/`, `rss/`, `rule_engine`, `parser`). Pure logic, no DB. | Used by `bridge` and `api-server`. |
| `core-parser` | Local file parsers (`epub`, `txt`, `umd`, `cleaner`). Pure logic, no DB. | Used by `bridge` for local imports. |
| `core-net` | HTTP client, cookie jar, retry, WebDAV, encoding detection. | Used by `core-source` and `bridge`. |
| `bridge` | flutter_rust_bridge surface. ~2700 lines of `pub fn` exposed to Dart. Owns `with_transaction` cross-DAO helper. | Linked into the Flutter app. |
| `api-server` | Optional debug REST server (`axum`). Used in development only. | Standalone binary. |

The full member list is fixed in `core/Cargo.toml:1` (`[workspace] members = [...]`) and a shared `[workspace.dependencies]` table centralizes 80% of dependency versions (BATCH-06).

## Spec Index

| Topic | File |
|---|---|
| Module ownership and import rules | [directory-structure.md](./directory-structure.md) |
| SQLite schema, transactions, DAO patterns | [storage-and-database.md](./storage-and-database.md) |
| Error propagation across `Result<T, String>` boundary | [error-handling.md](./error-handling.md) |
| `tracing` levels, log targets, secret handling | [logging.md](./logging.md) |
| Test layout, common fixtures, concurrency tests | [testing.md](./testing.md) |
| Forbidden patterns, lints, performance traps | [quality-and-anti-patterns.md](./quality-and-anti-patterns.md) |

## Quick Verification

```bash
# Run from the legado_flutter root (Cargo.toml lives in core/).
cd core
cargo build --workspace                    # 0 warning expected
cargo test --workspace --lib               # ~358 unit tests pass
cargo test -p bridge --tests               # 8 integration tests pass
cargo test -p api-server --tests           # 4 integration tests pass
```

The current green baseline is recorded in batch task PRDs under `.trellis/tasks/archive/2026-05/05-21-batch-09-aes-hardening/prd.md`.
