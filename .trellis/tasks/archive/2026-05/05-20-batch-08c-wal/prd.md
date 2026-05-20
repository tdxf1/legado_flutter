# BATCH-08c: 生产 WAL 启用

## Goal

闭环 F-W1A-055：在 `core/core-storage/src/database.rs::init_database` 内补一行 `pragma_update("journal_mode", "WAL")` 让 BATCH-07b 已加但实际未生效的两条 pragma（`synchronous=NORMAL` + `wal_autocheckpoint=1000`）真正起作用。同时把 BATCH-08b 删掉的 WAL 测试加回来（这次测真实生产功能而非死代码开关）。顺手把 backup_dao 是否处理 -wal/-shm sidecar 的潜在风险录入 master report 当 F-W1A-056 留独立批次。

## What I already know

### 来自 explore 审计（2026-05-20，本批次）

**1. `init_database` 现状**（`core/core-storage/src/database.rs:14-76`）

实际生效 PRAGMA 仅 3 条：
- `foreign_keys = ON`（execute）
- `synchronous = NORMAL`（pragma_update）
- `wal_autocheckpoint = 1000`（pragma_update）

**关键问题**：BATCH-07b 加的后两条注释写"WAL 持久性调优"，但 `journal_mode` 从未设过：
- `wal_autocheckpoint=1000` 在 rollback journal mode 下完全 no-op
- `synchronous=NORMAL` 在 rollback journal mode 下**不安全**（rollback 应是 FULL）
- 两条 pragma 当前是"半埋雷" — 启用 WAL 后才变成 SQLite 文档化推荐组合

**2. BATCH-08b 删除的 WAL 测试**（commit `aa1b6fe`）

删了两个 test：
```rust
#[test] fn test_wal_enabled() { /* StorageManager::new(enable_wal=true) */ }
#[test] fn test_wal_disabled() { /* enable_wal=false */ }
```

它们测 `StorageManager::new` 的 WAL 开关，但 `StorageManager` 是 production 0 caller 死代码，BATCH-08b 删它们是对的。删完后 production WAL 启用功能 0 测试覆盖。

测试 API 形式：
- `pragma_update(None, "journal_mode", "WAL")` — 大写字符串
- `pragma_query_value(None, "journal_mode", |row| row.get(0))` 返回 `String`
- 断言：`.to_lowercase() == "wal"`（SQLite 返回小写）

**3. SQLite WAL 启用语义**（rusqlite 0.31 + SQLite 3.45.x bundled）

- WAL 是**数据库文件级**持久化（写入 db header），一次设过永久有效
- 后续 `Connection::open`（包括 `get_connection` / r2d2 pool / 直调）自动是 WAL 模式
- 重复调 `pragma_update("journal_mode", "WAL")` 安全，no-op
- 启用时机：紧跟 `Connection::open` 之后即可
- `PRAGMA journal_mode=WAL` 返回当前 mode 字符串行 → 必须用 `pragma_update` 或 `pragma_update_and_check` 而非 `execute`（execute 不允许结果集）
- **跨平台全部支持**：Android internal storage / iOS Documents / Linux $HOME / macOS / Windows 本地存储；唯一禁忌 NFS/SMB（不涉及）

**4. caller 分布**

生产 caller（7 处）：
- `core/bridge/src/api.rs:18` — `init_legado(db_path)` Flutter 启动时通过 frb 调一次
- `core/api-server/src/main.rs:123` — desktop API server 启动调一次
- `core/bridge/src/local_book.rs:140, 245` — 本地书导入临时 conn
- `core/bridge/tests/download_test.rs:7, 163` — integration test fixture

下游每次操作走 `get_connection(db_path)`（`bridge/api.rs:26` / `api-server/util.rs:139`），它**不**调 `init_database`，只 `Connection::open` + 重设 connection-level pragma — 但因为 WAL 是 db-level，**自动继承**，不需要每次重设。

**异常 caller**（不动）：
- `core/core-source/src/legado/js_runtime.rs:828, 842` 直调 `Connection::open` 绕过 `get_connection` — WAL 仍自动继承（finding 留独立批次）

**5. backup_dao -wal/-shm sidecar**（潜在风险）

启用 WAL 后用户 db 目录会多 `legado.db-wal` + `legado.db-shm` sidecar。需要审计 `core/core-storage/src/backup_dao.rs` 是否只备份主 db 文件、漏掉 sidecar 会怎样：
- WAL checkpoint 后 sidecar 数据已 sync 回主 db，单独备份主 db 通常是完整的
- 但如果在 WAL 未 checkpoint 时备份，会丢失 -wal 内的未 commit 改动
- 是否需要先 `PRAGMA wal_checkpoint(TRUNCATE)` 再备份是 backup 流程的事

