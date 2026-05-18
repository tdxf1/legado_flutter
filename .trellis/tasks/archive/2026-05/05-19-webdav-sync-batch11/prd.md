# WebDAV 备份/恢复 (批次 11)

## Goal

让用户在"备份/恢复"页配置 WebDAV 服务器（URL / 账号 / 密码），把批次 10 的本地 zip 备份**自动 PUT 到远端**，并能**从远端列出已有 zip 并下载恢复**。对齐原 Legado `lib/webdav/WebDav.kt` + `help/AppWebDav.kt` 的同步链路。

## What I already know

- 批次 10 已就绪：`export_to_zip / import_from_zip / validate_zip` Rust API + Flutter `BackupPage`
- 调研 `legado-backup-format.md` §5 详尽：原 Legado WebDAV 走 PROPFIND/MKCOL/PUT/GET/DELETE，Authorization Basic 鉴权，URL 支持 `davs://` / `dav://` 自定义 scheme
- 备份 zip 在 WebDAV 上**扁平存放**（按 `displayName.startsWith("backup")` 列表筛选），文件名 `backup{date}-{deviceName}.zip`
- 现有 `core/core-net/` 模块已有 reqwest 客户端（http_client.rs），WebDAV 走 reqwest 即可，无需新依赖
- pubspec.yaml Flutter 端无 webdav 依赖；本批次**不引入新 Flutter 依赖**，所有 WebDAV 走 Rust 端
- 原项目 `BackupAES.kt` 加密 webDavPassword 字段，本批次**先存明文**到 settings.json（批次 12 加密备份时再加密）

## Decision

**MVP 范围（仅本批次）**：

### Rust 端
1. **新增 `core/core-net/src/webdav.rs`**：WebDav 客户端
   - `pub struct WebDavClient { url, basic_auth: String }`
   - `async fn list_files(&self, depth: u8) -> Result<Vec<WebDavEntry>, String>` — PROPFIND
   - `async fn upload(&self, remote_path: &str, body: Vec<u8>) -> Result<(), String>` — PUT
   - `async fn download(&self, remote_path: &str) -> Result<Vec<u8>, String>` — GET
   - `async fn delete(&self, remote_path: &str) -> Result<(), String>` — DELETE
   - `async fn mkcol(&self, remote_path: &str) -> Result<(), String>` — MKCOL（首次同步建目录）
   - `async fn check(&self) -> Result<(), String>` — PROPFIND Depth=0 探活
2. **bridge api 加 5 个新 fn**：
   - `webdav_check(url, user, password) -> ()` — 探活，UI 设置页用
   - `webdav_list_backups(url, user, password) -> Vec<String>` — 列远端 backup*.zip 文件名
   - `webdav_upload_backup(db_path, url, user, password, file_name) -> ()` — 本地 export → PUT
   - `webdav_download_backup(db_path, url, user, password, file_name) -> ImportSummary JSON` — GET → import
   - `webdav_delete_backup(url, user, password, file_name) -> ()` — 远端删除

### Flutter 端
3. **`ReaderSettings` 不动**（WebDAV 配置走独立 `WebDavConfig` 持久化文件）
4. **新建 `lib/features/settings/webdav_config_page.dart`**：
   - URL / 账号 / 密码 / 设备名 4 字段 TextField（密码用 obscureText）
   - "测试连接" 按钮调 `webdav_check`
   - 保存到 `<documentsDir>/webdav.json`
5. **改 `backup_page.dart`**：
   - 顶栏加齿轮按钮跳转 webdav 配置页
   - 新增"WebDAV 同步" 卡片（位于本地导出/导入下方）：
     - "上传到 WebDAV"按钮（本地 export → upload）
     - "从 WebDAV 恢复"按钮（list → 弹 dialog 选 zip → download → import）
     - 配置未填时显示"先去配置 WebDAV"
6. **`webdav.json` 格式**：
   ```json
   {
     "url": "https://dav.jianguoyun.com/dav/legado/",
     "user": "...",
     "password": "...",  // 明文，批次 12 加密
     "deviceName": "Pixel"
   }
   ```

### 测试
- Rust: ≥ 4 单测 — 用 `mockito` mock WebDAV 服务器测 list/upload/download/check（mockito 已在 core-net 里？如果没有就用 `httptest` 或自己起个 tokio TcpListener）
- Flutter: 1 widget test（webdav_config_page 渲染 + "测试连接" 按钮点击调 mock）

## Acceptance Criteria

- [ ] Rust: `cargo test -p core-net` ≥ baseline + 4
- [ ] Rust: `cargo test -p core-storage` 仍 45 全绿
- [ ] Rust: `cargo build -p bridge` 通过 + FRB regen
- [ ] Flutter: `flutter analyze` 0 issue
- [ ] Flutter: `flutter test` ≥ 349 (348 baseline + 1)
- [ ] **手工验证**：用真实 webdav.jianguoyun.com 账号上传/下载 zip 成功

## Definition of Done

- cargo + flutter test 全绿
- analyze 0 issue
- 不打 APK（磁盘紧张，留实机验证时手动 build_android_release.sh）
- commit "feat: 第五十批 — WebDAV 备份/恢复 (批次 11)" + archive

## Out of Scope

- AES 加密 webDavPassword（批次 12）
- WebDAV 自动备份触发（24h 定时器，原 Legado `Backup.autoBack`，留批次 12+）
- WebDAV 阅读进度同步（每书一文件 `bookProgress/<book>.json`，留进阶）
- WebDAV 阅读背景图同步（`background/`）
- `davs://` / `dav://` / `serverID://` 自定义 scheme 解析（先只支持 https/http）
