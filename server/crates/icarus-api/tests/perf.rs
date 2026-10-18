//! Read performance over one year of data (PLAN.md §19 Phase 8: "1-year data on web < 1 s per page").
//!
//! Ignored by default because it seeds about 1.1 million rows. Run it on purpose:
//! `DATABASE_URL=... cargo test -p icarus-api --test perf -- --ignored --nocapture`.
//! Timings are recorded in docs/deploy.md.

mod common;

use std::time::{Duration, Instant};

use axum::{body::Body, http::StatusCode};
use chrono::{Datelike, Duration as ChronoDuration, NaiveDate, SecondsFormat, Utc};
use common::*;
use icarus_db::MIGRATOR;
use sqlx::PgPool;

const RUNS: usize = 5;
const BUDGET: Duration = Duration::from_secs(1);

/// The partitions the daily job keeps: the past 13 months and the next one.
async fn ensure_partitions(pool: &PgPool) {
    let today = Utc::now().date_naive();
    let mut month = NaiveDate::from_ymd_opt(today.year(), today.month(), 1).unwrap();
    for _ in 0..13 {
        month = month.checked_sub_months(chrono::Months::new(1)).unwrap();
        icarus_jobs::partitions::ensure_month(pool, "hr_samples", month)
            .await
            .unwrap();
        icarus_jobs::partitions::ensure_month(pool, "rr_intervals", month)
            .await
            .unwrap();
    }
    icarus_jobs::partitions::ensure_current_and_next(pool, Utc::now())
        .await
        .unwrap();
}

async fn seed(pool: &PgPool, user_id: uuid::Uuid) -> (uuid::Uuid, i64) {
    ensure_partitions(pool).await;
    let band_id = uuid::Uuid::now_v7();
    sqlx::query("INSERT INTO bands (id, user_id, name) VALUES ($1, $2, 'WHOOP 4.0')")
        .bind(band_id)
        .bind(user_id)
        .execute(pool)
        .await
        .unwrap();

    // Seven days of raw samples at 1 Hz: about 605,000 rows.
    sqlx::query(
        "INSERT INTO hr_samples (band_id, ts, bpm, source, contact, batch_id)
         SELECT $1, ts, 60 + (extract(epoch FROM ts)::bigint % 40)::int, 1, true, gen_random_uuid()
         FROM generate_series(now() - interval '7 days', now(), interval '1 second') AS g(ts)",
    )
    .bind(band_id)
    .execute(pool)
    .await
    .unwrap();

    // One year of minute metrics: 525,600 rows.
    sqlx::query(
        "INSERT INTO minute_metrics (user_id, minute, hr_avg, hr_min, hr_max, hr_n, rmssd_ms, sdnn_ms,
                baevsky_sqrt, stress, stress_state, kcal, active_kcal, kcal_estimated, algo_version,
                origin, sync_rev)
         SELECT $1, m, 60 + (extract(epoch FROM m)::bigint % 30), 55, 90, 60, 40 + (extract(epoch FROM m)::bigint % 20),
                50, 9.1, (extract(epoch FROM m)::bigint % 100)::int, 'value', 1.4, 0.2, false, 1, 'device', 1
         FROM generate_series(date_trunc('minute', now()) - interval '365 days',
                              date_trunc('minute', now()), interval '1 minute') AS g(m)",
    )
    .bind(user_id)
    .execute(pool)
    .await
    .unwrap();

    sqlx::query(
        "INSERT INTO daily_summaries (user_id, day, rhr, hr_avg, hr_max, rmssd_night_ms, stress_avg,
                stress_high_minutes, kcal_total, kcal_active, coverage, algo_version, computed_at)
         SELECT $1, d::date, 55, 70, 120, 45, 30, 60, 2200, 500, 0.9, 1, now()
         FROM generate_series(current_date - 364, current_date, interval '1 day') AS g(d)",
    )
    .bind(user_id)
    .execute(pool)
    .await
    .unwrap();

    // Autovacuum would have analysed these tables long before a year of data exists.
    for table in ["hr_samples", "minute_metrics", "daily_summaries"] {
        sqlx::query(&format!("ANALYZE {table}"))
            .execute(pool)
            .await
            .unwrap();
    }
    let rows: i64 = sqlx::query_scalar(
        "SELECT (SELECT count(*) FROM hr_samples) + (SELECT count(*) FROM minute_metrics)
              + (SELECT count(*) FROM daily_summaries)",
    )
    .fetch_one(pool)
    .await
    .unwrap();
    (band_id, rows)
}

