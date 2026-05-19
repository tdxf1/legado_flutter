# BATCH-02: AndroidManifest 收紧 + release keystore 基础设施

> 修复路线图 BATCH-02 的**缩范围版本**：原计划包含 R8/proguard（F-W3-014）但需真机回归验证不破坏 JavascriptInterface / FRB / WebView，故拆出到 BATCH-02b 单独做。
> 路线图原文：[`.trellis/tasks/archive/2026-05/05-20-fix-roadmap/plan/batches/BATCH-02-harden-android-build-and-manifest.md`](../archive/2026-05/05-20-fix-roadmap/plan/batches/BATCH-02-harden-android-build-and-manifest.md)

## Goal

把 release 产物的"Android 工程层"安全短板按 quick-win 节奏收紧：禁用 backup、引入独立 release keystore 基础设施（不强制立即切换）、给 `taskAffinity=""` 加 ADR-lite 注释。三条 finding 都改 `app/build.gradle.kts` + `AndroidManifest.xml` + 新增 `key.properties.example`，零业务代码改动。

## Why

- **F-W3-002 (P1)**：`<application>` 没显式 `android:allowBackup="false"`，Android 6+ 默认 backup=true → ADB / Auto Backup 把 `legado.db`（含 WebDAV 凭据）+ `legado_local.json`（含备份密码明文）同步到 Google 云。F-W1A-020（备份密码明文）+ F-W2B-001（WebDAV 凭据明文）叠加默认 backup 等于"密码上云"。
- **F-W3-013 (P1)**：release `signingConfig = signingConfigs.getByName("debug")` —— 用 debug keystore 签名 release APK。debug.keystore 是 Android SDK 装机自动生成、对开发者公开的密钥；任何拿到 APK 的攻击者都能用同 debug key 签名 patch APK 替换升级用户。
- **F-W3-004 (P1)**：`MainActivity` `android:taskAffinity=""` 是空字符串——会让 activity 与系统其它 app 共享 task stack（Strandhogg 类劫持的常见跳板）。当前没注释说明引入这个值的动机；后续若有人误删 / 误改即留隐患。
- **F-W3-027 (P2)**：build.gradle.kts 残留 `// TODO: Specify your own unique Application ID` 与 `// TODO: Add your own signing config` 两条 Flutter 模板注释——本批 release 决策落地后顺手清掉。

## Scope

### in scope（4 条 finding）

- F-W3-002：`AndroidManifest.xml` 加 `android:allowBackup="false"`
- F-W3-013：引入 `key.properties` + `release.keystore` 基础设施（gitignore + 模板）；`build.gradle.kts` `signingConfigs.release` 条件读取（无 key.properties 时 fallback debug，但 release build 在控制台显示醒目警告）
- F-W3-004：在 `AndroidManifest.xml` 给 `taskAffinity=""` 加 ADR-lite 注释，文档化决策
- F-W3-027：删除 build.gradle.kts 内的 2 条 Flutter 模板 TODO 注释（顺手 quick win）

### out of scope（明确推迟）

- **F-W3-014 R8 / proguard / shrinking**：拆到 **BATCH-02b** 单独批次。原因：R8 会混淆 Kotlin 类名 / 方法名，可能破坏 `LegadoJsBridge.@JavascriptInterface` 方法 + FRB sync method registration + reflection 调用；写 keep rules 后**必须真机回归** webview / JS 桥 / 阅读器 / 备份导出四个核心路径。本会话无设备插着，不能验证；硬塞会破坏 quick-win 节奏。
- **F-W3-002 的 `dataExtractionRules` 白名单**：留给 BATCH-03（凭据保险柜批次）一起做更合适——届时已经识别清楚哪些文件是敏感的。
- **F-W3-013 的"无 key.properties → 直接 reject"强制策略**：本批仅做基础设施 + 警告，不强制；切换由 BATCH-02b 配合 R8 启用做（届时若开发者已经生成 keystore，自然就走 release-signed）。
- **README / docs/release-signing.md 详细文档**：本批仅在 `key.properties.example` 内写最小注释；完整文档留给 BATCH-02b。

## Requirements

