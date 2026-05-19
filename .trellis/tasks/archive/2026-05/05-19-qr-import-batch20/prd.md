# QR 扫码导入 (批次 20)

## Goal

阶段 5 第二批：实现"QR 扫码导入" — 用户在 RSS 源管理 / 书源管理 / 订阅源 / 替换规则各页**扫一个二维码**就能导入对应规则。原 Legado 圈子里"配置 = 一张二维码"的标准做法。

阶段 5 全 3 批：
- 批次 19（done）：RuleSub 订阅源
- 批次 20（**本批**）：QR 扫码导入
- 批次 21：书源验证增强

## What I already know

### 现状
- `pubspec.yaml` 暂无 `mobile_scanner` — 本批次首加（用户已确认 ^5）
- 各管理页均有"导入"按钮（file_picker）— 本批次扫码功能作为**补充入口**
- 批次 16/17 RSS 源管理 / 文章列表已有；批次 19 订阅源 RuleSub 已有
- bridge funcId 已用到 108

### 原 Legado 参考（`feature-gap-rss-manga-audio-misc.md` §7.3）
- `ui/qrcode/QrCodeActivity.kt` — ZXing 扫码 + 从相册识图
- `ui/association/OnLineImportActivity.kt` — `legado://import/<type>?src=<url>` 协议
  - `type` ∈ {bookSource, rssSource, replaceRule, sourceSub} — 扫码 / 浏览器 deep link 都走它
  - `src` 可以是直接 URL 或 base64 编码的 JSON 字符串

### Flutter 端现状
- 没有任何 QR 扫码代码
- bookshelf PopupMenu 已有：管理分组 / 备份/恢复 / 导入本地书 / 阅读统计 / 缓存管理 / RSS 源管理 / RSS 收藏 / 订阅源（批次 19 加）
- 各页（rss_source_manage / source_page）已有"导入"按钮但只支持本地 JSON 文件

## Decision

**MVP 范围 — QR 扫码 + Legado 协议解析 + 转发到对应 import**：

### Flutter 端

1. **`pubspec.yaml` 加依赖 `mobile_scanner: ^5`**

2. **新建 `lib/features/qr/qr_scan_page.dart`** ConsumerStatefulWidget：
   - 路由 `/qr-scan`
   - AppBar(title: "扫码导入")，actions = [手电筒 IconButton + 切换前后摄像头 IconButton]
   - body: `MobileScanner(controller, onDetect)` + 半透明遮罩中间留扫码框
   - 检测到二维码后：解析 + 弹 `AlertDialog(title: "确认导入", content: 扫到的内容)` → 用户点"导入"调对应 import → SnackBar
   - 失败 / 不识别协议 → 显示原始内容（可手动复制）+ "未识别为 Legado 协议"
   - 测试钩子：`scanResultOverride` 注入假扫码结果（绕过相机）

3. **新建 `lib/features/qr/legado_qr_protocol.dart`** — 解析 `legado://import/...` 与 GitHub raw URL：
   - `parseLegadoQrPayload(String raw) -> ParsedLegadoQr?`
     - `legado://import/bookSource?src=<url>` → `(LegadoQrType.bookSource, url)`
     - `legado://import/rssSource?src=<url>` → `(rssSource, url)`
     - `legado://import/sourceSub?src=<url>` → `(sourceSub, url)` — 走批次 19 RuleSub create + refresh
     - `legado://import/replaceRule?src=<url>` → 暂占位 SnackBar"批次 21+ 实装"
     - 直接 https URL 结尾是 `.json` → 视为 BookSource URL（兜底）
     - 其它 → null（"未识别"）
   - 返回 `(LegadoQrType, fetchUrl)` enum + url

