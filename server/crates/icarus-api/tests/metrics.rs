mod common;

use axum::http::StatusCode;
use common::*;
use sqlx::PgPool;
use uuid::Uuid;

/// Ten seconds of raw samples (60..=69 bpm) from 10:00:00Z, and ten minutes of minute metrics.
/// Minutes 0-4 average 60 (60 samples each), minute 5 averages 80, minute 6 averages 110 from only 30
/// samples, and minutes 7-9 average 80.
async fn seed(pool: &PgPool) -> Uuid {
    let user = user_id(pool).await;
    let band = Uuid::now_v7();
    sqlx::query("INSERT INTO bands (id, user_id, name) VALUES ($1, $2, 'WHOOP 4.0')")
        .bind(band)
        .bind(user)
        .execute(pool)
        .await
        .unwrap();
    sqlx::query(
        "INSERT INTO hr_samples (band_id, ts, bpm, source, contact, batch_id)
         SELECT $1, '2026-10-07 10:00:00+00'::timestamptz + g * interval '1 second', 60 + g, 1, true, gen_random_uuid()
         FROM generate_series(0, 9) g",
    )
    .bind(band)
    .execute(pool)
    .await
    .unwrap();

    for m in 0..10i64 {
        let (avg, n) = match m {
            0..=4 => (60.0f32, 60i16),
            6 => (110.0, 30),
            _ => (80.0, 60),
        };
        sqlx::query(
            "INSERT INTO minute_metrics (user_id, minute, hr_avg, hr_min, hr_max, hr_n, rmssd_ms, stress, stress_state,
               kcal, active_kcal, kcal_estimated, algo_version, sync_rev)
             VALUES ($1, '2026-10-07 10:00:00+00'::timestamptz + $2 * interval '1 minute', $3, $4, $5, $6,
               42.0, 31, 'value', 1.4, 0.2, false, 1, 1)",
        )
        .bind(user)
        .bind(m)
        .bind(avg)
        .bind(avg as i16 - 2)
        .bind(avg as i16 + 3)
        .bind(n)
        .execute(pool)
        .await
        .unwrap();
    }

    sqlx::query(
        "INSERT INTO daily_summaries (user_id, day, rhr, hr_avg, hr_max, rmssd_night_ms, stress_avg,
           stress_high_minutes, kcal_total, kcal_active, coverage, algo_version, computed_at)
         SELECT $1, d, 52, 71.5, 120, 44.0, 30.0, 12, 2100.0, 430.0, 0.8, 1, now()
         FROM generate_series(DATE '2026-10-05', DATE '2026-10-07', interval '1 day') d",
    )
    .bind(user)
    .execute(pool)
    .await
    .unwrap();
    band
}

