# BATCH-01: 清理 stale libbridge.so + 修复 release 构建脚本顺序

> 修复路线图 BATCH-01，详见
> [`.trellis/tasks/archive/2026-05/05-20-fix-roadmap/plan/batches/BATCH-01-cleanup-stale-jnilibs.md`](../archive/2026-05/05-20-fix-roadmap/plan/batches/BATCH-01-cleanup-stale-jnilibs.md)

## Goal

清掉仓库内 4 个 ABI 的 `libbridge.so`（其中 3 个停在 5/14 旧版本），把 `jniLibs/` 二进制加进 `.gitignore`，并修复 `build_android_release.sh` 的"先 cp .so 再 analyze/test 失败时污染 jniLibs"顺序问题。属于路线图第一批 quick wins，无业务逻辑改动。

## Why

- master report F-W3-001 (P0)：4 个 ABI 二进制（armeabi-v7a / x86 / x86_64 / arm64-v8a）共占 ~45MB；其中 3 个停在 commit `b0dfa87` 之前的旧版（与当前 Rust 源码已经分歧），若日后有人改 `abiFilters` 想加 32 位 ARM 兼容会**直接打进 stale 二进制**
- F-W3-016 (P1)：release script 第 60-65 行 `flutter analyze` / `flutter test` 跑在 `cp .so` 之后，analyze/test 失败时 jniLibs 已被覆盖，破坏幂等性
- F-W3-018 (P1)：脏工作区检查只 grep `^??` 排除新文件后用 `read -p` 问 y/N，release artefact 可能包含未 commit 改动，破坏 reproducible build

## Scope

### in scope

- `git rm` 全部 4 个 `flutter_app/android/app/src/main/jniLibs/*/libbridge.so`
- `.gitignore` 新增 `flutter_app/android/app/src/main/jniLibs/` 规则（覆盖目前已 tracked 的 .so）
- `build_android_release.sh`：
  - 重排顺序：先 `flutter analyze` + `flutter test` 全绿，再 cargo build + cp
  - 脏检查改强制 `git diff --quiet || exit 1`，移除 `read -p` 妥协
- `build_android_debug.sh`：cp 前 `rm -rf` 旧 .so 保证幂等性

### out of scope

- F-W3-001 建议中的"评估用 Gradle 任务自动 invoke `cargo build`，去掉手动 cp"——超出 quick win 范围，本批不做
- 引入 GitHub Release artefact 流程——同上
- F-W3-013 (debug keystore signing)——属于 BATCH-02
- F-W3-002 (allowBackup)——属于 BATCH-02
- 任何业务代码 / Rust 代码 / Flutter Dart 代码改动

## Requirements

- [ ] `git ls-files flutter_app/android/app/src/main/jniLibs/` 输出为空
- [ ] `.gitignore` 含 jniLibs 规则；本地 build 后 `git status` 不显示新生成的 .so
- [ ] `build_android_release.sh` 在 `flutter analyze` 失败时**不**污染 jniLibs（脚本顺序：脏检查 → analyze → test → cargo build → cp → flutter build）
- [ ] `build_android_release.sh` 工作区脏时直接 `exit 1`，无 y/N prompt
- [ ] `build_android_debug.sh` 在 cp .so 前清理旧 ABI 目录（防止后续若改回多 ABI 时残留）
- [ ] 0 业务代码改动

## Acceptance Criteria

