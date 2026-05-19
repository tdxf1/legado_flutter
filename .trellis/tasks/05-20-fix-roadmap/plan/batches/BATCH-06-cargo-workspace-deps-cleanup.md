# BATCH-06: Cargo workspace 依赖治理（集中化版本 + zeroize/secrecy）

**Stage**: P1
**Slug**: `cargo-workspace-deps-cleanup`
**Effort**: M (≤500 行)
**Depends on**: none

## 1. 范围

引入 `[workspace.dependencies]` + `[workspace.package]` + `[lints]` 一次性整治 6 个 sub-crate 的依赖版本（base64 / md5 / zip / urlencoding 多版本并存），同时把 `zeroize/secrecy` 加进 workspace 作为后续凭据相关 spec 的基础设施；顺便修一处 core-source 反向依赖 core-storage 的分层破坏。

## 2. 包含的 findings

- [F-W3-011] Cargo workspace 同 crate 多版本（base64 / md5 / zip / urlencoding） — `core/*/Cargo.toml`
- [F-W3-012] core-source 反向依赖 core-storage，破坏分层 — `core/core-source/Cargo.toml`
- [F-W3-020] Cargo workspace 缺 zeroize/secrecy — `core/Cargo.toml`
- [F-W3-017] pubspec 全 ^ 范围 + 未 commit pubspec.lock — `flutter_app/pubspec.yaml` (强耦合：本批顺手把"app-level 锁 lock"约束写进 spec)

## 3. 影响文件

- `core/Cargo.toml` — 新增 `[workspace.dependencies]`（base64 / zip / serde / serde_json / tokio / chrono / uuid / regex / encoding_rs / urlencoding / zeroize / secrecy）；新增 `[workspace.package]`（version / authors / license / repository）；新增 `[lints.clippy]` 与 `[lints.rust]`
- `core/core-storage/Cargo.toml` — 各依赖改 `{ workspace = true }`；`md-5` 与 `md5` 二选一统一到 `md-5`
- `core/core-source/Cargo.toml` — 同上；删除对 `core-storage` 的依赖（评估分层方案：Trait 注入 by caller）
- `core/core-net/Cargo.toml` — 同上
- `core/api-server/Cargo.toml` — 同上
- `core/core-parser/Cargo.toml` — 同上
- `core/bridge/Cargo.toml` — 同上；删除冗余 `tempfile` dev-dep（dev-deps 重复）
- `flutter_app/pubspec.yaml` — 评估收紧 sdk 下限到 3.3.0；保留 `^` 范围
- `.gitignore` — 删除"flutter_app/pubspec.lock"排除项（如果存在）；commit `pubspec.lock`
- `.trellis/spec/backend/quality-guidelines.md` — 写"子 crate 不允许内联版本号"+"app-level 锁 lock"约定

## 4. 修复方向

- F-W3-011：在 `core/Cargo.toml` 加 `[workspace.dependencies]` 集中管理；各子 crate 改成 `base64 = { workspace = true }`；`md5` 全部统一到 `md-5`（RustCrypto 同生态）；跑一次 `cargo tree --duplicates` 把清单贴在 PR 里。
- F-W3-012：评估能否把 core-source 内的 SQLite cache 抽成 trait，由 caller (bridge / api-server) 注入实现，core-source 只 `Box<dyn Cache>`；如范围太大，本批先标 `#[deprecated]` 并 README 记录。
- F-W3-020：引入 `zeroize = "1"` + `secrecy = "0.8"` 进 `[workspace.dependencies]`；具体业务字段改 `SecretString` 推到 BATCH-03 与后续凭据相关任务。本批仅落地基础设施，不改业务代码。
- F-W3-017：commit `pubspec.lock`；在 `.trellis/spec/backend/quality-guidelines.md` 加"app-level 锁 lock，library 不锁"。

## 5. 测试策略

- `cargo build --workspace` 全绿
- `cargo tree --duplicates` 输出空（base64 / zip 无重复）
- `cargo clippy --workspace -- -D warnings` 不引入新 warning（`[lints]` 启用 `unwrap_used = "warn"` 等）
- 不需要新单测

## 6. 验收

- [ ] `cargo tree --duplicates` 不再报 base64 / md5 / zip / urlencoding 重复
- [ ] `core/Cargo.toml` 含 `[workspace.dependencies]` / `[workspace.package]` / `[lints]` 三段
- [ ] `flutter_app/pubspec.lock` 已 commit
- [ ] master finding F-W3-011/012/020/017 全部消解或本批显式延后（F-W3-012 的分层方案评估若延后需在 spec 里记录）

## 7. implement.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-cross-config.md", "reason": "本批次涉及的 wave 3 findings"}
{"file": "core/Cargo.toml", "reason": "workspace 集中依赖入口"}
{"file": "core/core-storage/Cargo.toml", "reason": "改 workspace = true"}
{"file": "core/core-source/Cargo.toml", "reason": "改 workspace = true + 反向依赖"}
{"file": "core/core-net/Cargo.toml", "reason": "改 workspace = true"}
{"file": "core/api-server/Cargo.toml", "reason": "改 workspace = true"}
{"file": "core/core-parser/Cargo.toml", "reason": "改 workspace = true"}
{"file": "core/bridge/Cargo.toml", "reason": "改 workspace = true + 删除冗余 dev-dep"}
{"file": "flutter_app/pubspec.yaml", "reason": "sdk 下限 + lock 策略"}
{"file": ".trellis/spec/backend/quality-guidelines.md", "reason": "子 crate 版本号约束 + lock 策略 spec"}
```

## 8. check.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md", "reason": "master report 主题：Cargo workspace 依赖治理"}
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-cross-config.md", "reason": "Wave 3 详细 findings"}
{"file": ".trellis/tasks/05-20-fix-roadmap/plan/batches/BATCH-06-cargo-workspace-deps-cleanup.md", "reason": "本批次自身验收清单"}
{"file": ".trellis/spec/backend/quality-guidelines.md", "reason": "spec 是否落地"}
```
