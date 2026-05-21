# Build and Release

How the project is compiled, packaged, and signed. The repository targets Android only at the moment; iOS/macOS/Windows/Linux Flutter targets exist in `pubspec.yaml` but are not actively built or tested.

## Spec Index

| Topic | File |
|---|---|
| Cargo workspace dependency hygiene | [cargo-workspace.md](./cargo-workspace.md) |
| Android wrapper, Gradle, signing, native libs | [android-build.md](./android-build.md) |
| Local build scripts and artifact layout | [build-scripts.md](./build-scripts.md) |

## Quick Reference

```bash
# Debug build + install (requires a connected device).
bash build_android_debug.sh

# Reproducible release build to dist/, with SHA256.
# Requires a clean working tree and a configured keystore.
bash build_android_release.sh

# Workspace-only sanity checks.
cd core && cargo build --workspace && cargo test --workspace --lib
cd flutter_app && flutter analyze && flutter test
```

The two scripts at the repo root are the only blessed build entry points. Don't introduce a parallel script; extend the existing ones if needed.

## Build Artifacts

| Artifact | Where | Purpose |
|---|---|---|
| `core/target/...` | Cargo's default target dir | Rust compile output. Symlinked to `/mnt/usb/legado-build/core-target` on the maintainer's machine to relieve disk pressure. |
| `flutter_app/build/...` | Flutter's default | Symlinked similarly. |
| `flutter_app/android/app/src/main/jniLibs/<abi>/libbridge.so` | Per-ABI native libs | Built by the Rust cross-compile step inside the build scripts. |
| `dist/legado-arm64-release-v<ver>-<commit>.apk` | Local release output | Reproducible: filename embeds commit short hash; build aborts if the worktree is dirty. |

The `*.so` outputs are ignored by `.gitignore`. Stale ABI directories from earlier builds are scrubbed by `build_android_debug.sh` to avoid mixing native libs from different commits.

## Test Baselines

| Suite | Count | Where to verify |
|---|---|---|
| Rust workspace lib tests | ~358 | `cargo test --workspace --lib` |
| Bridge integration | 8 | `cargo test -p bridge --tests` |
| api-server integration | 4 | `cargo test -p api-server --tests` |
| Flutter widget + unit | ~421 | `flutter test` |

Numbers grow as new batches land. Up-to-date counts live in the most recent BATCH PRD under `.trellis/tasks/archive/2026-05/`.
