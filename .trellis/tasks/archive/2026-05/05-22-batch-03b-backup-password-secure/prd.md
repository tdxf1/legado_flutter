# BATCH-03b: backup 密码迁移到 secure_storage（凭据存储主题收尾）

**Stage**: P1 (follow-up of BATCH-03)
**Slug**: `backup-password-secure`
**Effort**: S-M (~120 行 Dart + ~30 行 Rust)
**Depends on**: BATCH-03 ✅（secure_storage 基础设施已就绪 + WebDAV password 迁移模板）

## 1. 范围

把"备份密码"从明文 `legado_local.json` 迁移到 secure_storage，闭环凭据存储主题。BATCH-03 已为 webdav_password 建好 migration 模板（webdav_config_page.dart:120-141），本批照抄。

**关键发现**：`set_backup_password` / `get_backup_password` 当前**只读写** `legado_local.json` 一个 `password` 字段，**没有任何 Rust 内部代码消费它**（`backup_dao::export_to_zip` / `import_from_zip` 完全不接 password 参数）。意味着迁移**不会破坏 backup zip 加密功能**——因为该功能从未接入。

## 2. 包含的 finding

| Finding | 状态 |
|---------|------|
| F-W1A-020 备份密码明文 JSON 写盘 | 路线图原标 BATCH-03b，本批闭环 |

## 3. 影响文件

### Dart 侧（核心）

**`flutter_app/lib/features/settings/webdav_config_page.dart`**

`_loadConfig` (line 142-151)：备份密码读路径从 `rust_api.getBackupPassword(...)` 改为：
```dart
// BATCH-03b (F-W1A-020)：备份密码迁移到 secure_storage。
// 旧版本 set_backup_password 把字符串写到 legado_local.json 的
// password 字段；首次打开本页时一次性迁到 Keystore-backed 存储
// 并从 legado_local.json 移除该字段（保留 .json 文件本身——其它
// 字段未来扩展可能用，BATCH-23 已加损坏文件 .bak 备份机制）。
final securePwd = await readSecret('backup_password');
if (securePwd != null) {
  _backupPwdCtl.text = securePwd;
} else {
  // 走旧 FRB 路径读 legado_local.json，如有值则迁移
  try {
    final fn = widget.getBackupPasswordOverride ??
        ({required String documentsDir}) =>
            rust_api.getBackupPassword(documentsDir: documentsDir);
    final legacyPwd = await fn(documentsDir: dir);
    if (legacyPwd.isNotEmpty) {
      await writeSecret('backup_password', legacyPwd);
      // 清理 legado_local.json 中的 password 字段
      try {
        final clearFn = widget.setBackupPasswordOverride ??
            ({required String documentsDir, required String password}) =>
                rust_api.setBackupPassword(
                    documentsDir: documentsDir, password: password);
        await clearFn(documentsDir: dir, password: '');
      } catch (_) {
        // 清理失败不阻塞迁移；下次启动 secure_storage 命中即可
      }
      _backupPwdCtl.text = legacyPwd;
    } else {
      _backupPwdCtl.text = '';
    }
  } catch (_) {
    _backupPwdCtl.text = '';
  }
}
```

`_saveConfig` (line 213-226)：备份密码写路径从 `rust_api.setBackupPassword(...)` 改为：
```dart
// BATCH-03b (F-W1A-020)：备份密码改 secure_storage。
await writeSecret('backup_password', _backupPwdCtl.text);
```
保留 try-catch，但失败的 SnackBar 文案改为"保存失败: $e"（去掉"备份密码保存失败"的特殊化文案，与 webdav_password 同步）。

**测试钩子 widget params**：
- `getBackupPasswordOverride` / `setBackupPasswordOverride` 仅用于一次性迁移路径，保留向后兼容（test 不动）
- 新增不需要：迁移走 secure_storage（已有 `setSecureStorageOverrideForTest`），FRB 失败时的 fallback 通过现有 override 注入

### Rust 侧（标 deprecate，不删 FRB）

**`core/bridge/src/api.rs::set_backup_password` / `get_backup_password`** (line 1452 / 1510)：

