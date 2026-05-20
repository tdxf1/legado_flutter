# BATCH-07a: SQLite 事务 RAII 化（核心 5 条）+ FRB explore 整组删除

> 路线图原文：[`.trellis/tasks/archive/2026-05/05-20-fix-roadmap/plan/batches/BATCH-07-sqlite-transactions-raii.md`](../archive/2026-05/05-20-fix-roadmap/plan/batches/BATCH-07-sqlite-transactions-raii.md)
>
> 路线图原 BATCH-07 含 9 条 finding，本批缩范围为 **5 条核心 RAII**（不引入 `with_transaction` helper / 不改 chapter_dao 签名）。剩余 4 条：F-W1A-009（import_local_book 跨 dao 事务）、F-W1A-021（download_and_save_chapter 跨 dao 事务）、F-W1A-004（WAL pragma 调优）、F-W1A-007（upsert silently rewrite id 注释）→ 拆出 **BATCH-07b**。

## Goal

把 core-storage / bridge 中 5 处"手写 BEGIN/COMMIT/ROLLBACK + `let _ =` 吞错"或"无事务循环"改成 `Connection::transaction()` RAII 风格；同时彻底删除唯一一条 P0（F-W1A-002 `explore`）— grep 验证 Flutter 端零消费者，与 BATCH-18a 死代码删除主题一致。

## Why

- **F-W1A-002（P0 严重）**：`pub fn explore` 内部 `block_on_explore(|rt| rt.block_on(...))` 嵌套 runtime — 若 caller 已在 tokio runtime 中会触发 panic。grep 验证 `flutter_app/lib/features/**` 内 0 处调用 `explore` 与 `get_explore_entries`，仅 `src/rust/` 自动生成代码出现 — 它是真死代码。删除一次性消除 P0 风险与维护负担。
- **F-W1A-005（P1）**：`migrate_database` 手写 BEGIN / COMMIT / ROLLBACK 非 RAII，迁移过程中 panic 时 ROLLBACK 用 `result == Err` 路径触发，不可靠；改 `Connection::transaction()` RAII 让 Drop 兜底。
- **F-W1A-008（P1）**：`delete_batch` 内 for 循环逐条 `execute(DELETE WHERE id=?)`，**无事务包裹**，N 条触发 N 次 fsync。50 个书源批量删 → 50 次磁盘 commit。包一层 transaction 即解决。
- **F-W1A-017（P1）**：`download_dao::create_task_with_chapters` 手写 `BEGIN / COMMIT / ROLLBACK`，`ROLLBACK` 路径 `let _ = ` 吞错，且嵌套 transaction 时（外层已开启）会 panic。改 `Connection::transaction()` RAII 即正常 Drop rollback。
- **F-W1A-022（P1）**：`download_and_save_chapter` 三个错误分支（Ok / Empty / Err）各自手写 update_chapter_status + recompute_download_task_status 序列，下次易漏一处。抽 helper `mark_chapter_failed(dao, task_id, chapter_id, error_message)` 收口。

## Scope

### In scope（本批做）

**Rust 端**：
- 删除 `core/bridge/src/api.rs:923-936` 整个 `block_on_explore` helper（包括 `static RT: OnceLock<Runtime>`）
- 删除 `pub fn explore`（line ~938，~16 行）
- 删除 `pub fn get_explore_entries`（line ~921，~9 行）— 同样零消费者
- `core/core-storage/src/database.rs:455-494` `migrate_database` 改 `Connection::transaction()` RAII（保留 12 个 `migrate_v*` 内部逻辑不动）
- `core/core-storage/src/source_dao.rs:188-203` `delete_batch` 包 `self.conn.transaction()?` + `tx.commit()?`
- `core/core-storage/src/download_dao.rs:164-183` `create_task_with_chapters` 改 RAII
- `core/bridge/src/api.rs:730-790` `download_and_save_chapter`：抽 `mark_chapter_failed` helper，三个错误分支统一调

**Flutter 端**：
- FRB regenerate（`flutter_rust_bridge_codegen generate`），把 Dart 侧 `explore` / `getExploreEntries` 自动清掉

### Out of scope（明确延后）

