use axum::{
    extract::{Json, State},
    routing::post,
    Router,
};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::sync::Semaphore;
use tokio::task::JoinSet;

use crate::error::ApiError;
use crate::state::AppState;
use crate::util;
use crate::util::db_blocking;

/// R58: how many sources we'll search in parallel for a single request.
///
/// Each task takes one connection from the pool while it loads the
/// source row, so this cap must stay strictly below
/// [`SQLITE_POOL_SIZE`](crate::state::SQLITE_POOL_SIZE) — otherwise a
/// single search request can drain the pool and stall every other
/// route (including /health). Tuned for "useful fan-out + headroom".
pub const SEARCH_FANOUT: usize = 16;

#[derive(Debug, Deserialize)]
pub struct SearchRequest {
    pub keyword: String,
    pub source_ids: Option<Vec<String>>,
}

#[derive(Debug, Serialize)]
pub struct SearchResponse {
    pub items: Vec<core_source::parser::SearchResult>,
    pub failed_sources: Vec<FailedSource>,
}

#[derive(Debug, Serialize)]
pub struct FailedSource {
    pub source_id: String,
    pub source_name: String,
    pub error: String,
}

async fn search(
    State(state): State<AppState>,
    Json(req): Json<SearchRequest>,
) -> Result<Json<SearchResponse>, ApiError> {
    if req.keyword.trim().is_empty() {
        return Err(ApiError::BadRequest("搜索关键词不能为空".into()));
    }

    let source_ids: Vec<String> = if let Some(ids) = req.source_ids {
        if ids.is_empty() {
            return Ok(Json(SearchResponse {
                items: vec![],
                failed_sources: vec![],
            }));
        }
        ids
    } else {
        // R60: synchronous DAO call moved off the tokio worker thread.
        db_blocking(&state, |conn| {
            let dao = core_storage::source_dao::SourceDao::new(conn);
            dao.get_enabled()
                .map_err(|e| ApiError::Database(e.to_string()))
                .map(|sources| sources.into_iter().map(|s| s.id).collect::<Vec<_>>())
        })
        .await?
    };

    let semaphore = Arc::new(Semaphore::new(SEARCH_FANOUT));
    let mut join_set = JoinSet::new();
    for sid in &source_ids {
        let sid = sid.clone();
        let pool = state.pool.clone();
        let keyword = req.keyword.clone();
        let permit = semaphore
            .clone()
            .acquire_owned()
            .await
            .map_err(|_| ApiError::Internal("信号量获取失败".into()))?;
        join_set.spawn(async move {
            let result = search_single_source(&pool, &sid, &keyword).await;
            drop(permit);
            result
        });
    }

    let mut items = Vec::new();
    let mut failed_sources = Vec::new();
    while let Some(result) = join_set.join_next().await {
        match result {
            Ok(Ok(search_results)) => items.extend(search_results),
            Ok(Err((id, name, error))) => {
                failed_sources.push(FailedSource {
                    source_id: id,
                    source_name: if name.is_empty() {
                        "未知书源".into()
                    } else {
                        name
                    },
                    error,
                });
            }
            Err(e) => {
                failed_sources.push(FailedSource {
                    source_id: "unknown".into(),
                    source_name: "未知书源".into(),
                    error: format!("任务执行失败: {}", e),
                });
            }
        }
    }

    Ok(Json(SearchResponse {
        items,
        failed_sources,
    }))
}

async fn search_single_source(
    pool: &crate::state::SqlitePool,
    source_id: &str,
    keyword: &str,
) -> Result<Vec<core_source::parser::SearchResult>, (String, String, String)> {
    // R60: DB row lookup moved off the tokio worker. We can't reuse
    // `db_blocking` here because the error type for this fan-out
    // routine is a custom tuple, not `ApiError`, but the pattern is
    // the same: pool clone + spawn_blocking.
    let pool_for_blocking = pool.clone();
    let source_id_owned = source_id.to_string();
    let storage_source = tokio::task::spawn_blocking(move || {
        let mut conn = pool_for_blocking.get().map_err(|e| {
            (
                source_id_owned.clone(),
                String::new(),
                format!("connection pool: {e}"),
            )
        })?;
        let dao = core_storage::source_dao::SourceDao::new(&mut conn);
        dao.get_by_id(&source_id_owned)
            .map_err(|e| (source_id_owned.clone(), String::new(), e.to_string()))?
            .ok_or_else(|| (source_id_owned.clone(), String::new(), "书源不存在".to_string()))
    })
    .await
    .map_err(|e| {
        (
            source_id.to_string(),
            String::new(),
            format!("blocking task join failed: {e}"),
        )
    })??;
    let source_name = storage_source.name.clone();
    let source = util::storage_to_core_source(&storage_source)
        .map_err(|e| (source_id.to_string(), source_name.clone(), e.to_string()))?;
    let parser = core_source::parser::BookSourceParser::new();
    // R82: parser.search now returns Result. Empty (no matches) is
    // converted to an empty Vec for the SearchResponse — this is a
    // legitimate "0 results" signal, distinct from the failed_sources
    // list which captures Network / RuleConfig / Parse errors.
    match parser.search(&source, keyword).await {
        Ok(results) => Ok(results),
        Err(core_source::ParserError::Empty) => Ok(Vec::new()),
        Err(e) => Err((source_id.to_string(), source_name.clone(), e.to_string())),
    }
}

pub fn routes() -> Router<AppState> {
    Router::new().route("/api/search", post(search))
}
