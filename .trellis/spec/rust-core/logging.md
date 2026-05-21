# Logging

The workspace uses [`tracing`](https://docs.rs/tracing) (configured at `core/Cargo.toml::workspace.dependencies`). Every crate may import it directly:

```rust
use tracing::{debug, info, warn};
```

A subscriber is installed by `api-server::main` for binary runs and by FRB initialization for the mobile app. Library crates only emit events; they never configure a subscriber.

## Level Ladder

| Level | When to use | Examples |
|---|---|---|
| `error!` | A failure the operator must investigate but the function can still return safely. **Rare** in this repo. | None at the moment of writing. |
| `warn!` | Recoverable error, soft failures, deprecated paths, or "weak crypto" once-per-process notices. | `legado_aes::warn_weak_crypto_once`; `replace_rule_dao` regex compile failures; `core-net` retry exhaustion. |
| `info!` | Lifecycle events that an operator wants to grep at boot: DB init, migration applied, backup zip imported, login success. | `database::init_database`; `backup_dao::import_from_zip`. |
| `debug!` | Per-call diagnostics that should not be on at default log level. | DAO writes summarising affected rows. |

Do not introduce `trace!` unless wiring up a temporary investigation; remove before merging.

## Targeted Logging

Use the `target:` argument when the event is broad enough that operators want to filter it independently of the module name:

```rust
warn!(
    target: "legado_aes",
    "legado_aes 使用 AES-128/ECB + MD5(password)（与原 Legado 兼容），\
     这是弱混淆而非真加密。",
);
```

This pattern is currently used by:

- `legado_aes::warn_weak_crypto_once` — `target: "legado_aes"`.
- `core/api-server/src/main.rs` access log middleware — implicit module target.

Default to module target unless multiple modules emit the same logical channel.

## What Must Never Be Logged

The following are explicitly forbidden by past findings (`findings-rust-data.md::F-W1A-023`, `F-W1A-030`, `F-W1A-040`, `F-W1A-047`):

- WebDAV passwords or backup encryption keys, even partial.
- `api-server` debug tokens. Log a fingerprint (e.g. first 4 + last 4 chars) instead, never the full value. The `eprintln!` of the full token in `core/api-server/src/main.rs` is a one-time dev-mode print at startup; keep it out of `tracing` so it never reaches log aggregators.
- Raw cookie jars or `Authorization` headers from `core-net`.
- The contents of `legado_local.json` (which holds the backup password JSON-encoded). Reference the file path only.

If you must log a credential-adjacent value for diagnosis, hash it with `sha2::Sha256` and log the hex prefix.

## Once-Per-Process Notices

For warnings that should fire once even if the function is called millions of times, use `std::sync::Once`:

```rust
static WEAK_CRYPTO_WARNED: Once = Once::new();

fn warn_weak_crypto_once() {
    WEAK_CRYPTO_WARNED.call_once(|| {
        warn!(target: "legado_aes", "...");
    });
}
```

Reference: `core/core-storage/src/legado_aes.rs::warn_weak_crypto_once`.

## Reading Logs During Development

```bash
RUST_LOG=info cargo test --workspace --lib  # Default. Misses debug! events.
RUST_LOG=core_storage::backup_dao=debug cargo test ...   # Per-module trace.
RUST_LOG=legado_aes=warn,info cargo run -p api-server    # Mix-and-match.
```

The Flutter app's debug build pipes Rust logs through FRB into `print` lines visible in `flutter logs`.
