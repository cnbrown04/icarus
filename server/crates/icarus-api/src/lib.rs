//! HTTP router, handlers and middleware for `icarus-server` (api-contract.md, PLAN.md §12).

pub mod accounts;
pub mod auth;
pub mod error;
pub mod extract;
pub mod ratelimit;
pub mod routes;
pub mod secrets;
pub mod state;

use std::time::Duration;

use axum::{
    Json, Router,
    extract::State,
    middleware::from_fn_with_state,
    response::{IntoResponse, Response},
    routing::{any, delete, get, patch, post, put},
};
use icarus_db::ReadyError;
use serde_json::json;
use tower::ServiceBuilder;
use tower_http::{
    compression::CompressionLayer,
    decompression::RequestDecompressionLayer,
    request_id::{MakeRequestUuid, PropagateRequestIdLayer, SetRequestIdLayer},
    services::{ServeDir, ServeFile},
    timeout::TimeoutLayer,
    trace::TraceLayer,
};

pub use accounts::{CreateUserError, create_user};
pub use error::ApiError;
pub use secrets::Secrets;
pub use state::{AppState, Config};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);

pub fn router(state: AppState) -> Router {
    let web_dir = state.config.web_dir.clone().filter(|dir| dir.is_dir());

    let mut app = Router::new()
        .route("/healthz", get(healthz))
        .route("/readyz", get(readyz))
        .route("/v1/auth/login", post(routes::auth::login))
        .route("/v1/auth/logout", post(routes::auth::logout))
        .route(
            "/v1/me",
            get(routes::me::get_me)
                .patch(routes::me::patch_me)
                .delete(routes::me::delete_me),
        )
        .route("/v1/devices", get(routes::devices::list))
        .route(
            "/v1/devices/pairing-codes",
            post(routes::devices::create_pairing_code),
        )
        .route("/v1/devices/pair", post(routes::devices::pair))
        .route(
            "/v1/devices/me/push-token",
            put(routes::devices::put_push_token),
        )
        .route("/v1/devices/{id}", delete(routes::devices::revoke))
        // Gzip request bodies are decoded here. The 2 MB limit applies to the decoded bytes.
        .route(
            "/v1/sync/batches",
            post(routes::sync::post_batch).layer(RequestDecompressionLayer::new()),
        )
        .route("/v1/sync/config", get(routes::sync::get_config))
        .route("/v1/sync/state", get(routes::sync::get_state))
        .route("/v1/metrics/hr", get(routes::metrics::hr))
        .route("/v1/metrics/minutes", get(routes::metrics::minutes))
        .route("/v1/metrics/daily", get(routes::metrics::daily))
        .route("/v1/metrics/live", get(routes::metrics::live))
        .route(
            "/v1/alarms",
            get(routes::alarms::list).post(routes::alarms::create),
        )
        // Before `/v1/alarms/{id}`: `pending` is a fixed segment, so it wins for GET.
        .route("/v1/alarms/pending", get(routes::dispatches::pending))
        .route(
            "/v1/alarms/{id}",
            patch(routes::alarms::patch).delete(routes::alarms::delete),
        )
        .route("/v1/alarms/{id}/test", post(routes::alarms::test))
        .route("/v1/alarm-dispatches", get(routes::dispatches::list))
        .route(
            "/v1/alarm-dispatches/{id}/ack",
            post(routes::dispatches::ack),
        )
        .route(
            "/v1/hooks",
            get(routes::hooks::list).post(routes::hooks::create),
        )
        // One path, three meanings: management takes the hook id, and the public ingress takes the slug.
        .route(
            "/v1/hooks/{key}",
            patch(routes::hooks::patch)
                .delete(routes::hooks::delete)
                .post(routes::ingress::post_signed),
        )
        .route("/v1/hooks/{key}/rotate-secret", post(routes::hooks::rotate))
        .route("/v1/hooks/{key}/deliveries", get(routes::hooks::deliveries))
        .route(
            "/v1/hooks/{key}/{secret}",
            post(routes::ingress::post_secret),
        )
        .route("/v1/export", get(routes::export::export))
        // Unknown API paths get a problem response, never the SPA page.
        .route("/v1", any(api_not_found))
        .route("/v1/{*rest}", any(api_not_found));

    app = match web_dir {
        Some(dir) => {
            let index = dir.join("index.html");
            app.fallback_service(ServeDir::new(&dir).fallback(ServeFile::new(index)))
        }
        None => app.fallback(api_not_found),
    };

    app.layer(from_fn_with_state(
        state.clone(),
        auth::refresh_session_cookie,
    ))
    .layer(
        ServiceBuilder::new()
            .layer(SetRequestIdLayer::x_request_id(MakeRequestUuid))
            .layer(TraceLayer::new_for_http())
            .layer(TimeoutLayer::with_status_code(
                axum::http::StatusCode::REQUEST_TIMEOUT,
                REQUEST_TIMEOUT,
            ))
            .layer(PropagateRequestIdLayer::x_request_id())
            .layer(CompressionLayer::new()),
    )
    .with_state(state)
}

async fn api_not_found() -> ApiError {
    ApiError::NotFound
}

async fn healthz() -> Json<serde_json::Value> {
    Json(json!({ "status": "ok" }))
}

async fn readyz(State(state): State<AppState>) -> Response {
    match icarus_db::check_ready(&state.pool).await {
        Ok(()) => Json(json!({ "status": "ready" })).into_response(),
        Err(err) => {
            tracing::warn!(error = %err, "readiness check failed");
            // Only the variant leaves this function. The driver message stays in the log.
            let err: ApiError = match err {
                ReadyError::Query(_) => ApiError::DatabaseUnavailable,
                ReadyError::MigrationsPending(_) => ApiError::MigrationsPending,
            };
            err.into_response()
        }
    }
}
