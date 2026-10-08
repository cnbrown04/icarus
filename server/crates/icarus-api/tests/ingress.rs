mod common;

use std::net::{Ipv4Addr, SocketAddr};

use axum::{
    body::Body,
    extract::ConnectInfo,
    http::{Request, StatusCode},
};
use chrono::Utc;
use common::*;
use hmac::{Hmac, Mac};
use serde_json::{Value, json};
use sha2::Sha256;
use sqlx::PgPool;

/// A signed ingress request from one client address, for the per-IP limit.
fn signed_from(ip: Ipv4Addr, slug: &str, secret: &str, key: usize) -> Request<Body> {
    let body = format!(r#"{{"idempotency_key":"k{key}"}}"#);
    let sig = signature(secret, Utc::now().timestamp(), body.as_bytes());
    let mut req = post_signed(slug, Some(&sig), body.as_bytes());
    req.extensions_mut()
        .insert(ConnectInfo(SocketAddr::new(ip.into(), 40_000)));
    req
}

fn to_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// `X-Icarus-Signature` for a body sent at `t`.
fn signature(secret: &str, t: i64, body: &[u8]) -> String {
    let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).unwrap();
    mac.update(format!("{t}.").as_bytes());
    mac.update(body);
    format!("t={t},v1={}", to_hex(&mac.finalize().into_bytes()))
}

struct Hook {
    slug: String,
    secret: String,
    id: String,
    alarm_id: String,
}

async fn setup(pool: &PgPool, mode: &str, rate: i64) -> (axum::Router, String, Hook) {
    setup_user(pool).await;
    let app = app_with_key(pool.clone());
    let cookie = login(&app).await;
    let alarm = json(
        send(
            &app,
            web("POST", "/v1/alarms", &cookie, Some(json!({ "kind": "webhook", "label": "Front door", "rhythm": "double", "channels": ["phone", "band"] }))),
        )
        .await,
    )
    .await;
    let res = send(
        &app,
        web("POST", "/v1/hooks", &cookie, Some(json!({ "label": "Door", "alarm_id": alarm["id"], "auth_mode": mode, "rate_limit_per_min": rate }))),
    )
    .await;
    let created: Value = json(res).await;
    let hook = Hook {
        slug: created["slug"].as_str().unwrap().into(),
        secret: created["secret"].as_str().unwrap().into(),
        id: created["id"].as_str().unwrap().into(),
        alarm_id: alarm["id"].as_str().unwrap().into(),
    };
    (app, cookie, hook)
}

fn post_signed(slug: &str, sig: Option<&str>, body: &[u8]) -> axum::http::Request<Body> {
    let mut builder = axum::http::Request::builder()
        .method("POST")
        .uri(format!("/v1/hooks/{slug}"))
        .header("content-type", "application/json")
        .header("user-agent", "TestSender/1.0");
    if let Some(sig) = sig {
        builder = builder.header("x-icarus-signature", sig);
    }
    builder.body(Body::from(body.to_vec())).unwrap()
}

