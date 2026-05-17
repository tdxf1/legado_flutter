//! Server-Sent Events 路由
//!
//! 提供两类长连接：
//! - `GET /api/search/sse?q=keyword&sources=id1,id2`
//!   多书源并发搜索流式返回。每收到一条结果就 yield 一次 `event: result`。
//!   全部完成后 yield `event: done`。
//! - `GET /api/logs/sse`
//!   订阅一个进程内 broadcast 频道，把 Rust 侧 `tracing` 的日志推送到客户端。
//!   **当前是占位实现**：只发 `event: heartbeat`，没有真正接进 tracing 层。
//!   要做真正的日志推送需要：(1) 注册一个 tracing layer 把事件投到
//!   `tokio::sync::broadcast`，(2) 在这里订阅 receiver 并 yield 出去。
//!   作为占位保留是为了让前端 SSE 客户端有连通性测试目标 (R62)。
//!
//! 协议要点：
//! - 一条 SSE 消息形如：`event: result\ndata: {...json...}\n\n`
//! - 客户端断开会让 `tokio::sync::broadcast::Receiver` drop，自动清理资源
//! - SSE 自带 `Last-Event-ID` 头部，后续可用于断点续传

use axum::{
    extract::{Query, State},
    response::sse::{Event, KeepAlive, Sse},
    routing::get,
    Router,
};
use futures::stream::{self, Stream};
use serde::Deserialize;
use serde_json::json;
use std::convert::Infallible;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{mpsc, Semaphore};
use tokio::task::JoinSet;
use tokio_stream::{wrappers::ReceiverStream, StreamExt};

use crate::error::ApiError;
use crate::routes::search::SEARCH_FANOUT;
use crate::state::AppState;
use crate::util;

#[derive(Debug, Deserialize)]
struct SearchSseQuery {
    q: String,
    /// 逗号分隔的 source_id 列表；缺省则用全部已启用书源
    sources: Option<String>,
}

/// 多书源搜索流式：每个书源结果到达时立即 yield；最后 yield 一条 done。
async fn search_sse(
    State(state): State<AppState>,
    Query(query): Query<SearchSseQuery>,
) -> Result<Sse<impl Stream<Item = Result<Event, Infallible>>>, ApiError> {
    if query.q.trim().is_empty() {
        return Err(ApiError::BadRequest("搜索关键词不能为空".into()));
    }

    let source_ids: Vec<String> = if let Some(ref ids) = query.sources {
        ids.split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect()
    } else {
        // R60: synchronous DAO call moved off the tokio worker.
        crate::util::db_blocking(&state, |conn| {
            let dao = core_storage::source_dao::SourceDao::new(conn);
            dao.get_enabled()
                .map_err(|e| ApiError::Database(e.to_string()))
                .map(|sources| sources.into_iter().map(|s| s.id).collect::<Vec<_>>())
        })
        .await?
    };

    // 用 mpsc 在 tasks 与 SSE stream 之间传消息。
    let (tx, rx) = mpsc::channel::<Event>(64);
    let keyword = query.q.clone();
    let pool = state.pool.clone();

    tokio::spawn(async move {
        // R61: cap concurrent downstream fetches so a request that lists
        // 100+ sources can't drain the SQLite pool or hammer remote
        // servers in lockstep. Same fan-out cap as the non-SSE search
        // route — both share the pool budget calibrated by
        // [`crate::state::SQLITE_POOL_SIZE`].
        let semaphore = Arc::new(Semaphore::new(SEARCH_FANOUT));
        let mut join_set = JoinSet::new();
        for sid in source_ids {
            let pool = pool.clone();
            let keyword = keyword.clone();
            let semaphore = semaphore.clone();
            join_set.spawn(async move {
                let _permit = match semaphore.acquire_owned().await {
                    Ok(p) => p,
                    Err(_) => {
                        return Err((
                            sid.clone(),
                            String::new(),
                            "信号量获取失败".to_string(),
                        ));
                    }
                };
                run_one(&pool, &sid, &keyword).await
            });
        }
        while let Some(joined) = join_set.join_next().await {
            let event = match joined {
                Ok(Ok((sid, items))) => Event::default()
                    .event("result")
                    .data(
                        json!({
                            "source_id": sid,
                            "items": items,
                        })
                        .to_string(),
                    ),
                Ok(Err((sid, name, err))) => Event::default()
                    .event("error")
                    .data(
                        json!({
                            "source_id": sid,
                            "source_name": name,
                            "error": err,
                        })
                        .to_string(),
                    ),
                Err(e) => Event::default()
                    .event("error")
                    .data(json!({ "error": format!("task join failed: {e}") }).to_string()),
            };
            if tx.send(event).await.is_err() {
                break;
            }
        }
        let _ = tx
            .send(Event::default().event("done").data("{}".to_string()))
            .await;
    });

    let stream = ReceiverStream::new(rx).map(Ok);
    Ok(Sse::new(stream).keep_alive(
        KeepAlive::new()
            .interval(Duration::from_secs(15))
            .text("ping"),
    ))
}

#[allow(clippy::type_complexity)]
async fn run_one(
    pool: &crate::state::SqlitePool,
    source_id: &str,
    keyword: &str,
) -> Result<(String, Vec<core_source::parser::SearchResult>), (String, String, String)> {
    // R60: DB row lookup moved off the tokio worker via spawn_blocking.
    // We can't reuse `db_blocking` here because the error type for this
    // fan-out routine is a custom tuple, not `ApiError`.
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
    // R82: precise error mapping — Empty becomes "0 results" (legitimate
    // success), other ParserError variants surface as the source's
    // failed_sources entry so the SSE client can show "源 X 失败: 网络
    // 超时" instead of just "0 results".
    match parser.search(&source, keyword).await {
        Ok(items) => Ok((source_id.to_string(), items)),
        Err(core_source::ParserError::Empty) => Ok((source_id.to_string(), Vec::new())),
        Err(e) => Err((source_id.to_string(), source_name, e.to_string())),
    }
}

/// 日志流：心跳 + 钩子位（后续可扩展为 tracing layer / broadcast）
async fn logs_sse() -> Sse<impl Stream<Item = Result<Event, Infallible>>> {
    let s = stream::unfold(0usize, |seq| async move {
        // 每 5 秒发送一次心跳，保活并提供基本可观测性
        tokio::time::sleep(Duration::from_secs(5)).await;
        let event = Event::default()
            .event("heartbeat")
            .data(json!({ "seq": seq, "ts": chrono::Utc::now().timestamp() }).to_string());
        Some((Ok::<_, Infallible>(event), seq + 1))
    });
    Sse::new(s).keep_alive(
        KeepAlive::new()
            .interval(Duration::from_secs(15))
            .text("ping"),
    )
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/search/sse", get(search_sse))
        .route("/api/logs/sse", get(logs_sse))
}
