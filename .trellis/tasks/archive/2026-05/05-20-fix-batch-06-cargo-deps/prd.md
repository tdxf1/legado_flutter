# BATCH-06: Cargo workspace 依赖治理（仅 Cargo.toml）

> 修复路线图 BATCH-06 的**缩范围版本**：原计划含 md5/zip 升级（需改业务代码）+ core-source 反向依赖 core-storage 重构（200+ 行架构改动），均拆出延后。本批仅做"纯 Cargo.toml 改动 + commit pubspec.lock"。
> 路线图原文：[`.trellis/tasks/archive/2026-05/05-20-fix-roadmap/plan/batches/BATCH-06-cargo-workspace-deps-cleanup.md`](../archive/2026-05/05-20-fix-roadmap/plan/batches/BATCH-06-cargo-workspace-deps-cleanup.md)

## Goal

把 Cargo workspace 6 个 sub-crate 的依赖版本集中化（base64 / urlencoding 等可统一），引入 `[workspace.dependencies]` + `[workspace.package]` + `[lints]` 三段元数据，把 `zeroize/secrecy` 加入 workspace 作为后续凭据相关 spec 的基础设施，并把 `flutter_app/pubspec.lock` 提交以保证 reproducible build。**0 业务代码改动**。

## Why

- **F-W3-011 (P1)**：6 个 crate 各自声明依赖版本，存在 3+ 处不一致：`base64 0.21 vs 0.22`、`urlencoding "2" vs "2.1"`、`md5 vs md-5`、`zip 0.6 vs 2.x`——cargo 同时编译多份重复 crate，bridge libbridge.so 体积虚胖。
- **F-W3-012 (P1)**：core-source 反向依赖 core-storage 破坏分层。
- **F-W3-020 (P1)**：workspace 缺 `zeroize/secrecy`——密码/token 类敏感数据没有零化基础设施。
- **F-W3-017 (P1)**：`pubspec.lock` 未 commit，CI 重跑同 commit 可能拉不同依赖版本，破坏 reproducible build。
- **F-W3-030 (P2)**：bridge `tempfile` 重复在 deps + dev-deps。
- **F-W3-039 (P3)**：缺 `[workspace.package]` 集中元数据。
- **F-W3-040 (P3)**：缺 `[lints]` 强制 clippy 规则。

## Scope

### in scope（本批做）

- `core/Cargo.toml`：
  - 新增 `[workspace.package]`（version / authors / license / repository / edition / rust-version）
  - 新增 `[workspace.dependencies]`：`base64 / urlencoding / serde / serde_json / tokio / chrono / uuid / regex / encoding_rs / tracing / thiserror / rusqlite / scraper / quick-xml / sha2 / aes / zeroize / secrecy`
  - 新增 `[workspace.lints.clippy]`：仅启用观察性 lints（`unwrap_used = "warn"` / `expect_used = "warn"` / `panic = "warn"`），**不**用 `-D warnings` 强制
  - 新增 `[workspace.lints.rust]`：`unused_must_use = "warn"`（默认已是 warn，显式声明）
- 6 个 sub-crate Cargo.toml（`bridge / core-net / core-parser / core-source / core-storage / api-server`）：
  - 共享依赖改 `{ workspace = true }` 形式
  - 每个 crate 加 `[lints] workspace = true` 声明继承 workspace lints
  - bridge：删除冗余的 `[dev-dependencies] tempfile`（已在 `[dependencies]`）
  - **保持** `md5 = "0.7"`（core-source）/ `md-5 = "0.10"`（core-storage）现状，标 TODO 留独立批次
  - **保持** `zip = "0.6"`（core-parser/core-source）/ `zip = "2"`（core-storage）现状，标 TODO 留独立批次
  - **保持** `core-source` 对 `core-storage` 的依赖，标 TODO（反向依赖架构问题）
- `flutter_app/pubspec.lock`：`git add -f` 提交（`.gitignore` 没排除它，但之前未 commit；本批显式入库）
- `flutter_app/pubspec.yaml`：sdk 下限提到 3.3.0（与 mobile_scanner 5.x 对齐，F-W3-043 P3 顺手）

### out of scope（明确延后）

- **md5 → md-5 统一**（API 不兼容，需改 `core-source/src/legado/js_runtime.rs:852` 调用）→ 独立 batch `cargo-md5-unify`
- **zip 0.6 → 2.x 升级**（core-parser/core-source 需改 ZipArchive API）→ 独立 batch `cargo-zip-upgrade`
- **core-source ← core-storage 反向依赖重构**（抽 Cache trait + caller 注入，200-400 行改动）→ 独立 batch `arch-core-source-cache-trait`
- **`unwrap_used` warn 后修 unwrap**：本批仅启用 lint level=warn 让其可见；批量修 unwrap 路线图已规划在 BATCH-11/12 内
- **业务代码使用 zeroize/secrecy**：本批仅基础设施进 workspace.dependencies；具体业务字段（密码 / token）改 SecretString 留 BATCH-03

