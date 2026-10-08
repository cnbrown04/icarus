//! Shared helpers for the API integration tests. Requests go through the router in-process.
#![allow(dead_code)]

use axum::{
    Router,
    body::Body,
    http::{HeaderMap, Request, Response, StatusCode},
};
use http_body_util::BodyExt;
use icarus_api::{AppState, Config, Secrets, create_user, router};
use serde_json::Value;
use sqlx::PgPool;
use tower::ServiceExt;
use uuid::Uuid;

pub const EMAIL: &str = "caleb@example.com";
pub const PASSWORD: &str = "correct horse battery";

pub fn app(pool: PgPool) -> Router {
    router(AppState::with_config(pool, Config::default()))
}

pub fn app_with(pool: PgPool, config: Config) -> Router {
    router(AppState::with_config(pool, config))
}

/// Test-only key. Production keys come from `ICARUS_ENC_KEY`.
pub fn app_with_key(pool: PgPool) -> Router {
    app_with(
        pool,
        Config {
            secrets: Some(Secrets::new([9; 32])),
            ..Config::default()
        },
    )
}

pub async fn setup_user(pool: &PgPool) -> Uuid {
    create_user(pool, EMAIL, PASSWORD)
        .await
        .expect("user created")
}

pub async fn send(app: &Router, req: Request<Body>) -> Response<Body> {
    app.clone().oneshot(req).await.expect("infallible service")
}

pub fn request(
    method: &str,
    uri: &str,
    headers: &[(&str, &str)],
    body: Option<Value>,
) -> Request<Body> {
    let mut builder = Request::builder().method(method).uri(uri);
    for (name, value) in headers {
        builder = builder.header(*name, *value);
    }
    match body {
        Some(json) => builder
            .header("content-type", "application/json")
            .body(Body::from(json.to_string()))
            .unwrap(),
        None => builder.body(Body::empty()).unwrap(),
    }
}

/// Cookie request with the CSRF header that writes need.
pub fn web(method: &str, uri: &str, cookie: &str, body: Option<Value>) -> Request<Body> {
    request(
        method,
        uri,
        &[("cookie", cookie), ("x-icarus-csrf", "1")],
        body,
    )
}

pub fn device(method: &str, uri: &str, token: &str, body: Option<Value>) -> Request<Body> {
    let bearer = format!("Bearer {token}");
    request(method, uri, &[("authorization", bearer.as_str())], body)
}

pub fn anon(method: &str, uri: &str, body: Option<Value>) -> Request<Body> {
    request(method, uri, &[], body)
}

pub async fn body_bytes(res: Response<Body>) -> Vec<u8> {
    res.into_body()
        .collect()
        .await
        .expect("body readable")
        .to_bytes()
        .to_vec()
}

pub async fn json(res: Response<Body>) -> Value {
    let bytes = body_bytes(res).await;
    serde_json::from_slice(&bytes)
        .unwrap_or_else(|e| panic!("not JSON ({e}): {}", String::from_utf8_lossy(&bytes)))
}

/// Asserts a problem+json response with the given slug, and returns its status and body.
pub async fn expect_problem(res: Response<Body>, status: StatusCode, slug: &str) -> Value {
    assert_eq!(res.status(), status);
    assert_eq!(res.headers()["content-type"], "application/problem+json");
    let body = json(res).await;
    assert_eq!(body["type"], format!("urn:icarus:problem:{slug}"), "{body}");
    assert_eq!(body["status"], status.as_u16(), "{body}");
    body
}

/// `icarus_session=<token>` from a login response, ready for a Cookie header.
pub fn session_cookie(headers: &HeaderMap) -> String {
    headers
        .get_all("set-cookie")
        .iter()
        .filter_map(|v| v.to_str().ok())
        .find(|v| v.starts_with("icarus_session="))
        .and_then(|v| v.split(';').next())
        .expect("session cookie set")
        .to_owned()
}

pub async fn login(app: &Router) -> String {
    let res = send(
        app,
        anon(
            "POST",
            "/v1/auth/login",
            Some(serde_json::json!({ "email": EMAIL, "password": PASSWORD })),
        ),
    )
    .await;
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
    session_cookie(res.headers())
}

/// Pairs a new device for the signed-in web session. Returns (device id, token).
pub async fn pair_device(app: &Router, cookie: &str, name: &str) -> (String, String) {
    let res = send(app, web("POST", "/v1/devices/pairing-codes", cookie, None)).await;
    assert_eq!(res.status(), StatusCode::OK);
    let code = json(res).await["code"].as_str().unwrap().to_owned();
    pair_with_code(app, &code, name).await
}

pub async fn pair_with_code(app: &Router, code: &str, name: &str) -> (String, String) {
    let res = send(
        app,
        anon(
            "POST",
            "/v1/devices/pair",
            Some(serde_json::json!({
                "code": code, "name": name, "model": "iPhone17,2", "os_version": "26.0", "app_version": "1.0"
            })),
        ),
    )
    .await;
    assert_eq!(res.status(), StatusCode::CREATED);
    let body = json(res).await;
    (
        body["device_id"].as_str().unwrap().to_owned(),
        body["token"].as_str().unwrap().to_owned(),
    )
}

pub async fn user_id(pool: &PgPool) -> Uuid {
    sqlx::query_scalar("SELECT id FROM users WHERE email = $1")
        .bind(EMAIL)
        .fetch_one(pool)
        .await
        .expect("user exists")
}

pub fn ms(rfc3339: &str) -> i64 {
    chrono::DateTime::parse_from_rfc3339(rfc3339)
        .unwrap()
        .timestamp_millis()
}