fn stamp(t: chrono::DateTime<Utc>) -> String {
    t.to_rfc3339_opts(SecondsFormat::Secs, true)
}

#[sqlx::test(migrator = "MIGRATOR")]
#[ignore = "seeds a year of data; run on purpose, see docs/deploy.md"]
async fn one_year_of_data_reads_each_web_page_under_a_second(pool: PgPool) {
    setup_user(&pool).await;
    let user = user_id(&pool).await;
    let (_, rows) = seed(&pool, user).await;

    let app = app(pool.clone());
    let cookie = login(&app).await;

    let now = Utc::now();
    let today = now.date_naive();
    let routes = [
        (
            "hr 6 h, raw",
            format!(
                "/v1/metrics/hr?from={}&to={}&res=raw",
                stamp(now - ChronoDuration::hours(6)),
                stamp(now)
            ),
        ),
        (
            "hr 24 h, 1m",
            format!(
                "/v1/metrics/hr?from={}&to={}&res=1m",
                stamp(now - ChronoDuration::hours(24)),
                stamp(now)
            ),
        ),
        (
            "hr 7 d, 5m",
            format!(
                "/v1/metrics/hr?from={}&to={}&res=5m",
                stamp(now - ChronoDuration::days(7)),
                stamp(now)
            ),
        ),
        (
            "minutes 24 h",
            format!(
                "/v1/metrics/minutes?from={}&to={}",
                stamp(now - ChronoDuration::hours(24)),
                stamp(now)
            ),
        ),
        (
            "daily 365 d",
            format!(
                "/v1/metrics/daily?from={}&to={}",
                today - ChronoDuration::days(364),
                today
            ),
        ),
        ("live", "/v1/metrics/live".to_owned()),
    ];

    println!("\nseeded {rows} rows for one user");
    println!("{:<16} {:>12} {:>12}", "route", "median ms", "max ms");
    let mut slowest = Duration::ZERO;
    for (name, uri) in &routes {
        // The first call warms the plan and page cache; it is not counted.
        let warm = send(&app, web_get(uri, &cookie)).await;
        assert_eq!(warm.status(), StatusCode::OK, "{name}");
        drop(body_bytes(warm).await);

        let mut timings = Vec::with_capacity(RUNS);
        for _ in 0..RUNS {
            let started = Instant::now();
            let res = send(&app, web_get(uri, &cookie)).await;
            let status = res.status();
            drop(body_bytes(res).await);
            timings.push(started.elapsed());
            assert_eq!(status, StatusCode::OK, "{name}");
        }
        timings.sort();
        let median = timings[RUNS / 2];
        let max = *timings.last().unwrap();
        slowest = slowest.max(max);
        println!(
            "{:<16} {:>12.1} {:>12.1}",
            name,
            median.as_secs_f64() * 1000.0,
            max.as_secs_f64() * 1000.0
        );
        assert!(
            median < BUDGET,
            "{name} takes {median:?} at the median, over the {BUDGET:?} page budget"
        );
    }
    println!("slowest run: {:.1} ms", slowest.as_secs_f64() * 1000.0);
}

fn web_get(uri: &str, cookie: &str) -> axum::http::Request<Body> {
    request("GET", uri, &[("cookie", cookie)], None)
}
