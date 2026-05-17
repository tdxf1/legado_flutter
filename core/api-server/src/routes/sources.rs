use axum::{
    extract::{DefaultBodyLimit, Json, Path, State},
    routing::{delete, get, post, put},
    Router,
};
use serde::{Deserialize, Serialize};

use crate::error::ApiError;
use crate::state::AppState;
use crate::util::db_blocking;

#[derive(Debug, Deserialize)]
pub struct CreateSourceRequest {
    pub name: String,
    pub url: String,
}

#[derive(Debug, Deserialize)]
pub struct ImportSourcesRequest {
    pub json: String,
}

#[derive(Debug, Deserialize)]
pub struct EnableSourceRequest {
    pub enabled: bool,
}

#[derive(Debug, Serialize)]
pub struct ImportSourcesResponse {
    pub count: i32,
}

async fn list_sources(State(state): State<AppState>) -> Result<Json<serde_json::Value>, ApiError> {
    // R60: synchronous SQLite work runs on the blocking pool so the
    // tokio async worker stays free to service other requests.
    let sources = db_blocking(&state, |conn| {
        let dao = core_storage::source_dao::SourceDao::new(conn);
        dao.get_all().map_err(|e| ApiError::Database(e.to_string()))
    })
    .await?;
    Ok(Json(serde_json::to_value(sources)?))
}

async fn list_enabled_sources(
    State(state): State<AppState>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let sources = db_blocking(&state, |conn| {
        let dao = core_storage::source_dao::SourceDao::new(conn);
        dao.get_enabled()
            .map_err(|e| ApiError::Database(e.to_string()))
    })
    .await?;
    Ok(Json(serde_json::to_value(sources)?))
}

async fn create_source(
    State(state): State<AppState>,
    Json(req): Json<CreateSourceRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    if req.name.trim().is_empty() {
        return Err(ApiError::BadRequest("书源名称不能为空".into()));
    }
    if req.url.trim().is_empty() {
        return Err(ApiError::BadRequest("书源 URL 不能为空".into()));
    }
    let source = db_blocking(&state, move |conn| {
        let dao = core_storage::source_dao::SourceDao::new(conn);
        dao.create(&req.name, &req.url)
            .map_err(|e| ApiError::Database(e.to_string()))
    })
    .await?;
    Ok(Json(serde_json::to_value(source)?))
}

async fn import_sources(
    State(state): State<AppState>,
    Json(req): Json<ImportSourcesRequest>,
) -> Result<Json<ImportSourcesResponse>, ApiError> {
    let count = db_blocking(&state, move |conn| {
        let mut dao = core_storage::source_dao::SourceDao::new(conn);
        dao.import_from_json(&req.json).map_err(ApiError::Parse)
    })
    .await?;
    Ok(Json(ImportSourcesResponse {
        count: count as i32,
    }))
}

async fn set_source_enabled(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(req): Json<EnableSourceRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    // R59: TOCTOU between `get_by_id` and `set_enabled` is possible if
    // another request deletes the source in between, but the worst-case
    // outcome is that `set_enabled` becomes a silent no-op against an
    // already-deleted row. No data integrity issue — wrapping these in
    // a transaction would protect the contract but adds DB round-trips
    // for no observable user benefit. Leaving as-is.
    db_blocking(&state, move |conn| {
        let dao = core_storage::source_dao::SourceDao::new(conn);
        dao.get_by_id(&id)
            .map_err(|e| ApiError::Database(e.to_string()))?
            .ok_or_else(|| ApiError::NotFound(format!("书源不存在: {}", id)))?;
        dao.set_enabled(&id, req.enabled)
            .map_err(|e| ApiError::Database(e.to_string()))
    })
    .await?;
    Ok(Json(serde_json::json!({ "ok": true })))
}

async fn delete_source(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    // R59: same TOCTOU note as `set_source_enabled`. A concurrent delete
    // of the same id makes the second caller's `delete` a no-op, which
    // is the desired idempotent outcome anyway.
    db_blocking(&state, move |conn| {
        let dao = core_storage::source_dao::SourceDao::new(conn);
        dao.get_by_id(&id)
            .map_err(|e| ApiError::Database(e.to_string()))?
            .ok_or_else(|| ApiError::NotFound(format!("书源不存在: {}", id)))?;
        dao.delete(&id)
            .map_err(|e| ApiError::Database(e.to_string()))
    })
    .await?;
    Ok(Json(serde_json::json!({ "ok": true })))
}

async fn export_legado(State(state): State<AppState>) -> Result<String, ApiError> {
    db_blocking(&state, |conn| {
        let dao = core_storage::source_dao::SourceDao::new(conn);
        dao.export_legado_json()
            .map_err(|e| ApiError::Database(e.to_string()))
    })
    .await
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/sources", get(list_sources).post(create_source))
        .route("/api/sources/enabled", get(list_enabled_sources))
        .route(
            "/api/sources/import",
            post(import_sources).layer(DefaultBodyLimit::max(25 * 1024 * 1024)),
        )
        .route("/api/sources/export/legado", get(export_legado))
        .route("/api/sources/:id/enabled", put(set_source_enabled))
        .route("/api/sources/:id", delete(delete_source))
}
