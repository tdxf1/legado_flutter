# BATCH-07: SQLite 事务 RAII 化 + 跨 dao 一致性 + FRB explore async 化

**Stage**: P0 + P1 (混合：F-W1A-002 是唯一一条孤立 P0，与本批同改 `core/bridge/src/api.rs`，强耦合合批避免回归同文件两次)
**Slug**: `sqlite-transactions-raii`
**Effort**: L (≤800 行)
**Depends on**: BATCH-06 (workspace deps 让所有子 crate 一致)

## 1. 范围

把 core-storage / bridge 中 6 处"手写 BEGIN / COMMIT / ROLLBACK + `let _ = ` 吞错"改成 `Connection::transaction()` RAII 风格；为多 dao 跨表写引入 `bridge::with_transaction(db_path, |tx| ...)` helper，让 import_local_book / download_and_save_chapter / Empty 错误分支统一进同一事务。**同时**把唯一一条"FRB 同步 fn explore 内嵌套 block_on"P0（F-W1A-002）合批解决——同文件、同主题（runtime / 错误传播一致性）。

## 2. 包含的 findings

- [F-W1A-002] FRB 同步 fn `explore` 内 `block_on` 嵌套 runtime — `core/bridge/src/api.rs:923-933` (P0，强耦合：与下面 P1 同文件且都涉及 bridge runtime 边界)
- [F-W1A-005] migrate_database 手写 BEGIN/COMMIT 非 RAII — `core/core-storage/src/database.rs:455-494`
- [F-W1A-008] delete_batch 无事务，N 条触发 N 次 fsync — `core/core-storage/src/source_dao.rs:188-203`
- [F-W1A-009] import_local_book 多 dao 多事务，FK 失败留脏数据 — `core/core-storage/src/chapter_dao.rs:115-160`
- [F-W1A-017] download_dao create_task_with_chapters 手写 BEGIN/COMMIT，ROLLBACK 用 `let _` — `core/core-storage/src/download_dao.rs:164-183`
- [F-W1A-021] download_and_save_chapter 多次 open_db 无事务，~7 次独立 commit — `core/bridge/src/api.rs:730-790`
- [F-W1A-022] Empty 错误分支 update + recompute 写法散落 — `core/bridge/src/api.rs:733-741`
- [F-W1A-004] WAL synchronous 调优缺失，断电可能丢提交 — `core/core-storage/src/database.rs:14-53`
- [F-W1A-007] source_dao.upsert silently rewrite id 行为 — `core/core-storage/src/source_dao.rs:69-78`

## 3. 影响文件

- `core/bridge/src/transaction.rs` (新增) — `with_transaction(db_path, |tx| ... )` helper
- `core/core-storage/src/database.rs` — `migrate_database` 改 `Connection::transaction()` RAII；加 `PRAGMA synchronous=NORMAL` + `PRAGMA wal_autocheckpoint=1000`
- `core/core-storage/src/source_dao.rs:188-203` — `delete_batch` 包 `transaction()`；行 69-78 上注释明确 silently-rewrite-id 行为
- `core/core-storage/src/chapter_dao.rs:115-160` — `replace_by_book` 改接受 `&Transaction` 参数；caller 走 with_transaction
- `core/core-storage/src/download_dao.rs:164-183` — 删除手写 BEGIN/COMMIT；改 RAII
- `core/bridge/src/api.rs:923-933` — F-W1A-002：删除 `block_on_explore` helper + `static RT: OnceLock<Runtime>`；`pub fn explore` 改 `pub async fn`，与 `search_books_online` 风格一致
- `core/bridge/src/api.rs:730-790` — `download_and_save_chapter` 走 with_transaction；抽 helper `mark_chapter_failed` 收口 update + recompute
- `flutter_app/lib/src/rust/api.dart` — FRB regenerate；explore 变 Future
- `flutter_app/lib/features/source/source_page.dart` — explore caller 加 await

## 4. 修复方向

