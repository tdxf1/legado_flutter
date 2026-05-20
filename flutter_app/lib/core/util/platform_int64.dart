/// PlatformInt64 → Dart `int` 桥接 helper（BATCH-24, 2026-05-21）。
///
/// flutter_rust_bridge 把 Rust `i64` 映射成 Dart 的 `PlatformInt64` 类型别名。
/// 在 native (io) 平台它就是 `int`，在 web (wasm) 平台是 `BigInt`。所以
/// caller 拿到返回值后，只要项目跑在 native 上，直接 `as int` 就行；但跨平台
/// 安全的写法是先做 type guard，BigInt 路径调 `toInt()` 再 `as int`。
///
/// 历史上 6 处 caller 各自重复同一段模板（rule_sub_page × 2、
/// rss_source_manage_page × 2、cache_management_page × 2）：
///
/// ```dart
/// final n = await rust_api.someCall(...);  // n: PlatformInt64
/// // ignore: unnecessary_cast
/// final dynamic raw = n;
/// return raw is int ? raw : raw.toInt() as int;
/// ```
///
/// BATCH-24 把这段抽成单一函数，caller 行变 1 行：
///
/// ```dart
/// final n = await rust_api.someCall(...);
/// return platformInt64ToInt(n);
/// ```
///
/// 见 finding F-W2B-007 in `findings-flutter-features.md`。
int platformInt64ToInt(dynamic raw) {
  if (raw is int) return raw;
  // BigInt（web）或其它带 toInt() 的数值对象。dynamic 调用绕过静态检查。
  return (raw as dynamic).toInt() as int;
}