## Requirements

- [ ] `core/Cargo.toml` 含 `[workspace.package]` + `[workspace.dependencies]` + `[workspace.lints]` 三段
- [ ] 6 个 sub-crate Cargo.toml 共享依赖改 `{ workspace = true }`；每个加 `[lints] workspace = true`
- [ ] 保持 `core-storage/aes / cbc / ecb / block-padding / md-5`、`core-source/md5` 等 crate 各自 inline 版本（API 不兼容方案）
- [ ] bridge `[dev-dependencies] tempfile` 删除（已在 [dependencies]）
- [ ] `flutter_app/pubspec.lock` 进入 git 索引
- [ ] `flutter_app/pubspec.yaml` `sdk` 下限 `>=3.3.0 <4.0.0`（仅缩小区间，不升 flutter 主版本）
- [ ] `core/core-source/Cargo.toml` 反向依赖 `core-storage` 上方加 TODO 注释指向 follow-up 批次
- [ ] `core/core-source/Cargo.toml` `md5 = "0.7"` 上方加 TODO 注释指向 md5 unify 批次
- [ ] 0 业务代码改动（无 .rs / .dart / .kt 文件改动）

## Acceptance Criteria

- [ ] master finding F-W3-011 / F-W3-020 / F-W3-017 / F-W3-030 / F-W3-039 / F-W3-040 / F-W3-043（P3）整体进展（仅"集中化部分"消解；md5/zip 统一显式延后并标 TODO）
- [ ] **本批 sub-agent 不跑 cargo build**（避免触发完整编译；用户 commit 后下次 build 是真正测试）
- [ ] 用户跑 `cargo build --workspace --target aarch64-linux-android` 应能成功（前提：所有 `{ workspace = true }` 字段名拼写正确，版本号在 workspace 层定义）
- [ ] `cargo tree --duplicates` 仍会报 md5 / zip 重复（因为本批未升级），其它依赖应消解

## Definition of Done

- 全部 7 个 Cargo.toml 改完（1 root + 6 sub-crate）
- `pubspec.lock` 提交
- `pubspec.yaml` sdk 下限收紧
- 所有 TODO 注释指向具体后续批次（md5 unify / zip upgrade / arch refactor）
- 0 业务代码改动
- commit message 风格对齐仓库历史（`chore(deps):`）

## Out of Scope（再次强调）

- 任何 .rs / .dart / .kt 文件改动
- md5 / zip API 升级（独立批次）
- core-source 反向依赖重构（独立批次）
- unwrap 修复（路线图 BATCH-11/12）
- zeroize/secrecy 业务字段使用（→ BATCH-03）
- 新增依赖（除 zeroize / secrecy）
- 跑 `cargo build` / `cargo clippy` / `flutter pub get`（留给用户）

## Technical Approach

### 步骤

#### 1. `core/Cargo.toml` 新增 workspace 元数据

完整新结构：

```toml
[workspace]
members = ["core-net", "core-parser", "core-storage", "core-source", "bridge", "api-server"]
resolver = "2"

[workspace.package]
version = "0.1.0"
edition = "2021"  # 与现状一致；README 说 2024 但所有 sub-crate 都用 2021，本批不改 edition
authors = ["legado_flutter contributors"]
license = "MIT"
repository = "https://github.com/lq-259/legado_flutter"

[workspace.dependencies]
# ── 序列化 / 数据 ──────────────────────────────────────────────
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"

# ── 日志 ────────────────────────────────────────────────────
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["fmt", "env-filter"] }

# ── 错误处理 ────────────────────────────────────────────────
thiserror = "1.0"

# ── 并发 / 异步 ─────────────────────────────────────────────
tokio = { version = "1", features = ["full"] }

# ── 时间 / UUID ─────────────────────────────────────────────
chrono = "0.4"
uuid = { version = "1.10", features = ["v4", "serde"] }

# ── 编码 ────────────────────────────────────────────────────
encoding_rs = "0.8"
base64 = "0.22"  # 统一到 0.22（原 core-storage/core-net 用 0.21，API 兼容）
urlencoding = "2.1"  # 统一到 2.1（原 core-net 用 "2"，等价同 SemVer）
sha2 = "0.10"

# ── 加密 ────────────────────────────────────────────────────
aes = "0.8"
# md-5 / md5 仍 inline（API 不兼容，留 follow-up batch 统一）

# ── 解析 ────────────────────────────────────────────────────
regex = "1.11"
scraper = "0.20"
quick-xml = { version = "0.37", features = ["serialize"] }

# ── 存储 ────────────────────────────────────────────────────
rusqlite = { version = "0.31", features = ["bundled"] }

# ── 测试 ────────────────────────────────────────────────────
tempfile = "3"

# ── 凭据 / 安全（基础设施，业务用法见 BATCH-03） ────────────
zeroize = "1"
secrecy = "0.8"

[workspace.lints.clippy]
unwrap_used = "warn"   # 仅观察性，不强制；批量修留 BATCH-11/12
expect_used = "warn"
panic = "warn"

[workspace.lints.rust]
unused_must_use = "warn"
```

