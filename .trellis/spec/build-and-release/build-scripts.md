# Build Scripts

Two Bash scripts live at the repo root: `build_android_debug.sh` and `build_android_release.sh`. They are the only blessed entry points for native + Flutter builds.

## `build_android_debug.sh`

What it does:

1. Sets toolchain env (`ANDROID_HOME`, `NDK_HOME`, `FLUTTER_ROOT`, cargo cross-compile vars).
2. Cross-compiles `core/bridge` to `aarch64-linux-android` (release profile for stable .so).
3. Scrubs old `flutter_app/android/app/src/main/jniLibs/*/libbridge.so`.
4. Copies the freshly built `libbridge.so` into `arm64-v8a/`.
5. Runs `flutter run` to build + install on the connected device.

When to use: every dev build, every functional verification.

## `build_android_release.sh`

Adds on top of the debug script:

- **Refuses to build with a dirty worktree.** `git diff --quiet` and `git diff --cached --quiet` must both pass. Reproducible release artifacts depend on the commit hash, so any uncommitted change would falsify the artifact name.
- Uses `key.properties` (or warns and falls back to debug keystore — see [android-build.md](./android-build.md)).
- Outputs to `dist/legado-arm64-release-v<ver>-<commit>.apk`.
- Generates a SHA256 file alongside the APK so users on GitHub Releases can verify integrity.

When to use: cutting a release. Run on a clean working tree from `main`.

## Environment Defaults

```bash
ANDROID_HOME="${ANDROID_HOME:-/opt/android-sdk}"
NDK_VER="28.2.13676358"
FLUTTER_ROOT="${FLUTTER_ROOT:-/root/flutter}"
```

If a maintainer's machine differs, the recommended pattern is to export the variables before running:

```bash
ANDROID_HOME=/path/to/sdk FLUTTER_ROOT=/path/to/flutter bash build_android_debug.sh
```

Don't hard-code different paths in the scripts. The `${VAR:-default}` form is the contract.

## Adding a New Build Step

If you need to add a step (e.g. running a code generator before `flutter run`), put it inside the existing scripts in the natural order:

```
1. env setup
2. cargo cross-compile
3. .so scrub + copy
4. (new step here, e.g. build_runner)
5. flutter run / flutter build apk
6. (release only) sign + dist + checksum
```

Don't introduce a third script. Two scripts cover the realistic matrix (debug-on-device vs reproducible-release); a third would dilute the workflow.

## What's NOT in the Scripts

- iOS / macOS / Windows / Linux Flutter builds. Listed in `pubspec.yaml` for `flutter create` to render scaffolding, but not actively built or tested. Adding them is a roadmap item, not a casual change.
- Code signing for the Rust binaries. The shipping artifact is the APK; .so files are bundled inside.
- Play Store upload. Uploads are manual.
- CI workflows. The repo does not run CI; commit hooks and `cargo build` / `flutter analyze` / `flutter test` are the local quality gates.

## Failure Triage

| Failure | Likely cause | Fix |
|---|---|---|
| `cargo: command not found` | `~/.cargo/bin` not in PATH | `export PATH="$HOME/.cargo/bin:$PATH"` |
| `Worktree dirty, refusing release build` | Uncommitted changes | Commit or stash, then re-run |
| `error: not connected` (flutter run) | No device | `adb devices` to check; debug script needs a device |
| `Could not find SDK 'flutter'` | Wrong `FLUTTER_ROOT` | Export with the correct path |
| `unresolved import bridge::api::foo_bar` (cargo) | Function added in Rust but FRB binding stale | See [frb-bridge](../cross-language/frb-bridge.md) and regenerate or hand-patch |

## Verification After a Release Build

```bash
ls -lh dist/                   # APK + .sha256
sha256sum -c dist/*.sha256     # verify
unzip -l dist/*.apk | grep libbridge.so   # confirm native lib is bundled
```
