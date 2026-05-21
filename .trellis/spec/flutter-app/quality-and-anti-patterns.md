# Quality and Anti-Patterns

What the Flutter app rejects and why.

## Lint Bar

`flutter_app/analysis_options.yaml` enables the default flutter_lints set with project-specific tightenings. `flutter analyze` must report **0 issues** before any commit.

When you must use `// ignore:`:

- Always include the lint name (`// ignore: invalid_use_of_protected_member`).
- Always add a one-line comment explaining why.
- Reserve `// ignore_for_file:` for generated code only.

Example used by `core/widgets/safe_setstate.dart`:

```dart
// ignore: invalid_use_of_protected_member
setState(fn);
```

This is acceptable because the extension is a thin syntactic wrapper. New `// ignore` lines that don't have a similar justification will be flagged.

## Forbidden Patterns

| Pattern | Why | Reference |
|---|---|---|
| `if (mounted) setState(() => ...)` inside `lib/features/` | 31 sites collapsed to `safeSetState`. Reintroduction breaks the convention. | BATCH-25 sweep |
| `getApplicationDocumentsDirectory()` outside `core/persistence/` | Bypasses the resolver + test hook. | BATCH-18e |
| `File('$dir/foo.json').readAsString` for new persistence | Bypasses `_Mutex` write serialization. | BATCH-18c json_store |
| `final dynamic raw = n; return raw is int ? raw : raw.toInt() as int;` | Use `platformInt64ToInt(n)` instead. | BATCH-24 |
| Hand-rolled `_formatRelativeTime` | Use `formatRelativeTime(int sec)` from `core/util/time_format.dart`. | BATCH-24 |
| Re-implementing the import-summary label string | Use `formatImportSummaryLabel(...)`. | BATCH-24 |
| Single-line `return author.isEmpty ? '未知作者' : author;` for fallback display name when there is a richer helper | Keep small inline helpers in feature when truly local; promote when 2nd caller appears. | BATCH-24 promotion rule |
| Using `print` / `debugPrint` for production logs | Use `core/perf_monitor.dart` or `tracing` (via FRB) for telemetry. `debugPrint` is fine for dev-time hints. | n/a |
| `setState` after `await` without a mounted check | See [async-and-mounted](./async-and-mounted.md). | BATCH-25 |
| Two providers exposing the same conceptual value | Derive one from the other. | BATCH-18d (`fontSizeProvider`) |
| Writing passwords / API tokens / WebDAV credentials to `settings.json` or any per-feature `*.json` | Use `core/security/secure_storage.dart` (`writeSecret/readSecret/deleteSecret`). See "凭据保险柜 (Credential Vault, BATCH-03)" below. | BATCH-03 |
| `Map<String, String>!` accessor pattern (`cfg['url']!`) for known-shape config | Use a file-private data class with `final` fields. The config "shape" should be encoded in the type, not implied via `!`. | BATCH-03 (`_WebDavCredentials`) |

## 凭据保险柜 (Credential Vault, BATCH-03)

**敏感字段必须走 `core/security/secure_storage.dart`，不允许进 `settings.json` / per-feature `*.json` / FRB string payload**。canonical 例子：WebDAV password。

### 何为「敏感字段」

- 用户密码、API token、设备私钥、OAuth refresh token、HTTP basic auth credential、WebDAV password。
- 反例（**非敏感**，仍可走 `json_store`）：URL / username / device-name / preference flags / cache keys / search history。

### IO 路径

```dart
// 写
import 'package:flutter_app/core/security/secure_storage.dart';
await writeSecret('webdav_password', controller.text);
// 顺手把非敏感字段单独走 json_store，不混在一起
await writeJsonFile('webdav.json', { 'url': url, 'user': user, 'deviceName': dev });

// 读
final pwd = await readSecret('webdav_password') ?? '';

// 删除（写 null 或空串等价）
await writeSecret('webdav_password', null);
// 或者
await deleteSecret('webdav_password');
```

后端：Android = `EncryptedSharedPreferences` (AES-256/GCM, key in Keystore，flutter_secure_storage v9 默认，与 minSdk 23+ 对齐)；iOS = Keychain；其它平台由 `flutter_secure_storage` 内置默认（不在主线优先级）。

