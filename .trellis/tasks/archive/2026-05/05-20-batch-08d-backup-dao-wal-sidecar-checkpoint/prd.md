# BATCH-08d: backup_dao WAL sidecar checkpoint（audit-only / dismiss）

## Goal

审计 F-W1A-056 — BATCH-08c 启用 WAL 后 `backup_dao` 是否需要在备份前调 `PRAGMA wal_checkpoint(TRUNCATE)` 把 -wal sidecar 数据 sync 回主 db 以保障备份完整性。

**审计结论：F-W1A-056 是误报，本批次降级为 audit-only，不写业务代码。**

理由：`backup_dao::export_to_zip` 走 SQL `SELECT` → JSON 序列化 → zip 写入路径，**完全不接触 .db / .db-wal / .db-shm 文件本身**。WAL sidecar 对 SQL 层透明：已 commit 的数据由 SQLite 引擎自动合并到 SELECT 结果，未 commit 数据按 ACID 隔离语义本就不属于备份范围。

## What I already know

### 来自 explore 审计（2026-05-20，本批次）+ 主对话复审

**1. backup_dao 完整结构**（`core/core-storage/src/backup_dao.rs`，925 行）

3 个 public fn：
- `export_to_zip(conn: &Connection, out_path: &str) -> Result<(), String>` (L75-130) — backup writer
- `import_from_zip(conn: &mut Connection, zip_path: &str) -> Result<ImportSummary, String>` (L180+) — restore reader
- `validate_zip(zip_path: &str) -> Result<Vec<String>, String>` (L153-167) — dry-run

备份产物：1 个 zip 容器，内含 5 个 Legado 兼容 camelCase JSON 数组：`bookshelf.json` / `bookGroup.json` / `bookmark.json` / `replaceRule.json` / `bookSource.json`。**没有任何 `.db` / `.db-wal` / `.db-shm` 文件被打入产物**。

**2. export_to_zip 数据流**（核心证据）

```rust
// backup_dao.rs:78-83
let books = select_all_books(conn)?;
let groups = select_all_groups(conn)?;
let bookmarks = select_all_bookmarks(conn)?;
let replace_rules = select_all_replace_rules(conn)?;
let sources = select_all_sources(conn)?;
```

每个 `select_all_*` 都是 `conn.prepare("SELECT ...") → query_map → Vec<Model>`。读到的 `Vec<Model>` 经 `legado_field_map::storage_*_to_legado_json` 转 `serde_json::Value`，再 `serde_json::to_string_pretty` 写进 `ZipWriter`。

**全程 SQL 层操作，文件系统层不接触 db 文件**。

**3. caller 路径**（确认无其它备份路径）

`core/bridge/src/api.rs`：
- `export_backup_zip(db_path, out_zip_path)` (L1219) — 本地导出
- `webdav_upload_backup(...)` (L1275) — 远端上传（先 `export_to_zip` 写到 `tempfile::NamedTempFile`，再读 bytes PUT）

两条 caller 都先 `open_db(db_path)` 拿到 `Connection`，然后调 `export_to_zip(conn, ...)`。

**4. 全仓负向验证**

| 模式 | 命中数 |
|---|---|
| `fs::copy` 涉及 db 文件 | 0（仅 `local_book.rs:126` copy 用户上传的 epub/txt 与 db 备份无关） |
| `sqlite3_backup_init` / `backup_step` | 0 |
| `VACUUM INTO` | 0 |
| `wal_checkpoint` 调用 | 0（仅 init 时设 `wal_autocheckpoint`） |
| Dart 侧拷贝 `legado.db` | 0（路径仅在 `providers.dart` 声明使用） |

**结论扎实**：仓库内不存在"二进制 db copy / VACUUM INTO 备份"路径。

**5. SQLite WAL 与 SELECT 的关系**

WAL 模式下 SQLite 把 `-wal` 视作 db 持久状态的一部分。任何 `SELECT` 通过同一连接（或同一 db 上的另一连接）读取时，引擎会自动合并主 db 与 -wal 中已 commit 的页，**对 SQL 层完全透明**。这是 SQLite 文档化保证（`https://sqlite.org/wal.html#concurrency`）。

`-wal` 中"未 commit"的事务**本来就不该被备份看到** — 这是 ACID 的隔离 + 持久性语义，不是 bug。

### 后续如果引入 binary-level backup 才需要 checkpoint

万一未来某个批次新增"二进制 db copy" / `VACUUM INTO` / `sqlite3_backup_init` 等 file-level 备份路径，**那条新路径**才需要重新评估 checkpoint。当前 5 表 JSON 备份不需要。新增 F-W1A-057 占位防止该顾虑彻底丢失。

## Open Questions

（已收敛）

## Requirements (final)

### MVP scope（3 项）

1. **`backup_dao.rs` 顶部加 doc-comment 段**（~8 行）
   - 说明本模块走 SQL SELECT → JSON → zip 路径，与 WAL sidecar 文件无关
   - 引用 BATCH-08d 审计 + F-W1A-056 dismissal
   - 防止后续 reviewer 看 backup_dao.rs 时重提此顾虑

