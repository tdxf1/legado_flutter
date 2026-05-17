use axum::{
    extract::{Json, Query, State},
    routing::get,
    Router,
};
use serde::{Deserialize, Serialize};

use crate::error::ApiError;
use crate::state::AppState;
use crate::util;
use crate::util::db_blocking;

#[derive(Debug, Deserialize)]
pub struct ExploreRequest {
    pub source_id: String,
    pub explore_url: String,
    #[serde(default = "default_page")]
    pub page: i32,
}

fn default_page() -> i32 {
    1
}

#[derive(Debug, Serialize)]
pub struct ExploreResponse {
    pub items: Vec<core_source::parser::SearchResult>,
    pub page: i32,
}

async fn explore(
    State(state): State<AppState>,
    Json(req): Json<ExploreRequest>,
) -> Result<Json<ExploreResponse>, ApiError> {
    let source_id = req.source_id.clone();
    let source = db_blocking(&state, move |conn| {
        let source_dao = core_storage::source_dao::SourceDao::new(conn);
        source_dao
            .get_by_id(&source_id)
            .map_err(|e| ApiError::Database(e.to_string()))?
            .ok_or_else(|| ApiError::NotFound(format!("书源不存在: {}", source_id)))
    })
    .await?;

    let core_source = util::storage_to_core_source(&source)?;
    let parser = core_source::parser::BookSourceParser::new();

    // R82: explore returns Result. Empty becomes empty Vec (legitimate
    // "no entries on this page"); other variants surface as ApiError
    // so the explore page can show why nothing loaded.
    let results = match parser
        .explore(&core_source, &req.explore_url, req.page)
        .await
    {
        Ok(items) => items,
        Err(core_source::ParserError::Empty) => Vec::new(),
        Err(e) => return Err(ApiError::BadRequest(format!("发现请求失败: {}", e))),
    };

    Ok(Json(ExploreResponse {
        items: results,
        page: req.page,
    }))
}

#[derive(Debug, Deserialize)]
pub struct ListExploreQuery {
    pub source_id: String,
}

async fn list_explore_entries(
    State(state): State<AppState>,
    Query(params): Query<ListExploreQuery>,
) -> Result<Json<Vec<core_source::parser::ExploreEntry>>, ApiError> {
    let source_id = params.source_id;
    let source_id_clone = source_id.clone();
    let source = db_blocking(&state, move |conn| {
        let source_dao = core_storage::source_dao::SourceDao::new(conn);
        source_dao
            .get_by_id(&source_id_clone)
            .map_err(|e| ApiError::Database(e.to_string()))?
            .ok_or_else(|| ApiError::NotFound(format!("书源不存在: {}", source_id_clone)))
    })
    .await?;

    let core_source = util::storage_to_core_source(&source)?;
    let entries = core_source::parser::BookSourceParser::get_explore_entries(&core_source);

    Ok(Json(entries))
}

pub fn routes() -> Router<AppState> {
    Router::new().route("/api/explore", get(list_explore_entries).post(explore))
}
