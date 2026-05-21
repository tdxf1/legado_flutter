# Cross-Language Boundary

This project is a Rust workspace + Flutter app linked by [flutter_rust_bridge](https://cjycode.com/flutter_rust_bridge/) v2.12.0. The boundary is a hot spot for bugs because the type system on both sides is strict but the contract between them is hand-maintained.

## Spec Index

| Topic | File |
|---|---|
| FRB API contract, funcId table, hand-patched bindings | [frb-bridge.md](./frb-bridge.md) |
| Legado JSON ↔ local model field mapping | [field-mapping.md](./field-mapping.md) |
| Mental model for cross-layer data flow audits | [data-flow.md](./data-flow.md) |

## High-Level Picture

```
┌────────────────────────┐
│ flutter_app/lib        │
│   features/...         │  <- ConsumerStatefulWidget
│   core/...             │  <- Riverpod providers, helpers
│   src/rust/            │  <- FRB-generated Dart bindings (do not edit)
└──────────┬─────────────┘
           │  Dart ↔ Rust via flutter_rust_bridge
           │  ~89 pub fn exposed in bridge::api
┌──────────▼─────────────┐
│ core/bridge            │
│   api.rs               │  <- Result<String, String> JSON-encoded payloads
│   transaction.rs       │  <- with_transaction helper
│   local_book.rs        │  <- import flow used by api::import_local_book
│   frb_generated.rs     │  <- partly hand-edited; build.rs guards it
└──────────┬─────────────┘
           │
┌──────────▼─────────────┐
│ core-storage / core-source / core-parser / core-net │
│ Pure Rust crates                                    │
└──────────────────────────────────────────────────────┘
```

The bridge is sync. Async work that needs `tokio` constructs a `Runtime` locally inside the entry function (see `findings-rust-data.md::F-W1A-002` for why a global `Runtime` was rejected).

## Why a Cross-Language Spec Exists

Three categories of recurring bug:

1. **Field shape drift.** Rust adds a field, Dart parses old shape, defaults to `null`, UI shows wrong data. The fix is the field-mapping spec.
2. **funcId mismatch.** Hand-patched `frb_generated.rs` requires extra care; `core/bridge/build.rs` runs a string-match guard at compile time. The FRB spec documents this.
3. **Cross-layer assumptions.** "I assumed Rust returns this on error" — but the Rust function returned `Ok("")`. The data-flow spec teaches how to walk the chain end-to-end.

Read these specs before changing anything that crosses the boundary.
