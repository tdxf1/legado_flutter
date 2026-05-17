use axum::{
    extract::{Json, Path, State},
    routing::{delete, get},
    Router,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::error::ApiError;
use crate::state::AppState;
use crate::util;
use crate::util::db_blocking;

fn stable_hash(input: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(input.as_bytes()))
}

#[derive(Debug, Deserialize)]
pub struct AddBookRequest {
    pub source_id: String,
    pub source_name: Option<String>,
    pub name: String,
    pub author: Option<String>,
    pub cover_url: Option<String>,
    pub book_url: String,
}

#[derive(Debug, Serialize)]
pub struct AddBookResponse {
    pub book_id: String,
    pub chapter_count: usize,
}

async fn list_books(State(state): State<AppState>) -> Result<Json<serde_json::Value>, ApiError> {
    let books = db_blocking(&state, |conn| {
        let dao = core_storage::book_dao::BookDao::new(conn);
        dao.get_all().map_err(|e| ApiError::Database(e.to_string()))
    })
    .await?;
    Ok(Json(serde_json::to_value(books)?))
}

async fn add_book(
    State(state): State<AppState>,
    Json(req): Json<AddBookRequest>,
) -> Result<Json<AddBookResponse>, ApiError> {
    if req.source_id.trim().is_empty() {
        return Err(ApiError::BadRequest("source_id 不能为空".into()));
    }
    if req.name.trim().is_empty() {
        return Err(ApiError::BadRequest("书名不能为空".into()));
    }
    if req.book_url.trim().is_empty() {
        return Err(ApiError::BadRequest("book_url 不能为空".into()));
    }

    // Validate source and URL before writing anything
    let source_id_lookup = req.source_id.clone();
    let storage_source = db_blocking(&state, move |conn| {
        let dao = core_storage::source_dao::SourceDao::new(conn);
        dao.get_by_id(&source_id_lookup)
            .map_err(|e| ApiError::Database(e.to_string()))?
            .ok_or_else(|| ApiError::NotFound(format!("书源不存在: {}", source_id_lookup)))
    })
    .await?;
    let source = util::storage_to_core_source(&storage_source)?;
    if !core_source::parser::source_matches_url(&source, &req.book_url) {
        return Err(ApiError::BadRequest(
            "book_url 不匹配书源的 book_url_pattern".into(),
        ));
    }

    let now = chrono::Utc::now().timestamp();
    let book_id = stable_hash(&format!(
        "{}|{}|{}|{}",
        req.source_id,
        req.book_url,
        req.name,
        req.author.as_deref().unwrap_or("")
    ));

    // Save the book (initial upsert)
    let book_for_save = core_storage::models::Book {
        id: book_id.clone(),
        source_id: req.source_id.clone(),
        source_name: req.source_name.clone(),
        name: req.name.clone(),
        author: req.author.clone(),
        cover_url: req.cover_url.clone(),
        chapter_count: 0,
        latest_chapter_title: None,
        intro: None,
        kind: None,
        book_url: Some(req.book_url.clone()),
        toc_url: None,
        last_check_time: None,
        last_check_count: 0,
        total_word_count: 0,
        can_update: true,
        order_time: now,
        latest_chapter_time: None,
        custom_cover_path: None,
        custom_info_json: None,
        created_at: now,
        updated_at: now,
    };
    db_blocking(&state, move |conn| {
        let dao = core_storage::book_dao::BookDao::new(conn);
        dao.upsert(&book_for_save)
            .map_err(|e| ApiError::Database(e.to_string()))
    })
    .await?;

    // Fetch book info for toc_url and metadata (network IO — stays async)
    let parser = core_source::parser::BookSourceParser::new();
    let book_info = parser.get_book_info(&source, &req.book_url).await;
    let toc_url = book_info.as_ref().and_then(|bi| bi.chapters_url.clone());
    let chapters_url = toc_url.as_deref().unwrap_or(&req.book_url);
    let chapters = parser.get_chapters(&source, chapters_url).await;

    let chapter_count = chapters.len();
    let storage_chapters: Vec<_> = chapters
        .iter()
        .enumerate()
        .map(|(i, ch)| core_storage::models::Chapter {
            id: stable_hash(&format!("{}|{}|{}", book_id, ch.url, i)),
            book_id: book_id.clone(),
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
        })
        .collect();
    let book_id_for_chapters = book_id.clone();
    db_blocking(&state, move |conn| {
        let chapter_dao = core_storage::chapter_dao::ChapterDao::new(conn);
        chapter_dao
            .replace_by_book_preserving_content(&book_id_for_chapters, &storage_chapters)
            .map_err(|e| ApiError::Database(e.to_string()))
    })
    .await?;

    // Update book chapter count + metadata
    let book_id_for_meta = book_id.clone();
    db_blocking(&state, move |conn| {
        let dao = core_storage::book_dao::BookDao::new(conn);
        let mut book = dao
            .get_by_id(&book_id_for_meta)
            .map_err(|e| ApiError::Database(e.to_string()))?
            .ok_or_else(|| ApiError::Internal("book not found after save".into()))?;
        book.chapter_count = chapter_count as i32;
        book.updated_at = chrono::Utc::now().timestamp();
        if let Some(ref bi) = book_info {
            if bi.author != book.author.clone().unwrap_or_default() && !bi.author.is_empty() {
                book.author = Some(bi.author.clone());
            }
            if let Some(ref intro) = bi.intro {
                book.intro = Some(intro.clone());
            }
            if let Some(ref kind) = bi.kind {
                book.kind = Some(kind.clone());
            }
            if let Some(ref cover) = bi.cover_url {
                book.cover_url = Some(cover.clone());
            }
            book.toc_url = bi.chapters_url.clone();
        }
        dao.upsert(&book)
            .map_err(|e| ApiError::Database(e.to_string()))
    })
    .await?;

    Ok(Json(AddBookResponse {
        book_id,
        chapter_count,
    }))
}

async fn delete_book(
    State(state): State<AppState>,
    Path(book_id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    db_blocking(&state, move |conn| {
        let dao = core_storage::book_dao::BookDao::new(conn);
        dao.get_by_id(&book_id)
            .map_err(|e| ApiError::Database(e.to_string()))?
            .ok_or_else(|| ApiError::NotFound(format!("书籍不存在: {}", book_id)))?;
        dao.delete(&book_id)
            .map_err(|e| ApiError::Database(e.to_string()))
    })
    .await?;
    Ok(Json(serde_json::json!({ "ok": true })))
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/bookshelf", get(list_books).post(add_book))
        .route("/api/bookshelf/:book_id", delete(delete_book))
}
