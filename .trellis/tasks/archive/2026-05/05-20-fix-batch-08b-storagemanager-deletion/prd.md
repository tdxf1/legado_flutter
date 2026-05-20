# BATCH-08b: StorageManager 死代码整删

## Goal

闭环 BATCH-08 拆出去的 F-W1A-014：删除 `core/core-storage/src/lib.rs` 内 `StorageManager` 整个 struct + impl + `DatabaseConfig` + `init_database` 顶层 wrapper + 配套 `#[cfg(test)] mod tests`（含 2 个 WAL 测试）。同时把 `bridge/tests/download_test.rs` 那 2 处通过 wrapper 调用的路径直接换成 `core_storage::database::init_database`。**不动**生产 WAL pragma 行为（顺手把"生产没启用 WAL"这件事记到 master report 当新 finding，留独立批次处理）。

## What I already know

### 来自本批次 explore 审计（2026-05-20）

**1. StorageManager surface（`core-storage/src/lib.rs:67-118`）**
- `pub struct StorageManager { conn: rusqlite::Connection }`（仅 1 字段）
- `pub fn new(config: DatabaseConfig) -> Result<Self, Box<dyn std::error::Error>>`（lib.rs:73）
- 7 个 `pub fn xxx_dao(&|&mut self) -> XxxDao<'_>`（book/source/chapter/progress/download/replace_rule/cache）

**2. `DatabaseConfig`（lib.rs:52-64）**
- `pub struct DatabaseConfig { pub path: String, pub enable_wal: bool }`
- `Default::default()` 给 `path: "legado.db"`（相对路径，生产不可用）

**3. `init_database` 顶层 wrapper（lib.rs:121-123）**
```rust
pub fn init_database(path: &str) -> Result<rusqlite::Connection, Box<dyn std::error::Error>> {
    database::init_database(path).map_err(|e| Box::new(e) as Box<dyn std::error::Error>)
}
```
纯类型 laundering：把 `rusqlite::Error` 包成 `Box<dyn>` 又透出去。

**4. caller 全仓审计**
- `StorageManager` / `DatabaseConfig` / 7 个 `xxx_dao()` 出口：**外部 0 caller**（grep `bridge/` `api-server/` `core-source/` `core-net/` `core-parser/` 全部 `No files found`）
- 仅 `lib.rs:67-168` 自身 + `#[cfg(test)] mod tests` 内 `test_wal_enabled` / `test_wal_disabled` 两个测试用
- `init_database` wrapper 有 **2 处** 外部 caller：`bridge/tests/download_test.rs:7` + `bridge/tests/download_test.rs:163`，其余生产代码（`bridge/src/api.rs:18`、`api-server/src/main.rs:123`）已经直接走 `core_storage::database::init_database`

**5. error type 统一影响**
- `StorageManager::new` 内部仅 2 个 `?` 站点（`db_init` + `pragma_update`），**两个都是 `rusqlite::Error`**
- `Box<dyn std::error::Error>` 完全是冗余包装，删掉零阻力

**6. WAL test 真相**（重要发现）
- `test_wal_enabled` / `test_wal_disabled` 测的是 `StorageManager::new` 里 `if config.enable_wal { conn.pragma_update(None, "journal_mode", "WAL") }` 这段开关
- **`database::init_database`（生产入口）压根不调 `pragma_update("journal_mode", "WAL")`** — 只设了 `synchronous=NORMAL` + `wal_autocheckpoint=1000`（database.rs:54-55，BATCH-07b 加的）
- 生产实际跑的是 SQLite 默认 `journal_mode=delete`，**WAL 测试只在死代码路径上验证一个生产从不启用的开关**
- `database.rs` 的现有测试块完全没测 `journal_mode` / `wal` / `WAL`

## Open Questions

（已收敛）

## Requirements (final)

### MVP scope（5 项）

1. **删除 `core/core-storage/src/lib.rs:52-118`**
   - `pub struct DatabaseConfig` + `impl Default for DatabaseConfig`（lib.rs:52-64）
   - `pub struct StorageManager` + `impl StorageManager`（lib.rs:67-118）

2. **删除 `core/core-storage/src/lib.rs:121-123`**
   - `pub fn init_database` wrapper（顶层 re-export，纯类型 laundering）

3. **删除 `core/core-storage/src/lib.rs:125-168`**
   - 整个 `#[cfg(test)] mod tests`（含 `journal_mode` extension impl + `test_wal_enabled` + `test_wal_disabled`）
   - 不迁移到 `database.rs` — 这两个测试测的是 production 不启用的开关，零生产价值

4. **修 `core/bridge/tests/download_test.rs`**
   - L7：`core_storage::init_database(&db_path).unwrap();` → `core_storage::database::init_database(&db_path).unwrap();`
   - L163：同上替换
   - 其它逻辑不动

