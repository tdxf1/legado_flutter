use axum::{
    extract::{Json, Path, State},
    routing::{delete, get},
    Router,
};
use serde::Deserialize;

use crate::error::ApiError;
use crate::state::AppState;
use crate::util::db_blocking;

#[derive(Debug, Deserialize)]
pub struct CreateReplaceRuleRequest {
    pub name: String,
    pub pattern: String,
    pub replacement: String,
    /// R24: scope 现在是 Option<String>（子串匹配 book.name 或
    /// book.origin），不再是 enum int。Caller 留空表示全局。
    #[serde(default)]
    pub scope: Option<String>,
    #[serde(default)]
    pub scope_title: Option<bool>,
    #[serde(default)]
    pub scope_content: Option<bool>,
    #[serde(default)]
    pub exclude_scope: Option<String>,
}

async fn list_rules(State(state): State<AppState>) -> Result<Json<serde_json::Value>, ApiError> {
    let rules = db_blocking(&state, |conn| {
        let dao = core_storage::replace_rule_dao::ReplaceRuleDao::new(conn);
        dao.get_all().map_err(|e| ApiError::Database(e.to_string()))
    })
    .await?;
    Ok(Json(serde_json::to_value(rules)?))
}

async fn list_enabled_rules(
    State(state): State<AppState>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let rules = db_blocking(&state, |conn| {
        let dao = core_storage::replace_rule_dao::ReplaceRuleDao::new(conn);
        dao.get_enabled()
            .map_err(|e| ApiError::Database(e.to_string()))
    })
    .await?;
    Ok(Json(serde_json::to_value(rules)?))
}

async fn create_rule(
    State(state): State<AppState>,
    Json(req): Json<CreateReplaceRuleRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    if req.name.trim().is_empty() {
        return Err(ApiError::BadRequest("规则名称不能为空".into()));
    }
    let rule = db_blocking(&state, move |conn| {
        let dao = core_storage::replace_rule_dao::ReplaceRuleDao::new(conn);
        // 先用 create() 拿默认全局规则，然后按需 upsert 覆盖 scope 字段。
        let mut rule = dao
            .create(&req.name, &req.pattern, &req.replacement)
            .map_err(|e| ApiError::Database(e.to_string()))?;
        let needs_update = req.scope.is_some()
            || req.scope_title.is_some()
            || req.scope_content.is_some()
            || req.exclude_scope.is_some();
        if needs_update {
            rule.scope = req.scope.filter(|s| !s.is_empty());
            if let Some(t) = req.scope_title {
                rule.scope_title = t;
            }
            if let Some(c) = req.scope_content {
                rule.scope_content = c;
            }
            rule.exclude_scope = req.exclude_scope.filter(|s| !s.is_empty());
            dao.upsert(&rule)
                .map_err(|e| ApiError::Database(e.to_string()))?;
        }
        Ok::<_, ApiError>(rule)
    })
    .await?;
    Ok(Json(serde_json::to_value(rule)?))
}

async fn delete_rule(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    db_blocking(&state, move |conn| {
        let dao = core_storage::replace_rule_dao::ReplaceRuleDao::new(conn);
        dao.get_by_id(&id)
            .map_err(|e| ApiError::Database(e.to_string()))?
            .ok_or_else(|| ApiError::NotFound(format!("替换规则不存在: {}", id)))?;
        dao.delete(&id)
            .map_err(|e| ApiError::Database(e.to_string()))
    })
    .await?;
    Ok(Json(serde_json::json!({ "ok": true })))
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/replace-rules", get(list_rules).post(create_rule))
        .route("/api/replace-rules/enabled", get(list_enabled_rules))
        .route("/api/replace-rules/:id", delete(delete_rule))
}