- **F-W1A-004 WAL pragma 调优**（`PRAGMA synchronous=NORMAL` / `wal_autocheckpoint=1000`）→ 留 BATCH-07b（独立改 `init_database`，无连带影响）
- **F-W1A-007 upsert silently rewrite id 注释** → 留 BATCH-07b（纯文档，无代码改动）
- **F-W1A-009 import_local_book 跨 dao 事务** → 留 BATCH-07b（需要 `with_transaction` helper + 改 chapter_dao::replace_by_book 接受 &Transaction，跨 dao 联动）
- **F-W1A-021 download_and_save_chapter 跨 dao 事务** → 留 BATCH-07b（同上）
- 不引入 `core/bridge/src/transaction.rs` 文件（`with_transaction` helper）
- 不改 `chapter_dao::replace_by_book` 签名
- 不补 unit test（与 BATCH-01..18a 同模式）
- 不动 `.trellis/spec/backend/database-guidelines.md`

## Requirements

- [ ] `flutter_app/lib/features/**` grep `explore` 零结果（除自动生成代码不算）
- [ ] `core/bridge/src/api.rs` 内 `block_on_explore` / `OnceLock<Runtime>` / `pub fn explore` / `pub fn get_explore_entries` 全删
- [ ] `core/bridge/src/api.rs:1-5` 顶部 `use regex::Regex;` + 顶部注释 sweep（无残留 explore 相关 import）
- [ ] `core/core-storage/src/database.rs::migrate_database` 不再含 `execute_batch("BEGIN")` / `COMMIT` / `ROLLBACK` 字面量
- [ ] `core/core-storage/src/source_dao.rs::delete_batch` 包 `transaction()`
- [ ] `core/core-storage/src/download_dao.rs::create_task_with_chapters` 改 RAII，无 `let _ = ROLLBACK` 模式
- [ ] `core/bridge/src/api.rs::download_and_save_chapter` 三个错误分支改用 `mark_chapter_failed` helper
- [ ] FRB regenerate 完成，`flutter_app/lib/src/rust/api.dart` 内不再有 `Future<String> explore(...)` / `getExploreEntries`

## Acceptance Criteria

- [ ] master finding F-W1A-002 / 005 / 008 / 017 / 022 消解
- [ ] `cargo check --workspace` 全绿（用户验证）
- [ ] `flutter analyze` 全绿（用户验证）
- [ ] 净改动 ≥ 200 行（删 explore 整组 ~50 行 + RAII 改写 ~80 行 + helper 抽取 ~70 行）
- [ ] 0 业务功能改动（explore 路径死代码已确认；其它都是事务边界改写，外部行为不变）

## Definition of Done

- 5 条 finding 修复落地
- FRB Dart 自动生成代码同步更新
- commit message 风格 `chore(rust):` 或 `refactor(rust):`，第六十八批

## Out of Scope（再次强调）

- WAL pragma 调优 → BATCH-07b
- upsert silently rewrite id 注释 → BATCH-07b
- 跨 dao 事务 helper → BATCH-07b
- chapter_dao::replace_by_book 签名变化 → BATCH-07b
- unit test → BATCH-07b 或独立测试批
- spec 文档更新 → BATCH-07b 或独立文档批

## Technical Approach

### 步骤

#### Rust 端

**Step 1 — 删除 explore 整组**

删除 `core/bridge/src/api.rs` 中：
- `pub fn get_explore_entries(db_path: String, source_id: String) -> Result<String, String>`（约 line 906-914）
- `fn block_on_explore<F, R>(f: F) -> R where F: FnOnce(&tokio::runtime::Runtime) -> R`（约 line 916-933）含 `static RT: std::sync::OnceLock<tokio::runtime::Runtime>`
- `pub fn explore(db_path, source_id, explore_url, page) -> Result<String, String>`（约 line 935-955）

注释 `// 发现页 (Explore) — FRB 桥接` section 整段删（删完之后 section header 也清掉）。

**Step 2 — `migrate_database` 改 RAII**

原 `core/core-storage/src/database.rs:455-494`：
```rust
pub fn migrate_database(conn: &mut Connection) -> Result<()> {
    let from = conn.pragma_query_value(...)?;
    if from >= TARGET_VERSION { return Ok(()); }
    conn.execute_batch("BEGIN")?;
    let result = (|| -> Result<()> {
        // 12 个 migrate_v* 调用
    })();
    match result {
        Ok(()) => { conn.execute_batch("COMMIT")?; ... },
        Err(e) => { let _ = conn.execute_batch("ROLLBACK"); return Err(e); }
    }
}
```

