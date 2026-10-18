mod common;

use axum::http::StatusCode;
use common::*;
use icarus_api::Config;
use sqlx::PgPool;

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn static_build_is_served_with_spa_fallback_but_not_for_api_paths(pool: PgPool) {
    let dir = std::path::PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("web-dist-test");
    std::fs::create_dir_all(dir.join("assets")).unwrap();
    std::fs::write(
        dir.join("index.html"),
        "<!doctype html><title>Icarus</title>",
    )
    .unwrap();
    std::fs::write(dir.join("assets/app.js"), "console.log(1)").unwrap();

    let app = app_with(
        pool,
        Config {
            web_dir: Some(dir),
            ..Config::default()
        },
    );

    let index = send(&app, anon("GET", "/", None)).await;
    assert_eq!(index.status(), StatusCode::OK);
    assert!(String::from_utf8_lossy(&body_bytes(index).await).contains("Icarus"));

    let asset = send(&app, anon("GET", "/assets/app.js", None)).await;
    assert_eq!(asset.status(), StatusCode::OK);

    let spa = send(&app, anon("GET", "/integrations/whoop", None)).await;
    assert_eq!(spa.status(), StatusCode::OK);
    assert!(String::from_utf8_lossy(&body_bytes(spa).await).contains("Icarus"));

    let api = send(&app, anon("GET", "/v1/missing", None)).await;
    expect_problem(api, StatusCode::NOT_FOUND, "not-found").await;
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn no_static_routes_without_a_web_directory(pool: PgPool) {
    let app = app_with(
        pool,
        Config {
            web_dir: Some("/nonexistent/icarus".into()),
            ..Config::default()
        },
    );
    let res = send(&app, anon("GET", "/", None)).await;
    assert_eq!(res.status(), StatusCode::NOT_FOUND);
}
