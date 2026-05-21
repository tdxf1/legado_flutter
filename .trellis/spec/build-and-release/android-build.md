# Android Build

Android is the only actively shipped platform. The Gradle wrapper lives in `flutter_app/android/`.

## Toolchain Pinning

The build scripts pin specific tool versions to avoid drift:

```bash
ANDROID_HOME="${ANDROID_HOME:-/opt/android-sdk}"
NDK_VER="28.2.13676358"
NDK_HOME="$ANDROID_HOME/ndk/$NDK_VER"
FLUTTER_ROOT="${FLUTTER_ROOT:-/root/flutter}"
```

`build.gradle.kts` mirrors:

- `compileSdk = flutter.compileSdkVersion` (from Flutter)
- `ndkVersion = "28.2.13676358"`
- `sourceCompatibility = JavaVersion.VERSION_17`
- `kotlinOptions.jvmTarget = "17"`
- `isCoreLibraryDesugaringEnabled = true`

When updating any of these, update `build_android_debug.sh` AND `build_android_release.sh` AND `build.gradle.kts` together.

## Manifest Hardening

`flutter_app/android/app/src/main/AndroidManifest.xml` includes intentional security choices:

- `android:allowBackup="false"` — disable Android auto-backup. Original Legado app did not need backup integration.
- `android:taskAffinity=""` — prevents the activity from sharing a task stack with the upstream Legado app (`io.legado.app`). Mitigates Strandhogg-style attacks.
- `<uses-permission CAMERA />` — required by `mobile_scanner` for QR import. Runtime permission is requested via `permission_handler`.
- `network_security_config="@xml/network_security_config"` — restricts cleartext traffic and pins certain hosts. See the file for the current rule set.

Don't add new permissions casually. Each permission needs a justification comment in the manifest and matching usage in the Flutter feature folder.

## Signing

```kotlin
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
```

- `flutter_app/android/key.properties` is **not** committed (`.gitignore` rule). Maintainers create it from `key.properties.example`.
- If `key.properties` is missing, the release build falls back to the debug keystore and prints a warning. This is enough for personal GitHub Releases but **not** for Play Store distribution.
- Production signing requires:
  1. `keytool -genkey -v -keystore release.keystore -alias legado_release -keyalg RSA -keysize 2048 -validity 10000`
  2. Place `release.keystore` at `flutter_app/android/release.keystore`.
  3. Fill `key.properties` with the password / alias.
  4. Build via `bash build_android_release.sh`.

The `key.properties.example` template is the source of truth for the field names. Don't rename them.

## Native Libraries (libbridge.so)

The Rust workspace's `bridge` crate compiles to `libbridge.so` per Android ABI. The build script copies the output into `flutter_app/android/app/src/main/jniLibs/<abi>/libbridge.so`.

ABIs maintained today:

- `arm64-v8a` — primary, all release builds.
- `armeabi-v7a` — sometimes built for debug. Watch for stale .so files.
- `x86_64` — emulator only.

The build scripts run a clean step before copying: stale `.so` files from earlier builds are removed to prevent shipping old native code with new Dart code.

## R8 / ProGuard

R8 is **not** currently configured for code shrinking; release APKs are unminified. This is a roadmap follow-up (`findings-cross-config.md` BATCH-02b). Do not enable R8 without a real-device regression pass — historic Legado proguard rules don't apply because this app's package name is different (`io.legado.app.flutter`).

## NDK / Cross-Compile Environment

```bash
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$NDK_BIN/aarch64-linux-android21-clang"
export CC_aarch64_linux_android="$NDK_BIN/aarch64-linux-android21-clang"
export AR_aarch64_linux_android="$NDK_BIN/llvm-ar"
```

API level 21 is the minimum target. Bumping requires updating `pubspec.yaml`'s minSdk and the cargo target triple suffix.

## Common Failures

- "libbridge.so not found" — the Rust cross-compile didn't run. Check `cargo build --target aarch64-linux-android` succeeded before `flutter build apk`.
- "Mismatched ABI" — old ABI directories still present. Run `bash build_android_debug.sh` which scrubs them, or manually `rm -rf flutter_app/android/app/src/main/jniLibs/<old-abi>`.
- Gradle daemon hangs — `cd flutter_app/android && ./gradlew --stop`.
- "Cannot resolve compileSdkVersion" — Flutter SDK not in PATH. The scripts set `FLUTTER_ROOT` and `PATH` explicitly.
