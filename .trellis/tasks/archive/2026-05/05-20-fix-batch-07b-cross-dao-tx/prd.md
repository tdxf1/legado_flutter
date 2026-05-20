# BATCH-07b: 跨 dao 事务 helper + WAL pragma 调优 + upsert 注释（剩余 4 条）

> 路线图原文：[`.trellis/tasks/archive/2026-05/05-20-fix-roadmap/plan/batches/BATCH-07-sqlite-transactions-raii.md`](../archive/2026-05/05-20-fix-roadmap/plan/batches/BATCH-07-sqlite-transactions-raii.md)
>
> BATCH-07a（commit `a279e0d`）已完成路线图 9 条 finding 中的 5 条。本批补完剩余 4 条：F-W1A-009 / F-W1A-021 / F-W1A-004 / F-W1A-007。

## Goal

把 BATCH-07a 留下的 4 条事务/数据库相关 finding 一次性消解：
1. 引入 `bridge::transaction::with_transaction(db_path, |tx| ...)` helper，让 `import_local_book` 跨 BookDao + ChapterDao 走单事务（FK 失败时 book 行也回滚）
2. `download_and_save_chapter` 的 DB 写入步骤（success 路径的 update_chapter_status + recompute；以及 mark_chapter_failed helper 内部的 update + recompute）用同一 with_transaction 包成单 tx；文件 IO 仍在 tx 外
3. `init_database` 加 `PRAGMA synchronous=NORMAL` + `PRAGMA wal_autocheckpoint=1000`，断电时减少丢提交风险
4. `source_dao::upsert` 加 doc-comment 注释明确 silently-rewrite-id 行为（纯文档）

## Why

- **F-W1A-009 (P1)**：`import_local_book` 中 BookDao::upsert 与 ChapterDao::replace_by_book 是两个独立事务，FK constraint 失败时 book 已 commit 留下脏数据。包同 tx 即解决。
- **F-W1A-021 (P1)**：`download_and_save_chapter` success 路径 update_chapter_status + recompute_download_task_status 之间无事务原子性，中间 panic / 错误时 task progress 与 chapter status 不一致。
- **F-W1A-004 (P1)**：WAL 启用后未设 `synchronous` / `wal_autocheckpoint`，断电可能丢最近几条 commit。Android 设备崩溃 / 电池抽走场景下风险明显。
- **F-W1A-007 (P1)**：`source_dao::upsert` 内部 URL 去重时 silently rewrite source.id 为 DB 中已有 id，调用方拿到 effective_id 但常常以为还是自己传的 id，后续查询找不到。该行为需文档化让 caller 感知。

## Scope

### In scope（本批做）

**Rust 端**：
- 新建 `core/bridge/src/transaction.rs`：`with_transaction(db_path, |tx| ...) -> Result<T, String>` helper
- `core/bridge/src/lib.rs`：`mod transaction;`（pub(crate) 仅 bridge 内部用）
- `core/core-storage/src/book_dao.rs`：补 `upsert_in_tx(tx: &Transaction, book: &Book) -> SqlResult<()>` 变体，原 `upsert(&self, ...)` 内部调 in_tx
- `core/core-storage/src/chapter_dao.rs`：补 `replace_by_book_in_tx(tx: &Transaction, book_id: &str, chapters: &[Chapter]) -> SqlResult<()>`，原 `replace_by_book(&mut self, ...)` 内部调 in_tx（参考已有的 `replace_by_book_preserving_content_in_tx` 范式）
- `core/core-storage/src/download_dao.rs`：补 `update_chapter_status_in_tx(tx, chapter_id, status, file_path, file_size, error_message) -> SqlResult<()>`，原 `&self` 版内部调 in_tx
- `core/bridge/src/api.rs::import_local_book`：改用 `with_transaction(&db_path, |tx| { BookDao::upsert_in_tx(tx, &book)?; ChapterDao::replace_by_book_in_tx(tx, &book_id, &storage_chapters)?; Ok(()) })`
- `core/bridge/src/api.rs::download_and_save_chapter`：success 路径的 update_chapter_status + recompute 用 with_transaction 包；mark_chapter_failed helper 也用 with_transaction（recompute_download_task_status 现在拿 `&DownloadDao`，需要改为 `_in_tx` 版接 `&Transaction` 直接走 tx.execute）
- `core/core-storage/src/database.rs::init_database`：line 32 之后加 `PRAGMA synchronous=NORMAL` + `PRAGMA wal_autocheckpoint=1000`（仅 init 设一次，注释解释为何不在 get_connection 重复设）
- `core/core-storage/src/source_dao.rs::upsert` 顶部 doc-comment：明确"传入 id 与 DB 中 url 已存在的不同 id 冲突时，返回 DB 中 id 而不是传入的 id；调用方应使用返回值而非源 id"

