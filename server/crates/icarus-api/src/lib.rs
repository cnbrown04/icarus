//! HTTP router, handlers and middleware for `icarus-server`.

use std::time::Duration;

use axum::{
    Json, Router,
    extract::State,
    http::{HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
    routing::get,
};
use icarus_db::ReadyError;
use serde::Serialize;
use serde_json::json;
use sqlx::PgPool;
use tower::ServiceBuilder;
use tower_http::{
    compression::CompressionLayer,
    request_id::{MakeRequestUuid, PropagateRequestIdLayer, SetRequestIdLayer},
    timeout::TimeoutLayer,
    trace::TraceLayer,
};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
}

impl AppState {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/healthz", get(healthz))
        .route("/readyz", get(readyz))
        .with_state(state)
        .layer(
            ServiceBuilder::new()
                .layer(SetRequestIdLayer::x_request_id(MakeRequestUuid))
                .layer(TraceLayer::new_for_http())
                .layer(TimeoutLayer::with_status_code(
                    StatusCode::REQUEST_TIMEOUT,
                    REQUEST_TIMEOUT,
                ))
                .layer(PropagateRequestIdLayer::x_request_id())
                .layer(CompressionLayer::new()),
        )
}

async fn healthz() -> Json<serde_json::Value> {
    Json(json!({ "status": "ok" }))
}

async fn readyz(State(state): State<AppState>) -> Response {
    match icarus_db::check_ready(&state.pool).await {
        Ok(()) => Json(json!({ "status": "ready" })).into_response(),
        Err(err) => {
            tracing::warn!(error = %err, "readiness check failed");
            not_ready(&err)
        }
    }
}

/// RFC 9457 problem details. `kind` is a stable type URI.
#[derive(Serialize)]
struct Problem {
    #[serde(rename = "type")]
    kind: &'static str,
    title: &'static str,
    status: u16,
    detail: &'static str,
}

fn not_ready(err: &ReadyError) -> Response {
    let (kind, title, detail) = match err {
        ReadyError::Query(_) => (
            "urn:icarus:problem:database-unavailable",
            "Database unavailable",
            "The database could not be reached.",
        ),
        ReadyError::MigrationsPending(_) => (
            "urn:icarus:problem:migrations-pending",
            "Migrations pending",
            "Database migrations have not been applied.",
        ),
    };
    let status = StatusCode::SERVICE_UNAVAILABLE;
    let problem = Problem {
        kind,
        title,
        status: status.as_u16(),
        detail,
    };
    let mut response = (status, Json(problem)).into_response();
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/problem+json"),
    );
    response
}

#[cfg(test)]
mod tests {
    use axum::{body::Body, http::Request};
    use sqlx::postgres::PgPoolOptions;
    use tower::ServiceExt;

    use super::*;

    #[tokio::test]
    async fn healthz_returns_ok_without_touching_the_db() {
        // connect_lazy opens no connection, so this passes only if /healthz never uses the pool.
        let pool = PgPoolOptions::new()
            .connect_lazy("postgres://postgres@127.0.0.1:1/icarus")
            .expect("valid url");
        let app = router(AppState::new(pool));

        let res = app
            .oneshot(Request::get("/healthz").body(Body::empty()).unwrap())
            .await
            .unwrap();

        assert_eq!(res.status(), StatusCode::OK);
        let body = axum::body::to_bytes(res.into_body(), 1024).await.unwrap();
        assert_eq!(&body[..], br#"{"status":"ok"}"#);
    }
}