- F-W1A-002：把 `explore` 改成 `pub async fn`（与 `search_books_online` 一致），删除 `block_on_explore` + `OnceLock<Runtime>`，让 FRB 走异步派发；下游 caller 加 `await`。
- F-W1A-005：`Connection::transaction()` RAII；迁移前 log DB 大小 + deferred-write 提示；考虑分批 commit。
- F-W1A-008：`self.conn.transaction()?` 包；或 `DELETE WHERE id IN (?...)` 单条 SQL（注意 999 限制可分批）。
- F-W1A-009：bridge 引入 `with_transaction(db_path, |tx| ...)` helper 让 `import_local_book` 等多步 fn 走单事务。
- F-W1A-017：改 `let tx = self.conn.transaction()?; ... tx.commit()`；删除手写 BEGIN/COMMIT。
- F-W1A-021：改 `let mut conn = open_db(...)?; let tx = conn.transaction()?;` 一次性包；或仿 api-server 的 `db_transaction` helper 统一封装。
- F-W1A-022：抽 helper `mark_chapter_failed(dao, task_id, chapter_id, error_message)` 把 update + recompute 包到一处；三个分支统一调它。
- F-W1A-004：`PRAGMA synchronous=NORMAL`、`PRAGMA wal_autocheckpoint=1000`；并在文档说明"WAL 设置是数据库属性而非连接属性"。
- F-W1A-007：在 upsert 注释明确"传入 id 与 DB 中 url 已存在的不同 id 冲突时返回 DB 中 id"；或新增 `try_insert_strict` 严格版本。

## 5. 测试策略

- Rust unit test：构造 import_local_book 在 chapter_dao 失败时，确认 book 行被回滚（之前会留脏数据）
- Rust unit test：delete_batch(50 条) 触发 1 次 fsync 而非 50 次
- Rust unit test：migrate_database 中间步骤模拟 panic 后 DB 状态可恢复
- 手动：批量删源 / 多次下载 / 备份导入回归
- 不引入新依赖

## 6. 验收

- [ ] 全代码库 grep `BEGIN.*COMMIT` 仅 RAII 路径
- [ ] master finding F-W1A-002/004/005/007/008/009/017/021/022 全部消解
- [ ] `with_transaction` helper 在 spec/backend/database-guidelines.md 中文档化

## 7. implement.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-data.md", "reason": "本批次涉及的 wave 1A findings"}
{"file": "core/bridge/src/api.rs", "reason": "import_local_book / download_and_save_chapter / Empty 分支 / explore async"}
{"file": "core/core-storage/src/database.rs", "reason": "migrate + WAL pragmas"}
{"file": "core/core-storage/src/source_dao.rs", "reason": "delete_batch + upsert"}
{"file": "core/core-storage/src/chapter_dao.rs", "reason": "replace_by_book"}
{"file": "core/core-storage/src/download_dao.rs", "reason": "create_task_with_chapters"}
{"file": "core/api-server/src/util.rs", "reason": "已有 db_transaction helper 参考"}
{"file": "flutter_rust_bridge.yaml", "reason": "FRB 配置（regen 命令依据）"}
{"file": "flutter_app/lib/src/rust/api.dart", "reason": "FRB regenerate 后 explore 变 Future"}
{"file": "flutter_app/lib/features/source/source_page.dart", "reason": "explore caller"}
{"file": ".trellis/spec/backend/database-guidelines.md", "reason": "事务约束 + with_transaction helper 进 spec"}
```

## 8. check.jsonl 草稿

```jsonl
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings.md", "reason": "master report 主题：SQLite 事务 / 并发 / 错误处理一致性"}
{"file": ".trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-data.md", "reason": "Wave 1A 详细 findings"}
{"file": ".trellis/tasks/05-20-fix-roadmap/plan/batches/BATCH-07-sqlite-transactions-raii.md", "reason": "本批次自身验收清单"}
{"file": ".trellis/spec/backend/database-guidelines.md", "reason": "事务约束 spec 是否落地"}
```
