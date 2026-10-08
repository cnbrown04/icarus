mod common;

use axum::http::StatusCode;
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use common::*;
use serde_json::{Value, json};
use sqlx::PgPool;
use uuid::Uuid;

async fn alarm(app: &axum::Router, cookie: &str) -> String {
    let body = json!({ "kind": "webhook", "label": "Front door", "rhythm": "double", "channels": ["phone", "band"] });
    let res = send(app, web("POST", "/v1/alarms", cookie, Some(body))).await;
    json(res).await["id"].as_str().unwrap().to_owned()
}

async fn create_hook(app: &axum::Router, cookie: &str, alarm_id: &str, mode: &str) -> Value {
    let res = send(
        app,
        web(
            "POST",
            "/v1/hooks",
            cookie,
            Some(json!({ "label": "Door sensor", "alarm_id": alarm_id, "auth_mode": mode })),
        ),
    )
    .await;
    assert_eq!(res.status(), StatusCode::CREATED);
    json(res).await
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn hook_secret_is_shown_once_and_stored_encrypted(pool: PgPool) {
    setup_user(&pool).await;
    let app = app_with_key(pool.clone());
    let cookie = login(&app).await;
    let alarm_id = alarm(&app, &cookie).await;

    let created = create_hook(&app, &cookie, &alarm_id, "hmac").await;
    let slug = created["slug"].as_str().unwrap();
    assert_eq!(slug.len(), 22, "22 url-safe characters");
    let secret = created["secret"].as_str().unwrap().to_owned();
    assert_eq!(URL_SAFE_NO_PAD.decode(&secret).unwrap().len(), 32);
    assert_eq!(
        created["url"],
        format!("http://localhost:8080/v1/hooks/{slug}"),
        "hmac URLs carry no secret"
    );
    assert_eq!(created["rate_limit_per_min"], 10);
    assert_eq!(created["enabled"], true);

    // Stored as ciphertext: the plaintext secret appears nowhere in the row.
    let sealed: Vec<u8> =
        sqlx::query_scalar("SELECT secret_ciphertext FROM webhook_endpoints WHERE slug = $1")
            .bind(slug)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert!(!sealed.windows(secret.len()).any(|w| w == secret.as_bytes()));
    assert!(
        sealed.len() > 32,
        "nonce and tag are stored with the ciphertext"
    );

    // Later reads never include the secret.
    let listed = json(send(&app, web("GET", "/v1/hooks", &cookie, None)).await).await;
    assert!(listed["hooks"][0].get("secret").is_none());
    assert_eq!(listed["hooks"][0]["slug"], slug);
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn secret_url_hooks_carry_the_secret_in_the_url_everywhere(pool: PgPool) {
    setup_user(&pool).await;
    let app = app_with_key(pool.clone());
    let cookie = login(&app).await;
    let alarm_id = alarm(&app, &cookie).await;
    let (_, token) = pair_device(&app, &cookie, "iPhone").await;

    let created = create_hook(&app, &cookie, &alarm_id, "secret_url").await;
    let secret = created["secret"].as_str().unwrap();
    let slug = created["slug"].as_str().unwrap();
    assert_eq!(
        created["url"],
        format!("http://localhost:8080/v1/hooks/{slug}/{secret}")
    );

    // The list and the app's sync config both build the same URL (PLAN.md §12.4, Phase 3 TODO).
    let listed = json(send(&app, web("GET", "/v1/hooks", &cookie, None)).await).await;
    assert_eq!(listed["hooks"][0]["url"], created["url"]);
    let config =
        json(send(&app, device("GET", "/v1/sync/config?since=0", &token, None)).await).await;
    assert_eq!(config["webhook_endpoints"][0]["url"], created["url"]);
    assert_eq!(config["webhook_endpoints"][0]["auth_mode"], "secret_url");
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn without_the_key_hook_routes_answer_503(pool: PgPool) {
    setup_user(&pool).await;
    let key_app = app_with_key(pool.clone());
    let cookie = login(&key_app).await;
    let alarm_id = alarm(&key_app, &cookie).await;
    let plain = app(pool.clone());

    let res = send(
        &plain,
        web(
            "POST",
            "/v1/hooks",
            &cookie,
            Some(json!({ "label": "x", "alarm_id": alarm_id, "auth_mode": "hmac" })),
        ),
    )
    .await;
    let problem = expect_problem(res, StatusCode::SERVICE_UNAVAILABLE, "internal").await;
    assert!(
        problem["detail"]
            .as_str()
            .unwrap()
            .contains("ICARUS_ENC_KEY")
    );

    // Listing hooks that do not need the key still works.
    let res = send(&plain, web("GET", "/v1/hooks", &cookie, None)).await;
    assert_eq!(res.status(), StatusCode::OK);
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn hook_patch_rotate_and_delete(pool: PgPool) {
    setup_user(&pool).await;
    let app = app_with_key(pool.clone());
    let cookie = login(&app).await;
    let alarm_id = alarm(&app, &cookie).await;
    let created = create_hook(&app, &cookie, &alarm_id, "secret_url").await;
    let id = created["id"].as_str().unwrap().to_owned();
    let version = created["version"].as_i64().unwrap();
    let uri = format!("/v1/hooks/{id}");

    let no_header = send(
        &app,
        web("PATCH", &uri, &cookie, Some(json!({ "enabled": false }))),
    )
    .await;
    expect_problem(no_header, StatusCode::PRECONDITION_REQUIRED, "validation").await;
    let stale = send(
        &app,
        request(
            "PATCH",
            &uri,
            &[
                ("cookie", &cookie),
                ("x-icarus-csrf", "1"),
                ("if-match", "999"),
            ],
            Some(json!({ "enabled": false })),
        ),
    )
    .await;
    expect_problem(stale, StatusCode::CONFLICT, "conflict").await;

    let patched = send(
        &app,
        request(
            "PATCH",
            &uri,
            &[
                ("cookie", &cookie),
                ("x-icarus-csrf", "1"),
                ("if-match", &version.to_string()),
            ],
            Some(json!({ "enabled": false, "rate_limit_per_min": 30 })),
        ),
    )
    .await;
    assert_eq!(patched.status(), StatusCode::OK);
    let patched = json(patched).await;
    assert_eq!(patched["enabled"], false);
    assert_eq!(patched["rate_limit_per_min"], 30);
    let version = patched["version"].as_i64().unwrap();

    let bad_rate = send(
        &app,
        request(
            "PATCH",
            &uri,
            &[
                ("cookie", &cookie),
                ("x-icarus-csrf", "1"),
                ("if-match", &version.to_string()),
            ],
            Some(json!({ "rate_limit_per_min": 0 })),
        ),
    )
    .await;
    expect_problem(bad_rate, StatusCode::BAD_REQUEST, "validation").await;

    // Rotating replaces the secret, shown once, and the secret URL follows it.
    let old_secret = created["secret"].as_str().unwrap().to_owned();
    let rotated = json(
        send(
            &app,
            web("POST", &format!("{uri}/rotate-secret"), &cookie, None),
        )
        .await,
    )
    .await;
    let new_secret = rotated["secret"].as_str().unwrap().to_owned();
    assert_ne!(new_secret, old_secret);
    let listed = json(send(&app, web("GET", "/v1/hooks", &cookie, None)).await).await;
    assert!(
        listed["hooks"][0]["url"]
            .as_str()
            .unwrap()
            .ends_with(&new_secret)
    );

    let deleted = send(&app, web("DELETE", &uri, &cookie, None)).await;
    assert_eq!(deleted.status(), StatusCode::NO_CONTENT);
    let listed = json(send(&app, web("GET", "/v1/hooks", &cookie, None)).await).await;
    assert!(listed["hooks"].as_array().unwrap().is_empty());
    let gone = send(&app, web("DELETE", &uri, &cookie, None)).await;
    expect_problem(gone, StatusCode::NOT_FOUND, "not-found").await;
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn hooks_must_point_at_your_live_alarm(pool: PgPool) {
    setup_user(&pool).await;
    let app = app_with_key(pool.clone());
    let cookie = login(&app).await;
    let res = send(
        &app,
        web(
            "POST",
            "/v1/hooks",
            &cookie,
            Some(json!({ "label": "x", "alarm_id": Uuid::now_v7(), "auth_mode": "hmac" })),
        ),
    )
    .await;
    expect_problem(res, StatusCode::BAD_REQUEST, "validation").await;

    let alarm_id = alarm(&app, &cookie).await;
    send(&app, with_delete_alarm(&alarm_id, &cookie)).await;
    let res = send(
        &app,
        web(
            "POST",
            "/v1/hooks",
            &cookie,
            Some(json!({ "label": "x", "alarm_id": alarm_id, "auth_mode": "hmac" })),
        ),
    )
    .await;
    expect_problem(res, StatusCode::BAD_REQUEST, "validation").await;
}

fn with_delete_alarm(id: &str, cookie: &str) -> axum::http::Request<axum::body::Body> {
    web("DELETE", &format!("/v1/alarms/{id}"), cookie, None)
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn deliveries_page_with_an_opaque_cursor(pool: PgPool) {
    setup_user(&pool).await;
    let app = app_with_key(pool.clone());
    let cookie = login(&app).await;
    let alarm_id = alarm(&app, &cookie).await;
    let created = create_hook(&app, &cookie, &alarm_id, "hmac").await;
    let id = created["id"].as_str().unwrap().to_owned();
    let endpoint: Uuid = id.parse().unwrap();

    sqlx::query(
        "INSERT INTO webhook_deliveries (id, endpoint_id, received_at, idempotency_key, signature_valid, status)
         SELECT gen_random_uuid(), $1, now() - (g || ' seconds')::interval, 'seed-' || g, false, 'rejected'
         FROM generate_series(1, 120) g",
    )
    .bind(endpoint)
    .execute(&pool)
    .await
    .unwrap();

    let mut seen = std::collections::HashSet::new();
    let mut cursor: Option<String> = None;
    let mut pages = 0;
    loop {
        let uri = match &cursor {
            Some(c) => format!("/v1/hooks/{id}/deliveries?cursor={c}"),
            None => format!("/v1/hooks/{id}/deliveries"),
        };
        let page = json(send(&app, web("GET", &uri, &cookie, None)).await).await;
        for item in page["deliveries"].as_array().unwrap() {
            assert!(
                seen.insert(item["id"].as_str().unwrap().to_owned()),
                "no repeats"
            );
            assert_eq!(item["status"], "rejected");
            assert!(item["dispatch"].is_null());
        }
        pages += 1;
        match page["next_cursor"].as_str() {
            Some(next) => cursor = Some(next.to_owned()),
            None => break,
        }
    }
    assert_eq!(seen.len(), 120);
    assert_eq!(pages, 3, "50 + 50 + 20");

    let bad = send(
        &app,
        web(
            "GET",
            &format!("/v1/hooks/{id}/deliveries?cursor=%%%"),
            &cookie,
            None,
        ),
    )
    .await;
    expect_problem(bad, StatusCode::BAD_REQUEST, "validation").await;
    let other = send(
        &app,
        web(
            "GET",
            &format!("/v1/hooks/{}/deliveries", Uuid::now_v7()),
            &cookie,
            None,
        ),
    )
    .await;
    expect_problem(other, StatusCode::NOT_FOUND, "not-found").await;
}
