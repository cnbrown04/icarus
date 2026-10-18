mod common;

use std::path::PathBuf;

use axum::http::StatusCode;
use common::*;
use icarus_api::Config;
use sqlx::PgPool;

fn web_dir(name: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(name);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("index.html"),
        "<!doctype html><title>Icarus</title>",
    )
    .unwrap();
    dir
}

const CSP: &str = "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'";

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn api_responses_carry_sniffing_and_referrer_headers_but_no_csp(pool: PgPool) {
    let res = send(&app(pool), anon("GET", "/healthz", None)).await;
    assert_eq!(res.status(), StatusCode::OK);
    let headers = res.headers();
    assert_eq!(headers["x-content-type-options"], "nosniff");
    assert_eq!(headers["referrer-policy"], "no-referrer");
    assert!(headers.get("content-security-policy").is_none());
    // Plain HTTP base URL: no HSTS, so local runs are not pinned to HTTPS.
    assert!(headers.get("strict-transport-security").is_none());
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn static_responses_carry_the_web_csp(pool: PgPool) {
    let app = app_with(
        pool,
        Config {
            web_dir: Some(web_dir("security-web-csp")),
            ..Config::default()
        },
    );
    for path in ["/", "/integrations/whoop"] {
        let res = send(&app, anon("GET", path, None)).await;
        assert_eq!(res.status(), StatusCode::OK, "{path}");
        assert_eq!(res.headers()["content-security-policy"], CSP, "{path}");
        assert_eq!(res.headers()["x-content-type-options"], "nosniff", "{path}");
        assert_eq!(res.headers()["referrer-policy"], "no-referrer", "{path}");
    }
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn https_public_url_adds_hsts_everywhere(pool: PgPool) {
    let app = app_with(
        pool,
        Config {
            public_base_url: "https://icarus.example.com".into(),
            web_dir: Some(web_dir("security-web-hsts")),
            ..Config::default()
        },
    );
    let api = send(&app, anon("GET", "/healthz", None)).await;
    assert_eq!(
        api.headers()["strict-transport-security"],
        "max-age=31536000"
    );

    let page = send(&app, anon("GET", "/", None)).await;
    assert_eq!(
        page.headers()["strict-transport-security"],
        "max-age=31536000"
    );
    assert_eq!(page.headers()["content-security-policy"], CSP);
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn api_errors_carry_the_headers_too(pool: PgPool) {
    let res = send(&app(pool), anon("GET", "/v1/me", None)).await;
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(res.headers()["x-content-type-options"], "nosniff");
}