2. **master report 同步**
   - F-W1A-056 状态从 Open 改为 "Dismissed by BATCH-08d audit (2026-05-20)"
   - 加 audit evidence（4 行：backup_dao.rs:75-130 走 SELECT；api.rs:1219/1275 是仅有 caller；全仓 0 处 fs::copy/VACUUM INTO/sqlite3_backup_init；ACID 语义自然排除未 commit 数据）

3. **新增 F-W1A-057 占位 finding**
   - 标题：If a future task adds binary-level db backup, evaluate WAL checkpoint before file copy
   - Status: Open（不修复，仅占位）
   - 防止"引入 binary backup 时漏掉 WAL checkpoint"风险被遗忘

### 不在范围内

- 任何 backup_dao 业务代码改动（无需 checkpoint）
- 测试新增（无 production 行为变化）
- WAL 配置调整（BATCH-08c 已完成）

## Acceptance Criteria

- [ ] `core/core-storage/src/backup_dao.rs` 顶部 doc-comment 含 "WAL sidecar 与备份产物的关系" 段
- [ ] master report `findings-rust-data.md` F-W1A-056 标 "Dismissed by BATCH-08d audit" + evidence
- [ ] master report `findings-rust-data.md` 新增 F-W1A-057 占位 entry
- [ ] master report `findings.md` 主索引更新 F-W1A-056 状态 + 新增 F-W1A-057 行
- [ ] `cargo build -p core-storage` 维持 PASS（仅 doc-comment 改动）
- [ ] `cargo test -p core-storage --lib` 维持 91 PASS（无 production 行为变化）

## Definition of Done

- F-W1A-056 文档清算（dismissal + evidence）
- F-W1A-057 占位防止后续 binary backup 顾虑遗忘
- backup_dao.rs 顶部 doc 让代码层 reviewer 直接看到结论
- 仓库无业务行为变化

## Decision (ADR-lite)

**Context**: BATCH-08c 启用 WAL 后顺手记的 finding F-W1A-056（"backup 可能漏未 checkpoint 的 -wal 数据"）建立在"备份会拷贝 db 文件"假设上。BATCH-08d audit 推翻该假设：backup_dao 走 SQL SELECT 路径，不接触文件系统层 db 文件。

**Decision**: 选项 1（推荐方案）— audit-only：backup_dao.rs doc-comment + master report dismissal + F-W1A-057 占位。

**Consequences**:
- 0 业务代码变化，0 风险
- 文档侧 reviewer 直接看到结论（顶部 doc-comment）
- F-W1A-057 占位让未来引入 binary backup 时不会漏掉 WAL checkpoint 顾虑
- commit 类型 `docs(rust):` 而非 `fix(rust):`

## Technical Notes

### 为什么不只更新 master report 不动 backup_dao.rs

只动 master report 的话，未来 reviewer 看 backup_dao.rs 时仍会自然产生"启用 WAL 后这里要不要 checkpoint"的疑问。把结论写在代码顶部 doc-comment（8 行）成本极低，长期省 reviewer 心智。

### F-W1A-057 占位 finding 草稿

```
**F-W1A-057: 引入 binary-level db backup 时需要重新评估 WAL checkpoint**

Status: Open（占位，识别于 BATCH-08d，2026-05-20）
File: core/core-storage/src/backup_dao.rs（潜在新增路径）

当前 backup_dao 走 SQL SELECT → JSON → zip，与 WAL sidecar 无关
（F-W1A-056 dismissed by BATCH-08d）。但若未来新增任何"二进制级"
备份路径（fs::copy db 文件 / VACUUM INTO / sqlite3_backup_init），
**那条新路径**必须在备份前调 PRAGMA wal_checkpoint(TRUNCATE) 把
-wal 数据 sync 回主 db，否则会丢失已 commit 但还未 checkpoint
回主 db 的事务。

修复触发条件：仅在新增 binary backup 路径的 PR 内联解决，本 finding
单独不修复。
```

### 风险评估

| 项 | 评估 |
|---|---|
| 业务行为变化 | 无（仅 doc-comment 改动） |
| 测试影响 | 无（91 PASS 维持） |
| 编译影响 | 无 |
| 长期成本 | doc 8 行 + 2 master report 条目，极低 |
| 风险残留 | F-W1A-057 占位覆盖未来 binary backup 场景 |

### 实施顺序

1. read backup_dao.rs 顶部 doc-comment 现状（line 1-30）找插入点
2. 加 "WAL sidecar 与备份产物的关系" 段
3. 更新 master report `findings-rust-data.md` F-W1A-056 + 新增 F-W1A-057
4. 更新 master report `findings.md` 主索引
5. cargo build -p core-storage 验证 doc 不破坏编译
6. cargo test -p core-storage --lib 验证 91 PASS
7. 写 implement.jsonl summary
8. archive + commit `docs(rust):`

## Research References

- 本任务 explore audit（in-context，未持久化到 research/）
- BATCH-08c archive：`.trellis/tasks/archive/2026-05/05-20-batch-08c-wal/`（启用 WAL 时记的 F-W1A-056）
- F-W1A-056 finding：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-data.md`（在 F-W1A-014 块下作为 follow-up）
- SQLite WAL doc: https://sqlite.org/wal.html#concurrency