- [ ] master finding F-W3-001 / F-W3-016 / F-W3-018 三条均不再触发（重读 master report 验证）
- [ ] 仓库体积减少 ~45MB（git 历史保留，但 working tree 净）
- [ ] release 脚本失败注入测试：手动改 `flutter_app/lib/main.dart` 引入 unused import 让 analyze 失败，跑 release 脚本应**未**生成 / 修改任何 jniLibs/*.so
- [ ] debug 脚本回归：`bash build_android_debug.sh` 仍能正常构建并安装到设备（前提是设备插着 + Rust toolchain 就位）

## Definition of Done

- 4 个 .so 从 git index 移除
- 两个 build 脚本按上述要求改完
- 自检：脚本顺序正确、脏检查严格化、release 失败注入测试通过
- commit message 风格对齐仓库历史（`fix(build):` 或 `chore(build):`）

## Out of Scope（再次强调）

- 业务代码 / Rust core / Flutter Dart 代码改动
- 引入新的 build 工具链
- gradle 配置（abiFilters / minifyEnabled / signing）改动
- Cargo / pubspec 依赖改动

## Technical Approach

### 步骤

1. **从 git 移除 4 个 .so**：
   ```
   git rm flutter_app/android/app/src/main/jniLibs/armeabi-v7a/libbridge.so
   git rm flutter_app/android/app/src/main/jniLibs/x86/libbridge.so
   git rm flutter_app/android/app/src/main/jniLibs/x86_64/libbridge.so
   git rm flutter_app/android/app/src/main/jniLibs/arm64-v8a/libbridge.so
   ```
   注意：仅从 index 移除，工作树保留 arm64-v8a/libbridge.so 让 app 仍可装（git rm 会同时删工作树文件 → 需要 build 才能再用；如果想保留工作树，用 `git rm --cached`）

2. **更新 .gitignore**：
   ```
   # Android jniLibs：build 产物，不入版本库
   flutter_app/android/app/src/main/jniLibs/
   ```
   注意：现有 `.gitignore` 已有 `*.so` 全局规则，但 tracked 文件不受影响，所以加目录级规则做防御。

3. **build_android_release.sh 重排**：
   - 移到 `BUILD_TYPE` 设置之后但 `cargo build` 之前的位置：
     - `git diff --quiet || { echo "工作区有未提交改动"; exit 1; }`（替换 line 38-46）
     - `flutter analyze`
     - `flutter test`
   - 然后才走 cargo build + cp + flutter build

4. **build_android_debug.sh 幂等化**：
   - 在 `cp libbridge.so` 之前 `rm -f flutter_app/android/app/src/main/jniLibs/arm64-v8a/libbridge.so`

### 工具

- `git rm`、`Edit` for `.gitignore` / build scripts
- 不修改业务代码

### 风险

- **arm64-v8a/libbridge.so 从 index 移除后，CI / 新克隆 用户必须先跑 `cargo build --release` 才能装 app**：本仓库 README 已经在"快速开始"里要求用户先 `cargo build --release`，所以新增要求与现有约定一致；不需要改 README
- **release 脚本严格化后，开发者本地有未 commit 改动时再也不能手动确认继续**——需要先 stash / commit。这是设计意图（reproducible build 要求），但对个人开发可能略微不便
- **debug 脚本只 rm arm64-v8a**：armeabi-v7a / x86 / x86_64 已被 git rm 不存在，不需要 rm；`abiFilters` 当前只 arm64-v8a，未来若加多 ABI 时本脚本要相应扩展

## Decision (ADR-lite)

**Context**: 仓库 4 个 ABI 二进制中 3 个 stale，全部用 git track，每次 clone 拉 45MB；release 脚本顺序 + 脏检查不严，破坏 reproducible build。

**Decision**:
1. 4 个全部 `git rm`，包括 arm64-v8a（与 master report F-W3-001 建议一致）
2. `.gitignore` 加目录级规则做防御（避免后续 build 误入库）
3. release 脏检查改强制 exit 1，无 y/N prompt（reproducible build > 个人便利）
4. release 脚本顺序：检查 → analyze → test → cargo → cp → flutter build（quality gate 在前，artefact production 在后）

**Consequences**:
- ✅ 仓库瘦身 45MB，clone 速度提升
- ✅ release artefact 与 commit 严格对应
- ✅ analyze / test 失败时 jniLibs 不被污染
- ⚠️ 新 contributor / CI 必须先跑 cargo build 才能装 app—— README 已要求，无回归
- ⚠️ 个人开发若有未 commit 改动想跑 release 测试，必须先 commit / stash—— 强制 reproducible 的代价

## Technical Notes

- 上一任务的 BATCH 文档：`.trellis/tasks/archive/2026-05/05-20-fix-roadmap/plan/batches/BATCH-01-cleanup-stale-jnilibs.md`
- master finding 详情：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-cross-config.md` 的 F-W3-001 / F-W3-016 / F-W3-018
- 当前 `.gitignore` 已有 `*.so` 但对 tracked 文件无效，必须先 git rm
- 本批次完成后 BATCH-02 可立即启动（无依赖）