### Out of scope

- 不动 BATCH-07a 已修的 5 条
- 不引入 bridge 端连接池（路线图主题 9 / F-W1A-033，独立批次）
- 不动 DownloadDao::conn 类型签名（持有 `&Connection`）— 仅补 in_tx fn
- 不补 unit test
- 不动 `.trellis/spec/backend/database-guidelines.md`
- 不补 `try_insert_strict` 严格版 upsert（F-W1A-007 仅注释，不引入新 fn）
- 不在 `get_connection` 重复设 WAL pragma（仅 init_database）

## Requirements

- [ ] `core/bridge/src/transaction.rs` 存在，`with_transaction` helper 可用
- [ ] `core/bridge/src/lib.rs` 加 `mod transaction;`
- [ ] `BookDao::upsert_in_tx` / `ChapterDao::replace_by_book_in_tx` / `DownloadDao::update_chapter_status_in_tx` / `recompute_download_task_status_in_tx` 落地
- [ ] `import_local_book` 走 with_transaction
- [ ] `download_and_save_chapter` 三个 DB 写路径（success / Empty / Err）都走 with_transaction
- [ ] `init_database` 含 `PRAGMA synchronous=NORMAL` + `PRAGMA wal_autocheckpoint=1000` + 解释注释
- [ ] `source_dao::upsert` 顶部 doc-comment 描述 silently-rewrite-id
- [ ] `cargo check --workspace` 全绿
- [ ] `cargo test -p core-storage --lib` 全绿（85 个测试不破）

## Acceptance Criteria

- [ ] master finding F-W1A-004 / 007 / 009 / 021 全部消解
- [ ] 路线图 BATCH-07 全部 9 条 finding 闭环（5 条 BATCH-07a + 4 条 BATCH-07b）
- [ ] 0 业务功能改动
- [ ] 净改动 ≤ 300 行

## Definition of Done

- 4 条 finding 修复落地
- commit message 风格 `refactor(rust):` 第六十九批
- 不需要 FRB regen（不动任何 pub fn 签名）

## Out of Scope（再次强调）

- 连接池（路线图主题 9）
- DownloadDao::conn 类型签名
- spec 文档
- unit test
- try_insert_strict
- get_connection 内重设 WAL pragma

## Technical Approach

### Step 1 — `with_transaction` helper

