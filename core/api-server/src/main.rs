use axum::{
    extract::DefaultBodyLimit,
    extract::{Request, State},
    http::{HeaderMap, StatusCode},
    middleware::{self, Next},
    response::Response,
    Router,
};
use tokio::net::TcpListener;
use tracing_subscriber::EnvFilter;

mod error;
mod routes;
mod state;
mod util;

use state::AppState;

fn is_loopback(host: &str) -> bool {
    host == "127.0.0.1"
        || host == "localhost"
        || host == "::1"
        || host.starts_with("127.")
        || host == "[::1]"
        || host
            .parse::<std::net::IpAddr>()
            .is_ok_and(|ip| ip.is_loopback())
}

/// R57: defence-in-depth against CSRF / DNS-rebinding to localhost.
///
/// A browser running an attacker's page can issue cross-origin requests
/// to `http://127.0.0.1:8787` even when the user thinks they're on a
/// totally unrelated site. With `mode: 'no-cors'` the attacker can't
/// read the response, but POST/DELETE side-effects already hit our DB.
///
/// We allow:
///   - Requests with no `Origin` header (typical for native clients,
///     curl, the Flutter app's `dart:io` HttpClient, etc.).
///   - Requests whose `Origin` host matches the server's bind host
///     (the user navigated directly to our origin).
///
/// Everything else is rejected. Token auth is the primary defence; this
/// is belt-and-braces.
fn origin_allowed(headers: &HeaderMap, allowed_hosts: &[&str]) -> bool {
    let Some(origin) = headers.get("origin").and_then(|v| v.to_str().ok()) else {
        return true; // no Origin header → not a browser cross-origin request
    };
    let Ok(parsed) = url::Url::parse(origin) else {
        return false; // malformed Origin
    };
    let Some(host) = parsed.host_str() else {
        return false;
    };
    allowed_hosts.iter().any(|h| h.eq_ignore_ascii_case(host))
}

async fn auth_middleware(
    State(state): State<AppState>,
    req: Request,
    next: Next,
) -> Result<Response, StatusCode> {
    // R57: Origin check runs first; if the request looks like a
    // cross-origin browser request to a host we don't recognise, refuse
    // before even looking at the token.
    if !origin_allowed(req.headers(), &state.allowed_origin_hosts()) {
        return Err(StatusCode::FORBIDDEN);
    }
    // R56: token is mandatory now (the env-var check at startup
    // guarantees `state.api_token` is `Some`). The previous "if
    // api_token.is_some()" gate let loopback-no-token deployments run
    // wide open, which made the API trivially callable from any
    // browser tab via no-cors fetch.
    let auth = req
        .headers()
        .get("Authorization")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    if auth != format!("Bearer {}", state.api_token) {
        return Err(StatusCode::UNAUTHORIZED);
    }
    Ok(next.run(req).await)
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .init();

    let db_path = std::env::var("LEGADO_DB_PATH").unwrap_or_else(|_| "./legado.db".into());
    let host = std::env::var("LEGADO_HOST").unwrap_or_else(|_| "127.0.0.1".into());
    let port = std::env::var("LEGADO_PORT").unwrap_or_else(|_| "8787".into());

    // R56: a token is now mandatory regardless of bind host. If the
    // operator hasn't supplied one, we generate a random UUIDv4 and log
    // it so a local dev session is still ergonomic. The previous
    // "loopback => no auth" exception let any browser tab hit the API.
    let api_token = std::env::var("LEGADO_API_TOKEN")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| {
            let generated = uuid::Uuid::new_v4().to_string();
            tracing::warn!(
                "LEGADO_API_TOKEN not set; generated ephemeral token for this run: {} \
                 (set LEGADO_API_TOKEN to keep a stable token across restarts)",
                generated
            );
            generated
        });
    let bind_addr = format!("{}:{}", host, port);

    tracing::info!("Initializing database at {}", db_path);
    core_storage::database::init_database(&db_path).expect("Failed to initialize database");

    core_source::legado::js_runtime::set_cache_db_path(Some(db_path.clone()));

    let pool = AppState::build_pool(&db_path).expect("Failed to build SQLite connection pool");
    let state = AppState {
        db_path,
        api_token,
        pool,
        bind_host: host.clone(),
    };

    // /health is intentionally exempt from auth so that load balancers and
    // k8s liveness probes work even with token enforcement.
    let health: Router<AppState> = Router::new()
        .route("/health", axum::routing::get(routes::health::health));

    let protected: Router<AppState> = Router::new()
        .nest("/", routes::routes())
        .layer(DefaultBodyLimit::max(5 * 1024 * 1024))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            auth_middleware,
        ));

    let app = health.merge(protected).with_state(state);

    let listener = TcpListener::bind(&bind_addr)
        .await
        .expect("Failed to bind address");

    tracing::info!(
        "API server listening on {} (loopback={})",
        bind_addr,
        is_loopback(&host)
    );
    axum::serve(listener, app).await.unwrap();
}
