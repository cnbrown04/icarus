//! WHOOP integration against a local mock of the WHOOP API (PLAN.md §5.2, §6.3, §12.6).
//! The mock rotates tokens on refresh, the way WHOOP does, and counts calls so tests can assert them.

mod common;

use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::Duration,
};

use axum::{
    Json, Router,
    extract::{Form, Path, Query, State},
    http::{HeaderMap, StatusCode, header::AUTHORIZATION},
    response::{IntoResponse, Response},
    routing::{delete, get, post},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use common::*;
use hmac::{Hmac, Mac};
use icarus_api::{Config, Secrets, WhoopConfig};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::Sha256;
use sqlx::PgPool;
use tokio::net::TcpListener;

const CLIENT_ID: &str = "client-id";
const CLIENT_SECRET: &str = "whoop-client-secret";
const CODE: &str = "good-code";
const SCOPE_GRANTED: &str =
    "offline read:recovery read:cycles read:workout read:sleep read:profile read:body_measurement";

#[derive(Default)]
struct MockState {
    access: Option<String>,
    refresh: Option<String>,
    issued: u32,
    token_calls: u32,
    refresh_calls: u32,
    revoke_calls: u32,
    last_cycle_query: HashMap<String, String>,
    /// Delay before a token answer, so two callers overlap at the mock.
    token_delay: Duration,
    /// When set, the cycle collection is empty.
    no_cycles: bool,
}

type Shared = Arc<Mutex<MockState>>;

struct Mock {
    url: String,
    state: Shared,
}

impl Mock {
    fn with<T>(&self, f: impl FnOnce(&mut MockState) -> T) -> T {
        f(&mut self.state.lock().unwrap())
    }
}

#[derive(Deserialize)]
struct TokenForm {
    grant_type: String,
    code: Option<String>,
    refresh_token: Option<String>,
    client_id: Option<String>,
    client_secret: Option<String>,
}

async fn token(State(shared): State<Shared>, Form(form): Form<TokenForm>) -> Response {
    if form.client_id.as_deref() != Some(CLIENT_ID)
        || form.client_secret.as_deref() != Some(CLIENT_SECRET)
    {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let delay = shared.lock().unwrap().token_delay;
    tokio::time::sleep(delay).await;
    let mut m = shared.lock().unwrap();
    m.token_calls += 1;
    let accepted = match form.grant_type.as_str() {
        "authorization_code" => form.code.as_deref() == Some(CODE),
        "refresh_token" => {
            m.refresh_calls += 1;
            m.refresh.is_some() && form.refresh_token == m.refresh
        }
        _ => false,
    };
    if !accepted {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "invalid_grant" })),
        )
            .into_response();
    }
    m.issued += 1;
    let access = format!("access-{}", m.issued);
    let refresh = format!("refresh-{}", m.issued);
    m.access = Some(access.clone());
    m.refresh = Some(refresh.clone());
    Json(json!({
        "access_token": access,
        "refresh_token": refresh,
        "expires_in": 3600,
        "scope": SCOPE_GRANTED,
    }))
    .into_response()
}

