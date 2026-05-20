//! 跨 DAO 事务 helper（批次 69 / 05-20，BATCH-07b）。
//!
//! bridge 端没有连接池，每次 fn fresh `open_db`。本 helper 把"打开 conn
//! → begin tx → 跑闭包 → commit on Ok / rollback on Err"模板化，让多
//! dao 多步写入（如 [`crate::api::import_local_book`] 的 BookDao 与
//! ChapterDao、[`crate::api::download_and_save_chapter`] 的
//! `update_chapter_status` 与 `recompute_download_task_status`）能走单
//! 事务，FK / 中间步骤错误时整批回滚不留脏数据。
//!
//! 闭包接 `&rusqlite::Transaction`：
//! - 调任何 DAO 的 `*_in_tx(tx, ...)` 变体直接传 `tx`；
//! - DAO 只读方法持 `&Connection`，因 rusqlite `Transaction:
//!   Deref<Target=Connection>`，把 `&tx` 当 `&Connection` 用也 work。
//!
//! Drop 时未 commit 的 tx 自动 ROLLBACK（RAII），与 panic-safe 同等保证。
//! 与 api-server 的 async `db_transaction` 是孪生设计，仅同步 / 异步运
//! 行时差异。

/// 打开 db、开启事务、跑 `f`、Ok 时 commit / Err 时 rollback（Drop 兜底）。
///
/// 错误一律转 `String`，与 bridge 各 fn 现有错误风格一致。`f` 内部任意
/// `?` 早返都会让 tx 在 Drop 时回滚，调用方不必手写 ROLLBACK。
pub(crate) fn with_transaction<F, T>(db_path: &str, f: F) -> Result<T, String>
where
    F: FnOnce(&rusqlite::Transaction<'_>) -> Result<T, String>,
{
    let mut conn = core_storage::database::get_connection(db_path)
        .map_err(|e| format!("数据库连接失败: {}", e))?;
    let tx = conn
        .transaction()
        .map_err(|e| format!("开启事务失败: {}", e))?;
    let result = f(&tx)?;
    tx.commit().map_err(|e| format!("提交事务失败: {}", e))?;
    Ok(result)
}