4. **新建 `lib/features/qr/qr_import_handler.dart`** ConsumerStatefulWidget Helper：
   - `handleLegadoQr(BuildContext, WidgetRef, ParsedLegadoQr)` async：
     - bookSource → reqwest GET URL → BookSourceDao::import_from_json (走现有 `rust_api.importSourcesFromJson`)
     - rssSource → reqwest GET URL → RssSourceDao::import_from_json (走现有 `rust_api.rssSourceImportJson`)
     - sourceSub → 调 `rust_api.ruleSubCreate` 添加订阅源 → 立即调 `rust_api.ruleSubRefresh` 刷新（一气呵成）
   - 返回 SnackBar 消息

5. **入口加 4 处**（每个相关管理页 AppBar 加扫码 IconButton）：
   - `bookshelf_page.dart` PopupMenu 加 "扫码导入"
   - `source_page.dart` AppBar 加 IconButton(qr_code_scanner)
   - `rss_source_manage_page.dart` AppBar 加 IconButton(qr_code_scanner)
   - `rule_sub_page.dart` AppBar 加 IconButton(qr_code_scanner)

6. **路由注册** `/qr-scan` → QrScanPage

### Rust 端 — 无新代码

本批次纯 Flutter 实现（Rust 端通过现有 import_from_json + rule_sub_create/refresh 复用）。

### 平台权限

7. **Android `android/app/src/main/AndroidManifest.xml`** 加：
   ```xml
   <uses-permission android:name="android.permission.CAMERA"/>
   ```
   注：mobile_scanner 5+ 内部用 `permission_handler` 自动请求，但 manifest 必须显式声明。

8. **iOS `ios/Runner/Info.plist`** 加（hold — 当前以 Android 为主，iOS 加个占位 string 即可）：
   ```xml
   <key>NSCameraUsageDescription</key>
   <string>用于扫描书源 / RSS 源 / 订阅源的二维码</string>
   ```

### 测试

- Flutter ≥ 3 widget tests：
  1. `qr_scan_page_test` — `scanResultOverride='legado://import/bookSource?src=https://...'` → 验证弹 AlertDialog
  2. `legado_qr_protocol_test` — 5 种协议 / URL 分类 + null 兜底
  3. `qr_import_handler_test` — mock `rust_api` 的 3 种 import → 验证调对应 fn

## Acceptance Criteria

- [ ] cargo test 全 crate 不变（不动 Rust）
- [ ] flutter analyze 0 issue
- [ ] flutter test ≥ 375 (372 baseline + 3)
- [ ] **手工**：开扫码页 → 扫一个 `legado://import/bookSource?src=https://...` → 看到确认对话框 → 点导入 → 进 `/sources` 查看新增

## Definition of Done

- flutter test 全绿
- analyze 0 issue
- 不打 APK
- commit "feat: 第六十批 — QR 扫码导入 (批次 20)" + archive

## Out of Scope

- iOS 实机测试（hold；Android 优先）
- replaceRule 协议（批次 21+）
- QR 生成（导出书源 / RSS 源为 QR 给别人扫）— MVP 只支持读取，不做生成
- 从相册识图（mobile_scanner.scanImage）— MVP 仅相机实时扫
- legado 协议 src 是 base64 编码的 JSON 字符串（直接含规则 JSON）— MVP 仅支持 src=URL 的远端拉取模式

## Technical Notes

- mobile_scanner 5+ 默认 BarcodeFormat 包含所有；本批次保持默认
- `MobileScannerController(detectionTimeoutMs: 1000)` 防快速重复扫码
- 协议正则：`^legado://import/(bookSource|rssSource|sourceSub|replaceRule)\?src=(.+)$`
- 远端 URL 拉取：直接用 dart 的 `http.get` 或 dio（已有？检查 pubspec），不引新 http 包
- 各管理页 AppBar IconButton 用相同 callback：`context.push('/qr-scan')`，扫描结果由 qr_scan_page 自己处理 + pop 后回到原页
- 测试钩子：`QrScanPage.scanResultOverride` = `String?`，非 null 时跳过相机直接走 `_onDetect(text)`
