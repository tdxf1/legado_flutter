# BATCH-01: 清理 stale libbridge.so + 修复 release 构建脚本顺序

**Stage**: P0
**Slug**: `cleanup-stale-jnilibs`
**Effort**: S (≤200 行)
**Depends on**: none

## 1. 范围

清掉仓库内 4 个 ABI 的 `libbridge.so`（其中 3 个停在 5/14 旧版本），把 `jniLibs/` 加进 `.gitignore`，并修复 release 脚本"先 cp .so 后 analyze/test 失败时污染 jniLibs"的顺序问题。

## 2. 包含的 findings

- [F-W3-001] 4 个 ABI stale `libbridge.so`（armeabi-v7a / x86 / x86_64 旧版） — `flutter_app/android/app/src/main/jniLibs/`
- [F-W3-016] release script analyze/test 在 cp .so 之后污染 jniLibs — `build_android_release.sh:60-65`
- [F-W3-018] release 工作区脏检查只 grep `^??`，不阻断 — `build_android_release.sh:38-46`

## 3. 影响文件

- `flutter_app/android/app/src/main/jniLibs/{armeabi-v7a,x86,x86_64}/libbridge.so` — `git rm` 三个目录
- `flutter_app/android/app/src/main/jniLibs/arm64-v8a/libbridge.so` — 加入 `.gitignore` 但保留构建后产生
- `.gitignore` — 新增 `flutter_app/android/app/src/main/jniLibs/**/*.so`
- `build_android_release.sh` — 重排顺序：先 analyze/test 全绿，再 cargo build + cp；脏检查改强制 `git diff --quiet || exit 1`
- `build_android_debug.sh` — 同步加幂等性 `rm -rf` 旧 .so 再 cp

## 4. 修复方向

按 master report F-W3-001 建议：
1. `git rm flutter_app/android/app/src/main/jniLibs/{armeabi-v7a,x86,x86_64}/libbridge.so` 并把整个 `jniLibs/` 加进 `.gitignore`；
2. release script 末尾加 stale 检测或 build 前 `rm -rf` 整个 jniLibs；
3. 调整 build script 顺序：先 `flutter analyze` + `flutter test` 全绿后再 cargo build + cp；
4. release 脏检查改强制 `git diff --quiet || exit 1`，移除"问 y/N"的妥协。

## 5. 测试策略

- 手动验证：本地跑一次 `bash build_android_release.sh`，确认（a）脚本失败时 jniLibs 不被污染（b）clean repo 后第一次 build arm64-v8a/libbridge.so 重新生成且未被 git track。
- 不需要新单测。

## 6. 验收

- [ ] 3 个 stale .so 已从 git 历史移除（`git ls-files` 不显示）
- [ ] `.gitignore` 包含 jniLibs 规则；新 build 不会在 `git status` 出现 .so
- [ ] build_android_release.sh 在 analyze/test 失败时不污染 jniLibs；脏工作区直接 exit 1
- [ ] master finding F-W3-001/016/018 均不再触发

## 7. implement.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-cross-config.md", "reason": "本批次涉及的 wave 3 findings 详细内容（F-W3-001/016/018）"}
{"file": "build_android_release.sh", "reason": "release 构建脚本，需要重排顺序 + 强化脏检查"}
{"file": "build_android_debug.sh", "reason": "debug 构建脚本，幂等性同步修复"}
{"file": ".gitignore", "reason": "新增 jniLibs 规则"}
{"file": "flutter_app/android/app/build.gradle.kts", "reason": "确认 abiFilters 仅 arm64-v8a，jniLibs 行为预期"}
{"file": ".trellis/spec/backend/quality-guidelines.md", "reason": "后续若引入'build artefact 不入 git'规则需要同步进 spec"}
```

## 8. check.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md", "reason": "master report，验证 finding 主题边界"}
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-cross-config.md", "reason": "Wave 3 详细 findings，校验所有相关条目均已修复"}
{"file": ".trellis/tasks/05-20-fix-roadmap/plan/batches/BATCH-01-cleanup-stale-jnilibs.md", "reason": "本批次自身验收清单"}
{"file": ".gitignore", "reason": "确认新规则生效"}
{"file": "build_android_release.sh", "reason": "确认顺序与脏检查严格化"}
```
