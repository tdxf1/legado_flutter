use crate::error::ApiError;
use crate::state::AppState;

/// Pool-backed connection accessor used by route handlers.
///
/// The returned [`r2d2::PooledConnection`] derefs to an `&Connection`/
/// `&mut Connection`, so existing DAO code (`SourceDao::new(&mut conn)`,
/// `BookDao::new(&conn)`) keeps working without any signature changes.
pub fn pooled_conn(
    state: &AppState,
) -> Result<r2d2::PooledConnection<r2d2_sqlite::SqliteConnectionManager>, ApiError> {
    state
        .pool
        .get()
        .map_err(|e| ApiError::Database(format!("connection pool: {e}")))
}

/// Legacy direct-open helper kept for the rare path that doesn't have
/// access to `AppState` (none currently — kept for forward-compat with
/// future maintenance scripts). Prefer [`pooled_conn`].
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