- [ ] `AndroidManifest.xml` 含 `android:allowBackup="false"`
- [ ] `AndroidManifest.xml` `taskAffinity=""` 行上方有 XML 注释解释决策（≥ 2 行）
- [ ] `flutter_app/android/app/build.gradle.kts` 删除 2 条 `// TODO:` Flutter 模板注释
- [ ] `flutter_app/android/app/build.gradle.kts` 含 `signingConfigs.release` block，从 `key.properties` 读 keystore 信息；若文件不存在 fallback 到 `signingConfigs.debug` 但在控制台 println warning
- [ ] `flutter_app/android/key.properties.example` 新增（含 4 字段模板：`storeFile / storePassword / keyAlias / keyPassword` + 注释说明 keytool 生成命令）
- [ ] `.gitignore` 加 `flutter_app/android/key.properties` + `*.keystore` + `*.jks`
- [ ] 0 业务代码改动（无 Kotlin / Java / Dart / Rust / pubspec / Cargo 变化）

## Acceptance Criteria

- [ ] master finding F-W3-002 / F-W3-013 / F-W3-004 / F-W3-027 四条均不再触发（重读 master report 验证）
- [ ] `apkanalyzer` 显示 release APK manifest `allowBackup` = false（如果你能在设备上验证）
- [ ] 本批不强制 release-signed（用户未生成 keystore 时仍可跑 `bash build_android_release.sh`，输出含警告但能成功打包）
- [ ] 本批改完后跑 `bash build_android_release.sh` 应能正常完成（前提：BATCH-01 已合并，工作区干净）

## Definition of Done

- 4 条 finding 均改完
- gradle.kts 与 manifest.xml 改动通过本地 `flutter analyze` / gradle sync 验证（**注**：本批由 sub-agent 静态实现，gradle sync 留给用户跑一次确认；sub-agent 自己不跑 build）
- commit message 风格对齐仓库历史（`fix(android):` 或 `chore(android):`）

## Out of Scope（再次强调）

- R8 / proguard / shrinking（→ BATCH-02b）
- dataExtractionRules 白名单（→ BATCH-03）
- 实际生成 release.keystore（用户操作）
- README / 完整签名文档（→ BATCH-02b）
- 任何业务代码 / Rust / Dart 改动

## Technical Approach

### 步骤

1. **`AndroidManifest.xml`**：
   - L7-11 `<application>` 加 `android:allowBackup="false"`
   - L16 `taskAffinity=""` 上方加 XML 注释：
     ```xml
     <!-- taskAffinity="" 让 MainActivity 不与其它 app 共享 task stack。
          原因：避免与原 Legado / Legado-MD3 应用 (io.legado.app namespace)
          被 Android 系统按相同 affinity 合并到同一 recents stack；同时降低
          Strandhogg 类劫持风险（exported=true 的 launcher activity 是常见
          跳板）。如要恢复默认行为可改为 android:taskAffinity="${applicationId}"。-->
     ```

2. **`flutter_app/android/app/build.gradle.kts`**：
   - 删除 L31 `// TODO: Specify your own unique Application ID...` 注释
   - 删除 L50-51 两行 TODO 注释（替换为下面的 release signingConfig）
   - 顶部 `plugins {` 之上加 `keystoreProperties` 加载逻辑（kts 写法）：
     ```kotlin
     import java.util.Properties
     import java.io.FileInputStream

     val keystorePropertiesFile = rootProject.file("key.properties")
     val keystoreProperties = Properties()
     val hasReleaseKeystore = keystorePropertiesFile.exists()
     if (hasReleaseKeystore) {
         keystoreProperties.load(FileInputStream(keystorePropertiesFile))
     }
     ```
   - `android { ... signingConfigs { ... } }` 内加 release block：
     ```kotlin
     signingConfigs {
         create("release") {
             if (hasReleaseKeystore) {
                 storeFile = file(keystoreProperties["storeFile"] as String)
                 storePassword = keystoreProperties["storePassword"] as String
                 keyAlias = keystoreProperties["keyAlias"] as String
                 keyPassword = keystoreProperties["keyPassword"] as String
             }
             // 若 key.properties 不存在，本 config 保持 unconfigured；
             // buildTypes.release 下方会做条件 fallback。
         }
     }
     ```
   - `buildTypes.release` 改成条件 signingConfig：
     ```kotlin
     buildTypes {
         release {
             signingConfig = if (hasReleaseKeystore) {
                 signingConfigs.getByName("release")
             } else {
                 println("⚠️  flutter_app/android/key.properties 不存在；release 仍用 debug keystore 签名（不可上架，也无法做受信升级）")
                 println("    生成 release keystore 见 flutter_app/android/key.properties.example")
                 signingConfigs.getByName("debug")
             }
         }
     }
     ```

