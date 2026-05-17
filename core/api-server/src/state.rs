use r2d2::Pool;
use r2d2_sqlite::SqliteConnectionManager;

/// SQLite connection pool used by all axum handlers.
///
/// Previously every request opened a fresh `rusqlite::Connection`; the
/// concurrent search route alone could open ~30 of them in parallel for one
/// query. P3-10 swaps that for an `r2d2` pool sized to a small constant
/// (default 16) so we get connection re-use without bounding fan-out so
/// tightly that a slow query can starve health probes.
pub type SqlitePool = Pool<SqliteConnectionManager>;

#[derive(Clone)]
pub struct AppState {
    /// Kept for diagnostics / future maintenance scripts that need to open a
    /// fresh connection outside the pool. Day-to-day handlers should use
    /// [`SqlitePool`] via `state.pool` instead.
    #[allow(dead_code)]
    pub db_path: String,
    pub api_token: Option<String>,
    pub pool: SqlitePool,
}

impl AppState {
    pub fn build_pool(db_path: &str) -> Result<SqlitePool, r2d2::Error> {
        let manager = SqliteConnectionManager::file(db_path)
            .with_init(|conn| conn.execute_batch("PRAGMA foreign_keys = ON;"));
        Pool::builder().max_size(16).build(manager)
    }
}