新建 `core/bridge/src/transaction.rs`：
```rust
//! 跨 DAO 事务 helper。bridge 端没有连接池，每次 fn fresh open_db。
//! 本 helper 把"打开 conn → begin tx → 跑闭包 → commit / rollback"模板化。

use rusqlite::Connection;

/// Open db, begin a transaction, run `f`, commit on Ok / rollback on Err.
///
/// `f` 拿 `&Transaction` 即可走任何 DAO 的 `*_in_tx(&tx, ...)` 变体；
/// rusqlite `Transaction: Deref<Target=Connection>` 也允许把 `&tx` 当
/// `&Connection` 用，因此调 read-only DAO 方法（持 `&Connection`）也直接 work。
///
/// Drop 时未 commit 的 tx 自动 ROLLBACK（RAII），与 panic-safe 同等保证。
pub(crate) fn with_transaction<F, T>(db_path: &str, f: F) -> Result<T, String>
where
    F: FnOnce(&rusqlite::Transaction) -> Result<T, String>,
{
    let mut conn = core_storage::database::get_connection(db_path)
        .map_err(|e| format!("数据库连接失败: {}", e))?;
    let tx = conn.transaction().map_err(|e| format!("开启事务失败: {}", e))?;
    let result = f(&tx)?;
    tx.commit().map_err(|e| format!("提交事务失败: {}", e))?;
    Ok(result)
}
```

`core/bridge/src/lib.rs` 加 `mod transaction;`（pub(crate) 仅 bridge 内部用，不暴露 FRB）。

### Step 2 — DAO in_tx 变体

**book_dao.rs**：
```rust
/// 接 `&Transaction` 的 in_tx 变体，让 caller 在外层共享 tx
/// （比如 import_local_book 把 book + chapters 包同 tx）。
pub fn upsert_in_tx(tx: &rusqlite::Transaction, book: &Book) -> SqlResult<()> {
    tx.execute(BOOK_UPSERT_SQL, params![/* ... */])?;
    Ok(())
}

// 原有：
pub fn upsert(&self, book: &Book) -> SqlResult<()> {
    // 自身仍接 &self（持 &Connection），改为内部调 in_tx 等价 — 但这里
    // 不能直接调（in_tx 接 &Transaction，&Connection 不兼容）。
    // 决策：保留 upsert 直接 self.conn.execute，in_tx 是平行变体，不强行复用。
}
```

> 注意：`upsert` 与 `upsert_in_tx` 的 SQL 共用同一个 `BOOK_UPSERT_SQL` 常量，无 SQL 字面量重复（消除 F-W1A-011 主题在书 upsert 上的部分重复）。

**chapter_dao.rs**：
```rust
/// 接 `&Transaction` 的 in_tx 变体（参照已有的
/// `replace_by_book_preserving_content_in_tx` 范式）。
pub fn replace_by_book_in_tx(
    tx: &rusqlite::Transaction,
    book_id: &str,
    chapters: &[Chapter],
) -> SqlResult<()> {
    tx.execute("DELETE FROM chapters WHERE book_id = ?1", params![book_id])?;
    for ch in chapters {
        tx.execute(CHAPTER_INSERT_SQL, params![/* ... */])?;
    }
    Ok(())
}
```

**download_dao.rs**：
```rust
/// `&Transaction` 版 update_chapter_status，让 caller 在外层 tx 内一并
/// 跑 update + recompute，避免两步 SQL 中间 panic 留脏数据。
pub fn update_chapter_status_in_tx(
    tx: &rusqlite::Transaction,
    chapter_id: &str,
    status: i32,
    file_path: Option<&str>,
    file_size: i64,
    error_message: Option<&str>,
) -> SqlResult<()> {
    tx.execute(
        "UPDATE download_chapters SET ... WHERE id = ?",
        params![/* ... */],
    )?;
    Ok(())
}
```

`recompute_download_task_status` 当前在 `bridge/api.rs` 内（不在 dao），接 `&DownloadDao`。本批改为接 `&Transaction` + `task_id`，全部 SQL inline 走 tx.execute（保留 4 个 SELECT/UPDATE 步骤）。

### Step 3 — `import_local_book` 走 with_transaction

