#!/bin/bash
set -euo pipefail

# Android 构建脚本 —— 编译 Rust 原生库 + Flutter APK 并安装到设备
# 用法: bash build_android_debug.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export ANDROID_HOME="${ANDROID_HOME:-/opt/android-sdk}"
NDK_VER="28.2.13676358"
export NDK_HOME="$ANDROID_HOME/ndk/$NDK_VER"
NDK_BIN="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"

export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$NDK_BIN/aarch64-linux-android21-clang"
export CC_aarch64_linux_android="$NDK_BIN/aarch64-linux-android21-clang"
export AR_aarch64_linux_android="$NDK_BIN/llvm-ar"
export FLUTTER_ROOT="${FLUTTER_ROOT:-/root/flutter}"
export PATH="$FLUTTER_ROOT/bin:$ANDROID_HOME/platform-tools:$PATH"

echo "[1/3] Cross-compiling Rust bridge crate..."
cargo build --manifest-path core/bridge/Cargo.toml --release --target aarch64-linux-android

echo "[2/3] Copying libbridge.so to jniLibs..."
# 先清理旧 .so 保证幂等性：避免上次构建残留与本次产物混淆
rm -f flutter_app/android/app/src/main/jniLibs/arm64-v8a/libbridge.so
cp core/target/aarch64-linux-android/release/libbridge.so \
   flutter_app/android/app/src/main/jniLibs/arm64-v8a/libbridge.so

echo "[3/3] Building Flutter debug APK and installing..."
cd flutter_app
# 显式只打 arm64-v8a：与 build.gradle.kts 的 abiFilters 对齐，
# 同时让 Flutter engine + Dart AOT/JIT 也只走 android-arm64 流水线，
# 大幅缩短构建时间，APK 体积少一半左右。
flutter build apk --debug --target-platform android-arm64
adb install -r build/app/outputs/flutter-apk/app-debug.apk || adb install build/app/outputs/flutter-apk/app-debug.apk

echo ""
echo "Done! APK installed to device."
