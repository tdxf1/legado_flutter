# 加密备份 (批次 12)

## Goal

让备份 zip 内的敏感字段（webDavPassword + servers.json）走 AES 加密，对齐原 Legado `BackupAES.kt` + `Backup.kt:180-202` 的格式。这样从原 Legado 导入的 zip 能正确解密 webDavPassword，本工程导出的 zip 在原 Legado 上也能正确加密读出。

## What I already know

- 原 Legado 加密细节（research §1.3 + §8.8）：
  - 算法：Hutool `cn.hutool.crypto.symmetric.AES`，**默认 = AES/ECB/PKCS5Padding**
  - 密钥：`MD5(LocalConfig.password ?: "")` 取前 16 字节 = AES-128
  - **密码空串时**：`MD5("")` 前 16 字节 = `D41D8CD98F00B204E9800998` 的前 16 字节
  - API：`encryptBase64(plain): String` → base64；`decryptStr(b64): String` → 明文
- 原 Legado 仅在两处用 AES：
  1. `servers.json` 整体内容 base64 加密（解密时若 `isJsonArray()` 通过则视为未加密 fallback）
  2. `config.xml` 里 `web_dav_password` 字段加密（其它 prefs 全明文）
- 当前工程 batch 10/11 已实现 zip 导出/导入 + WebDAV 上传/下载，但 webdav.json **明文存储**密码
- pubspec.yaml Flutter 端无加密依赖；本批次**所有加密走 Rust 端**
- `core/core-net/Cargo.toml` 已有 base64 依赖
- 现有的 `webdav.json` 不影响兼容（独立文件，未来加密只覆盖此一文件）

## Decision

**MVP 范围**：
1. **Rust 端** `core/core-storage/src/legado_aes.rs` 新建：AES/ECB/PKCS7（≡ PKCS5）helper，与 Hutool 兼容
   - `pub fn encrypt_legado_aes(plain: &str, password: &str) -> Result<String, String>` → base64
   - `pub fn decrypt_legado_aes(b64: &str, password: &str) -> Result<String, String>` → plain
   - `pub fn try_decrypt_or_passthrough_array(text: &str, password: &str) -> String` — 服务实现：先 isJsonArray 探针，是数组返回原文；否则 AES 解密
2. **Cargo.toml**：`aes = "0.8"` + `cbc` 不需要 + `block-modes = "0.9"` 已弃；用 `aes` + 手写 ECB 包装（ECB 极简）
3. **bridge api 新增 2 个**：
   - `set_backup_password(password: String) -> ()` — 持久化到 `<documentsDir>/legado_local.json` 的 `password` 字段（明文 — 这是原 Legado 的设计：`LocalConfig.password` 也是明文存 SharedPreferences）
   - `get_backup_password() -> String` — 返回当前密码（空串表示未设）
4. **Flutter 端**：
   - `webdav_config_page.dart` 加"备份密码"字段 → 调 `set_backup_password`
   - 现有 `webdav.json` 保持明文（它本身只在本机用，原 Legado 也只对**导出 zip 内的 web_dav_password**加密，不对本机 prefs 加密）
   - 未来批次（如果要做 servers.json 备份）可以调 `encrypt_legado_aes(content, password)` 加密
5. **集成到批次 10 backup_dao**：当导出/导入 servers.json 时（目前还不导，预留接口）能用上加密

**注意**：本批次目标是**为后续 servers.json / config.xml 备份打底**，并对齐原 Legado 加密格式。当前**不**加密 webdav.json 本机存储；用户实际加密生效要等到 servers.json 导入导出实现。

## Requirements

### Rust 端
1. **新建 `core/core-storage/src/legado_aes.rs`**：
   - 实现 AES-128/ECB/PKCS7 加密 + base64 编码
   - 用 `md-5 = "0.10"` 计算 MD5 取前 16 字节
   - `encrypt_legado_aes` / `decrypt_legado_aes` / `try_decrypt_or_passthrough_array`
   - `pub fn legado_md5_key(password: &str) -> [u8; 16]` 公开供单测验证
2. **`core/core-storage/src/lib.rs`** 加 `pub mod legado_aes;`
3. **`core/core-storage/Cargo.toml`** 加 `aes = "0.8"` + `md-5 = "0.10"`（base64 已在 core-net，core-storage 加一份）
4. **bridge api 加 2 个 fn**：set_backup_password / get_backup_password（持久化到 `<documentsDir>/legado_local.json`）

### Flutter 端
5. **`webdav_config_page.dart` 加"备份密码"字段**（obscureText）：
   - load 时调 `get_backup_password` 填回
   - 保存时调 `set_backup_password`
   - 提示文案："留空 = 不加密；与原 Legado 兼容"

### 测试
- Rust ≥ 4 单测：
  1. `test_legado_md5_key_empty_password` — `MD5("")[0..16]` 等于已知字节序列
  2. `test_legado_md5_key_with_password` — 已知 password 输出对得上（手算或 echo -n password | md5sum）
  3. `test_encrypt_decrypt_roundtrip` — encrypt → decrypt 等于原文（多种长度：1B / 16B / 100B / 1KB）
  4. `test_decrypt_legado_compatible` — 用一段从原 Legado dump 的 base64 验证能解密成功（手工提供已知密文）
  5. `test_try_decrypt_or_passthrough_handles_plain_array` — 输入 `[]` 直接返回（探针生效）
- Flutter ≥ 1 widget test — 备份密码字段渲染 + 保存调 `set_backup_password` 一次

## Acceptance Criteria

- [ ] cargo test core-storage ≥ 49 (45 baseline + 4 aes)
- [ ] cargo build bridge 通过 + FRB regen
- [ ] flutter analyze 0 issue
- [ ] flutter test ≥ 350 (349 baseline + 1)
- [ ] **手工验证**（可选，留实机阶段）：用原 Legado 的 servers.json 加密文本能在本工程解密成功

## Definition of Done

- cargo + flutter test 全绿
- analyze 0 issue
- 不打 APK（磁盘紧张）
- commit "feat: 第五十一批 — 加密备份 AES Legado 兼容 (批次 12)" + archive

## Out of Scope

- WebDAV 自动备份 24h 定时器（留批次后续）
- WebDAV 阅读进度同步 / 背景图同步
- servers.json 实际导出导入（schema 还没实现 servers 表）
- config.xml 备份（schema 还没实现 SharedPreferences 映射）
- 阅读时长合并（read_records DAO 还没写）