**本批不修复，仅录入 master report 当 F-W1A-056 留独立批次审计**。

### 实施草案（来自 explore）

**改 `core/core-storage/src/database.rs:init_database`**（约 +10 行）：

```rust
let mut conn = Connection::open(db_path)?;

// F-W1A-055（BATCH-08c）：启用 WAL。WAL 是 db 文件级持久化，一次设置后
// 所有后续连接自动继承。配合下方既有 synchronous=NORMAL +
// wal_autocheckpoint=1000 形成 SQLite 官方推荐组合（注：synchronous=NORMAL
// 仅在 WAL 模式下安全；rollback journal mode 下应是 FULL）。
let journal_mode: String =
    conn.pragma_update_and_check(None, "journal_mode", "WAL", |row| row.get(0))?;
if journal_mode.eq_ignore_ascii_case("wal") {
    info!("数据库 WAL 模式已启用");
} else {
    warn!("WAL 启用失败，当前 journal_mode = {}", journal_mode);
}

// 启用外键约束
conn.execute("PRAGMA foreign_keys = ON", [])?;
```

**新增 2 个 test**（`#[cfg(test)] mod tests` 内）：

```rust
#[test]
fn test_wal_enabled_on_fresh_init() {
    let temp_dir = TempDir::new().unwrap();
    let db_path = temp_dir.path().join("wal_fresh.db").to_string_lossy().to_string();
    let conn = init_database(&db_path).unwrap();
    let mode: String = conn.pragma_query_value(None, "journal_mode", |row| row.get(0)).unwrap();
    assert_eq!(mode.to_lowercase(), "wal", "fresh init should enable WAL");
}

#[test]
fn test_wal_persists_across_reopens() {
    let temp_dir = TempDir::new().unwrap();
    let db_path = temp_dir.path().join("wal_persist.db").to_string_lossy().to_string();
    { let _ = init_database(&db_path).unwrap(); } // first conn drops
    let conn2 = rusqlite::Connection::open(&db_path).unwrap();
    let mode: String = conn2.pragma_query_value(None, "journal_mode", |row| row.get(0)).unwrap();
    assert_eq!(mode.to_lowercase(), "wal",
        "WAL is db-file level — second open without init_database must still see WAL");
}
```

第二个 test 关键 — 验证"WAL 是 db-level"假设在我们代码里成立，间接保护下游所有 `get_connection` / 直调 `Connection::open` 的路径。

## Open Questions

（已收敛）

## Requirements (final)

### MVP scope（4 项）

1. **改 `core/core-storage/src/database.rs::init_database`**
   - 在 `Connection::open` 之后、`foreign_keys` 之前插入 `pragma_update_and_check` 启用 WAL
   - 加 info!/warn! log（启用成功 / 失败 fallback）
   - 加注释说明 F-W1A-055（BATCH-08c）+ 与 synchronous=NORMAL 的关联

2. **新增 2 个 unit test 到 `database.rs::tests`**
   - `test_wal_enabled_on_fresh_init` — 验证 init_database 后 journal_mode == "wal"
   - `test_wal_persists_across_reopens` — 验证 WAL 是 db-level（第二次 `Connection::open` 不调 init_database 仍是 WAL）

3. **更新 `core/core-storage/src/lib.rs:57-60` 注释**
   - 把"production WAL 未启用"那段 follow-up 注释改成"BATCH-08c 已启用，详见 database.rs:29 附近"

4. **master report 同步**
   - F-W1A-055 标 "Resolved by BATCH-08c"
   - 新增 F-W1A-056（backup_dao -wal/-shm sidecar 潜在风险）— 仅录入，不修复

### 不在范围内

- `js_runtime.rs::java_cache_get/put` 直调 `Connection::open` 路径（WAL 自动继承，独立 finding 留观察）
- `backup_dao` 备份逻辑修改（F-W1A-056 独立批次）
- 其它 SQLite pragma 调优（busy_timeout / cache_size / mmap_size 等）
- 引入 r2d2 connection pool 改造（BATCH-13 范围）

## Acceptance Criteria

- [ ] `init_database` 内含 `pragma_update_and_check(None, "journal_mode", "WAL", ...)` 调用
- [ ] log 层级：成功 info!，失败 warn!，不 panic 不阻塞启动
- [ ] `database.rs::tests` 2 个新 test 全 PASS
- [ ] `cargo test -p core-storage --lib` 从 89 → 91 PASS（恢复 BATCH-08b 之前数量但功能不同）
- [ ] `cargo test -p bridge --lib` 维持 16/16 PASS
- [ ] `cargo test -p bridge --tests` 维持 8/8 PASS
- [ ] `cargo clippy -p core-storage --lib` 0 warning
- [ ] `lib.rs:57-60` 注释更新
- [ ] master report `findings-rust-data.md` F-W1A-055 标 "Resolution (BATCH-08c)"
- [ ] master report 新增 F-W1A-056 entry（backup_dao sidecar）含 status=Open
- [ ] master report `findings.md` 主索引同步状态

