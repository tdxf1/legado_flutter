#!/bin/bash
set -euo pipefail

# Android Release 打包脚本 —— 编译 Rust 原生库 + Flutter Release APK
# 输出到 dist/ 用规范文件名 + SHA256 校验和；不安装到设备、不 push tag。
# 用法: bash build_android_release.sh
#
# 当前签名策略：复用 debug keystore（见 flutter_app/android/app/build.gradle.kts
# release buildType signingConfig）。仅适合个人分发到 GitHub Release，
# 不能上架 Play Store；上架前需替换为正式签名。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── 工具链环境变量（与 build_android_debug.sh 对齐） ──────────────
export ANDROID_HOME="${ANDROID_HOME:-/opt/android-sdk}"
NDK_VER="28.2.13676358"
export NDK_HOME="$ANDROID_HOME/ndk/$NDK_VER"
NDK_BIN="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"

export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$NDK_BIN/aarch64-linux-android21-clang"
export CC_aarch64_linux_android="$NDK_BIN/aarch64-linux-android21-clang"
export AR_aarch64_linux_android="$NDK_BIN/llvm-ar"
export FLUTTER_ROOT="${FLUTTER_ROOT:-/root/flutter}"
export PATH="/root/.cargo/bin:$FLUTTER_ROOT/bin:$ANDROID_HOME/platform-tools:$PATH"

# ── 版本号 + commit 哈希（用作 APK 文件名） ─────────────────────────
VERSION_LINE="$(grep -E '^version:' flutter_app/pubspec.yaml | head -1 | awk '{print $2}')"
VERSION_NAME="${VERSION_LINE%+*}"   # 0.1.0+1 → 0.1.0
COMMIT_SHORT="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
DATE_TAG="$(date +%Y%m%d-%H%M%S)"

DIST_DIR="$SCRIPT_DIR/dist"
mkdir -p "$DIST_DIR"
APK_OUT="$DIST_DIR/legado-arm64-release-v${VERSION_NAME}-${COMMIT_SHORT}.apk"

# ── 工作区检查（reproducible build 强制要求干净工作区） ───────────
# release artefact 文件名携带 ${COMMIT_SHORT}，必须保证 APK 内容与该 commit
# 严格对应；任何 unstaged / staged 改动都会让 hash 失去可复现性。
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "❌ 工作区有未提交改动，release 构建要求干净的工作区"
    echo "请先 commit 或 stash 后再试"
    git status --short | head -10
    exit 1
fi

# ── 1/4 Flutter analyze + test（quality gate 在前，artefact 在后） ──
# 必须先全绿再去 cargo build + cp，否则失败时 jniLibs 已经被覆盖，破坏幂等。
echo ""
echo "[1/4] Running flutter analyze + test (release 必跑)..."
cd flutter_app
flutter --no-version-check analyze
xvfb-run -a flutter --no-version-check test
cd "$SCRIPT_DIR"

# ── 2/4 Rust 交叉编译 release ─────────────────────────────────────
echo ""
echo "[2/4] Cross-compiling Rust bridge crate (release)..."
cargo build --manifest-path core/bridge/Cargo.toml --release --target aarch64-linux-android

# ── 3/4 拷贝 libbridge.so ─────────────────────────────────────────
echo ""
echo "[3/4] Copying libbridge.so to jniLibs..."
# 先清理旧 .so 保证幂等性
rm -f flutter_app/android/app/src/main/jniLibs/arm64-v8a/libbridge.so
cp core/target/aarch64-linux-android/release/libbridge.so \
   flutter_app/android/app/src/main/jniLibs/arm64-v8a/libbridge.so
ls -lh flutter_app/android/app/src/main/jniLibs/arm64-v8a/libbridge.so

# ── 4/4 构建 release APK ─────────────────────────────────────────
echo ""
echo "[4/4] Building Flutter release APK (arm64-v8a only)..."
cd flutter_app
flutter build apk --release --target-platform android-arm64

cd "$SCRIPT_DIR"
APK_SRC="flutter_app/build/app/outputs/flutter-apk/app-release.apk"
if [[ ! -f "$APK_SRC" ]]; then
    echo "❌ 构建产物缺失：$APK_SRC"
    exit 1
fi
cp "$APK_SRC" "$APK_OUT"

# ── 校验和 ──────────────────────────────────────────────────────
SHA256="$(sha256sum "$APK_OUT" | awk '{print $1}')"
APK_SIZE="$(du -h "$APK_OUT" | awk '{print $1}')"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "✅ Release APK 构建完成"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  路径:    $APK_OUT"
echo "  体积:    $APK_SIZE"
echo "  SHA256:  $SHA256"
echo "  版本:    v${VERSION_NAME}"
echo "  Commit:  ${COMMIT_SHORT}"
echo "  Date:    ${DATE_TAG}"
echo ""
echo "  签名:    Debug keystore（仅适合个人分发，不能上架 Play Store）"
echo ""
echo "下一步（手动）："
echo "  1. 测试 APK 在设备上能否正常运行："
echo "       adb install -r \"$APK_OUT\""
echo ""
echo "  2. push 当前分支到 origin（48 commits 领先）："
echo "       git push origin main"
echo ""
echo "  3. 打 tag 并发布 GitHub Release："
echo "       git tag -a v${VERSION_NAME} -m 'Release v${VERSION_NAME}'"
echo "       git push origin v${VERSION_NAME}"
echo "       gh release create v${VERSION_NAME} \"$APK_OUT\" \\"
echo "           --title 'v${VERSION_NAME}' \\"
echo "           --notes-file dist/release-notes-v${VERSION_NAME}.md"
echo ""
echo "═══════════════════════════════════════════════════════════════"