#### 2. 各 sub-crate Cargo.toml 改 `{ workspace = true }`

对每个 sub-crate：
- `[package]` 段保留 `name` / 自身的 `crate-type`，把 `version = "0.1.0"` / `edition = "2021"` 改为 `version.workspace = true` / `edition.workspace = true`，加 `license.workspace = true` 等
- `[dependencies]` 内对应 workspace 已声明的依赖改 `{ workspace = true }`，例如：
  - `serde = { workspace = true }`（带 derive feature 已在 workspace 定义）
  - `serde_json = { workspace = true }`
  - `tracing = { workspace = true }`
  - `base64 = { workspace = true }`
  - `urlencoding = { workspace = true }`
  - `chrono = { workspace = true }`
  - `uuid = { workspace = true, features = ["v4"] }` （features 可在 sub-crate 局部加，注意：workspace 定义已含 v4+serde 时无需重复；具体看每个 sub-crate 的需求）
  - `tokio = { workspace = true }`（如 sub-crate 需特定 features，可在子 crate 里追加 `features = [...]`）
  - `regex = { workspace = true }`
  - `encoding_rs = { workspace = true }`
  - `scraper = { workspace = true }`
  - `quick-xml = { workspace = true }`
  - `rusqlite = { workspace = true }`（注意 features 可能子 crate 各异：bridge / core-storage 用不同 feature 子集；如有差异保持 inline）
  - `thiserror = { workspace = true }`
  - `sha2 = { workspace = true }`
  - `aes = { workspace = true }`
  - `tempfile = { workspace = true }`（dev-deps 也走 workspace）
- **特殊保留 inline**：
  - `md5 = "0.7"`（core-source）+ `md-5 = "0.10"`（core-storage）— API 不兼容，加 TODO 指向独立批次
  - `zip = "0.6"`（core-parser/core-source）+ `zip = { version = "2", default-features = false, features = ["deflate"] }`（core-storage）— 同上
  - `cookie_store = "0.21"`、`tokio-retry = "0.3"`、`reqwest`、`rustls`、`hickory-resolver`、`ureq`、`flutter_rust_bridge`、`r2d2`、`r2d2_sqlite`、`axum`、`tower-http`、`futures`、`tokio-stream`、`subtle`、`url`、`flate2`、`cbc`、`ecb`、`block-padding`、`sxd-document`、`sxd-xpath`、`jsonpath_lib`、`ttf-parser`、`rquickjs`、`boa_engine`、`httpmock`：单一使用方或非共享，保持 inline 即可（不入 workspace.dependencies）
- `[lints]` 段加：
  ```toml
  [lints]
  workspace = true
  ```

#### 3. `core/bridge/Cargo.toml` 删除冗余 dev-dep

```toml
# 删除：
# [dev-dependencies]
# tempfile = "3"
# 替换为（如本批通过 workspace.dependencies 引入）：无（如果 [dependencies] 已经 workspace = true 引入 tempfile，dev-deps 不需要再列）
```

注意：bridge 的 `tempfile` 是 build-time 用，且 `[dependencies]` 已含 tempfile，dev-deps 删除即可。

#### 4. 标 TODO 注释

`core/core-source/Cargo.toml`：
```toml
# TODO(BATCH-06b: cargo-md5-unify): 统一到 md-5 (RustCrypto)，需改
# core-source/src/legado/js_runtime.rs:852 调用从 md5::compute() 改为
# Md5::new() + update + finalize 模式。
md5 = "0.7"

# TODO(BATCH-06c: cargo-zip-upgrade): 升级到 zip = "2" 与 core-storage
# 对齐，需改 core-source/src/legado/js_runtime.rs ZipArchive::new 调用
# （0.6 与 2.x API 有破坏性变化）。
zip = { version = "0.6", default-features = false }

# TODO(BATCH-06d: arch-core-source-cache-trait): 抽 Cache trait 由
# caller (bridge / api-server) 注入，移除 core-source → core-storage
# 反向依赖（破坏分层）。当前留作便利。
core-storage = { path = "../core-storage" }
```

`core/core-parser/Cargo.toml`：
```toml
# TODO(BATCH-06c: cargo-zip-upgrade): 升级到 zip = "2"，需改
# core-parser/src/epub.rs ZipArchive 调用。
zip = { version = "0.6", default-features = false }
```