## Definition of Done

- WAL 在 production 真实启用（非死代码路径）
- 既存 `synchronous=NORMAL` + `wal_autocheckpoint=1000` 从"半埋雷"变"正确选择"
- 测试覆盖 fresh init + 跨连接持久化
- F-W1A-055 闭环；F-W1A-056 录入

## Decision (ADR-lite)

**Context**: F-W1A-055 是 BATCH-08b 内顺手发现的 finding（BATCH-07b 加的 WAL pragma 实际无效）。BATCH-08b 删 StorageManager 时连带删了 2 个 WAL test，删完后 production 0 测试覆盖此功能。本批同时闭环 F-W1A-055 + 加测试。

**Decision**: 选项 1（推荐方案）— `pragma_update_and_check` 一行实现 + 2 test + 顺手记 F-W1A-056（backup sidecar）。

**Consequences**:
- 1 文件主代码改动 + 1 文件注释改动 + 2 新 test，差不多 +50 行
- 写性能预计提升 10-30%（WAL vs rollback journal）
- 读不再阻塞写（WAL 的核心优势）
- 用户 db 目录多 `legado.db-wal` + `legado.db-shm` sidecar
- 已存在 db 自动迁移（SQLite 内置），无需 migration script
- F-W1A-056 留独立批次审计（backup_dao 是否处理 sidecar）

## Technical Notes

### 风险评估

| 项 | 评估 |
|---|---|
| 已存在 db 切换 WAL | 安全 — SQLite 自动迁移；单进程无 active reader 冲突 |
| 跨平台 | 全部支持（Android/iOS/Linux/macOS/Windows 本地存储） |
| 多进程并发 | Flutter app 单进程；desktop api-server 单进程 — 安全 |
| sidecar 文件 | 备份逻辑需后续审计（F-W1A-056） |
| 测试覆盖 | +2 test 覆盖 fresh + 跨连接持久化 |
| 数据安全 | 提升 — synchronous=NORMAL 在 WAL 下是文档化推荐 |

### 实施顺序

1. read 当前 `database.rs::init_database`（行 14-76）+ tests mod 找插入点
2. 改 init_database 加 WAL 启用 + log
3. 在 tests mod 加 2 个新 test
4. 更新 lib.rs 注释
5. 跑 `cargo test -p core-storage --lib`（应 91 PASS）+ `cargo clippy -p core-storage --lib`（应 0 warning）
6. 跑 `cargo test -p bridge --lib --tests`（应 16/16 + 8/8 维持）
7. 更新 master report：F-W1A-055 标 Resolution + 新增 F-W1A-056 entry
8. 写 implement.jsonl summary

### 测试 case 设计要点

- 用 `tempfile::TempDir`（已是 dev-dependency，BATCH-07b 测试已用）
- 第二个 test 关键：第一个 conn drop 后用 `rusqlite::Connection::open` 直接打开（不走 init_database），验证 db-level 持久化

### F-W1A-056 草稿（master report 新条目）

```
**F-W1A-056: backup_dao 未处理 WAL sidecar 文件**

Status: Open（识别于 BATCH-08c）
File: core/core-storage/src/backup_dao.rs

启用 WAL 后（BATCH-08c）用户 db 目录会多 -wal/-shm sidecar 文件。
backup_dao 当前只备份主 db 文件 — 如果备份发起时 WAL 未 checkpoint，
-wal 内的未 commit 改动会丢失。

修复方向：备份前先 `PRAGMA wal_checkpoint(TRUNCATE)` 把 -wal 数据
强制 sync 回主 db，或备份 db + sidecar 三件套。

不阻塞 BATCH-08c 启用 WAL — Legado 写量小、checkpoint 频繁
（autocheckpoint=1000 页 ≈ 4MB），实际丢失风险低。
```

## Research References

- 本任务 explore audit（in-context，未持久化到 research/）
- F-W1A-055 finding：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-data.md`（BATCH-08b 顺手添加）
- BATCH-07b archive：`.trellis/tasks/archive/2026-05/05-20-fix-batch-07b-cross-dao-tx/`
- BATCH-08b archive：`.trellis/tasks/archive/2026-05/05-20-fix-batch-08b-storagemanager-deletion/`
