mod common;

use axum::http::StatusCode;
use common::*;
use icarus_api::{Config, CreateUserError, create_user};
use serde_json::json;
use sqlx::PgPool;

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn login_sets_a_secure_session_cookie_and_me_works(pool: PgPool) {
    setup_user(&pool).await;
    let app = app(pool);

    let res = send(
        &app,
        anon(
            "POST",
            "/v1/auth/login",
            Some(json!({ "email": EMAIL, "password": PASSWORD })),
        ),
    )
    .await;
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
    let set_cookie = res.headers()["set-cookie"].to_str().unwrap().to_owned();
    assert!(set_cookie.starts_with("icarus_session="), "{set_cookie}");
    for attr in [
        "HttpOnly",
        "Secure",
        "SameSite=Lax",
        "Path=/",
        "Max-Age=2592000",
    ] {
        assert!(set_cookie.contains(attr), "missing {attr} in {set_cookie}");
    }
    let cookie = session_cookie(res.headers());

    let me_res = send(&app, web("GET", "/v1/me", &cookie, None)).await;
    // A successful cookie request renews the cookie, which keeps the 30-day window sliding.
    let refreshed = me_res.headers()["set-cookie"].to_str().unwrap().to_owned();
    assert!(refreshed.starts_with(&cookie), "{refreshed}");
    let me = json(me_res).await;
    assert_eq!(me["email"], EMAIL);
    assert_eq!(me["tz"], "America/Chicago");
    assert_eq!(me["version"], 0);
    assert!(me["formula_sex"].is_null());
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn insecure_cookies_drop_the_secure_flag(pool: PgPool) {
    setup_user(&pool).await;
    let app = app_with(
        pool,
        Config {
            cookie_secure: false,
            ..Config::default()
        },
    );
    let res = send(
        &app,
        anon(
            "POST",
            "/v1/auth/login",
            Some(json!({ "email": EMAIL, "password": PASSWORD })),
        ),
    )
    .await;
    assert!(
        !res.headers()["set-cookie"]
            .to_str()
            .unwrap()
            .contains("Secure")
    );
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn bad_credentials_are_401_for_wrong_password_and_unknown_email(pool: PgPool) {
    setup_user(&pool).await;
    let app = app(pool);
    let wrong_password = send(
        &app,
        anon(
            "POST",
            "/v1/auth/login",
            Some(json!({ "email": EMAIL, "password": "nope nope nope" })),
        ),
    )
    .await;
    expect_problem(wrong_password, StatusCode::UNAUTHORIZED, "unauthorized").await;

    let unknown = send(
        &app,
        anon(
            "POST",
            "/v1/auth/login",
            Some(json!({ "email": "x@example.com", "password": PASSWORD })),
        ),
    )
    .await;
    expect_problem(unknown, StatusCode::UNAUTHORIZED, "unauthorized").await;
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn login_is_rate_limited_per_ip_after_five_attempts(pool: PgPool) {
    setup_user(&pool).await;
    let config = Config {
        trust_proxy: true,
        ..Config::default()
    };
    let app = app_with(pool, config);
    let bad = json!({ "email": EMAIL, "password": "wrong wrong wrong" });

    for attempt in 1..=5 {
        let res = send(
            &app,
            request(
                "POST",
                "/v1/auth/login",
                &[("x-forwarded-for", "203.0.113.1")],
                Some(bad.clone()),
            ),
        )
        .await;
        assert_eq!(res.status(), StatusCode::UNAUTHORIZED, "attempt {attempt}");
    }
    let limited = send(
        &app,
        request(
            "POST",
            "/v1/auth/login",
            &[("x-forwarded-for", "203.0.113.1")],
            Some(bad.clone()),
        ),
    )
    .await;
    expect_problem(limited, StatusCode::TOO_MANY_REQUESTS, "rate-limited").await;

    // A different client IP has its own budget, even with the right password.
    let other = send(
        &app,
        request(
            "POST",
            "/v1/auth/login",
            &[("x-forwarded-for", "203.0.113.2")],
            Some(json!({ "email": EMAIL, "password": PASSWORD })),
        ),
    )
    .await;
    assert_eq!(other.status(), StatusCode::NO_CONTENT);
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn cookie_writes_need_the_csrf_header(pool: PgPool) {
    setup_user(&pool).await;
    let app = app(pool);
    let cookie = login(&app).await;

    let no_csrf = send(
        &app,
        request(
            "PATCH",
            "/v1/me",
            &[("cookie", cookie.as_str()), ("if-match", "0")],
            Some(json!({ "hr_max": 190 })),
        ),
    )
    .await;
    expect_problem(no_csrf, StatusCode::FORBIDDEN, "forbidden").await;

    let logout_no_csrf = send(
        &app,
        request(
            "POST",
            "/v1/auth/logout",
            &[("cookie", cookie.as_str())],
            None,
        ),
    )
    .await;
    expect_problem(logout_no_csrf, StatusCode::FORBIDDEN, "forbidden").await;

    // Reads never need it.
    let read = send(
        &app,
        request("GET", "/v1/me", &[("cookie", cookie.as_str())], None),
    )
    .await;
    assert_eq!(read.status(), StatusCode::OK);
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn logout_ends_the_session(pool: PgPool) {
    setup_user(&pool).await;
    let app = app(pool);
    let cookie = login(&app).await;

    let res = send(&app, web("POST", "/v1/auth/logout", &cookie, None)).await;
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
    assert!(
        res.headers()["set-cookie"]
            .to_str()
            .unwrap()
            .contains("Max-Age=0")
    );

    let after = send(&app, web("GET", "/v1/me", &cookie, None)).await;
    expect_problem(after, StatusCode::UNAUTHORIZED, "unauthorized").await;
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn me_patch_needs_if_match_and_reports_conflicts(pool: PgPool) {
    setup_user(&pool).await;
    let app = app(pool);
    let cookie = login(&app).await;

    let missing = send(
        &app,
        web("PATCH", "/v1/me", &cookie, Some(json!({ "hr_max": 190 }))),
    )
    .await;
    let body = expect_problem(missing, StatusCode::PRECONDITION_REQUIRED, "validation").await;
    assert!(body.get("current").is_none());

    let stale = send(
        &app,
        request(
            "PATCH",
            "/v1/me",
            &[
                ("cookie", cookie.as_str()),
                ("x-icarus-csrf", "1"),
                ("if-match", "7"),
            ],
            Some(json!({ "hr_max": 190 })),
        ),
    )
    .await;
    let body = expect_problem(stale, StatusCode::CONFLICT, "conflict").await;
    assert_eq!(body["current"]["version"], 0);

    let ok = request(
        "PATCH",
        "/v1/me",
        &[
            ("cookie", cookie.as_str()),
            ("x-icarus-csrf", "1"),
            ("if-match", "0"),
        ],
        Some(
            json!({ "hr_max": 190, "formula_sex": "female", "birth_year": 1995, "height_cm": 170.5 }),
        ),
    );
    let res = send(&app, ok).await;
    assert_eq!(res.status(), StatusCode::OK);
    let me = json(res).await;
    assert_eq!(me["version"], 1);
    assert_eq!(me["hr_max"], 190);
    assert_eq!(me["formula_sex"], "female");
    assert_eq!(me["height_cm"], 170.5);

    // The old version is now stale.
    let again = send(
        &app,
        request(
            "PATCH",
            "/v1/me",
            &[
                ("cookie", cookie.as_str()),
                ("x-icarus-csrf", "1"),
                ("if-match", "0"),
            ],
            Some(json!({ "hr_max": 180 })),
        ),
    )
    .await;
    expect_problem(again, StatusCode::CONFLICT, "conflict").await;

    // An explicit null clears a field. Absent fields are untouched.
    let cleared = send(
        &app,
        request(
            "PATCH",
            "/v1/me",
            &[
                ("cookie", cookie.as_str()),
                ("x-icarus-csrf", "1"),
                ("if-match", "1"),
            ],
            Some(json!({ "birth_year": null })),
        ),
    )
    .await;
    let me = json(cleared).await;
    assert!(me["birth_year"].is_null());
    assert_eq!(me["hr_max"], 190);
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn me_patch_rejects_bad_values(pool: PgPool) {
    setup_user(&pool).await;
    let app = app(pool);
    let cookie = login(&app).await;
    for body in [
        json!({ "tz": "Mars/Olympus" }),
        json!({ "tz": null }),
        json!({ "hr_max": 10 }),
        json!({ "formula_sex": "other" }),
    ] {
        let res = send(
            &app,
            request(
                "PATCH",
                "/v1/me",
                &[
                    ("cookie", cookie.as_str()),
                    ("x-icarus-csrf", "1"),
                    ("if-match", "0"),
                ],
                Some(body.clone()),
            ),
        )
        .await;
        assert!(
            res.status().is_client_error(),
            "{body} gave {}",
            res.status()
        );
    }
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn delete_me_needs_the_email_and_cascades(pool: PgPool) {
    let user = setup_user(&pool).await;
    let app = app(pool.clone());
    let cookie = login(&app).await;
    let (_, token) = pair_device(&app, &cookie, "Caleb's iPhone").await;
    assert!(!token.is_empty());

    let wrong = send(
        &app,
        web(
            "DELETE",
            "/v1/me",
            &cookie,
            Some(json!({ "confirm": "nobody@example.com" })),
        ),
    )
    .await;
    expect_problem(wrong, StatusCode::BAD_REQUEST, "validation").await;

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

    let devices: i64 = sqlx::query_scalar("SELECT count(*) FROM devices WHERE user_id = $1")
        .bind(user)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(devices, 0);
    let sessions: i64 = sqlx::query_scalar("SELECT count(*) FROM sessions WHERE user_id = $1")
        .bind(user)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(sessions, 0);
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn pairing_codes_expire_and_are_single_use(pool: PgPool) {
    setup_user(&pool).await;
    let app = app(pool.clone());
    let cookie = login(&app).await;

    let created = json(
        send(
            &app,
            web("POST", "/v1/devices/pairing-codes", &cookie, None),
        )
        .await,
    )
    .await;
    let code = created["code"].as_str().unwrap().to_owned();
    assert_eq!(code.len(), 8);
    assert!(created["qr_svg"].as_str().unwrap().contains("<svg"));
    assert!(created["expires_at"].as_str().unwrap().ends_with('Z'));

    // Codes are case-insensitive on input.
    let (_, token) = pair_with_code(&app, &code.to_lowercase(), "Caleb's iPhone").await;
    assert!(!token.is_empty());

    // Single use.
    let reused = send(
        &app,
        anon(
            "POST",
            "/v1/devices/pair",
            Some(json!({ "code": code, "name": "Second phone", "model": "m", "os_version": "o", "app_version": "a" })),
        ),
    )
    .await;
    expect_problem(reused, StatusCode::BAD_REQUEST, "pairing-code-invalid").await;

    // Expiry (TTL 10 minutes).
    let second = json(
        send(
            &app,
            web("POST", "/v1/devices/pairing-codes", &cookie, None),
        )
        .await,
    )
    .await;
    let second_code = second["code"].as_str().unwrap().to_owned();
    sqlx::query(
        "UPDATE pairing_codes SET expires_at = now() - interval '1 minute' WHERE code_hash = $1",
    )
    .bind(icarus_api::auth::sha256(second_code.as_bytes()))
    .execute(&pool)
    .await
    .unwrap();
    let expired = send(
        &app,
        anon(
            "POST",
            "/v1/devices/pair",
            Some(json!({ "code": second_code, "name": "Late phone", "model": "m", "os_version": "o", "app_version": "a" })),
        ),
    )
    .await;
    expect_problem(expired, StatusCode::BAD_REQUEST, "pairing-code-invalid").await;

    // Malformed codes get the same answer.
    let junk = send(
        &app,
        anon(
            "POST",
            "/v1/devices/pair",
            Some(json!({ "code": "0000000O", "name": "x" })),
        ),
    )
    .await;
    expect_problem(junk, StatusCode::BAD_REQUEST, "pairing-code-invalid").await;
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn device_token_works_until_revoked(pool: PgPool) {
    setup_user(&pool).await;
    let app = app(pool);
    let cookie = login(&app).await;
    let (device_id, token) = pair_device(&app, &cookie, "Caleb's iPhone").await;

    let devices = send(&app, device("GET", "/v1/devices", &token, None)).await;
    assert_eq!(devices.status(), StatusCode::OK);
    let list = json(devices).await;
    assert_eq!(list["devices"][0]["name"], "Caleb's iPhone");
    assert_eq!(list["devices"][0]["model"], "iPhone17,2");
    assert!(list["devices"][0]["revoked_at"].is_null());
    assert!(list["bands"].as_array().unwrap().is_empty());

    let me = send(&app, device("GET", "/v1/me", &token, None)).await;
    assert_eq!(me.status(), StatusCode::OK);

    // Web-only routes refuse a device token, and app-only routes refuse a cookie.
    let web_only = send(
        &app,
        device("POST", "/v1/devices/pairing-codes", &token, None),
    )
    .await;
    expect_problem(web_only, StatusCode::FORBIDDEN, "forbidden").await;
    let app_only = send(&app, web("GET", "/v1/sync/config", &cookie, None)).await;
    expect_problem(app_only, StatusCode::FORBIDDEN, "forbidden").await;

    let revoke = send(
        &app,
        web("DELETE", &format!("/v1/devices/{device_id}"), &cookie, None),
    )
    .await;
    assert_eq!(revoke.status(), StatusCode::NO_CONTENT);

    let after = send(&app, device("GET", "/v1/me", &token, None)).await;
    expect_problem(after, StatusCode::UNAUTHORIZED, "unauthorized").await;

    let missing = send(
        &app,
        web(
            "DELETE",
            "/v1/devices/00000000-0000-0000-0000-000000000000",
            &cookie,
            None,
        ),
    )
    .await;
    expect_problem(missing, StatusCode::NOT_FOUND, "not-found").await;
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn push_token_is_stored_for_the_device(pool: PgPool) {
    setup_user(&pool).await;
    let app = app(pool.clone());
    let cookie = login(&app).await;
    let (device_id, token) = pair_device(&app, &cookie, "Caleb's iPhone").await;
    let apns = "ab".repeat(32);

    let res = send(
        &app,
        device(
            "PUT",
            "/v1/devices/me/push-token",
            &token,
            Some(json!({ "apns_token": apns, "environment": "sandbox" })),
        ),
    )
    .await;
    assert_eq!(res.status(), StatusCode::NO_CONTENT);

    let bad = send(
        &app,
        device(
            "PUT",
            "/v1/devices/me/push-token",
            &token,
            Some(json!({ "apns_token": "zz", "environment": "sandbox" })),
        ),
    )
    .await;
    expect_problem(bad, StatusCode::BAD_REQUEST, "validation").await;

    let stored: String =
        sqlx::query_scalar("SELECT environment FROM push_tokens WHERE device_id = $1::uuid")
            .bind(&device_id)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(stored, "sandbox");
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn oversize_json_is_413_and_unknown_api_paths_are_problems(pool: PgPool) {
    setup_user(&pool).await;
    let app = app(pool);
    let big = "x".repeat(20 * 1024);
    let res = send(
        &app,
        anon(
            "POST",
            "/v1/auth/login",
            Some(json!({ "email": big, "password": "p" })),
        ),
    )
    .await;
    expect_problem(res, StatusCode::PAYLOAD_TOO_LARGE, "payload-too-large").await;

    let unknown = send(&app, anon("GET", "/v1/nope", None)).await;
    expect_problem(unknown, StatusCode::NOT_FOUND, "not-found").await;
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn create_user_rejects_bad_input_and_duplicates(pool: PgPool) {
    assert!(matches!(
        create_user(&pool, "not-an-email", PASSWORD).await,
        Err(CreateUserError::InvalidEmail)
    ));
    assert!(matches!(
        create_user(&pool, EMAIL, "short").await,
        Err(CreateUserError::WeakPassword)
    ));
    setup_user(&pool).await;
    assert!(
        matches!(
            create_user(&pool, "CALEB@example.com", PASSWORD).await,
            Err(CreateUserError::EmailTaken)
        ),
        "email is case-insensitive (citext)"
    );
}