#### 5. `flutter_app/pubspec.yaml` sdk 下限收紧

```yaml
environment:
  sdk: '>=3.3.0 <4.0.0'  # 原 ">=3.0.0"；与 mobile_scanner 5.x 要求对齐
  flutter: '>=3.35.0'
```

#### 6. `flutter_app/pubspec.lock` 入库

- 确认 `.gitignore` 不排除它（已确认：现有 .gitignore 没有 `pubspec.lock` 排除项）
- `git add -f flutter_app/pubspec.lock`（虽然没排除，但之前可能未 commit）

### 工具

- `Edit` / `Write` 改 7 个 Cargo.toml + pubspec.yaml
- `git add` pubspec.lock
- **不跑** `cargo build` / `cargo clippy` / `flutter pub get`

### 风险

- **workspace.dependencies 字段拼写错误**：sub-crate `{ workspace = true }` 找不到对应 workspace 项时 cargo 会立刻报错；改完后**用户跑一次 `cargo check --workspace`**确认。
- **sub-crate features 不一致**：多个 sub-crate 用 tokio 但要求不同 features（如 core-net 要 "full"，bridge 只要 "rt", "rt-multi-thread"）。workspace 用 `features = ["full"]` 上限定义，sub-crate 实际不会用到的 feature 不影响功能但会被链接进来——本批接受这个 trade-off（cargo 已对未用 feature 做 dead-code elim）。
- **rusqlite features 差异**：core-storage 用 `["bundled", "serde_json"]`，bridge / api-server 用 `["bundled"]`，core-source 用 `["bundled"]`——workspace 用最小公共集 `["bundled"]`，core-storage 在子 crate 追加 `features = ["serde_json"]`。
- **`[lints] workspace = true` 在 sub-crate 是否生效**：cargo 1.74+ 才支持 workspace lints；本仓库 README 没声明 cargo 版本，但 edition 2021 + cargo workspace.dependencies (1.64+) 说明工具链够新，应该 OK。
- **pubspec.lock 与 CI**：commit lock 后所有人 / CI 必须用相同 Flutter SDK 才不会重写 lock；本仓库目前是个人项目，影响小。

## Decision (ADR-lite)

**Context**: 路线图 BATCH-06 原计划包含 md5 / zip / 反向依赖三大类需要改业务代码的项；本会话目标是延续前两批"零业务代码改动"的稳健节奏，避免一次性引入跨语言改动。

**Decision**:
1. **缩 BATCH-06 范围至纯 Cargo.toml + pubspec.lock**——所有需要改 .rs / .dart 的项延后
2. md5 / zip / 反向依赖 → 拆出 BATCH-06b/06c/06d 三个独立批次（标 TODO 指向）
3. **`[lints]` 启用 level=warn 但不强制**——`-D warnings` 留给 BATCH-11/12 集中修 unwrap 时打开
4. zeroize/secrecy **仅入 workspace.dependencies**，业务字段使用 → BATCH-03
5. **保留 ureq + reqwest 双 HTTP 客户端共存**（F-W3-031 P2）——评估后觉得"async/sync 路径分别用"是合理设计，留 inline 注释说明，不在本批改

**Consequences**:
- ✅ 本批仍是"零业务代码改动" + 不需要 sub-agent 跑 build 即可完成
- ✅ workspace 元数据基础设施就位，后续依赖升级路径清晰（改 workspace.toml 一处即可）
- ✅ pubspec.lock 进版本库，CI / 多人协作 reproducible
- ⚠️ md5 / zip 多版本仍存在；libbridge.so 体积没立即缩减——延后批次完成后再次 cargo tree --duplicates 验证
- ⚠️ `unwrap_used = "warn"` 启用后用户跑 cargo clippy 会立刻看到几十条 warning（master 报告已点出 unwrap 滥用）；但因为 level=warn 不挂 build，可见性提高 ≠ 立刻修

## Technical Notes

- 上一任务（BATCH-02）已完成（commit `551766d`），Android Manifest + keystore 基础设施就绪
- master finding 详情：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-cross-config.md` 的 F-W3-011/012/017/020/030/039/040/043
- workspace.dependencies 文档：https://doc.rust-lang.org/cargo/reference/workspaces.html#the-dependencies-table
- workspace.lints 文档：https://doc.rust-lang.org/cargo/reference/workspaces.html#the-lints-table（cargo 1.74+）
- 当前 cargo 版本未确认；若 lints 段不被支持，sub-agent 可降级到只做 `[workspace.dependencies]` + `[workspace.package]`（删除 lints 段并加注释说明）
- 本批完成后 pubspec.lock 进入 git 历史，flutter_app 的依赖锁定问题彻底解决