### 测试钩子

```dart
import 'package:flutter_app/core/security/secure_storage.dart';
import '_secure_storage_fake.dart';

setUp(() {
  setSecureStorageOverrideForTest(InMemorySecureStorage());
});

tearDown(() {
  setSecureStorageOverrideForTest(null); // 恢复 production 实现
});
```

`InMemorySecureStorage` 在 `flutter_app/test/_secure_storage_fake.dart`，是共享 fake；不要在每个测试文件各自重写。

### 为什么 top-level fn override 而不是 ProviderScope

`secure_storage` 是 cross-feature 工具（凭据全局唯一），不绑业务 Provider；与 `core/persistence/json_store.dart` 一致用 top-level fn + `setXxxOverrideForTest` 钩子。这与 BATCH-20 的「features 用 service provider + ProviderScope.overrides」不矛盾——后者针对**业务领域**（FRB 调用、文件选择等），前者针对**基础设施**。

### 迁移路径模板

旧版本可能把敏感字段写在普通 JSON 里（典型：webdav.json 含 password）。迁移逻辑放对应 page 的 `_loadConfig`（页面入口）：

```dart
final map = await readJsonFile<Map<String, dynamic>>(...);
final legacyPwd = (map['password'] as String?) ?? '';
final securePwd = await readSecret('webdav_password');

if (legacyPwd.isNotEmpty && securePwd == null) {
  // 一次性迁移：写入保险柜 + 重写 json 去掉敏感字段
  await writeSecret('webdav_password', legacyPwd);
  await writeJsonFile('webdav.json', {
    'url': map['url'], 'user': map['user'], 'deviceName': map['deviceName'],
    // password 不再写入
  });
}
```

幂等：第二次启动 `securePwd != null`，迁移路径自动跳过。`writeJsonFile` 永不再带敏感字段，旧字段会被下一次正常 save 自然清掉。

### Forbidden 反向

- ❌ `await writeJsonFile('webdav.json', { 'password': pwd, ... })` — 把密码混进普通 JSON
- ❌ `await writeJsonKey('webdav_password', pwd)` — 写 settings.json 也不允许
- ❌ FRB API 把 password 当 String 透传 + Rust 端写普通文件（F-W1A-020 备份密码即此问题，留 BATCH-03b 处理）
- ❌ 在 widget test 直接构造 `FlutterSecureStorage()` 跑——会触发 platform channel `MissingPluginException`；用 `setSecureStorageOverrideForTest(InMemorySecureStorage())`


## Performance Notes

- `cached_network_image` is the only blessed image cache. Don't add a parallel `Image.network` call site.
- `ListView` should be `ListView.builder` for any list whose length depends on user data. Eager `ListView(children: [...])` is allowed only for short fixed menus (settings rows, etc.).
- Reader page is the largest file (~2900 lines) and uses `RepaintBoundary` carefully. Do not casually wrap widgets in `RepaintBoundary`; profile first.
- `safeSetState` after FRB is cheap; the FRB call itself is the expensive part. Don't aggressively `setState({})` inside reader pan/scroll callbacks.

## Code Style

- Follow `dart format` defaults (80-col wrap, trailing commas where they help diff readability).
- Class members ordered: fields → constructor → static helpers → public methods → `build`/`createState` → private methods.
- Avoid `late` for fields that can have a sensible default; reserve it for FRB-injected handles.
- Use `const` constructors where possible. Linter will flag missing ones.

## Verification Cadence

Before commit:

```bash
cd flutter_app
flutter analyze
flutter test
```

Both must be 0-issue / all-green. The repo does not currently run `flutter format --output=none --set-exit-if-changed`, but matching `dart format` style is expected.

## When You Spot a New Anti-Pattern

1. Check if it appears 2+ times in the codebase. One-off slips don't warrant a rule.
2. Either fix it in the same change set, or open a Trellis batch task that captures the audit.
3. Add the pattern to the table above with a reference to the batch.

The historical record lives in `findings-flutter-features.md` (Wave 2B) and `findings-flutter-core.md` (Wave 2A). Reading a few entries before starting a refactor calibrates what we already know is bad.