加 `#[deprecated]` doc comment（**不**加 `#[deprecated]` attr —— 会污染 cargo 编译输出 + FRB binding 已生成）：
```rust
/// **DEPRECATED (BATCH-03b)**: backup 密码已迁移到 Dart 端 secure_storage
/// (key: `backup_password`)。本 fn 仅保留以支持启动期一次性迁移
/// （从 legado_local.json 读旧值 → 写 secure_storage → 调 set_backup_password
/// 传空串清理）。新代码不要调用。
///
/// FRB funcId 71/72 保留契约不删，方便未来 backup zip 加密功能（如真接入）
/// 直接复用；同时避免 binding regen 风险。
pub fn set_backup_password(...) -> ...
```

类似注释加在 `get_backup_password`。

### 测试

**`flutter_app/test/webdav_config_page_test.dart`**：

- 加 `flutter_app/test/backup_password_secure_test.dart` 新文件覆盖：
  - load 路径：secure_storage 命中直接用
  - load 路径：secure_storage miss + FRB 旧值 → 触发迁移 + 清理
  - load 路径：secure_storage miss + FRB 也空 → 空串
  - save 路径：写 secure_storage
- 现有 `webdav_config_page_test.dart` 行 137 `getBackupPasswordOverride: ... async => ''` 改为也 stub `setSecureStorageOverrideForTest` + verify secure_storage 路径优先（如不便改，加一个 `setUp` 注入空 fake secure storage 让走 FRB fallback 路径，保持原 test 行为）

### Spec

**`.trellis/spec/flutter-app/quality-and-anti-patterns.md`**

「凭据存储边界」段（BATCH-03 已加）扩充：
- secure_storage key namespace：`webdav_password`（BATCH-03）+ `backup_password`（BATCH-03b）
- backup_password 迁移模式（与 webdav_password 同模式）：load 优先 secure_storage，miss 回退 FRB 旧路径并触发一次性迁移 + 清理
- 凭据存储主题闭环（F-W2B-001 + F-W1A-020）

## 4. 测试策略

- `cd flutter_app && flutter analyze` 0 issue
- `cd flutter_app && flutter test` 全套 PASS（baseline 523 + 新增 4 case ≈ 527）
- `cargo build --workspace` 0 error（FRB binary contract 未变）
- `cargo test --workspace` PASS（不动 Rust 测试）

## 5. 验收

- [ ] master finding F-W1A-020 标 Resolved by BATCH-03b（凭据存储主题闭环）
- [ ] webdav_config_page.dart load + save 路径走 secure_storage
- [ ] Rust set/get_backup_password doc 标 deprecate（FRB 契约保留）
- [ ] 启动期一次性迁移：旧 legado_local.json 中 password 字段读出 → secure_storage → 清空字段
- [ ] flutter analyze 0 / flutter test 527 PASS / cargo build 0 / cargo test PASS

## 6. 不在范围

- 删 FRB funcId 71/72：保留契约（未来 backup zip 加密功能可复用）
- legado_local.json 文件本身：保留（BATCH-23 已加损坏 .bak 机制，未来其他字段扩展用）
- 接入真实 backup zip 加密：F-W1A-020 finding 仅说"密码明文写盘"，不要求加密 backup（路线图未涵盖）

## 7. 风险点

- **迁移幂等性**：用户首次打开 webdav_config_page 后旧 legado_local.json 的 password 已清空；二次/三次打开走 secure_storage 路径，原 FRB 调用返回空串 → 不会重复迁移，安全。
- **FRB override 测试**：现有 webdav_config_page_test.dart 用 override 注入 `setBackupPassword` / `getBackupPassword`；本批 load 路径**先**查 secure_storage，需要在 test 中先注入空 fake secure storage 才会走到 override 路径。如需保持现有 test 不动，可在 `setUp` 或 single test 用 `setSecureStorageOverrideForTest` 注入空实现。
- **save 路径无 try-catch**：原 `rust_api.setBackupPassword` 包了 try-catch（FRB 失败展示 SnackBar）；改为 `writeSecret` 后 secure_storage 失败概率极低（Keystore 异常需要硬件级故障），可删特殊 SnackBar 与 webdav_password save 同模式。
- **deprecate 注释非 attr**：`#[deprecated]` attr 会让 dart 端调用出 warning，但 dart 端**仍要调**（迁移路径）；用 doc 注释更合适。
