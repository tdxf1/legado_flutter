use crate::error::ApiError;
use crate::state::{AppState, SqlitePool};

/// Pool-backed connection accessor.
///
/// Currently unused — every active call site goes through [`db_blocking`]
/// (R60). Kept around for parity with the legacy interface and as an
/// escape hatch for future maintenance scripts that already hold an
/// [`AppState`] but for some reason need a raw connection. Calling this
/// directly inside an async handler holds the current tokio worker
/// hostage; if you find yourself reaching for it, you almost certainly
/// want [`db_blocking`] instead.
#[allow(dead_code)]
pub fn pooled_conn(
    state: &AppState,
) -> Result<r2d2::PooledConnection<r2d2_sqlite::SqliteConnectionManager>, ApiError> {
    state
        .pool
        .get()
        .map_err(|e| ApiError::Database(format!("connection pool: {e}")))
}

/// R60: run a synchronous DB closure on tokio's blocking pool.
///
/// `rusqlite::Connection` is sync and CPU/IO-blocking; calling DAO
/// methods directly from an async axum handler holds the current
/// tokio worker hostage. We instead clone the [`SqlitePool`] (cheap —
/// it's `Arc` internally), move it into a [`spawn_blocking`] task, and
/// pull a connection from there. Caller's closure can then use the
/// existing DAO API unchanged.
///
/// The closure receives a `PooledConnection` so it can pass `&Connection`
/// or `&mut Connection` to DAO constructors. Errors from `pool.get()`
/// surface as [`ApiError::Database`]; user errors come back through
/// the closure's `Result` arm.
///
/// Type bounds:
///   - `F: FnOnce(...) -> Result<T, E> + Send + 'static`
///   - `T: Send + 'static`
///   - `E: Into<ApiError> + Send + 'static`
///
/// `'static` is satisfied because [`SqlitePool::clone`] yields an
/// owned, fully self-contained handle and the closure captures only
/// inputs the caller has already cloned/owned.
///
/// **Atomicity note (R73)**: each call grabs a fresh connection and
/// commits independently. Sequences of `db_blocking` calls do *not*
/// form a single transaction — the connection is returned to the pool
/// between calls. Use [`db_transaction`] when a sequence of DAO
/// operations must succeed or fail together.
pub async fn db_blocking<F, T, E>(state: &AppState, f: F) -> Result<T, ApiError>
where
    F: FnOnce(
            &mut r2d2::PooledConnection<r2d2_sqlite::SqliteConnectionManager>,
        ) -> Result<T, E>
        + Send
        + 'static,
    T: Send + 'static,
    E: Into<ApiError> + Send + 'static,
{
    let pool: SqlitePool = state.pool.clone();
    tokio::task::spawn_blocking(move || -> Result<T, ApiError> {
        let mut conn = pool
            .get()
            .map_err(|e| ApiError::Database(format!("connection pool: {e}")))?;
        f(&mut conn).map_err(Into::into)
    })
    .await
    .map_err(|e| ApiError::Internal(format!("blocking task join failed: {e}")))?
}