改为：
```rust
pub fn migrate_database(conn: &mut Connection) -> Result<()> {
    let from = conn.pragma_query_value(...)?;
    if from >= TARGET_VERSION { return Ok(()); }
    let tx = conn.transaction()?;  // RAII：drop 即 rollback
    // 12 个 migrate_v* 调用，传 &tx 替代 &mut conn / 重写为 tx-aware
    // 注意：migrate_v* 当前接 &Connection 还是 &mut Connection？需要查
    tx.commit()?;
    Ok(())
}
```

注意点：
- `migrate_v*` 当前签名若是 `&mut Connection` 需要兼容 `&Transaction`（rusqlite `Transaction` 实现 `Deref<Target=Connection>`）→ 大概率不需改
- 若 migrate_v* 内部用 `conn.execute(...)` 直接调用，`&Transaction` 也支持

**Step 3 — `delete_batch` 包事务**

原 `core/core-storage/src/source_dao.rs:188-203`：
```rust
pub fn delete_batch(&mut self, ids: &[String]) -> SqlResult<()> {
    for id in ids {
        self.conn.execute("DELETE FROM book_sources WHERE id = ?1", params![id])?;
    }
    Ok(())
}
```

改为：
```rust
pub fn delete_batch(&mut self, ids: &[String]) -> SqlResult<()> {
    let tx = self.conn.transaction()?;
    for id in ids {
        tx.execute("DELETE FROM book_sources WHERE id = ?1", params![id])?;
    }
    tx.commit()?;
    Ok(())
}
```

**Step 4 — `create_task_with_chapters` RAII**

原 `core/core-storage/src/download_dao.rs:164-183`：
```rust
pub fn create_task_with_chapters(&self, task: &DownloadTask, chapters: &[DownloadChapter]) -> SqlResult<()> {
    self.conn.execute("BEGIN", [])?;
    let result = (|| -> SqlResult<()> {
        self.upsert(task)?;
        self.batch_create_chapters(chapters)?;
        Ok(())
    })();
    match result {
        Ok(()) => self.conn.execute("COMMIT", []),
        Err(e) => { let _ = self.conn.execute("ROLLBACK", []); return Err(e); }
    }
}
```

改为：
```rust
pub fn create_task_with_chapters(&mut self, task: &DownloadTask, chapters: &[DownloadChapter]) -> SqlResult<()> {
    let tx = self.conn.transaction()?;
    // 注意：upsert / batch_create_chapters 当前接 &self（持有 &Connection）
    // 需要重写成接受 &Transaction 或 inline 它们的 SQL
    // 简单做法：inline SQL 不抽 helper
    tx.execute(BOOK_UPSERT_SQL, params![...])?;
    for ch in chapters {
        tx.execute(CHAPTER_INSERT_SQL, params![...])?;
    }
    tx.commit()?;
    Ok(())
}
```

注意点：
- `&self` 改 `&mut self`（`transaction()` 需要 `&mut Connection`）
- caller 有几处？需 grep `create_task_with_chapters` 确认全部更新
- `DownloadDao::new(&conn)` 调用方需改成 `DownloadDao::new(&mut conn)` — 但本 dao 的 `new` 当前接 `&Connection`；改 conn 类型会牵涉很多 caller

**预案**：若改签名牵动太广，保留 `&self` + `unchecked_transaction()`（rusqlite API 跳过 borrow check）。注释解释为何选 unchecked。

**Step 5 — `mark_chapter_failed` helper**

原 `core/bridge/src/api.rs:730-790` `download_and_save_chapter` 三个错误分支：
```rust
let text = match &content {
    Ok(c) => c.content.clone(),
    Err(core_source::ParserError::Empty) => {
        let conn = open_db(&db_path)?;
        let dao = DownloadDao::new(&conn);
        dao.update_chapter_status(&download_chapter_id, 3, None, 0, Some("章节内容为空"))?;
        recompute_download_task_status(&dao, &task_id)?;
        return Err("章节内容为空".to_string());
    }
    Err(e) => {
        // 几乎相同的 12 行
    }
};
```

