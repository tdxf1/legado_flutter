mod bookshelf;
mod explore;
pub mod health;
mod reader;
mod replace_rules;
mod search;
mod sources;
mod sse;

use axum::Router;

use crate::state::AppState;

/// All protected routes. `/health` is mounted separately in `main.rs` so it
/// stays accessible without a token (k8s probes, load balancers).
pub fn routes() -> Router<AppState> {
    Router::new()
        .merge(sources::routes())
        .merge(search::routes())
        .merge(bookshelf::routes())
        .merge(reader::routes())
        .merge(replace_rules::routes())
        .merge(explore::routes())
        .merge(sse::routes())
}