/// R74: run a synchronous DB closure inside a single transaction on
/// tokio's blocking pool.
///
/// Same off-thread story as [`db_blocking`], with the addition that the
/// closure receives a `&mut rusqlite::Transaction` instead of a raw
/// connection. The transaction is committed automatically when the
/// closure returns `Ok(_)` and rolled back when it returns `Err(_)` or
/// panics — `Transaction`'s `Drop` impl rolls back if you don't call
/// `.commit()`, so we explicitly commit at the end of the success
/// branch.
///
/// Use this whenever a sequence of writes must be atomic. Multi-step
/// sequences spread across separate `db_blocking` calls each commit
/// independently and can leave the DB half-updated if a later step
/// fails (R73).
///
/// Note: DAO constructors that take `&Connection` / `&mut Connection`
/// still work because `Transaction` derefs to `Connection`. Pass
/// `&*tx` or `tx.deref_mut()` if a constructor needs the explicit
/// reference type.
///
/// **Panic safety (R86)**: a panic inside the closure is caught by the
/// underlying [`tokio::task::spawn_blocking`] and surfaces as
/// [`ApiError::Internal`] via the join error path. The
/// [`rusqlite::Transaction`] is dropped during unwinding without
/// calling `.commit()`, which triggers `ROLLBACK`. The pool slot is
/// returned via the `PooledConnection`'s own Drop. So a panic leaves
/// the DB clean and the pool unleaked; no special handling needed in
/// the caller.
pub async fn db_transaction<F, T, E>(state: &AppState, f: F) -> Result<T, ApiError>
where
    F: FnOnce(&mut rusqlite::Transaction<'_>) -> Result<T, E> + Send + 'static,
    T: Send + 'static,
    E: Into<ApiError> + Send + 'static,
{
    let pool: SqlitePool = state.pool.clone();
    tokio::task::spawn_blocking(move || -> Result<T, ApiError> {
        let mut conn = pool
            .get()
            .map_err(|e| ApiError::Database(format!("connection pool: {e}")))?;
        let mut tx = conn
            .transaction()
            .map_err(|e| ApiError::Database(format!("begin transaction: {e}")))?;
        match f(&mut tx) {
            Ok(value) => {
                tx.commit()
                    .map_err(|e| ApiError::Database(format!("commit transaction: {e}")))?;
                Ok(value)
            }
            Err(e) => {
                // Drop without commit triggers rollback; explicit drop is
                // not strictly needed but documents intent.
                drop(tx);
                Err(e.into())
            }
        }
    })
    .await
    .map_err(|e| ApiError::Internal(format!("blocking task join failed: {e}")))?
}

/// Legacy direct-open helper kept for the rare path that doesn't have
/// access to `AppState` (none currently — kept for forward-compat with
/// future maintenance scripts). Prefer [`pooled_conn`] +
/// [`db_blocking`].
#[allow(dead_code)]
pub fn open_db(db_path: &str) -> Result<rusqlite::Connection, ApiError> {
    core_storage::database::get_connection(db_path).map_err(|e| ApiError::Database(e.to_string()))
}

pub fn storage_to_core_source(
    s: &core_storage::models::BookSource,
) -> Result<core_source::types::BookSource, ApiError> {
    let rule_search = s
        .rule_search
        .as_deref()
        .map(|r| serde_json::from_str(r))
        .transpose()
        .map_err(|e| ApiError::Parse(format!("解析 rule_search 失败: {}", e)))?;
    let rule_book_info = s
        .rule_book_info
        .as_deref()
        .map(|r| serde_json::from_str(r))
        .transpose()
        .map_err(|e| ApiError::Parse(format!("解析 rule_book_info 失败: {}", e)))?;
    let rule_toc = s
        .rule_toc
        .as_deref()
        .map(|r| serde_json::from_str(r))
        .transpose()
        .map_err(|e| ApiError::Parse(format!("解析 rule_toc 失败: {}", e)))?;
    let rule_content = s
        .rule_content
        .as_deref()
        .map(|r| serde_json::from_str(r))
        .transpose()
        .map_err(|e| ApiError::Parse(format!("解析 rule_content 失败: {}", e)))?;

    Ok(core_source::types::BookSource {
        id: s.id.clone(),
        name: s.name.clone(),
        url: s.url.clone(),
        source_type: s.source_type,
        enabled: s.enabled,
        group_name: s.group_name.clone(),
        custom_order: s.custom_order,
        weight: s.weight,
        rule_search,
        rule_book_info,
        rule_toc,
        rule_content,
        rule_review: None,
        login_url: s.login_url.clone(),
        login_ui: s.login_ui.clone(),
        login_check_js: s.login_check_js.clone(),
        header: s.header.clone(),
        js_lib: s.js_lib.clone(),
        cover_decode_js: s.cover_decode_js.clone(),
        rule_explore: s
            .rule_explore
            .as_deref()
            .map(|r| serde_json::from_str(r))
            .transpose()
            .map_err(|e| ApiError::Parse(format!("解析 rule_explore 失败: {}", e)))?,
        explore_url: s.explore_url.clone(),
        book_url_pattern: s.book_url_pattern.clone(),
        enabled_explore: s.enabled_explore,
        last_update_time: s.last_update_time,
        book_source_comment: s.book_source_comment.clone(),
        concurrent_rate: s.concurrent_rate.clone(),
        variable_comment: s.variable_comment.clone(),
        explore_screen: s.explore_screen,
        created_at: s.created_at,
        updated_at: s.updated_at,
    })
}
