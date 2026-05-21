# Cargo Workspace

Conventions for `core/Cargo.toml` and the 6 sub-crates' `Cargo.toml`.

## Workspace Layout

```toml
[workspace]
members = ["core-net", "core-parser", "core-storage", "core-source", "bridge", "api-server"]
resolver = "2"
```

Member order is stable; do not shuffle. Some scripts grep for "members =" to enumerate crates.

## `[workspace.package]` and `[workspace.dependencies]`

`[workspace.package]` centralizes:

- `version = "0.1.0"`
- `edition = "2021"` — README mentions 2024 but every sub-crate is on 2021. Don't bump edition without a dedicated batch.
- `authors`, `license`, `repository`.

`[workspace.dependencies]` covers ~80% of dependencies. Sub-crates inherit via `serde = { workspace = true }` style. Two known exceptions are intentional:

| Dependency | Status | Why |
|---|---|---|
| `md5` (core-source) vs `md-5` (core-storage) | Not unified | Different APIs (`md5::compute` vs `Md5::new + update + finalize`). Unification batch tracked separately. |
| `zip 0.6` (one consumer) vs `zip 2.x` (backup_dao) | Not unified | API breaks in 2.0; backup_dao explicitly uses `zip = "2"`. |

When adding a new dependency:

1. Check if it's already in `[workspace.dependencies]`.
2. If not and ≥2 crates will use it → add to workspace deps.
3. If only one crate uses it → add to that crate's `[dependencies]` directly.
4. Use exact or pinned versions for security-sensitive crates (`aes`, `aes-gcm`, `argon2`, `tokio`); allow caret for general utilities.

## Lints

`core/Cargo.toml` declares:

```toml
[workspace.lints.rust]
unsafe_code = "forbid"

[workspace.lints.clippy]
# Rules added incrementally; mass-deny would break old code.
```

Each sub-crate inherits via `[lints] workspace = true` in its own `Cargo.toml`. Do not override at sub-crate level.

`unsafe_code = "forbid"` is firm. The only crate that may need an exception is `bridge` for FRB-generated code, but FRB v2 does not emit `unsafe` blocks today, so the forbid stays.

## Versioning

The whole workspace shares one version (`0.1.0`). Don't bump per-crate versions independently. The Flutter app reads its version from `pubspec.yaml` separately; keeping the Rust workspace at one number keeps tooling simple.

When the project reaches 1.0, the convention will revisit — until then, don't introduce per-crate versioning.

## Common Cargo Mistakes

- Adding a workspace dep but forgetting `{ workspace = true }` in the crate that needs it. Cargo silently uses the crate-local definition; the workspace version is ignored.
- Using `version = "*"` to "let cargo resolve". This breaks reproducibility and was a finding (`findings-cross-config.md::F-W3-024`-adjacent).
- Mixing `tokio = { workspace = true }` with `tokio = { features = ["full"] }` in the same crate. The right form is `tokio = { workspace = true, features = ["macros"] }` to extend, or accept the workspace's `features = ["full"]` umbrella as-is.

## Verification

```bash
cd core
cargo build --workspace                # 0 warning required
cargo tree -d                           # check duplicate dep versions
cargo audit                             # security advisories (optional but encouraged)
```

`cargo tree -d` is the fastest way to spot accidental dual-version situations introduced by a new dep.