5. **master report 同步**
   - F-W1A-014 标 "Resolved by BATCH-08b"（与 BATCH-08 那 7 条同样格式）
   - 顺手在 master report 加一条新 finding 记录"production WAL 未启用"事实（lib `database::init_database` 不调 `pragma_update("journal_mode","WAL")`，仅 `synchronous=NORMAL` + `wal_autocheckpoint=1000`，与代码注释意图不一致），编号沿用 wave 1A 续位（如 F-W1A-055 类似）— 不在本批次实施，仅记录给后续批次

### 不在范围内

- **生产 WAL 启用**：是独立行为变化（涉及 SQLite 文件格式 / 单文件迁移路径），单独立项
- 任何业务逻辑改动 / Flutter 端
- `core-storage` 其它模块的 error type 迁移（本批次仅消除 `Box<dyn>` 在 lib.rs 顶层的 2 处出现）

### 测试策略

- `cargo check --workspace` 全绿
- `cargo test -p core-storage --lib` 全 PASS（baseline 应当从 91 → 89，因为删了 2 个 WAL test）
- `cargo test -p bridge --lib` 全 PASS（16/16，不受影响）
- `cargo test -p bridge --tests` 全 PASS（含 `download_test`，验证那两行替换正确）

## Acceptance Criteria

- [ ] `core-storage/src/lib.rs` 内 grep `StorageManager` / `DatabaseConfig` 全 0 命中
- [ ] `core-storage/src/lib.rs` 顶部不再有 `pub fn init_database`（仅保留 `pub use database` re-export 与 `pub mod xxx_dao` 导出）
- [ ] `core-storage/src/lib.rs` 整文件不再含 `Box<dyn std::error::Error>` 字面量
- [ ] grep `core_storage::init_database\b` 在整个 `core/` 下 0 命中（已统一走 `core_storage::database::init_database`）
- [ ] `cargo check --workspace` 全绿
- [ ] `cargo test -p core-storage --lib` 全 PASS（预期 89/89，比 BATCH-08 的 91/91 少 2 个 WAL 测试）
- [ ] `cargo test -p bridge --tests` 全 PASS（含 `download_test`）
- [ ] master report `findings-rust-data.md` F-W1A-014 标 "Resolved by BATCH-08b"
- [ ] master report 加新 finding（编号续 1A 系列）记录"生产 WAL 未启用"事实

## Definition of Done

- 7 个核心 dao() 出口的死代码消失
- `lib.rs` 缩到只剩 `pub use` / `pub mod` 模块导出（约 50 行以内）
- 所有测试 PASS

## Decision (ADR-lite)

**Context**: BATCH-08 9 条 finding 拆 7+2，F-W1A-014 StorageManager 拆 BATCH-08b 单独处理，因为它涉及 7 个 public dao() 出口 + DatabaseConfig + init_database wrapper + WAL test 4 类删除，表面变化重需要独立 commit / 独立回滚。

**Decision**: 选项 A 整删（见 explore audit）。

**Consequences**:
- F-W1A-014 闭环
- `lib.rs` 从 ~170 行缩到 ~50 行（约 -120 行净 diff）
- 删 2 个 WAL test，单测从 91 → 89（这是好事 — 测试一个生产不启用的开关本来就是噪声）
- 改 2 行 `download_test.rs` import 路径
- production WAL 行为完全不变（与生产无关的死代码删除）
- 把"生产 WAL 未启用"作为新 finding 记录给后续批次

## Technical Notes

### 风险点

- `download_test.rs` 那 2 行替换：`core_storage::init_database` 与 `core_storage::database::init_database` 签名不同 — 前者返回 `Box<dyn>`（已删），后者返回 `SqlResult<Connection>`。两者都能 `.unwrap()`，行为一致。但如果 `download_test.rs` 后续有 `?` 链或 `match`，需要核对类型。本批次先 grep `download_test.rs` 内现有用法确认。
- `lib.rs` 的 `pub use database;` / `pub mod xxx_dao` 导出是否会受影响？答：不会，那些是独立的 `pub mod` 模块导出，与 StorageManager 无依赖。

### 实施顺序

1. 先 grep `download_test.rs` 现有用法确认替换范围
2. 改 `download_test.rs` 那 2 行（import 路径替换）
3. 删 `lib.rs` 内 StorageManager / DatabaseConfig / init_database wrapper / `#[cfg(test)] mod tests`
4. `cargo check --workspace` 验证
5. `cargo test -p core-storage --lib` + `cargo test -p bridge --tests` 验证
6. 更新 master report F-W1A-014 + 加新 finding

## Research References

- 本任务 explore audit（in-context，未持久化到 research/）
- BATCH-08 commit `788ed71` — 7 条 finding + 6 个新单测
- BATCH-08 PRD（`.trellis/tasks/archive/2026-05/05-20-fix-batch-08-dao-sql-dedup/prd.md`）— F-W1A-014 拆批理由
