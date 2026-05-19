# BATCH-23: FFI 契约 + 错误码 + 日志 跨层一致 + network_security pinning

**Stage**: P1
**Slug**: `cross-layer-ffi-error-log`
**Effort**: L (≤800 行)
**Depends on**: BATCH-06 (workspace deps), BATCH-19 (reader controller)

## 1. 范围

跨层契约最后清扫：FFI JSON-string 模式选 5-10 条热路径迁移到强类型、PlatformInt64 选型规则、sentinel `""` → Option、统一 BridgeError enum + Dart 端 Log 类、apply_replace_rules 不再每次传整章 content、删除 v1/v2 同存的 search fn、network_security pinning（TOFU）、cleartext 收窄。

## 2. 包含的 findings

- [F-W3-005] FFI 全表 JSON-string 模式 — `flutter_app/lib/src/rust/api.dart`
- [F-W3-006] PlatformInt64 / i64 滥用 — `core/bridge/src/api.rs`
- [F-W3-007] rss_get_articles 用 `""` sentinel 与 Option 共存 — `core/bridge/src/api.rs:1815-1875`
- [F-W3-008] Rust 端错误消息中英混用 — multiple files
- [F-W3-009] Rust tracing vs Dart debugPrint 风格不统一 — multiple files
- [F-W3-010] apply_replace_rules 每次切章传整章 content — `core/bridge/src/api.rs:1018-1109`
- [F-W3-019] search_with_source_from_db v1/v2 同存 — `core/bridge/src/api.rs:474-580`
- [F-W3-021] network_security_config 缺 pin-set，远程 api-server 可 MITM — `flutter_app/android/.../network_security_config.xml`
- [F-W3-003] network_security_config 全局 cleartext — `flutter_app/android/app/src/main/res/xml/network_security_config.xml:22-27`

## 3. 影响文件

- `core/bridge/src/error.rs` (新增) — `pub enum BridgeError` (thiserror)；所有 bridge::api fn 统一返回 `Result<T, BridgeError>`
- `core/bridge/src/api.rs` — 选 5-10 条热路径（add_bookmark / get_all_books / replace_book_chapters_preserving_content / import_sources_from_json / apply_replace_rules）改强类型；删除 v1 search_with_source_from_db 标 `#[deprecated]`；rss_get_articles 改 Option
- `core/bridge/src/api.rs:1018-1109` — `apply_replace_rules` 改接受 chapter_id；Rust 端 LRU cache 内容（避免每次跨 FFI 复制）
- `flutter_app/lib/src/rust/api.dart` — FRB regenerate
- `flutter_app/lib/core/log.dart` (新增) — `class Log { static void warn(String tag, String msg, [Object? err]) }`；release 时 forward 到 platform Log.w()
- 全代码库 `debugPrint(...)` → `Log.warn/info/debug`；优先级：reader / search / rss / settings 5 个高频模块
- `flutter_app/android/app/src/main/res/xml/network_security_config.xml` — cleartext 改 domain-config 形式；为 api-server URL 加 TOFU pinning
- `.trellis/spec/backend/error-handling.md` — 写"FFI 何时用 JSON / 何时用强类型 + i64/i32 选型规则 + sentinel 禁止"
- `.trellis/spec/backend/logging-guidelines.md` — 写"Rust tracing + Dart Log 统一格式"
- `.trellis/spec/backend/error-codes.md` (新增) — 错误码集中索引（F-W3-042 P3 顺手解决）

## 4. 修复方向

复用 master findings-cross-config.md 主题 7、8、9 的"共同建议"段落。本批不一刀切重构 FFI 全表，挑 5-10 条热路径做样板，剩余 ~95% 留给后续按需迁移。

## 5. 测试策略

- Rust unit test：BridgeError enum + thiserror 自动序列化 OK
- Widget test：Dart 端 Log.warn 在 release 模式下 forward 到 logcat
- 手动：构造 v1/v2 search 调用确认 v1 deprecated warning
- 手动：apply_replace_rules 切章性能 profile（marshal 开销下降）

## 6. 验收

- [ ] master finding F-W3-005/006/007/008/009/010/019/021/003 全部消解或显式延后（FFI 全表迁移本批仅 5-10 条样板，其余条目记入 spec 与后续 cleanup 任务）
- [ ] grep `search_with_source_from_db[^_v]` 仅 deprecation
- [ ] grep `_vars.*sentinel` 类（"" 当 None）的实例数量 < 5

## 7. implement.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-cross-config.md", "reason": "本批次涉及的 wave 3 findings"}
{"file": "core/bridge/src/api.rs", "reason": "FFI 主体"}
{"file": "flutter_app/lib/src/rust/api.dart", "reason": "FRB 生成代码"}
{"file": "flutter_rust_bridge.yaml", "reason": "FRB 配置"}
{"file": "flutter_app/android/app/src/main/res/xml/network_security_config.xml", "reason": "pin + cleartext 收窄"}
{"file": ".trellis/spec/backend/error-handling.md", "reason": "FFI 选型 + sentinel 禁止 + BridgeError 落 spec"}
{"file": ".trellis/spec/backend/logging-guidelines.md", "reason": "Rust + Dart 日志 spec"}
{"file": ".trellis/spec/backend/quality-guidelines.md", "reason": "i64 / i32 选型规则"}
{"file": ".trellis/spec/guides/cross-layer-thinking-guide.md", "reason": "FFI 边界契约 spec"}
```

## 8. check.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md", "reason": "master report 主题：FFI 契约 + 错误信息 / 日志"}
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-cross-config.md", "reason": "Wave 3 详细"}
{"file": ".trellis/tasks/05-20-fix-roadmap/plan/batches/BATCH-23-cross-layer-ffi-error-log.md", "reason": "本批次自身验收清单"}
{"file": ".trellis/spec/backend/error-handling.md", "reason": "spec 是否落地"}
{"file": ".trellis/spec/backend/logging-guidelines.md", "reason": "spec 是否落地"}
```