fn bearer_ok(m: &MockState, headers: &HeaderMap) -> bool {
    let presented = headers
        .get(AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "));
    presented.is_some() && presented == m.access.as_deref()
}

async fn profile(State(shared): State<Shared>, headers: HeaderMap) -> Response {
    let m = shared.lock().unwrap();
    if !bearer_ok(&m, &headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    Json(json!({ "user_id": 4242, "first_name": "Caleb" })).into_response()
}

async fn cycles(
    State(shared): State<Shared>,
    headers: HeaderMap,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let mut m = shared.lock().unwrap();
    if !bearer_ok(&m, &headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    m.last_cycle_query = query;
    if m.no_cycles {
        return Json(json!({ "records": [] })).into_response();
    }
    Json(json!({
        "records": [{ "id": 77, "score": { "strain": 12.4, "kilojoule": 8123.5 } }],
        "next_token": null
    }))
    .into_response()
}

async fn recovery(
    State(shared): State<Shared>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Response {
    let m = shared.lock().unwrap();
    if !bearer_ok(&m, &headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    if id != "77" {
        return StatusCode::NOT_FOUND.into_response();
    }
    Json(json!({
        "score": { "recovery_score": 67.0, "resting_heart_rate": 52.0, "hrv_rmssd_milli": 88.1 }
    }))
    .into_response()
}

async fn sleep(
    State(shared): State<Shared>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Response {
    let m = shared.lock().unwrap();
    if !bearer_ok(&m, &headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    if id != "77" {
        return StatusCode::NOT_FOUND.into_response();
    }
    Json(json!({ "score": { "sleep_performance_percentage": 91.0 } })).into_response()
}

async fn revoke(State(shared): State<Shared>, headers: HeaderMap) -> Response {
    let mut m = shared.lock().unwrap();
    if !bearer_ok(&m, &headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    m.revoke_calls += 1;
    m.access = None;
    m.refresh = None;
    StatusCode::NO_CONTENT.into_response()
}

async fn spawn_mock() -> Mock {
    let shared: Shared = Shared::default();
    let app = Router::new()
        .route("/oauth/oauth2/token", post(token))
        .route("/developer/v2/user/profile/basic", get(profile))
        .route("/developer/v2/cycle", get(cycles))
        .route("/developer/v2/cycle/{id}/recovery", get(recovery))
        .route("/developer/v2/cycle/{id}/sleep", get(sleep))
        .route("/developer/v2/oauth/revoke", delete(revoke))
        .with_state(shared.clone());
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    Mock { url, state: shared }
}

fn whoop_config(api_base: &str) -> WhoopConfig {
    WhoopConfig::new(CLIENT_ID, CLIENT_SECRET)
        .with_api_base(api_base)
        .expect("mock URL is valid")
}

fn enabled_config(mock: &Mock) -> Config {
    Config {
        secrets: Some(Secrets::new([9; 32])),
        whoop: Some(whoop_config(&mock.url)),
        ..Config::default()
    }
}

/// Signs in, connects through the real routes, and returns the session cookie.
async fn connected(app: &Router) -> String {
    let cookie = login(app).await;
    let res = send(
        app,
        web("GET", "/v1/integrations/whoop/connect", &cookie, None),
    )
    .await;
    assert_eq!(res.status(), StatusCode::FOUND);
    let state = query_param(res.headers()["location"].to_str().unwrap(), "state");
    let res = send(
        app,
        anon(
            "GET",
            &format!("/v1/integrations/whoop/callback?code={CODE}&state={state}"),
            None,
        ),
    )
    .await;
    assert_eq!(res.status(), StatusCode::FOUND);
    assert_eq!(res.headers()["location"], "/integrations/whoop");
    cookie
}

fn query_param(url: &str, name: &str) -> String {
    reqwest::Url::parse(url)
        .expect("absolute URL")
        .query_pairs()
        .find(|(k, _)| k == name)
        .map(|(_, v)| v.into_owned())
        .unwrap_or_else(|| panic!("no {name} in {url}"))
}

async fn count(pool: &PgPool, table: &str) -> i64 {
    sqlx::query_scalar(&format!("SELECT count(*) FROM {table}"))
        .fetch_one(pool)
        .await
        .unwrap()
}

/// Makes the access token look close to expiry, so the next call refreshes.
async fn expire_access(pool: &PgPool) {
    sqlx::query("UPDATE whoop_connections SET expires_at = now() - interval '1 minute'")
        .execute(pool)
        .await
        .unwrap();
}

fn sign(secret: &str, timestamp: &str, body: &[u8]) -> String {
    let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).unwrap();
    mac.update(timestamp.as_bytes());
    mac.update(body);
    STANDARD.encode(mac.finalize().into_bytes())
}

fn webhook_request(
    trace: &str,
    user: i64,
    kind: &str,
    timestamp: &str,
    signature: &str,
) -> axum::http::Request<axum::body::Body> {
    let body =
        json!({ "user_id": user, "id": "obj-1", "type": kind, "trace_id": trace }).to_string();
    axum::http::Request::builder()
        .method("POST")
        .uri("/v1/integrations/whoop/webhook")
        .header("content-type", "application/json")
        .header("x-whoop-signature-timestamp", timestamp)
        .header("x-whoop-signature", signature)
        .body(axum::body::Body::from(body))
        .unwrap()
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn disabled_integration_answers_not_found_before_auth(pool: PgPool) {
    setup_user(&pool).await;
    let app = app(pool);
    for (method, uri) in [
        ("GET", "/v1/integrations/whoop"),
        ("GET", "/v1/integrations/whoop/connect"),
        ("GET", "/v1/integrations/whoop/callback?code=x&state=y"),
        ("POST", "/v1/integrations/whoop/webhook"),
        ("GET", "/v1/integrations/whoop/summary?day=2026-10-07"),
        ("DELETE", "/v1/integrations/whoop"),
    ] {
        // No cookie: a disabled route must not say 401 first.
        let res = send(&app, anon(method, uri, None)).await;
        expect_problem(res, StatusCode::NOT_FOUND, "not-found").await;
    }
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn connect_redirects_with_an_8_char_state_and_stores_it(pool: PgPool) {
    let user = setup_user(&pool).await;
    let mock = spawn_mock().await;
    let app = app_with(pool.clone(), enabled_config(&mock));
    let cookie = login(&app).await;

    let res = send(
        &app,
        web("GET", "/v1/integrations/whoop/connect", &cookie, None),
    )
    .await;
    assert_eq!(res.status(), StatusCode::FOUND);
    let location = res.headers()["location"].to_str().unwrap().to_owned();
    assert!(
        location.starts_with(&format!("{}/oauth/oauth2/auth?", mock.url)),
        "{location}"
    );
    assert_eq!(query_param(&location, "client_id"), CLIENT_ID);
    assert_eq!(query_param(&location, "response_type"), "code");
    assert_eq!(
        query_param(&location, "redirect_uri"),
        "http://localhost:8080/v1/integrations/whoop/callback"
    );
    assert_eq!(query_param(&location, "scope"), SCOPE_GRANTED);
    let state = query_param(&location, "state");
    assert_eq!(state.len(), 8, "8-character state (PLAN.md §5.2)");
    assert!(state.chars().all(|c| c.is_ascii_alphanumeric()));

    let stored: Option<uuid::Uuid> =
        sqlx::query_scalar("SELECT user_id FROM oauth_states WHERE state = $1")
            .bind(&state)
            .fetch_optional(&pool)
            .await
            .unwrap();
    assert_eq!(stored, Some(user));

    let status = json(send(&app, web("GET", "/v1/integrations/whoop", &cookie, None)).await).await;
    assert_eq!(status["connected"], false);
    assert_eq!(status["scopes"], json!([]));
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn callback_exchanges_code_and_stores_encrypted_tokens(pool: PgPool) {
    setup_user(&pool).await;
    let mock = spawn_mock().await;
    let app = app_with(pool.clone(), enabled_config(&mock));
    let cookie = connected(&app).await;

    let status = json(send(&app, web("GET", "/v1/integrations/whoop", &cookie, None)).await).await;
    assert_eq!(status["connected"], true);
    assert_eq!(status["scopes"].as_array().unwrap().len(), 7);
    assert!(status["connected_at"].is_string());
    assert_eq!(status["last_webhook_at"], Value::Null);

    let (access_ct, refresh_ct, whoop_user): (Vec<u8>, Vec<u8>, i64) = sqlx::query_as(
        "SELECT access_token_ct, refresh_token_ct, whoop_user_id FROM whoop_connections",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(whoop_user, 4242);
    assert_ne!(access_ct, b"access-1".to_vec(), "ciphertext, not plaintext");
    assert!(!access_ct.windows(8).any(|w| w == b"access-1"));
    assert!(!refresh_ct.windows(9).any(|w| w == b"refresh-1"));

    let used: i64 = count(&pool, "oauth_states").await;
    assert_eq!(used, 0, "state is deleted once used");
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn state_is_single_use_and_expires_after_ten_minutes(pool: PgPool) {
    setup_user(&pool).await;
    let mock = spawn_mock().await;
    let app = app_with(pool.clone(), enabled_config(&mock));
    let cookie = login(&app).await;

    let connect = |app: &Router| {
        let app = app.clone();
        let cookie = cookie.clone();
        async move {
            let res = send(
                &app,
                web("GET", "/v1/integrations/whoop/connect", &cookie, None),
            )
            .await;
            query_param(res.headers()["location"].to_str().unwrap(), "state")
        }
    };

    let state = connect(&app).await;
    let uri = format!("/v1/integrations/whoop/callback?code={CODE}&state={state}");
    assert_eq!(
        send(&app, anon("GET", &uri, None)).await.status(),
        StatusCode::FOUND
    );
    let reused = send(&app, anon("GET", &uri, None)).await;
    expect_problem(reused, StatusCode::BAD_REQUEST, "validation").await;

    let stale = connect(&app).await;
    sqlx::query(
        "UPDATE oauth_states SET created_at = now() - interval '11 minutes' WHERE state = $1",
    )
    .bind(&stale)
    .execute(&pool)
    .await
    .unwrap();
    let res = send(
        &app,
        anon(
            "GET",
            &format!("/v1/integrations/whoop/callback?code={CODE}&state={stale}"),
            None,
        ),
    )
    .await;
    expect_problem(res, StatusCode::BAD_REQUEST, "validation").await;

    let res = send(
        &app,
        anon(
            "GET",
            "/v1/integrations/whoop/callback?code=x&state=unknown1",
            None,
        ),
    )
    .await;
    expect_problem(res, StatusCode::BAD_REQUEST, "validation").await;
    assert_eq!(
        mock.with(|m| m.token_calls),
        1,
        "only the first callback reached WHOOP"
    );
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn webhook_checks_signature_and_dedupes_by_trace_id(pool: PgPool) {
    setup_user(&pool).await;
    let mock = spawn_mock().await;
    let app = app_with(pool.clone(), enabled_config(&mock));
    let cookie = connected(&app).await;

    let ts = "1790000000";
    let good = sign(
        CLIENT_SECRET,
        ts,
        json!({ "user_id": 4242, "id": "obj-1", "type": "sleep.updated", "trace_id": "trace-1" })
            .to_string()
            .as_bytes(),
    );
    let res = send(
        &app,
        webhook_request("trace-1", 4242, "sleep.updated", ts, &good),
    )
    .await;
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
    assert_eq!(count(&pool, "whoop_webhook_events").await, 1);

    // Same trace id again: acknowledged, not stored twice.
    let res = send(
        &app,
        webhook_request("trace-1", 4242, "sleep.updated", ts, &good),
    )
    .await;
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
    assert_eq!(count(&pool, "whoop_webhook_events").await, 1);

    // A signature made with another secret, or over another timestamp, is refused and stores nothing.
    let wrong = sign("not-the-secret", ts, b"{}");
    let res = send(
        &app,
        webhook_request("trace-2", 4242, "sleep.updated", ts, &wrong),
    )
    .await;
    expect_problem(res, StatusCode::UNAUTHORIZED, "signature-invalid").await;
    let retimed = sign(
        CLIENT_SECRET,
        "1790000999",
        json!({ "user_id": 4242, "id": "obj-1", "type": "sleep.updated", "trace_id": "trace-2" })
            .to_string()
            .as_bytes(),
    );
    let res = send(
        &app,
        webhook_request("trace-2", 4242, "sleep.updated", ts, &retimed),
    )
    .await;
    expect_problem(res, StatusCode::UNAUTHORIZED, "signature-invalid").await;
    assert_eq!(count(&pool, "whoop_webhook_events").await, 1);

    // Events for a WHOOP user we are not connected to are acknowledged and dropped.
    let other = sign(
        CLIENT_SECRET,
        ts,
        json!({ "user_id": 9, "id": "obj-1", "type": "recovery.updated", "trace_id": "trace-9" })
            .to_string()
            .as_bytes(),
    );
    let res = send(
        &app,
        webhook_request("trace-9", 9, "recovery.updated", ts, &other),
    )
    .await;
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
    assert_eq!(count(&pool, "whoop_webhook_events").await, 1);

    let status = json(send(&app, web("GET", "/v1/integrations/whoop", &cookie, None)).await).await;
    assert!(status["last_webhook_at"].is_string(), "{status}");
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn summary_maps_live_values_and_writes_nothing(pool: PgPool) {
    setup_user(&pool).await;
    let mock = spawn_mock().await;
    let app = app_with(pool.clone(), enabled_config(&mock));
    let cookie = connected(&app).await;

    let tables = [
        "whoop_webhook_events",
        "oauth_states",
        "minute_metrics",
        "daily_summaries",
        "hr_samples",
        "rr_intervals",
        "band_events",
        "alarms",
    ];
    let mut before = Vec::new();
    for table in tables {
        before.push(count(&pool, table).await);
    }
    let connection_before: Vec<u8> =
        sqlx::query_scalar("SELECT access_token_ct FROM whoop_connections")
            .fetch_one(&pool)
            .await
            .unwrap();

    let res = send(
        &app,
        web(
            "GET",
            "/v1/integrations/whoop/summary?day=2026-10-07",
            &cookie,
            None,
        ),
    )
    .await;
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(res.headers()["cache-control"], "no-store");
    let body = json(res).await;
    assert_eq!(
        body,
        json!({
            "recovery_score": 67.0,
            "hrv_rmssd_milli": 88.1,
            "resting_heart_rate": 52.0,
            "strain": 12.4,
            "kilojoule": 8123.5,
            "sleep_performance": 91.0
        })
    );

    // Day window: midnight to midnight in the user's zone (America/Chicago, CDT in October).
    let query = mock.with(|m| m.last_cycle_query.clone());
    assert_eq!(query["start"], "2026-10-07T05:00:00Z");
    assert_eq!(query["end"], "2026-10-08T05:00:00Z");
    assert_eq!(
        mock.with(|m| m.refresh_calls),
        0,
        "fresh token is not refreshed"
    );

    for (table, expected) in tables.iter().zip(before) {
        assert_eq!(count(&pool, table).await, expected, "{table} unchanged");
    }
    let connection_after: Vec<u8> =
        sqlx::query_scalar("SELECT access_token_ct FROM whoop_connections")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(connection_before, connection_after);
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn summary_is_all_null_when_there_is_no_cycle(pool: PgPool) {
    setup_user(&pool).await;
    let mock = spawn_mock().await;
    let app = app_with(pool.clone(), enabled_config(&mock));
    let cookie = connected(&app).await;
    mock.with(|m| m.no_cycles = true);

    let body = json(
        send(
            &app,
            web(
                "GET",
                "/v1/integrations/whoop/summary?day=2026-10-07",
                &cookie,
                None,
            ),
        )
        .await,
    )
    .await;
    assert_eq!(
        body,
        json!({
            "recovery_score": null, "hrv_rmssd_milli": null, "resting_heart_rate": null,
            "strain": null, "kilojoule": null, "sleep_performance": null
        })
    );
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn summary_rejects_a_bad_day(pool: PgPool) {
    setup_user(&pool).await;
    let mock = spawn_mock().await;
    let app = app_with(pool.clone(), enabled_config(&mock));
    let cookie = connected(&app).await;
    for day in ["2026-13-01", "10/07/2026", "2026-1-7"] {
        let res = send(
            &app,
            web(
                "GET",
                &format!("/v1/integrations/whoop/summary?day={day}"),
                &cookie,
                None,
            ),
        )
        .await;
        expect_problem(res, StatusCode::BAD_REQUEST, "validation").await;
    }
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn concurrent_refreshes_make_one_token_request(pool: PgPool) {
    setup_user(&pool).await;
    let mock = spawn_mock().await;
    let app = app_with(pool.clone(), enabled_config(&mock));
    let cookie = connected(&app).await;
    expire_access(&pool).await;
    let before: Vec<u8> = sqlx::query_scalar("SELECT refresh_token_ct FROM whoop_connections")
        .fetch_one(&pool)
        .await
        .unwrap();
    mock.with(|m| m.token_delay = Duration::from_millis(300));

    let first = web(
        "GET",
        "/v1/integrations/whoop/summary?day=2026-10-07",
        &cookie,
        None,
    );
    let second = web(
        "GET",
        "/v1/integrations/whoop/summary?day=2026-10-07",
        &cookie,
        None,
    );
    let (a, b) = tokio::join!(send(&app, first), send(&app, second));
    assert_eq!(a.status(), StatusCode::OK);
    assert_eq!(b.status(), StatusCode::OK);

    // The second caller waited for the row lock and found the token already fresh.
    assert_eq!(mock.with(|m| m.refresh_calls), 1, "one refresh at WHOOP");
    let after: Vec<u8> = sqlx::query_scalar("SELECT refresh_token_ct FROM whoop_connections")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_ne!(before, after, "refresh token rotated and re-sealed");
    assert!(
        !after.windows(9).any(|w| w == b"refresh-2"),
        "plaintext absent"
    );
    let expires_ok: bool = sqlx::query_scalar(
        "SELECT expires_at > now() + interval '50 minutes' FROM whoop_connections",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert!(expires_ok, "new expiry from expires_in");
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn rejected_refresh_removes_the_connection(pool: PgPool) {
    setup_user(&pool).await;
    let mock = spawn_mock().await;
    let app = app_with(pool.clone(), enabled_config(&mock));
    let cookie = connected(&app).await;
    expire_access(&pool).await;
    // WHOOP no longer accepts the refresh token, for example after the user revoked the app there.
    mock.with(|m| m.refresh = None);

    let res = send(
        &app,
        web(
            "GET",
            "/v1/integrations/whoop/summary?day=2026-10-07",
            &cookie,
            None,
        ),
    )
    .await;
    expect_problem(res, StatusCode::NOT_FOUND, "not-found").await;
    assert_eq!(count(&pool, "whoop_connections").await, 0);
    let status = json(send(&app, web("GET", "/v1/integrations/whoop", &cookie, None)).await).await;
    assert_eq!(status["connected"], false);
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn client_side_budget_returns_429(pool: PgPool) {
    setup_user(&pool).await;
    let mock = spawn_mock().await;
    // Code exchange and profile use two calls. The cycle call is the third; the recovery call is refused.
    let mut config = whoop_config(&mock.url);
    config.per_minute = 3;
    let app = app_with(
        pool.clone(),
        Config {
            secrets: Some(Secrets::new([9; 32])),
            whoop: Some(config),
            ..Config::default()
        },
    );
    let cookie = connected(&app).await;
    let res = send(
        &app,
        web(
            "GET",
            "/v1/integrations/whoop/summary?day=2026-10-07",
            &cookie,
            None,
        ),
    )
    .await;
    let body = expect_problem(res, StatusCode::TOO_MANY_REQUESTS, "rate-limited").await;
    assert!(
        body["detail"].as_str().unwrap().contains("minute"),
        "{body}"
    );
    assert_eq!(
        mock.with(|m| m.token_calls),
        1,
        "the refused call never left the server"
    );
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn delete_revokes_and_removes_tokens_and_events(pool: PgPool) {
    setup_user(&pool).await;
    let mock = spawn_mock().await;
    let app = app_with(pool.clone(), enabled_config(&mock));
    let cookie = connected(&app).await;
    let ts = "1790000000";
    let body = json!({ "user_id": 4242, "id": "obj-1", "type": "workout.updated", "trace_id": "trace-del" }).to_string();
    let sig = sign(CLIENT_SECRET, ts, body.as_bytes());
    let res = send(
        &app,
        webhook_request("trace-del", 4242, "workout.updated", ts, &sig),
    )
    .await;
    assert_eq!(res.status(), StatusCode::NO_CONTENT);

    let res = send(&app, web("DELETE", "/v1/integrations/whoop", &cookie, None)).await;
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
    assert_eq!(mock.with(|m| m.revoke_calls), 1);
    assert_eq!(count(&pool, "whoop_connections").await, 0);
    assert_eq!(count(&pool, "whoop_webhook_events").await, 0);
    let status = json(send(&app, web("GET", "/v1/integrations/whoop", &cookie, None)).await).await;
    assert_eq!(status["connected"], false);
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn account_deletion_removes_whoop_rows(pool: PgPool) {
    setup_user(&pool).await;
    let mock = spawn_mock().await;
    let app = app_with(pool.clone(), enabled_config(&mock));
    let cookie = connected(&app).await;
    let ts = "1790000000";
    let body = json!({ "user_id": 4242, "id": "obj-1", "type": "recovery.updated", "trace_id": "trace-me" }).to_string();
    let sig = sign(CLIENT_SECRET, ts, body.as_bytes());
    send(
        &app,
        webhook_request("trace-me", 4242, "recovery.updated", ts, &sig),
    )
    .await;

    let res = send(
        &app,
        web(
            "DELETE",
            "/v1/me",
            &cookie,
            Some(json!({ "confirm": EMAIL })),
        ),
    )
    .await;
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
    assert_eq!(count(&pool, "whoop_connections").await, 0);
    assert_eq!(count(&pool, "whoop_webhook_events").await, 0);
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn reconcile_refreshes_and_marks_events_processed(pool: PgPool) {
    setup_user(&pool).await;
    let mock = spawn_mock().await;
    let state = icarus_api::AppState::with_config(pool.clone(), enabled_config(&mock));
    let app = icarus_api::router(state.clone());
    connected(&app).await;
    let ts = "1790000000";
    let body =
        json!({ "user_id": 4242, "id": "obj-1", "type": "sleep.deleted", "trace_id": "trace-job" })
            .to_string();
    let sig = sign(CLIENT_SECRET, ts, body.as_bytes());
    send(
        &app,
        webhook_request("trace-job", 4242, "sleep.deleted", ts, &sig),
    )
    .await;
    sqlx::query("INSERT INTO oauth_states (state, user_id, created_at) SELECT 'stale001', id, now() - interval '1 hour' FROM users")
        .execute(&pool)
        .await
        .unwrap();

    icarus_api::whoop::reconcile_once(&state).await.unwrap();
    assert_eq!(
        mock.with(|m| m.refresh_calls),
        1,
        "every connection refreshed once"
    );
    let open: i64 =
        sqlx::query_scalar("SELECT count(*) FROM whoop_webhook_events WHERE processed_at IS NULL")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(open, 0);
    assert_eq!(
        count(&pool, "oauth_states").await,
        0,
        "expired states pruned"
    );
    assert_eq!(
        count(&pool, "whoop_webhook_events").await,
        1,
        "processed rows kept until retention"
    );
}