抽 helper（放在 `download_and_save_chapter` 内或文件末尾）：
```rust
fn mark_chapter_failed(
    db_path: &str,
    task_id: &str,
    chapter_id: &str,
    error_message: &str,
) -> Result<(), String> {
    let conn = open_db(db_path)?;
    let dao = core_storage::download_dao::DownloadDao::new(&conn);
    dao.update_chapter_status(chapter_id, 3, None, 0, Some(error_message))
        .map_err(|e| format!("更新章节状态失败: {}", e))?;
    recompute_download_task_status(&dao, task_id)
        .map_err(|e| format!("更新任务状态失败: {}", e))?;
    Ok(())
}
```

三个分支改：
```rust
Err(ParserError::Empty) => {
    mark_chapter_failed(&db_path, &task_id, &download_chapter_id, "章节内容为空")?;
    return Err("章节内容为空".to_string());
}
Err(e) => {
    let msg = e.to_string();
    let short = if msg.len() > 200 { &msg[..200] } else { &msg };
    mark_chapter_failed(&db_path, &task_id, &download_chapter_id, short)?;
    return Err(msg);
}
```

#### FRB regenerate

**Step 6 — 重新生成 Dart 桥接**

```bash
cd flutter_app
flutter_rust_bridge_codegen generate
```

预期：`lib/src/rust/api.dart` 与 `lib/src/rust/frb_generated.dart` 中的 `explore` / `getExploreEntries` / `Explore`-related deserialize 全部消失。**用户跑该命令** — sub-agent 不跑（与历史模式一致）。

### 风险

- **migrate_v* 签名兼容**：若 `migrate_v*` 接 `&mut Connection`，改 `&tx`（`tx: &Transaction`）+ rusqlite `Transaction: Deref<Target=Connection>` 隐式转换 → 大概率 work，但需读源验证
- **`DownloadDao::new(&conn)` 改 `&mut conn`**：所有 caller 需改。grep 找全
- **FRB regenerate 输出抖动**：FRB 可能生成大量行变化（行号 / 注释微调）→ 让 commit 难审。预案：若变化太大，commit 拆为 2 个：`refactor(rust): xxxx` + `chore(frb): regenerate`

### 工具

- `Edit` / `Read` / `Bash`（grep / cargo check）
- 不跑 `flutter analyze` / `cargo check`（留给用户）

## Decision (ADR-lite)

**Context**: 路线图原 BATCH-07 含 9 条 finding，工作量 ~700 行 + 跨 dao 联动；要在"零业务代码改动"基线 + ≤800 行 diff 下做完不可能。

**Decision**:
1. 缩范围至 **5 条核心 RAII**：F-W1A-002 + F-W1A-005 + F-W1A-008 + F-W1A-017 + F-W1A-022
2. **explore 整组删除**（grep 验证 Flutter 端零消费者）— 比路线图的"改 async fn 保留"更彻底，与 BATCH-18a 死代码主题一致
3. **不引入 `with_transaction` helper / 不改 chapter_dao::replace_by_book 签名** — 留 BATCH-07b 处理跨 dao 事务
4. **不补 unit test / 不动 spec** — 与 BATCH-01..18a 模式一致

**Consequences**:
- ✅ 净改动 ~200 行 + FRB regen，单一主题（事务 RAII + 死代码）
- ✅ master finding 5 条直接消解
- ✅ 路线图 9 条 finding 中 5 条本批 + 4 条 BATCH-07b，每条都有清晰归属
- ⚠️ 跨 dao 事务一致性（F-W1A-009 / 021）继续延后；当前行为 = "import_local_book 失败时 book 行写入但 chapters 没写入" 仍存在，BATCH-07b 处理
- ⚠️ FRB regen 可能扩大 diff（不影响业务）

## Technical Notes

- 上一任务（BATCH-18a）已完成（commit `c82713c`），working tree 干净
- master finding 详情：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-data.md`
- 路线图原文：`.trellis/tasks/archive/2026-05/05-20-fix-roadmap/plan/batches/BATCH-07-sqlite-transactions-raii.md`
- `core/api-server/src/util.rs:101` 已有参考的 `db_transaction` async helper（仅供 read，不本批用）
- `core/core-storage/src/chapter_dao.rs:113-129` 已有 `replace_by_book_preserving_content_in_tx(&Transaction, ...)` in_tx 变体范式（BATCH-07b 模仿）
- 本批完成后用户应跑：
  - `cd flutter_app && flutter_rust_bridge_codegen generate`（regenerate）
  - `cd core && cargo check --workspace`
  - `cd flutter_app && flutter analyze`