async fn count(pool: &PgPool, sql: &str) -> i64 {
    sqlx::query_scalar(sql).fetch_one(pool).await.unwrap()
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn valid_signature_is_accepted_and_queues_a_dispatch(pool: PgPool) {
    let (app, cookie, hook) = setup(&pool, "hmac", 10).await;
    let body = br#"{"message":"Front door opened","rhythm":"sos","channels":["phone"]}"#;
    let now = Utc::now().timestamp();
    let res = send(
        &app,
        post_signed(&hook.slug, Some(&signature(&hook.secret, now, body)), body),
    )
    .await;
    assert_eq!(res.status(), StatusCode::ACCEPTED);
    let dispatch_id = json(res).await["dispatch_id"].as_str().unwrap().to_owned();

    let dispatches =
        json(send(&app, web("GET", "/v1/alarm-dispatches", &cookie, None)).await).await;
    let row = &dispatches["dispatches"][0];
    assert_eq!(row["id"], dispatch_id);
    assert_eq!(row["status"], "pending");
    assert_eq!(row["message"], "Front door opened");
    assert_eq!(
        row["rhythm"], "sos",
        "the body's rhythm wins over the alarm's"
    );
    assert_eq!(row["alarm_id"], hook.alarm_id);

    let stored: Vec<String> =
        sqlx::query_scalar("SELECT channels FROM alarm_dispatches WHERE id = $1::uuid")
            .bind(&dispatch_id)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(stored, vec!["phone".to_owned()]);
    let last: Option<chrono::DateTime<Utc>> =
        sqlx::query_scalar("SELECT last_triggered_at FROM webhook_endpoints WHERE id = $1::uuid")
            .bind(&hook.id)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert!(last.is_some());
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn empty_body_uses_the_alarm_defaults(pool: PgPool) {
    let (app, cookie, hook) = setup(&pool, "hmac", 10).await;
    let now = Utc::now().timestamp();
    let res = send(
        &app,
        post_signed(&hook.slug, Some(&signature(&hook.secret, now, b"")), b""),
    )
    .await;
    assert_eq!(res.status(), StatusCode::ACCEPTED);
    let dispatches =
        json(send(&app, web("GET", "/v1/alarm-dispatches", &cookie, None)).await).await;
    assert_eq!(dispatches["dispatches"][0]["rhythm"], "double");
    assert!(dispatches["dispatches"][0]["message"].is_null());
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn stale_and_forged_signatures_are_401_and_leave_no_body_behind(pool: PgPool) {
    let (app, _, hook) = setup(&pool, "hmac", 10).await;
    let body = br#"{"message":"secret-looking payload 4242"}"#;
    let now = Utc::now().timestamp();

    let stale = send(
        &app,
        post_signed(
            &hook.slug,
            Some(&signature(&hook.secret, now - 301, body)),
            body,
        ),
    )
    .await;
    expect_problem(stale, StatusCode::UNAUTHORIZED, "signature-invalid").await;

    let forged = send(
        &app,
        post_signed(
            &hook.slug,
            Some(&signature("wrong-secret", now, body)),
            body,
        ),
    )
    .await;
    expect_problem(forged, StatusCode::UNAUTHORIZED, "signature-invalid").await;

    let tampered = send(
        &app,
        post_signed(&hook.slug, Some(&signature(&hook.secret, now, b"{}")), body),
    )
    .await;
    expect_problem(tampered, StatusCode::UNAUTHORIZED, "signature-invalid").await;

    let missing = send(&app, post_signed(&hook.slug, None, body)).await;
    expect_problem(missing, StatusCode::UNAUTHORIZED, "signature-invalid").await;

    // Rejected attempts are recorded with their reason, but never the body.
    let rejected = count(&pool, "SELECT count(*) FROM webhook_deliveries WHERE status = 'rejected' AND signature_valid = false").await;
    assert_eq!(rejected, 4);
    let meta: String =
        sqlx::query_scalar("SELECT string_agg(request_meta::text, ' ') FROM webhook_deliveries")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert!(!meta.contains("4242"), "no body in request_meta: {meta}");
    assert!(meta.contains("outside the 300 s window"));
    assert_eq!(
        count(&pool, "SELECT count(*) FROM alarm_dispatches").await,
        0
    );
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn repeating_an_idempotency_key_returns_the_original_dispatch(pool: PgPool) {
    let (app, _, hook) = setup(&pool, "hmac", 10).await;
    let body = br#"{"idempotency_key":"door-42","message":"once"}"#;
    let now = Utc::now().timestamp();
    let first = send(
        &app,
        post_signed(&hook.slug, Some(&signature(&hook.secret, now, body)), body),
    )
    .await;
    assert_eq!(first.status(), StatusCode::ACCEPTED);
    let dispatch_id = json(first).await["dispatch_id"].clone();

    // A replay with a different timestamp still matches the key.
    let again = send(
        &app,
        post_signed(
            &hook.slug,
            Some(&signature(&hook.secret, now + 1, body)),
            body,
        ),
    )
    .await;
    assert_eq!(again.status(), StatusCode::OK);
    let dup = json(again).await;
    assert_eq!(dup["duplicate"], true);
    assert_eq!(dup["dispatch_id"], dispatch_id);

    assert_eq!(
        count(&pool, "SELECT count(*) FROM alarm_dispatches").await,
        1
    );
    assert_eq!(
        count(
            &pool,
            "SELECT count(*) FROM webhook_deliveries WHERE status = 'accepted'"
        )
        .await,
        1
    );
    assert_eq!(
        count(
            &pool,
            "SELECT count(*) FROM webhook_deliveries WHERE status = 'duplicate'"
        )
        .await,
        1
    );
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn default_key_treats_the_same_signed_request_as_a_duplicate(pool: PgPool) {
    let (app, _, hook) = setup(&pool, "hmac", 10).await;
    let body = br#"{"message":"same"}"#;
    let now = Utc::now().timestamp();
    let sig = signature(&hook.secret, now, body);
    assert_eq!(
        send(&app, post_signed(&hook.slug, Some(&sig), body))
            .await
            .status(),
        StatusCode::ACCEPTED
    );
    let again = send(&app, post_signed(&hook.slug, Some(&sig), body)).await;
    assert_eq!(again.status(), StatusCode::OK);
    assert_eq!(json(again).await["duplicate"], true);
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn rate_limit_answers_429_once_the_budget_is_spent(pool: PgPool) {
    let (app, _, hook) = setup(&pool, "hmac", 2).await;
    let now = Utc::now().timestamp();
    for i in 0..2 {
        let body = format!(r#"{{"message":"ring {i}"}}"#);
        let sig = signature(&hook.secret, now, body.as_bytes());
        let res = send(&app, post_signed(&hook.slug, Some(&sig), body.as_bytes())).await;
        assert_eq!(res.status(), StatusCode::ACCEPTED, "request {i}");
    }
    let body = br#"{"message":"ring 2"}"#;
    let sig = signature(&hook.secret, now, body);
    expect_problem(
        send(&app, post_signed(&hook.slug, Some(&sig), body)).await,
        StatusCode::TOO_MANY_REQUESTS,
        "rate-limited",
    )
    .await;
    assert_eq!(
        count(
            &pool,
            "SELECT count(*) FROM webhook_deliveries WHERE status = 'rate_limited'"
        )
        .await,
        1
    );
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn secret_url_mode_checks_the_secret_in_constant_time(pool: PgPool) {
    let (app, _, hook) = setup(&pool, "secret_url", 10).await;
    let body = br#"{"message":"Front door opened"}"#;
    let ok = send(
        &app,
        axum::http::Request::builder()
            .method("POST")
            .uri(format!("/v1/hooks/{}/{}", hook.slug, hook.secret))
            .body(Body::from(body.to_vec()))
            .unwrap(),
    )
    .await;
    assert_eq!(ok.status(), StatusCode::ACCEPTED);

    let wrong = send(
        &app,
        axum::http::Request::builder()
            .method("POST")
            .uri(format!("/v1/hooks/{}/{}", hook.slug, "x".repeat(43)))
            .body(Body::from(body.to_vec()))
            .unwrap(),
    )
    .await;
    expect_problem(wrong, StatusCode::UNAUTHORIZED, "signature-invalid").await;

    // Signed requests do not work on a secret-URL endpoint.
    let now = Utc::now().timestamp();
    let signed = send(
        &app,
        post_signed(&hook.slug, Some(&signature(&hook.secret, now, body)), body),
    )
    .await;
    expect_problem(signed, StatusCode::UNAUTHORIZED, "signature-invalid").await;
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn secret_path_is_not_found_on_signed_endpoints(pool: PgPool) {
    let (app, _, hook) = setup(&pool, "hmac", 10).await;
    let res = send(
        &app,
        axum::http::Request::builder()
            .method("POST")
            .uri(format!("/v1/hooks/{}/{}", hook.slug, hook.secret))
            .body(Body::from("{}"))
            .unwrap(),
    )
    .await;
    expect_problem(res, StatusCode::NOT_FOUND, "not-found").await;
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn bodies_over_16_kb_are_413(pool: PgPool) {
    let (app, _, hook) = setup(&pool, "hmac", 10).await;
    let body = format!(r#"{{"message":"x","pad":"{}"}}"#, "y".repeat(16 * 1024));
    let now = Utc::now().timestamp();
    let sig = signature(&hook.secret, now, body.as_bytes());
    let res = send(&app, post_signed(&hook.slug, Some(&sig), body.as_bytes())).await;
    expect_problem(res, StatusCode::PAYLOAD_TOO_LARGE, "payload-too-large").await;
    assert_eq!(
        count(&pool, "SELECT count(*) FROM alarm_dispatches").await,
        0
    );
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn invalid_bodies_are_400_and_recorded_as_rejected(pool: PgPool) {
    let (app, _, hook) = setup(&pool, "hmac", 10).await;
    let now = Utc::now().timestamp();
    let too_long = format!(r#"{{"message":"{}"}}"#, "m".repeat(121));
    let cases: [&[u8]; 3] = [
        too_long.as_bytes(),
        br#"{"rhythm":[{"type":"pause","ms":40000}]}"#,
        br#"{"channels":[]}"#,
    ];
    for body in cases {
        let sig = signature(&hook.secret, now, body);
        let res = send(&app, post_signed(&hook.slug, Some(&sig), body)).await;
        expect_problem(res, StatusCode::BAD_REQUEST, "validation").await;
    }
    assert_eq!(
        count(
            &pool,
            "SELECT count(*) FROM webhook_deliveries WHERE status = 'rejected' AND signature_valid"
        )
        .await,
        3
    );
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn unknown_disabled_and_deleted_endpoints_are_404(pool: PgPool) {
    let (app, cookie, hook) = setup(&pool, "hmac", 10).await;
    let now = Utc::now().timestamp();
    let body = br#"{}"#;
    let sig = signature(&hook.secret, now, body);
    let uri = format!("/v1/hooks/{}", hook.id);

    expect_problem(
        send(
            &app,
            post_signed("nosuchslug0000000000000", Some(&sig), body),
        )
        .await,
        StatusCode::NOT_FOUND,
        "not-found",
    )
    .await;

    // Disabled: 404 for the public route, even with a valid signature.
    let version = json(send(&app, web("GET", "/v1/hooks", &cookie, None)).await).await["hooks"][0]
        ["version"]
        .as_i64()
        .unwrap();
    let disable = send(
        &app,
        request(
            "PATCH",
            &uri,
            &[
                ("cookie", &cookie),
                ("x-icarus-csrf", "1"),
                ("if-match", &version.to_string()),
            ],
            Some(json!({ "enabled": false })),
        ),
    )
    .await;
    assert_eq!(disable.status(), StatusCode::OK);
    expect_problem(
        send(&app, post_signed(&hook.slug, Some(&sig), body)).await,
        StatusCode::NOT_FOUND,
        "not-found",
    )
    .await;

    // Re-enabled, then the alarm is deleted: the endpoint cannot queue anything any more.
    let version = json(disable).await["version"].as_i64().unwrap();
    let enable = send(
        &app,
        request(
            "PATCH",
            &uri,
            &[
                ("cookie", &cookie),
                ("x-icarus-csrf", "1"),
                ("if-match", &version.to_string()),
            ],
            Some(json!({ "enabled": true })),
        ),
    )
    .await;
    assert_eq!(enable.status(), StatusCode::OK);
    assert_eq!(
        send(&app, post_signed(&hook.slug, Some(&sig), body))
            .await
            .status(),
        StatusCode::ACCEPTED
    );

    let alarm_uri = format!("/v1/alarms/{}", hook.alarm_id);
    assert_eq!(
        send(&app, web("DELETE", &alarm_uri, &cookie, None))
            .await
            .status(),
        StatusCode::NO_CONTENT
    );
    let after = br#"{"message":"after"}"#;
    let after_sig = signature(&hook.secret, now + 2, after);
    expect_problem(
        send(&app, post_signed(&hook.slug, Some(&after_sig), after)).await,
        StatusCode::NOT_FOUND,
        "not-found",
    )
    .await;
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn ingress_answers_503_without_the_key(pool: PgPool) {
    let (_, _, hook) = setup(&pool, "hmac", 10).await;
    let plain = app(pool.clone());
    let now = Utc::now().timestamp();
    let body = br#"{}"#;
    let res = send(
        &plain,
        post_signed(&hook.slug, Some(&signature(&hook.secret, now, body)), body),
    )
    .await;
    expect_problem(res, StatusCode::SERVICE_UNAVAILABLE, "internal").await;
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn per_ip_limit_rejects_before_any_row_is_written(pool: PgPool) {
    // The endpoint's own budget is generous, so only the per-IP limit can refuse.
    let (app, _, hook) = setup(&pool, "hmac", 600).await;
    let noisy = Ipv4Addr::new(203, 0, 113, 7);
    for i in 0..60 {
        let res = send(&app, signed_from(noisy, &hook.slug, &hook.secret, i)).await;
        assert_eq!(res.status(), StatusCode::ACCEPTED, "request {i}");
    }
    expect_problem(
        send(&app, signed_from(noisy, &hook.slug, &hook.secret, 60)).await,
        StatusCode::TOO_MANY_REQUESTS,
        "rate-limited",
    )
    .await;
    // Refused before the signature check, so a bad signature is not recorded either.
    let mut forged = post_signed(&hook.slug, Some("t=1,v1=00"), b"{}");
    forged
        .extensions_mut()
        .insert(ConnectInfo(SocketAddr::new(noisy.into(), 40_000)));
    expect_problem(
        send(&app, forged).await,
        StatusCode::TOO_MANY_REQUESTS,
        "rate-limited",
    )
    .await;
    assert_eq!(
        count(&pool, "SELECT count(*) FROM webhook_deliveries").await,
        60,
        "only the 60 admitted requests left rows"
    );

    // Another address has its own budget.
    let other = Ipv4Addr::new(203, 0, 113, 8);
    let res = send(&app, signed_from(other, &hook.slug, &hook.secret, 100)).await;
    assert_eq!(res.status(), StatusCode::ACCEPTED);
}
