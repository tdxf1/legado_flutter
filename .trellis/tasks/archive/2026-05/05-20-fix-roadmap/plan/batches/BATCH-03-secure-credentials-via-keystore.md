# BATCH-03: 凭据保险柜（Android Keystore）+ WebDAV / 备份密码迁移

**Stage**: P0
**Slug**: `secure-credentials-via-keystore`
**Effort**: M (≤500 行)
**Depends on**: BATCH-02 (allowBackup=false 是该批迁移的防御深度前提)

## 1. 范围

引入 Android Keystore wrapper 一次性解决"WebDAV 凭据 / 备份密码明文写盘"两个 P0/P1，同主题强耦合一并改完；同时把"明文写日志"的 token 路径也一起 sanitize。

## 2. 包含的 findings

- [F-W2B-001] WebDAV 凭据明文写 `webdav.json` — `flutter_app/lib/features/settings/webdav_config_page.dart:181-187`
- [F-W1A-020] 备份密码明文 JSON 写盘 — `core/bridge/src/api.rs:1407-1429` (强耦合：同主题 + 同基础设施)
- [F-W1A-023] api-server 临时 token 在 warn 日志输出明文 — `core/api-server/src/main.rs:108-119` (强耦合：凭据外泄路径)
- [F-W2B-005] _loadWebDavConfig catch (_) 静默返回 null — `flutter_app/lib/features/settings/backup_page.dart:474-494` (同文件迁移顺手解决)
- [F-W2B-006] webdav cfg 三处 `!` 强制断言 — `flutter_app/lib/features/settings/backup_page.dart:540` (同文件)

## 3. 影响文件

- `flutter_app/lib/core/security/secure_storage.dart` — 新增；包装 `flutter_secure_storage`（Android Keystore 后端）
- `flutter_app/lib/features/settings/webdav_config_page.dart` — 改用 secure_storage 读写；旧 `webdav.json` 启动迁移后删除
- `flutter_app/lib/features/settings/backup_page.dart` — `_loadWebDavConfig` 改 secure_storage；区分 FileSystemException vs FormatException；移除 `!` 强制断言
- `core/bridge/src/api.rs:1407-1447` — `set_backup_password` / `get_backup_password` 改走 FRB 调用 Dart 端 secure_storage（或 Rust 端 `secrecy::SecretString` 包裹后再写盘）
- `core/api-server/src/main.rs:108-119` — token 改 `token_set=true/false` 日志，token 实际值仅 stderr 单行打印 + 一次性
- `flutter_app/pubspec.yaml` — 新增 `flutter_secure_storage` 依赖

## 4. 修复方向

- F-W2B-001 / F-W1A-020：用 `flutter_secure_storage` 替换 `webdav.json` 与 `legado_local.json` 中的密码字段；启动时若旧文件存在则读出 → 写入 secure storage → 删除旧字段（迁移路径）。Android 端走 Keystore；iOS 走 Keychain（即使非主线也能复用同 API）。
- F-W1A-023：仅记录 `token_set=true/false`，不打印实际值；首次启动时 stderr 单行 + 提示用户复制，后续不重复打。
- F-W2B-005 / F-W2B-006：迁移到 secure_storage 后，错误来源天然清晰；同时统一 catch 语义并删除 `!` 断言。

## 5. 测试策略

- Widget test：webdav_config_page 保存后 secure_storage 命中、磁盘无明文（mock secure_storage backend）。
- Widget test：backup_page 加载 WebDAV 配置时区分"文件不存在"vs"格式损坏"。
- 手动：装 release APK，跑 `adb backup` 不应导出密码字段（与 BATCH-02 的 allowBackup=false 互证）；旧版本升级路径验证迁移成功后旧文件被清。
- Rust 端 unit test：api-server token 路径无 token 明文。

## 6. 验收

- [ ] 全代码库 grep "webdav.json" / "password.*json" 不再出现明文写盘
- [ ] api-server 启动日志不含 token 明文（仅 token_set=true/false）
- [ ] master finding F-W2B-001 / F-W1A-020 / F-W1A-023 / F-W2B-005 / F-W2B-006 全部消解
- [ ] 升级测试：旧版本写入 webdav.json，升级后凭据迁移到 Keystore 且旧文件删除

## 7. implement.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-flutter-features.md", "reason": "本批次涉及的 wave 2B findings（F-W2B-001/005/006）"}
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-data.md", "reason": "本批次涉及的 wave 1A findings（F-W1A-020/023）"}
{"file": "flutter_app/lib/features/settings/webdav_config_page.dart", "reason": "WebDAV 凭据写盘主路径"}
{"file": "flutter_app/lib/features/settings/backup_page.dart", "reason": "WebDAV 凭据加载 + 备份密码 UI 入口"}
{"file": "core/bridge/src/api.rs", "reason": "set_backup_password / get_backup_password 入口"}
{"file": "core/api-server/src/main.rs", "reason": "token 明文日志"}
{"file": "flutter_app/pubspec.yaml", "reason": "新增 flutter_secure_storage 依赖"}
{"file": ".trellis/spec/backend/quality-guidelines.md", "reason": "凭据存储 spec：'敏感字段必须 SecretString / Keystore'"}
```

## 8. check.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md", "reason": "master report 主题汇总：凭据存储主题"}
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-flutter-features.md", "reason": "Wave 2B 详细 findings"}
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-data.md", "reason": "Wave 1A 详细 findings"}
{"file": ".trellis/tasks/05-20-fix-roadmap/plan/batches/BATCH-03-secure-credentials-via-keystore.md", "reason": "本批次自身验收清单"}
{"file": ".trellis/spec/backend/quality-guidelines.md", "reason": "凭据存储新约定是否落地"}
```