3. **`flutter_app/android/key.properties.example`** 新增：
   ```properties
   # Release Keystore 配置（实际文件需重命名为 key.properties，已 gitignore）
   #
   # 生成 keystore（一次性）：
   #   keytool -genkey -v -keystore release.keystore \
   #     -alias legado_release -keyalg RSA -keysize 2048 -validity 10000
   #
   # 然后把 release.keystore 放到 flutter_app/android/，并填写下面 4 项：
   storeFile=release.keystore
   storePassword=YOUR_STORE_PASSWORD
   keyAlias=legado_release
   keyPassword=YOUR_KEY_PASSWORD
   ```

4. **`.gitignore`** 末尾加：
   ```
   # Android release signing：本地 keystore + properties 不入版本库
   flutter_app/android/key.properties
   flutter_app/android/*.keystore
   flutter_app/android/*.jks
   ```

### 工具

- `Edit` / `Write` (无业务代码)
- 不跑 `gradle sync` / `flutter build` / 测试

### 风险

- **gradle.kts 语法**：`val keystorePropertiesFile = rootProject.file(...)` 必须放在 `plugins {}` 之外；`signingConfigs` block 在 `android {}` 内的位置必须在 `buildTypes {}` 之前——sub-agent 必须严格遵守 Kotlin DSL gradle 语法。
- **`hasReleaseKeystore` 在 plugins 之上声明**：plugins block 之前 import + val 声明在 Kotlin DSL 是合法的，参考 Flutter 官方 [release signing 文档](https://docs.flutter.dev/deployment/android#signing-the-app)。
- **本批不会触发 gradle sync 失败**：sub-agent 不跑 build；用户接到 commit 后下次 build 是真正测试时机。如果失败，回退即可（git revert）。
- **README 不改**：本批 keystore 仍 fallback debug，使用流程不变；READN 完整签名文档留 BATCH-02b。

## Decision (ADR-lite)

**Context**: BATCH-02 原计划 4 条 P0/P1 一起做，但 R8 启用必须真机回归——本会话无设备，硬塞破坏 quick-win 节奏。

**Decision**:
1. 缩 BATCH-02 范围至 3 条主要 finding（F-W3-002 / F-W3-013 / F-W3-004）+ 1 条顺手 P2（F-W3-027）
2. R8 / proguard 拆到 BATCH-02b，依赖用户真机
3. release keystore **基础设施就位但不强制**：未生成 keystore 时仍 fallback debug 签名 + 警告；强制策略 BATCH-02b 配 R8 一起切
4. dataExtractionRules 推迟到 BATCH-03（凭据保险柜）

**Consequences**:
- ✅ 本批 0 业务代码改动 + 不需要真机即可完成
- ✅ allowBackup=false 立即生效，凭据不再随 Auto Backup 上云
- ✅ keystore 基础设施就位，开发者按 README 生成后下次 build 自动切 release-signed
- ⚠️ 本批未启用 R8——APK 体积、混淆未改善，但与"安全短板"目标一致（短板是签名 + backup，不是 obfuscation）
- ⚠️ 路线图 roadmap.md 没有 BATCH-02b——下次开 BATCH-02b 时需要先把它正式加入路线图（创建任务时 `--parent` 仍指向 review 任务即可）

## Technical Notes

- 上一任务（BATCH-01）已完成（commit `0c47760`），仓库 jniLibs 已瘦身 + release 脚本顺序正确
- master finding 详情：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-cross-config.md` 的 F-W3-002 / F-W3-004 / F-W3-013 / F-W3-014 / F-W3-027
- gradle Kotlin DSL 语法参考：https://docs.flutter.dev/deployment/android#signing-the-app（Flutter 官方）
- 当前 `flutter_app/android/app/build.gradle.kts` 用的是 Kotlin DSL（`.kts`），非 Groovy
- 本批完成后 BATCH-03（secure-credentials-via-keystore）可启动；BATCH-02b（R8）需用户真机准备好后再开