async fn get(
    app: &axum::Router,
    cookie: &str,
    uri: &str,
) -> axum::http::Response<axum::body::Body> {
    send(app, web("GET", uri, cookie, None)).await
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn raw_heart_rate_is_per_second_and_limited_to_six_hours(pool: PgPool) {
    setup_user(&pool).await;
    seed(&pool).await;
    let app = app(pool.clone());
    let cookie = login(&app).await;

    let body = json(
        get(
            &app,
            &cookie,
            "/v1/metrics/hr?from=2026-10-07T10:00:00Z&to=2026-10-07T10:00:10Z&res=raw",
        )
        .await,
    )
    .await;
    assert_eq!(body["res"], "raw");
    let points = body["points"].as_array().unwrap();
    assert_eq!(points.len(), 10);
    assert_eq!(points[0]["t"], "2026-10-07T10:00:00Z");
    assert_eq!(points[0]["avg"], 60.0);
    assert_eq!(points[9]["avg"], 69.0);
    assert_eq!(points[9]["min"], 69);
    assert_eq!(points[9]["max"], 69);

    let too_long = get(
        &app,
        &cookie,
        "/v1/metrics/hr?from=2026-10-07T00:00:00Z&to=2026-10-07T06:00:01Z&res=raw",
    )
    .await;
    expect_problem(too_long, StatusCode::BAD_REQUEST, "validation").await;
    let six_hours = get(
        &app,
        &cookie,
        "/v1/metrics/hr?from=2026-10-07T00:00:00Z&to=2026-10-07T06:00:00Z&res=raw",
    )
    .await;
    assert_eq!(six_hours.status(), StatusCode::OK);
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn heart_rate_resolutions_aggregate_minute_metrics(pool: PgPool) {
    setup_user(&pool).await;
    seed(&pool).await;
    let app = app(pool.clone());
    let cookie = login(&app).await;
    let range = "from=2026-10-07T10:00:00Z&to=2026-10-07T10:10:00Z";

    let minute = json(get(&app, &cookie, &format!("/v1/metrics/hr?{range}&res=1m")).await).await;
    let points = minute["points"].as_array().unwrap();
    assert_eq!(points.len(), 10);
    assert_eq!(points[0]["avg"], 60.0);
    assert_eq!(points[0]["min"], 58);
    assert_eq!(points[0]["max"], 63);

    // Weighted by hr_n: (80 * 60 * 4 + 110 * 30) / 270 = 83.33 -> 83.3.
    let five = json(get(&app, &cookie, &format!("/v1/metrics/hr?{range}&res=5m")).await).await;
    let buckets = five["points"].as_array().unwrap();
    assert_eq!(buckets.len(), 2);
    assert_eq!(buckets[0]["t"], "2026-10-07T10:00:00Z");
    assert_eq!(buckets[0]["avg"], 60.0);
    assert_eq!(buckets[1]["t"], "2026-10-07T10:05:00Z");
    assert_eq!(buckets[1]["avg"], 83.3);
    assert_eq!(buckets[1]["max"], 113);

    // Weighted over all ten minutes: 40500 / 570 = 71.05 -> 71.1.
    let hour = json(get(&app, &cookie, &format!("/v1/metrics/hr?{range}&res=1h")).await).await;
    let hours = hour["points"].as_array().unwrap();
    assert_eq!(hours.len(), 1);
    assert_eq!(hours[0]["avg"], 71.1);
    assert_eq!(hours[0]["min"], 58);

    let fifteen_days = "from=2026-09-01T00:00:00Z&to=2026-09-16T00:00:00Z";
    expect_problem(
        get(
            &app,
            &cookie,
            &format!("/v1/metrics/hr?{fifteen_days}&res=1m"),
        )
        .await,
        StatusCode::BAD_REQUEST,
        "validation",
    )
    .await;
    expect_problem(
        get(
            &app,
            &cookie,
            &format!("/v1/metrics/hr?{fifteen_days}&res=1h"),
        )
        .await,
        StatusCode::BAD_REQUEST,
        "validation",
    )
    .await;
    expect_problem(
        get(&app, &cookie, &format!("/v1/metrics/hr?{range}&res=2m")).await,
        StatusCode::BAD_REQUEST,
        "validation",
    )
    .await;
    expect_problem(
        get(&app, &cookie, &format!("/v1/metrics/hr?{range}")).await,
        StatusCode::BAD_REQUEST,
        "validation",
    )
    .await;
    expect_problem(
        get(
            &app,
            &cookie,
            "/v1/metrics/hr?from=2026-10-07T10:00:00Z&res=1m",
        )
        .await,
        StatusCode::BAD_REQUEST,
        "validation",
    )
    .await;
    expect_problem(
        get(
            &app,
            &cookie,
            "/v1/metrics/hr?from=2026-10-07T10:00:00Z&to=2026-10-07T09:00:00Z&res=1m",
        )
        .await,
        StatusCode::BAD_REQUEST,
        "validation",
    )
    .await;
    expect_problem(
        get(
            &app,
            &cookie,
            "/v1/metrics/hr?from=yesterday&to=2026-10-07T10:00:00Z&res=1m",
        )
        .await,
        StatusCode::BAD_REQUEST,
        "validation",
    )
    .await;
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn minutes_route_returns_every_field_and_limits_the_range(pool: PgPool) {
    setup_user(&pool).await;
    seed(&pool).await;
    let app = app(pool.clone());
    let cookie = login(&app).await;

    let body = json(
        get(
            &app,
            &cookie,
            "/v1/metrics/minutes?from=2026-10-07T10:00:00Z&to=2026-10-07T10:03:00Z",
        )
        .await,
    )
    .await;
    let minutes = body["minutes"].as_array().unwrap();
    assert_eq!(minutes.len(), 3);
    let first = &minutes[0];
    assert_eq!(first["minute"], "2026-10-07T10:00:00Z");
    assert_eq!(first["hr_avg"], 60.0);
    assert_eq!(first["hr_n"], 60);
    assert_eq!(first["rmssd_ms"], 42.0);
    assert_eq!(first["stress_state"], "value");
    assert_eq!(first["kcal_estimated"], false);
    assert!(first["baevsky_sqrt"].is_null());

    expect_problem(
        get(
            &app,
            &cookie,
            "/v1/metrics/minutes?from=2026-09-01T00:00:00Z&to=2026-09-16T00:00:01Z",
        )
        .await,
        StatusCode::BAD_REQUEST,
        "validation",
    )
    .await;
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn daily_route_returns_days_inclusive_and_validates_dates(pool: PgPool) {
    setup_user(&pool).await;
    seed(&pool).await;
    let app = app(pool.clone());
    let cookie = login(&app).await;

    let body = json(
        get(
            &app,
            &cookie,
            "/v1/metrics/daily?from=2026-10-05&to=2026-10-07",
        )
        .await,
    )
    .await;
    let days = body["days"].as_array().unwrap();
    assert_eq!(days.len(), 3);
    assert_eq!(days[0]["day"], "2026-10-05");
    assert_eq!(days[0]["rhr"], 52);
    assert_eq!(days[0]["kcal_total"], 2100.0);
    assert_eq!(days[0]["stress_high_minutes"], 12);
    assert_eq!(days[0]["coverage"], 0.8);

    expect_problem(
        get(
            &app,
            &cookie,
            "/v1/metrics/daily?from=2026-10-07&to=2026-10-05",
        )
        .await,
        StatusCode::BAD_REQUEST,
        "validation",
    )
    .await;
    expect_problem(
        get(
            &app,
            &cookie,
            "/v1/metrics/daily?from=2026-13-01&to=2026-10-05",
        )
        .await,
        StatusCode::BAD_REQUEST,
        "validation",
    )
    .await;
    expect_problem(
        get(&app, &cookie, "/v1/metrics/daily?from=2026-10-05").await,
        StatusCode::BAD_REQUEST,
        "validation",
    )
    .await;
    expect_problem(
        get(
            &app,
            &cookie,
            "/v1/metrics/daily?from=2000-01-01&to=2026-10-05",
        )
        .await,
        StatusCode::BAD_REQUEST,
        "validation",
    )
    .await;
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn live_is_the_latest_raw_sample_or_null(pool: PgPool) {
    setup_user(&pool).await;
    let app = app(pool.clone());
    let cookie = login(&app).await;
    let empty = json(get(&app, &cookie, "/v1/metrics/live").await).await;
    assert!(empty["bpm"].is_null());
    assert!(empty["ts"].is_null());

    seed(&pool).await;
    let live = json(get(&app, &cookie, "/v1/metrics/live").await).await;
    assert_eq!(live["bpm"], 69);
    assert_eq!(live["ts"], "2026-10-07T10:00:09Z");
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn metrics_need_a_session_or_device(pool: PgPool) {
    setup_user(&pool).await;
    let app = app(pool.clone());
    let res = send(&app, anon("GET", "/v1/metrics/live", None)).await;
    expect_problem(res, StatusCode::UNAUTHORIZED, "unauthorized").await;
}
