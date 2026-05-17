use axum::{
    extract::{Json, Path, Query, State},
    routing::{get, post},
    Router,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;

use crate::error::ApiError;
use crate::state::AppState;
use crate::util;
use crate::util::db_blocking;

#[derive(Debug, Serialize)]
pub struct ChapterContentResponse {
    pub book_id: String,
    pub chapter_index: i32,
    pub title: String,
    pub content: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub platform_request: Option<core_source::parser::PlatformRequest>,
}

#[derive(Debug, Deserialize)]
pub struct SaveProgressRequest {
    pub chapter_index: i32,
    pub paragraph_index: i32,
    pub offset: i32,
}

#[derive(Debug, Deserialize)]
pub struct SaveChapterContentRequest {
    pub chapter_index: i32,
    pub content: String,
}

fn hash_id(input: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(input.as_bytes()))
}

#[derive(Debug, Serialize)]
pub struct RefreshChaptersResponse {
    pub book_id: String,
    pub total_count: usize,
}

async fn list_chapters(
    State(state): State<AppState>,
    Path(book_id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let chapters = db_blocking(&state, move |conn| {
        let dao = core_storage::chapter_dao::ChapterDao::new(conn);
        dao.get_by_book(&book_id)
            .map_err(|e| ApiError::Database(e.to_string()))
    })
    .await?;
    Ok(Json(serde_json::to_value(chapters)?))
}

/// Inner result of the cached-content lookup: either we have content
/// already and can short-circuit, or we need to go fetch it from the
/// source.
enum CachedChapter {
    Cached {
        title: String,
        content: String,
    },
    NeedsFetch {
        chapter_url: String,
        chapter_title: String,
        chapter_id: String,
    },
}

async fn get_chapter_content(
    State(state): State<AppState>,
    Path(book_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
) -> Result<Json<ChapterContentResponse>, ApiError> {
    let chapter_index: i32 = params
        .get("chapter_index")
        .unwrap_or(&"0".to_string())
        .parse()
        .map_err(|_| ApiError::BadRequest("无效的章节索引".into()))?;

    let book_id_for_chapter = book_id.clone();
    let cached = db_blocking(&state, move |conn| -> Result<CachedChapter, ApiError> {
        let chapter_dao = core_storage::chapter_dao::ChapterDao::new(conn);
        let chapters = chapter_dao
            .get_by_book(&book_id_for_chapter)
            .map_err(|e| ApiError::Database(e.to_string()))?;
        let chapter = chapters
            .get(chapter_index as usize)
            .ok_or_else(|| ApiError::NotFound(format!("章节不存在: index {}", chapter_index)))?;
        if let Some(ref content) = chapter.content {
            Ok(CachedChapter::Cached {
                title: chapter.title.clone(),
                content: content.clone(),
            })
        } else {
            Ok(CachedChapter::NeedsFetch {
                chapter_url: chapter.url.clone(),
                chapter_title: chapter.title.clone(),
                chapter_id: chapter.id.clone(),
            })
        }
    })
    .await?;

    let (chapter_url, chapter_title, chapter_id) = match cached {
        CachedChapter::Cached { title, content } => {
            return Ok(Json(ChapterContentResponse {
                book_id,
                chapter_index,
                title,
                content,
                platform_request: None,
            }));
        }
        CachedChapter::NeedsFetch {
            chapter_url,
            chapter_title,
            chapter_id,
        } => (chapter_url, chapter_title, chapter_id),
    };

    let book_id_for_book = book_id.clone();
    let chapter_url_for_check = chapter_url.clone();
    let source_id = db_blocking(&state, move |conn| {
        let dao = core_storage::book_dao::BookDao::new(conn);
        let book = dao
            .get_by_id(&book_id_for_book)
            .map_err(|e| ApiError::Database(e.to_string()))?
            .ok_or_else(|| ApiError::NotFound(format!("书籍不存在: {}", book_id_for_book)))?;
        if book.source_id.is_empty() || chapter_url_for_check.is_empty() {
            return Err(ApiError::BadRequest("缺少书源信息或章节链接".into()));
        }
        Ok(book.source_id)
    })
    .await?;

    let source_id_for_lookup = source_id.clone();
    let storage_source = db_blocking(&state, move |conn| {
        let dao = core_storage::source_dao::SourceDao::new(conn);
        dao.get_by_id(&source_id_for_lookup)
            .map_err(|e| ApiError::Database(e.to_string()))?
            .ok_or_else(|| ApiError::NotFound(format!("书源不存在: {}", source_id_for_lookup)))
    })
    .await?;

    let source = util::storage_to_core_source(&storage_source)?;
    let parser = core_source::parser::BookSourceParser::new();
    let content_result = parser.get_chapter_content(&source, &chapter_url).await;

    let (content, platform_request) = match content_result {
        Some(c) => (c.content, c.platform_request),
        None => return Err(ApiError::NotFound("章节内容为空".into())),
    };

    if platform_request.is_none() {
        let content_for_save = content.clone();
        let chapter_id_for_save = chapter_id.clone();
        db_blocking(&state, move |conn| {
            let dao = core_storage::chapter_dao::ChapterDao::new(conn);
            dao.update_content(&chapter_id_for_save, &content_for_save)
                .map_err(|e| ApiError::Database(e.to_string()))
        })
        .await?;
    }

    Ok(Json(ChapterContentResponse {
        book_id,
        chapter_index,
        title: chapter_title,
        content,
        platform_request,
    }))
}

async fn save_chapter_content(
    State(state): State<AppState>,
    Path(book_id): Path<String>,
    Json(req): Json<SaveChapterContentRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let chapter_index = req.chapter_index;
    let req_content = req.content;
    db_blocking(&state, move |conn| {
        let chapter_dao = core_storage::chapter_dao::ChapterDao::new(conn);
        let chapters = chapter_dao
            .get_by_book(&book_id)
            .map_err(|e| ApiError::Database(e.to_string()))?;
        let chapter_id = chapters
            .get(chapter_index as usize)
            .map(|chapter| chapter.id.clone())
            .ok_or_else(|| ApiError::NotFound(format!("章节不存在: index {}", chapter_index)))?;
        chapter_dao
            .update_content(&chapter_id, &req_content)
            .map_err(|e| ApiError::Database(e.to_string()))
    })
    .await?;
    Ok(Json(serde_json::json!({ "ok": true })))
}

async fn get_progress(
    State(state): State<AppState>,
    Path(book_id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let progress = db_blocking(&state, move |conn| {
        let dao = core_storage::progress_dao::ProgressDao::new(conn);
        dao.get_by_book(&book_id)
            .map_err(|e| ApiError::Database(e.to_string()))
    })
    .await?;
    Ok(Json(serde_json::to_value(progress)?))
}

async fn save_progress(
    State(state): State<AppState>,
    Path(book_id): Path<String>,
    Json(req): Json<SaveProgressRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    db_blocking(&state, move |conn| {
        let book_dao = core_storage::book_dao::BookDao::new(conn);
        book_dao
            .get_by_id(&book_id)
            .map_err(|e| ApiError::Database(e.to_string()))?
            .ok_or_else(|| ApiError::NotFound(format!("书籍不存在: {}", book_id)))?;
        let dao = core_storage::progress_dao::ProgressDao::new(conn);
        dao.update_progress(&book_id, req.chapter_index, req.paragraph_index, req.offset)
            .map_err(|e| ApiError::Database(e.to_string()))
    })
    .await?;
    Ok(Json(serde_json::json!({ "ok": true })))
}

async fn get_book(
    State(state): State<AppState>,
    Path(book_id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let book = db_blocking(&state, move |conn| {
        let dao = core_storage::book_dao::BookDao::new(conn);
        dao.get_by_id(&book_id)
            .map_err(|e| ApiError::Database(e.to_string()))?
            .ok_or_else(|| ApiError::NotFound(format!("书籍不存在: {}", book_id)))
    })
    .await?;
    Ok(Json(serde_json::to_value(book)?))
}

async fn refresh_chapters(
    State(state): State<AppState>,
    Path(book_id): Path<String>,
) -> Result<Json<RefreshChaptersResponse>, ApiError> {
    let book_id_for_lookup = book_id.clone();
    let (source_id, toc_url) = db_blocking(&state, move |conn| {
        let dao = core_storage::book_dao::BookDao::new(conn);
        let book = dao
            .get_by_id(&book_id_for_lookup)
            .map_err(|e| ApiError::Database(e.to_string()))?
            .ok_or_else(|| ApiError::NotFound(format!("书籍不存在: {}", book_id_for_lookup)))?;

        if book.source_id.is_empty() {
            return Err(ApiError::BadRequest("缺少书源信息".into()));
        }
        let url = book
            .toc_url
            .filter(|t| !t.trim().is_empty())
            .or_else(|| book.book_url.clone())
            .unwrap_or_default();
        if url.is_empty() {
            return Err(ApiError::BadRequest("缺少 book_url".into()));
        }
        Ok((book.source_id, url))
    })
    .await?;

    let source_id_for_lookup = source_id.clone();
    let storage_source = db_blocking(&state, move |conn| {
        let dao = core_storage::source_dao::SourceDao::new(conn);
        dao.get_by_id(&source_id_for_lookup)
            .map_err(|e| ApiError::Database(e.to_string()))?
            .ok_or_else(|| ApiError::NotFound(format!("书源不存在: {}", source_id_for_lookup)))
    })
    .await?;
    let source = util::storage_to_core_source(&storage_source)?;
    let parser = core_source::parser::BookSourceParser::new();
    let chapters = parser.get_chapters(&source, &toc_url).await;

    let now = chrono::Utc::now().timestamp();
    let book_id_for_chapters = book_id.clone();
    let storage_chapters: Vec<_> = chapters
        .iter()
        .enumerate()
        .map(|(i, ch)| {
            let ch_id = hash_id(&format!("{}|{}|{}", book_id_for_chapters, ch.url, i));
            core_storage::models::Chapter {
                id: ch_id,
                book_id: book_id_for_chapters.clone(),
                index_num: ch.index,
                title: ch.title.clone(),
                url: ch.url.clone(),
                content: None,
                is_volume: false,
                is_checked: false,
                start: 0,
                end: 0,
                created_at: now,
                updated_at: now,
            }
        })
        .collect();
    let total_count = chapters.len();
    let book_id_for_replace = book_id.clone();
    db_blocking(&state, move |conn| {
        let chapter_dao = core_storage::chapter_dao::ChapterDao::new(conn);
        chapter_dao
            .replace_by_book_preserving_content(&book_id_for_replace, &storage_chapters)
            .map_err(|e| ApiError::Database(e.to_string()))
    })
    .await?;

    let book_id_for_count = book_id.clone();
    db_blocking(&state, move |conn| {
        let dao = core_storage::book_dao::BookDao::new(conn);
        let mut book = dao
            .get_by_id(&book_id_for_count)
            .map_err(|e| ApiError::Database(e.to_string()))?
            .ok_or_else(|| ApiError::Internal("book not found after refresh".into()))?;
        book.chapter_count = total_count as i32;
        book.updated_at = chrono::Utc::now().timestamp();
        dao.upsert(&book)
            .map_err(|e| ApiError::Database(e.to_string()))
    })
    .await?;

    Ok(Json(RefreshChaptersResponse {
        book_id,
        total_count,
    }))
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/books/:book_id", get(get_book))
        .route(
            "/api/books/:book_id/refresh-chapters",
            post(refresh_chapters),
        )
        .route("/api/books/:book_id/chapters", get(list_chapters))
        .route(
            "/api/books/:book_id/chapters/content",
            get(get_chapter_content),
        )
        .route(
            "/api/books/:book_id/chapters/content/save",
            post(save_chapter_content),
        )
        .route(
            "/api/books/:book_id/progress",
            get(get_progress).put(save_progress),
        )
}