```rust
// 原（line 1485-1535）：
let mut conn = open_db(&db_path)?;
let source_id = crate::local_book::ensure_local_source(&mut conn)?;
// ... 构造 book
{
    let book_dao = BookDao::new(&conn);
    book_dao.upsert(&book)?;
}
{
    let mut chapter_dao = ChapterDao::new(&mut conn);
    chapter_dao.replace_by_book(&book_id, &storage_chapters)?;
}

// 改为：
let source_id = {
    let mut conn = open_db(&db_path)?;
    crate::local_book::ensure_local_source(&mut conn)?
};
// ... 构造 book（用上面的 source_id）
crate::transaction::with_transaction(&db_path, |tx| {
    BookDao::upsert_in_tx(tx, &book).map_err(|e| format!("写入书籍失败: {}", e))?;
    ChapterDao::replace_by_book_in_tx(tx, &book_id, &storage_chapters)
        .map_err(|e| format!("写入章节失败: {}", e))?;
    Ok(())
})?;
```

### Step 4 — `download_and_save_chapter` 走 with_transaction

```rust
// success path（line 773-778 改）：
crate::transaction::with_transaction(&db_path, |tx| {
    DownloadDao::update_chapter_status_in_tx(
        tx, &download_chapter_id, 2, Some(&file_path), file_size, None,
    ).map_err(|e| format!("更新章节状态失败: {}", e))?;
    recompute_download_task_status_in_tx(tx, &task_id)
        .map_err(|e| format!("更新任务状态失败: {}", e))?;
    Ok(())
})?;

// mark_chapter_failed helper 也改为内部用 with_transaction：
fn mark_chapter_failed(
    db_path: &str,
    task_id: &str,
    chapter_id: &str,
    error_message: &str,
) -> Result<(), String> {
    crate::transaction::with_transaction(db_path, |tx| {
        DownloadDao::update_chapter_status_in_tx(
            tx, chapter_id, 3, None, 0, Some(error_message),
        ).map_err(|e| format!("更新章节状态失败: {}", e))?;
        recompute_download_task_status_in_tx(tx, task_id)
            .map_err(|e| format!("更新任务状态失败: {}", e))?;
        Ok(())
    })
}
```

> `recompute_download_task_status_in_tx` 是新 helper（接 `&Transaction` + task_id），把原 `recompute_download_task_status(&DownloadDao, &task_id)` 的 4 步 SQL 改为 tx.execute / tx.query_row。

### Step 5 — WAL pragma

`core/core-storage/src/database.rs::init_database` line 32 之后：
```rust
// 启用外键约束
conn.execute("PRAGMA foreign_keys = ON", [])?;

// WAL 持久性调优（F-W1A-004）：
// - synchronous=NORMAL：WAL 模式下推荐值，断电时仅丢失最近未 fsync 的 commit；
//   FULL 太严格（每次 commit fsync 慢）；OFF 不安全。
// - wal_autocheckpoint=1000：每 1000 页（~4 MB）触发 WAL checkpoint，限制
//   WAL 文件无限增长。这是数据库属性（写 -wal 文件 header），仅 init 一次设；
//   下次打开同 db 不需重设。
// 不在 get_connection 重复设 — connection-level 属性 SQLite 默认会从 db 文件
// 表头读取，重设浪费 round-trip。
conn.execute("PRAGMA synchronous = NORMAL", [])?;
conn.execute("PRAGMA wal_autocheckpoint = 1000", [])?;
```

### Step 6 — F-W1A-007 注释

`core/core-storage/src/source_dao.rs` line 63（`/// 插入或更新书源...`）扩充：
```rust
/// 插入或更新书源，返回**实际写入的 ID**（可能与 source.id 不同）。
///
/// **silently-rewrite-id 行为（F-W1A-007）**：当传入的 source.id 与 DB
/// 中已有行 id 不同、但 source.url 与该已有行 url 相同时，本 fn 会把
/// 写入目标改为已有行 id（用 URL 去重避免外键 book.source_id 失效）。
/// 调用方**必须使用返回值而非传入的 source.id**做后续查询，否则会
/// 出现"按 source.id 查找返回 None 但数据其实在数据库另一行"的诡异。
///
/// 严格语义（"id 冲突直接报错让 caller 决定"）暂未提供；如未来需要，
/// 单独补 `try_insert_strict(&self, &BookSource) -> SqlResult<()>` 不
/// 复用本 fn 的去重逻辑。
pub fn upsert(&self, source: &BookSource) -> SqlResult<String> {
```

