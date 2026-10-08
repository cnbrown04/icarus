mod common;

use std::io::Write;

use axum::http::StatusCode;
use common::*;
use flate2::{Compression, write::GzEncoder};
use serde_json::{Value, json};
use sqlx::PgPool;
use uuid::Uuid;

/// Local 00:00 on 2026-10-07 in America/Chicago (CDT) is 05:00Z.
const LOCAL_MIDNIGHT: &str = "2026-10-07T05:00:00Z";

fn minute_at(base: &str, minutes: i64) -> i64 {
    ms(base) + minutes * 60_000
}

fn hr_batch(batch_id: Uuid, device_id: Uuid, band_id: Uuid, ts_ms: &[i64]) -> Value {
    let n = ts_ms.len();
    json!({
        "schema": 1,
        "batch_id": batch_id,
        "device_id": device_id,
        "created_at": "2026-10-07T14:30:00Z",
        "bands": [{ "id": band_id, "name": "WHOOP 4.0", "firmware": "4.0.1" }],
        "hr": { "band_id": band_id, "ts_ms": ts_ms, "bpm": vec![60; n], "source": vec![1; n], "contact": vec![true; n] },
        "rr": null,
        "minute_metrics": [],
        "events": [],
        "alarm_deliveries": [],
        "cursors": { "hr_sample": 1, "rr_interval": 1 }
    })
}

fn minute(minute_ms: i64, hr_avg: f64, sync_rev: i64) -> Value {
    json!({
        "minute_ms": minute_ms, "hr_avg": hr_avg, "hr_min": 58, "hr_max": 66, "hr_n": 60,
        "rmssd_ms": 42.1, "sdnn_ms": 50.3, "baevsky_sqrt": 9.1, "stress": 31, "stress_state": "value",
        "kcal": 1.4, "active_kcal": 0.2, "kcal_estimated": false, "algo_version": 1, "sync_rev": sync_rev
    })
}

async fn paired(pool: &PgPool) -> (axum::Router, String, String) {
    setup_user(pool).await;
    let app = app(pool.clone());
    let cookie = login(&app).await;
    let (device_id, token) = pair_device(&app, &cookie, "Caleb's iPhone").await;
    (app, device_id, token)
}

async fn post_batch(
    app: &axum::Router,
    token: &str,
    batch: &Value,
) -> axum::http::Response<axum::body::Body> {
    let key = batch["batch_id"].as_str().unwrap().to_owned();
    send(
        app,
        request(
            "POST",
            "/v1/sync/batches",
            &[
                ("authorization", &format!("Bearer {token}")),
                ("idempotency-key", &key),
            ],
            Some(batch.clone()),
        ),
    )
    .await
}

