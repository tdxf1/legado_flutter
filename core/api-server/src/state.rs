use r2d2::Pool;
use r2d2_sqlite::SqliteConnectionManager;

/// SQLite connection pool used by all axum handlers.
///
/// Previously every request opened a fresh `rusqlite::Connection`; the
/// concurrent search route alone could open ~30 of them in parallel for one
/// query. P3-10 swaps that for an `r2d2` pool sized so handlers can all
/// own a connection simultaneously without one slow query starving the
/// rest. R58: pool size is calibrated against the search fan-out
/// semaphore so /health probes still get a free connection during a hot
/// 16-source search burst.
pub type SqlitePool = Pool<SqliteConnectionManager>;

/// Connection-pool capacity. Must be ≥ the search fan-out semaphore
/// (see `routes/search.rs::SEARCH_FANOUT`) plus a few spare slots so
/// other routes (sources CRUD, /health, etc.) aren't blocked while a
/// search is running.
pub const SQLITE_POOL_SIZE: u32 = 32;

#[derive(Clone)]
pub struct AppState {
    /// Kept for diagnostics / future maintenance scripts that need to open a
    /// fresh connection outside the pool. Day-to-day handlers should use
    /// [`SqlitePool`] via `state.pool` instead.
    #[allow(dead_code)]
    pub db_path: String,
    /// R56: token is now mandatory at startup. main() either takes the
    /// LEGADO_API_TOKEN env value or generates a UUIDv4 and logs it; we
    /// no longer accept "no token" deployments.
    pub api_token: String,
    pub pool: SqlitePool,
    /// Bind host (LEGADO_HOST). Used by [`origin_allowed`] to decide
    /// which Origin values count as same-origin.
    pub bind_host: String,
}

impl AppState {
    pub fn build_pool(db_path: &str) -> Result<SqlitePool, r2d2::Error> {
        let manager = SqliteConnectionManager::file(db_path)
            .with_init(|conn| conn.execute_batch("PRAGMA foreign_keys = ON;"));
        Pool::builder().max_size(SQLITE_POOL_SIZE).build(manager)
    }

    /// Hosts that are accepted as same-origin by the auth middleware.
    /// Always includes the bind host, plus loopback aliases when the
    /// server is bound to loopback (so the Flutter dev workflow on
    /// `127.0.0.1` works whether the request comes via localhost,
    /// 127.0.0.1 or ::1).
    pub fn allowed_origin_hosts(&self) -> Vec<&str> {
        let mut hosts = vec![self.bind_host.as_str()];
        if matches!(
            self.bind_host.as_str(),
            "127.0.0.1" | "localhost" | "::1" | "[::1]" | "0.0.0.0"
        ) {
            for h in ["127.0.0.1", "localhost", "::1"] {
                if !hosts.contains(&h) {
                    hosts.push(h);
                }
            }
        }
        hosts
    }
}