### 风险

- **DownloadDao::conn 类型不变**：仅补 `update_chapter_status_in_tx` 平行 fn，原 `&self` 版保留供其它 caller。无破坏性。
- **`BookDao` 与 `ChapterDao` SQL 字面量复用**：upsert_in_tx 用同 `BOOK_UPSERT_SQL` 常量，replace_by_book_in_tx 用同 CHAPTER_INSERT_SQL 常量；无新 SQL 重复。
- **`recompute_download_task_status_in_tx` 改写**：原 fn 在 bridge/api.rs 内 60 行 SQL 逻辑（4 个 SELECT/UPDATE），改 in_tx 时全部转为 `tx.execute` / `tx.query_row` 即可；逻辑完全一致，仅切换调用对象。
- **`get_connection` 不重设 pragma**：BATCH-07a 已确认 `init_database` 在首次打开时设 foreign_keys；后续 `get_connection` 也设 foreign_keys（database.rs 内有重复设逻辑）。本批 WAL pragma 仅 init 设——但有疑虑：bridge fn 每次 fresh open 走 get_connection，synchronous 是 connection-level，会不会被重置回默认 NORMAL？需要 verify。

### 验证项

- 风险点 verify：grep `get_connection`，read 它的实现，确认 `synchronous` 是否需要 connection-level 重设
- `import_local_book` 在 chapter_dao 失败时验证 book 行也回滚（手动测试或读源码 reasoning）
- `cargo check --workspace`
- `cargo test -p core-storage --lib`

## Decision (ADR-lite)

**Context**: BATCH-07a 缩范围后留下 4 条 finding 中有 2 条跨 dao 事务（F-W1A-009 / 021），需要 with_transaction helper；另 2 条小改（F-W1A-004 WAL pragma / F-W1A-007 注释）顺手做。

**Decisions**:
1. **with_transaction helper 落 `core/bridge/src/transaction.rs` 单独文件**（非 api.rs 内）— api.rs 已 2554 行过胖，单独 mod 让未来更多事务 helper 集中
2. **补 `*_in_tx(tx: &Transaction, ...)` 变体**（不在 bridge 内 inline SQL，不引入 dao Mode 切换）— 与已有 `replace_by_book_preserving_content_in_tx` 范式一致
3. **WAL pragma 仅 init_database 设一次**（非 get_connection 重设）— `wal_autocheckpoint` 是数据库属性；`synchronous` 是 connection 属性但 SQLite 会从 db 文件表头读默认，init 设过一次后 conn 默认值已是 NORMAL（待 verify）
4. **F-W1A-007 仅文档注释**（不补 strict fn）— 路线图列了两选项，注释最简

**Consequences**:
- ✅ 路线图 BATCH-07 全 9 条闭环
- ✅ DAO in_tx 变体为 BATCH-08+ 跨 dao 事务铺路
- ⚠️ get_connection 重设 synchronous 这点需要 verify；若发现确实需要重设，调整为两处都设
- ⚠️ recompute_download_task_status 改名 in_tx 后调用方一处（download_and_save_chapter），无破坏

## Technical Notes

- 上一任务 BATCH-07a commit `a279e0d`
- master finding 详情：`.trellis/tasks/archive/2026-05/05-19-full-codebase-review/research/findings-rust-data.md`
- `core/api-server/src/util.rs:101` 已有 async 版 `db_transaction`（仅供参考）
- `core/core-storage/src/chapter_dao.rs:113-129` 的 `replace_by_book_preserving_content_in_tx` 范式
- 完成后用户跑：
  - `cd core && cargo check --workspace`
  - `cd core && cargo test -p core-storage --lib`