async fn count(pool: &PgPool, sql: &str) -> i64 {
    sqlx::query_scalar(sql).fetch_one(pool).await.unwrap()
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn same_batch_twice_stores_one_set_of_rows(pool: PgPool) {
    let (app, device_id, token) = paired(&pool).await;
    let batch_id = Uuid::now_v7();
    let band = Uuid::now_v7();
    let ts: Vec<i64> = (0..3).map(|i| minute_at(LOCAL_MIDNIGHT, i)).collect();
    let batch = hr_batch(batch_id, device_id.parse().unwrap(), band, &ts);

    let first = json(post_batch(&app, &token, &batch).await).await;
    assert_eq!(first["duplicate"], false);
    assert_eq!(
        first["counts"]["hr"],
        json!({ "inserted": 3, "duplicate": 0 })
    );
    assert_eq!(
        first["counts"]["minute_metrics"],
        json!({ "upserted": 0, "stale": 0 })
    );

    let again = post_batch(&app, &token, &batch).await;
    assert_eq!(again.status(), StatusCode::OK);
    let second = json(again).await;
    assert_eq!(second["duplicate"], true);
    assert_eq!(second["counts"], first["counts"]);

    assert_eq!(count(&pool, "SELECT count(*) FROM hr_samples").await, 3);
    assert_eq!(count(&pool, "SELECT count(*) FROM sync_batches").await, 1);
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn partial_overlap_counts_inserted_and_duplicate_rows(pool: PgPool) {
    let (app, device_id, token) = paired(&pool).await;
    let band = Uuid::now_v7();
    let device: Uuid = device_id.parse().unwrap();
    let first: Vec<i64> = (0..2).map(|i| minute_at(LOCAL_MIDNIGHT, i)).collect();
    post_batch(
        &app,
        &token,
        &hr_batch(Uuid::now_v7(), device, band, &first),
    )
    .await;

    // Two rows are already stored (minutes 0 and 1), two are new (minutes 2 and 3).
    let overlap: Vec<i64> = (0..4).map(|i| minute_at(LOCAL_MIDNIGHT, i)).collect();
    let res = json(
        post_batch(
            &app,
            &token,
            &hr_batch(Uuid::now_v7(), device, band, &overlap),
        )
        .await,
    )
    .await;
    assert_eq!(
        res["counts"]["hr"],
        json!({ "inserted": 2, "duplicate": 2 })
    );
    assert_eq!(count(&pool, "SELECT count(*) FROM hr_samples").await, 4);
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn gzip_bodies_are_decoded(pool: PgPool) {
    let (app, device_id, token) = paired(&pool).await;
    let batch_id = Uuid::now_v7();
    let band = Uuid::now_v7();
    let ts: Vec<i64> = (0..50)
        .map(|i| minute_at(LOCAL_MIDNIGHT, 0) + i * 1000)
        .collect();
    let body = hr_batch(batch_id, device_id.parse().unwrap(), band, &ts).to_string();

    let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
    encoder.write_all(body.as_bytes()).unwrap();
    let gzipped = encoder.finish().unwrap();
    assert!(gzipped.len() < body.len());

    let key = batch_id.to_string();
    let res = send(
        &app,
        axum::http::Request::builder()
            .method("POST")
            .uri("/v1/sync/batches")
            .header("authorization", format!("Bearer {token}"))
            .header("idempotency-key", key)
            .header("content-encoding", "gzip")
            .header("content-type", "application/json")
            .body(axum::body::Body::from(gzipped))
            .unwrap(),
    )
    .await;
    assert_eq!(res.status(), StatusCode::OK);
    let body = json(res).await;
    assert_eq!(body["counts"]["hr"]["inserted"], 50);
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn bodies_over_two_megabytes_are_413(pool: PgPool) {
    let (app, device_id, token) = paired(&pool).await;
    let batch_id = Uuid::now_v7();
    let mut batch = hr_batch(batch_id, device_id.parse().unwrap(), Uuid::now_v7(), &[]);
    // Padding in an event payload, so the decoded body is over 2 MB.
    batch["events"] = json!([{
        "band_id": Uuid::now_v7(), "ts_ms": 0, "kind": "wrist_on", "payload": { "pad": "x".repeat(2 * 1024 * 1024) }
    }]);
    let res = post_batch(&app, &token, &batch).await;
    expect_problem(res, StatusCode::PAYLOAD_TOO_LARGE, "payload-too-large").await;
    assert_eq!(count(&pool, "SELECT count(*) FROM sync_batches").await, 0);
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn gzip_bodies_are_limited_after_decompression(pool: PgPool) {
    let (app, device_id, token) = paired(&pool).await;
    let batch_id = Uuid::now_v7();
    let mut batch = hr_batch(batch_id, device_id.parse().unwrap(), Uuid::now_v7(), &[]);
    batch["events"] = json!([{
        "band_id": Uuid::now_v7(), "ts_ms": 0, "kind": "wrist_on", "payload": { "pad": "x".repeat(3 * 1024 * 1024) }
    }]);
    let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
    encoder.write_all(batch.to_string().as_bytes()).unwrap();
    let gzipped = encoder.finish().unwrap();
    assert!(
        gzipped.len() < 2 * 1024 * 1024,
        "compressed size is under the limit"
    );

    let res = send(
        &app,
        axum::http::Request::builder()
            .method("POST")
            .uri("/v1/sync/batches")
            .header("authorization", format!("Bearer {token}"))
            .header("idempotency-key", batch_id.to_string())
            .header("content-encoding", "gzip")
            .body(axum::body::Body::from(gzipped))
            .unwrap(),
    )
    .await;
    expect_problem(res, StatusCode::PAYLOAD_TOO_LARGE, "payload-too-large").await;
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn more_than_20000_series_rows_is_413(pool: PgPool) {
    let (app, device_id, token) = paired(&pool).await;
    let ts: Vec<i64> = (0..20_001)
        .map(|i| minute_at(LOCAL_MIDNIGHT, 0) + i)
        .collect();
    let batch = hr_batch(
        Uuid::now_v7(),
        device_id.parse().unwrap(),
        Uuid::now_v7(),
        &ts,
    );
    let res = post_batch(&app, &token, &batch).await;
    expect_problem(res, StatusCode::PAYLOAD_TOO_LARGE, "payload-too-large").await;
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn invalid_batches_are_rejected_before_any_write(pool: PgPool) {
    let (app, device_id, token) = paired(&pool).await;
    let device: Uuid = device_id.parse().unwrap();
    let band = Uuid::now_v7();
    let ts = [minute_at(LOCAL_MIDNIGHT, 0)];

    // Column arrays of different lengths.
    let mut mismatched = hr_batch(Uuid::now_v7(), device, band, &ts);
    mismatched["hr"]["bpm"] = json!([60, 61]);
    expect_problem(
        post_batch(&app, &token, &mismatched).await,
        StatusCode::BAD_REQUEST,
        "validation",
    )
    .await;

    // Heart rate outside 20 to 250.
    let mut bad_bpm = hr_batch(Uuid::now_v7(), device, band, &ts);
    bad_bpm["hr"]["bpm"] = json!([251]);
    expect_problem(
        post_batch(&app, &token, &bad_bpm).await,
        StatusCode::BAD_REQUEST,
        "validation",
    )
    .await;

    // Batch sent by a different device than the token.
    let other = hr_batch(Uuid::now_v7(), Uuid::now_v7(), band, &ts);
    expect_problem(
        post_batch(&app, &token, &other).await,
        StatusCode::FORBIDDEN,
        "forbidden",
    )
    .await;

    // Idempotency-Key must match batch_id.
    let batch = hr_batch(Uuid::now_v7(), device, band, &ts);
    let wrong_key = send(
        &app,
        request(
            "POST",
            "/v1/sync/batches",
            &[
                ("authorization", &format!("Bearer {token}")),
                ("idempotency-key", &Uuid::now_v7().to_string()),
            ],
            Some(batch.clone()),
        ),
    )
    .await;
    expect_problem(wrong_key, StatusCode::BAD_REQUEST, "validation").await;
    let no_key = send(
        &app,
        request(
            "POST",
            "/v1/sync/batches",
            &[("authorization", &format!("Bearer {token}"))],
            Some(batch.clone()),
        ),
    )
    .await;
    expect_problem(no_key, StatusCode::BAD_REQUEST, "validation").await;

    // Unknown schema version.
    let mut schema = hr_batch(Uuid::now_v7(), device, band, &ts);
    schema["schema"] = json!(2);
    expect_problem(
        post_batch(&app, &token, &schema).await,
        StatusCode::BAD_REQUEST,
        "validation",
    )
    .await;

    // Band that belongs to nobody on this account.
    let mut foreign = hr_batch(Uuid::now_v7(), device, band, &ts);
    foreign["bands"] = json!([]);
    foreign["hr"]["band_id"] = json!(Uuid::now_v7());
    expect_problem(
        post_batch(&app, &token, &foreign).await,
        StatusCode::BAD_REQUEST,
        "validation",
    )
    .await;

    assert_eq!(count(&pool, "SELECT count(*) FROM hr_samples").await, 0);
    assert_eq!(count(&pool, "SELECT count(*) FROM sync_batches").await, 0);
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn minute_metrics_only_upsert_on_a_higher_sync_rev(pool: PgPool) {
    let (app, device_id, token) = paired(&pool).await;
    let device: Uuid = device_id.parse().unwrap();
    let m = minute_at(LOCAL_MIDNIGHT, 0);

    let mut first = hr_batch(Uuid::now_v7(), device, Uuid::now_v7(), &[]);
    first["minute_metrics"] = json!([minute(m, 60.0, 1)]);
    let r1 = json(post_batch(&app, &token, &first).await).await;
    assert_eq!(
        r1["counts"]["minute_metrics"],
        json!({ "upserted": 1, "stale": 0 })
    );

    // Same revision: stale, value unchanged.
    let mut same = hr_batch(Uuid::now_v7(), device, Uuid::now_v7(), &[]);
    same["minute_metrics"] = json!([minute(m, 70.0, 1)]);
    let r2 = json(post_batch(&app, &token, &same).await).await;
    assert_eq!(
        r2["counts"]["minute_metrics"],
        json!({ "upserted": 0, "stale": 1 })
    );

    // Higher revision: replaces the value.
    let mut newer = hr_batch(Uuid::now_v7(), device, Uuid::now_v7(), &[]);
    newer["minute_metrics"] = json!([minute(m, 80.0, 2)]);
    let r3 = json(post_batch(&app, &token, &newer).await).await;
    assert_eq!(
        r3["counts"]["minute_metrics"],
        json!({ "upserted": 1, "stale": 0 })
    );

    let (hr_avg, sync_rev): (f32, i32) =
        sqlx::query_as("SELECT hr_avg, sync_rev FROM minute_metrics WHERE minute = to_timestamp($1::float8 / 1000)")
            .bind(m)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!((hr_avg, sync_rev), (80.0, 2));

    // Two revisions of one minute in a single batch: the higher one wins.
    let mut both = hr_batch(Uuid::now_v7(), device, Uuid::now_v7(), &[]);
    let m2 = minute_at(LOCAL_MIDNIGHT, 1);
    both["minute_metrics"] = json!([minute(m2, 61.0, 5), minute(m2, 99.0, 4)]);
    let r4 = json(post_batch(&app, &token, &both).await).await;
    assert_eq!(
        r4["counts"]["minute_metrics"],
        json!({ "upserted": 1, "stale": 1 })
    );
    let stored: f32 = sqlx::query_scalar(
        "SELECT hr_avg FROM minute_metrics WHERE minute = to_timestamp($1::float8 / 1000)",
    )
    .bind(m2)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(stored, 61.0);
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn batches_refresh_the_daily_summary_in_the_user_timezone(pool: PgPool) {
    let (app, device_id, token) = paired(&pool).await;
    let device: Uuid = device_id.parse().unwrap();
    let mut batch = hr_batch(Uuid::now_v7(), device, Uuid::now_v7(), &[]);
    batch["minute_metrics"] = json!(
        (0..10)
            .map(|i| minute(minute_at(LOCAL_MIDNIGHT, i), 60.0 + i as f64, 1))
            .collect::<Vec<_>>()
    );
    let res = json(post_batch(&app, &token, &batch).await).await;
    assert_eq!(res["counts"]["minute_metrics"]["upserted"], 10);

    let (rhr, coverage): (Option<i16>, f32) =
        sqlx::query_as("SELECT rhr, coverage FROM daily_summaries WHERE day = DATE '2026-10-07'")
            .fetch_one(&pool)
            .await
            .unwrap();
    // Ten qualifying minutes give six rolling windows. The lowest is the mean of 60..=64, which is 62.
    assert_eq!(rhr, Some(62));
    assert!((coverage - 10.0 / 1440.0).abs() < 1e-6);
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn config_returns_changes_since_a_version_including_tombstones(pool: PgPool) {
    let (app, _, token) = paired(&pool).await;
    let user: Uuid = sqlx::query_scalar("SELECT id FROM users WHERE email = $1")
        .bind(EMAIL)
        .fetch_one(&pool)
        .await
        .unwrap();
    // Sequence values are assigned in insert order.
    for (label, deleted) in [("Wake up", false), ("Old reminder", true)] {
        sqlx::query(
            "INSERT INTO alarms (id, user_id, kind, label, schedule, rhythm, channels, enabled, deleted_at)
             VALUES ($1, $2, 'scheduled', $3, '{\"time\":\"06:30\",\"weekdays\":[1,2,3,4,5]}', '\"double\"',
                     ARRAY['phone','band'], true, CASE WHEN $4 THEN now() ELSE NULL END)",
        )
        .bind(Uuid::now_v7())
        .bind(user)
        .bind(label)
        .bind(deleted)
        .execute(&pool)
        .await
        .unwrap();
    }
    let versions: Vec<i64> = sqlx::query_scalar("SELECT version FROM alarms ORDER BY version")
        .fetch_all(&pool)
        .await
        .unwrap();
    let (first, second) = (versions[0], versions[1]);

    let all = json(send(&app, device("GET", "/v1/sync/config?since=0", &token, None)).await).await;
    assert_eq!(all["alarms"].as_array().unwrap().len(), 2);
    assert_eq!(all["alarms"][0]["schedule"]["time"], "06:30");
    assert_eq!(all["alarms"][0]["rhythm"], "double");
    assert_eq!(all["max_version"], second);
    assert_eq!(all["profile"]["email"], EMAIL);
    assert!(all["webhook_endpoints"].as_array().unwrap().is_empty());

    let since_first = json(
        send(
            &app,
            device(
                "GET",
                &format!("/v1/sync/config?since={first}"),
                &token,
                None,
            ),
        )
        .await,
    )
    .await;
    let alarms = since_first["alarms"].as_array().unwrap();
    assert_eq!(alarms.len(), 1, "only the change after `since`");
    assert_eq!(alarms[0]["label"], "Old reminder");
    assert!(alarms[0]["deleted_at"].is_string(), "tombstone is returned");
    assert_eq!(since_first["max_version"], second);

    let none = json(
        send(
            &app,
            device(
                "GET",
                &format!("/v1/sync/config?since={second}"),
                &token,
                None,
            ),
        )
        .await,
    )
    .await;
    assert!(none["alarms"].as_array().unwrap().is_empty());

    let bad = send(
        &app,
        device("GET", "/v1/sync/config?since=-1", &token, None),
    )
    .await;
    expect_problem(bad, StatusCode::BAD_REQUEST, "validation").await;
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn sync_state_lists_recent_batches(pool: PgPool) {
    let (app, device_id, token) = paired(&pool).await;
    let batch_id = Uuid::now_v7();
    let batch = hr_batch(
        batch_id,
        device_id.parse().unwrap(),
        Uuid::now_v7(),
        &[minute_at(LOCAL_MIDNIGHT, 0)],
    );
    post_batch(&app, &token, &batch).await;

    let state = json(send(&app, device("GET", "/v1/sync/state", &token, None)).await).await;
    assert!(state["last_batch_at"].is_string());
    let batches = state["batches"].as_array().unwrap();
    assert_eq!(batches.len(), 1);
    assert_eq!(batches[0]["id"], batch_id.to_string());
    assert_eq!(batches[0]["status"], "accepted");
    assert_eq!(batches[0]["counts"]["hr"]["inserted"], 1);
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn events_and_alarm_deliveries_are_stored_idempotently(pool: PgPool) {
    let (app, device_id, token) = paired(&pool).await;
    let device: Uuid = device_id.parse().unwrap();
    let band = Uuid::now_v7();
    let delivery = Uuid::now_v7();
    let mut batch = hr_batch(Uuid::now_v7(), device, band, &[]);
    batch["events"] = json!([
        { "band_id": band, "ts_ms": minute_at(LOCAL_MIDNIGHT, 0), "kind": "wrist_off", "payload": {} },
        { "band_id": band, "ts_ms": minute_at(LOCAL_MIDNIGHT, 0), "kind": "wrist_off", "payload": {} }
    ]);
    batch["alarm_deliveries"] = json!([{
        "id": delivery, "alarm_id": null, "dispatch_id": null, "ts_ms": minute_at(LOCAL_MIDNIGHT, 1),
        "channel": "phone", "status": "shown", "detail": null
    }]);
    let res = json(post_batch(&app, &token, &batch).await).await;
    assert_eq!(
        res["counts"]["events"],
        json!({ "inserted": 1, "duplicate": 1 })
    );
    assert_eq!(
        res["counts"]["alarm_deliveries"],
        json!({ "inserted": 1, "duplicate": 0 })
    );

    let mut again = hr_batch(Uuid::now_v7(), device, band, &[]);
    again["alarm_deliveries"] = batch["alarm_deliveries"].clone();
    let res = json(post_batch(&app, &token, &again).await).await;
    assert_eq!(
        res["counts"]["alarm_deliveries"],
        json!({ "inserted": 0, "duplicate": 1 })
    );
    assert_eq!(
        count(&pool, "SELECT count(*) FROM alarm_deliveries").await,
        1
    );
    assert_eq!(count(&pool, "SELECT count(*) FROM band_events").await, 1);
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn rr_intervals_are_stored_and_deduplicated(pool: PgPool) {
    let (app, device_id, token) = paired(&pool).await;
    let device: Uuid = device_id.parse().unwrap();
    let band = Uuid::now_v7();
    let base = minute_at(LOCAL_MIDNIGHT, 0);
    let rr = |offset: i64| {
        json!({ "band_id": band, "ts_ms": [base + offset, base + offset], "seq": [0, 1],
                "rr_ms": [812.5, 790.0], "accepted": [true, false] })
    };
    let mut first = hr_batch(Uuid::now_v7(), device, band, &[]);
    first["rr"] = rr(0);
    let r1 = json(post_batch(&app, &token, &first).await).await;
    assert_eq!(r1["counts"]["rr"], json!({ "inserted": 2, "duplicate": 0 }));

    let mut second = hr_batch(Uuid::now_v7(), device, band, &[]);
    second["rr"] = rr(0);
    let r2 = json(post_batch(&app, &token, &second).await).await;
    assert_eq!(r2["counts"]["rr"], json!({ "inserted": 0, "duplicate": 2 }));

    let accepted: i64 = count(&pool, "SELECT count(*) FROM rr_intervals WHERE accepted").await;
    assert_eq!(accepted, 1);
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn deleting_the_account_removes_its_time_series(pool: PgPool) {
    let (app, device_id, token) = paired(&pool).await;
    let device: Uuid = device_id.parse().unwrap();
    let band = Uuid::now_v7();
    let mut batch = hr_batch(
        Uuid::now_v7(),
        device,
        band,
        &[minute_at(LOCAL_MIDNIGHT, 0)],
    );
    batch["rr"] = json!({ "band_id": band, "ts_ms": [minute_at(LOCAL_MIDNIGHT, 0)], "seq": [0], "rr_ms": [800.0], "accepted": [true] });
    batch["minute_metrics"] = json!([minute(minute_at(LOCAL_MIDNIGHT, 0), 60.0, 1)]);
    post_batch(&app, &token, &batch).await;
    assert_eq!(count(&pool, "SELECT count(*) FROM hr_samples").await, 1);

    let cookie = login(&app).await;
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

    for table in [
        "hr_samples",
        "rr_intervals",
        "minute_metrics",
        "bands",
        "sync_batches",
        "daily_summaries",
    ] {
        assert_eq!(
            count(&pool, &format!("SELECT count(*) FROM {table}")).await,
            0,
            "{table}"
        );
    }
}
