# Trellis Specs

Coding guidance for the Legado Flutter project. The repository combines a Rust workspace (`core/`) with a Flutter app (`flutter_app/`), linked by [flutter_rust_bridge](https://cjycode.com/flutter_rust_bridge/). These specs reflect the codebase as it exists today.

## Map

| Scope | Folder | When to read |
|---|---|---|
| Rust workspace conventions (storage, error handling, logging, testing) | [rust-core/](./rust-core/index.md) | Adding or changing anything under `core/` |
| Flutter app layout, providers, mounted style, persistence | [flutter-app/](./flutter-app/index.md) | Adding or changing anything under `flutter_app/` |
| FRB bridge, field mapping, cross-layer audits | [cross-language/](./cross-language/index.md) | Anything that crosses the Rust ↔ Dart boundary |
| Cargo workspace hygiene, Android wrapper, build scripts | [build-and-release/](./build-and-release/index.md) | Touching `Cargo.toml`, `build.gradle.kts`, signing, or the build scripts |
| Pre-coding thinking guides | [guides/](./guides/index.md) | Before features that span layers, before promoting helpers, before backup-AES changes |

## How These Specs Are Maintained

- Each spec rule should cite a real file, test, or finding. If the rule has no source-backed example, prefer to delete it over keeping a generic statement.
- Findings in `.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-*.md` document the historical rationale for many rules. New rules added to a spec should reference the relevant finding ID when applicable.
- Batches under `.trellis/tasks/archive/` capture the migrations that produced the current shape (e.g. BATCH-24 promoted three helpers; BATCH-25 introduced `safeSetState`; BATCH-09 added zip caps and JSON-Array validation). When a spec rule says "use X", look at the batch that introduced X to understand the trade-offs.

## Quick Sanity Check

```bash
# Rust workspace
cd core && cargo build --workspace && cargo test --workspace --lib

# Flutter app
cd flutter_app && flutter analyze && flutter test
```

Baselines are recorded in the most recent batch PRD under `.trellis/tasks/archive/`.
