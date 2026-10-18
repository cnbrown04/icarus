use std::time::Duration;

use axum::{
    body::Body,
    http::{Request, StatusCode, header},
    response::Response,
};
use icarus_api::{AppState, router};
use serde_json::Value;
use sqlx::{PgPool, postgres::PgPoolOptions};
use tower::ServiceExt;

async fn get_readyz(pool: PgPool) -> Response {
    router(AppState::new(pool))
        .oneshot(Request::get("/readyz").body(Body::empty()).unwrap())
        .await
        .unwrap()
}

async fn body_json(res: Response) -> Value {
    let bytes = axum::body::to_bytes(res.into_body(), 64 * 1024)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn readyz_returns_200_when_db_is_migrated(pool: PgPool) {
    let res = get_readyz(pool).await;

    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(
        body_json(res).await,
        serde_json::json!({ "status": "ready" })
    );
}

#[sqlx::test]
async fn readyz_returns_503_when_migrations_are_not_applied(pool: PgPool) {
    let res = get_readyz(pool).await;

    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(
        res.headers()[header::CONTENT_TYPE],
        "application/problem+json"
    );
    let body = body_json(res).await;
    assert_eq!(body["type"], "urn:icarus:problem:migrations-pending");
    assert_eq!(body["status"], 503);
}

#[tokio::test]
async fn readyz_returns_503_when_db_is_unreachable() {
    // Port 1 has no listener, so every connection attempt fails fast.
    let pool = PgPoolOptions::new()
        .acquire_timeout(Duration::from_millis(500))
        .connect_lazy("postgres://postgres@127.0.0.1:1/icarus")
        .expect("valid url");

    let res = get_readyz(pool).await;

    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(
        res.headers()[header::CONTENT_TYPE],
        "application/problem+json"
    );
    let body = body_json(res).await;
    assert_eq!(body["type"], "urn:icarus:problem:database-unavailable");
    assert_eq!(body["title"], "Database unavailable");
    assert_eq!(body["status"], 503);
    assert_eq!(body["detail"], "The database could not be reached.");
}
