# BATCH-02: AndroidManifest 安全收紧 + release keystore + R8

**Stage**: P0
**Slug**: `harden-android-build-and-manifest`
**Effort**: M (≤500 行)
**Depends on**: BATCH-01 (避免 jniLibs 污染影响 release 验证)

## 1. 范围

把 release 产物的"Android 工程层"安全短板一次性收紧：禁用 backup、独立 release keystore、启用 R8/proguard。三条 finding 都改 `app/build.gradle.kts` + `AndroidManifest.xml`，在同一批做避免 release 流程被 N 次回归。

## 2. 包含的 findings

- [F-W3-002] AndroidManifest 缺 `allowBackup="false"`（凭据 / DB 上 Google Auto Backup） — `flutter_app/android/app/src/main/AndroidManifest.xml:7-11`
- [F-W3-013] release APK 用 debug keystore 签名（任何人可伪造同包升级） — `flutter_app/android/app/build.gradle.kts:48-54`
- [F-W3-014] release build 不做 R8 / shrinking / obfuscation — `flutter_app/android/app/build.gradle.kts:48-54`
- [F-W3-004] MainActivity exported=true + taskAffinity="" 未文档化 — `AndroidManifest.xml:12-20`

## 3. 影响文件

- `flutter_app/android/app/src/main/AndroidManifest.xml` — 加 `android:allowBackup="false"`；显式注释 `taskAffinity` 决策；可选 `dataExtractionRules` 白名单 XML
- `flutter_app/android/app/build.gradle.kts` — 引入 `signingConfigs.release`（读 `key.properties`）；`buildTypes.release`：`signingConfig = release` + `minifyEnabled = true` + `proguardFiles getDefaultProguardFile("proguard-android-optimize.txt"), file("proguard-rules.pro")`
- `flutter_app/android/key.properties.example` — 新增模板文件
- `flutter_app/android/app/proguard-rules.pro` — 新增；至少 `-keep class io.legado.app.flutter.MainActivity$LegadoJsBridge { *; }` 防 JavascriptInterface 方法名混淆
- `.gitignore` — 新增 `flutter_app/android/key.properties` 与 `*.keystore`
- `README.md` 或 `docs/release-signing.md` — 写"如何生成 release keystore"
- `build_android_release.sh` — 在没有 `key.properties` 时直接拒绝构建

## 4. 修复方向

- F-W3-002：在 `<application>` 加 `android:allowBackup="false"`，同时为后续敏感文件预留 `dataExtractionRules` 白名单（或显式延后到 P1 阶段做）。
- F-W3-013：引入 `release.keystore` + `key.properties`（gitignore），release 必须读这个文件签名；CI 可保留 debug-signed dev-build，但 GitHub Release 工件必须 release-signed。
- F-W3-014：release `minifyEnabled = true` + `proguardFiles getDefaultProguardFile("proguard-android-optimize.txt")` + `proguard-rules.pro`；keep rules 防 JavascriptInterface 名字混淆；release build 需真机回归 webview / JS bridge。
- F-W3-004：在 build.gradle.kts / Manifest 里写 ADR-lite 注释解释 `taskAffinity=""` 缘由；评估改为 `android:taskAffinity="${applicationId}"`。

## 5. 测试策略

- 手动：跑一次 `bash build_android_release.sh`（先创 key.properties），确认 APK 可装且签名指纹与 debug 不同（`apksigner verify --print-certs`）；未配 key.properties 时脚本直接 exit。
- 真机回归：装 release APK，验证 webview JS bridge / 阅读器 / 书源测试 / 备份导出 → 这些是 R8 后最易出错的路径。
- 不强求新单测。

## 6. 验收

- [ ] release APK 用独立 keystore 签名（指纹与 debug 不同）
- [ ] `apkanalyzer` 显示 release APK `allowBackup` = false
- [ ] R8 启用后真机阅读器 / JS 桥 / 书源测试 / 备份导出 全 OK
- [ ] master finding F-W3-002/013/014/004 全部消解或加 ADR-lite 注释解释

## 7. implement.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-cross-config.md", "reason": "本批次涉及的 wave 3 findings"}
{"file": "flutter_app/android/app/src/main/AndroidManifest.xml", "reason": "manifest 收紧 backup 与 taskAffinity 注释"}
{"file": "flutter_app/android/app/build.gradle.kts", "reason": "signingConfigs / buildTypes / R8 配置"}
{"file": "flutter_app/android/build.gradle.kts", "reason": "上下文：项目级 gradle"}
{"file": "build_android_release.sh", "reason": "在没有 key.properties 时拒绝构建"}
{"file": "flutter_app/android/app/src/main/kotlin/io/legado/app/flutter/MainActivity.kt", "reason": "JavascriptInterface 方法名是 keep rules 关键依据"}
```

## 8. check.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md", "reason": "master report，验证 finding 主题边界"}
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-cross-config.md", "reason": "Wave 3 详细 findings"}
{"file": ".trellis/tasks/05-20-fix-roadmap/plan/batches/BATCH-02-harden-android-build-and-manifest.md", "reason": "本批次自身验收清单"}
{"file": "flutter_app/android/app/proguard-rules.pro", "reason": "新增 keep rules 是否覆盖 JS bridge"}
{"file": "flutter_app/android/key.properties.example", "reason": "确认模板存在但真实 key.properties 已 gitignore"}
```
