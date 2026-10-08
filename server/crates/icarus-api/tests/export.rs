mod common;

use std::collections::BTreeSet;

use axum::http::StatusCode;
use common::*;
use serde_json::{Value, json};
use sqlx::PgPool;
use uuid::Uuid;

const KINDS: [&str; 11] = [
    "me",
    "device",
    "band",
    "hr",
    "rr",
    "minute_metric",
    "daily_summary",
    "event",
    "alarm",
    "hook",
    "dispatch",
];

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn export_contains_every_kind_as_ndjson_without_secrets(pool: PgPool) {
    setup_user(&pool).await;
    let app = app_with_key(pool.clone());
    let cookie = login(&app).await;
    let (_, _) = pair_device(&app, &cookie, "Caleb's iPhone").await;

    let alarm = json(
        send(
            &app,
            web("POST", "/v1/alarms", &cookie, Some(json!({ "kind": "webhook", "label": "Front door", "rhythm": "double", "channels": ["phone"] }))),
        )
        .await,
    )
    .await;
    let alarm_id = alarm["id"].as_str().unwrap().to_owned();
    let hook = json(
        send(
            &app,
            web(
                "POST",
                "/v1/hooks",
                &cookie,
                Some(json!({ "label": "Door", "alarm_id": alarm_id, "auth_mode": "secret_url" })),
            ),
        )
        .await,
    )
    .await;
    let secret = hook["secret"].as_str().unwrap().to_owned();
    let queued = send(
        &app,
        web(
            "POST",
            &format!("/v1/alarms/{alarm_id}/test"),
            &cookie,
            None,
        ),
    )
    .await;
    assert_eq!(queued.status(), StatusCode::ACCEPTED);

    // Time series and daily rows, seeded directly.
    let user = user_id(&pool).await;
    let band = Uuid::now_v7();
    sqlx::query("INSERT INTO bands (id, user_id, name) VALUES ($1, $2, 'WHOOP 4.0')")
        .bind(band)
        .bind(user)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO hr_samples (band_id, ts, bpm, source, contact, batch_id) VALUES ($1, '2026-10-07 10:00:00.250+00', 61, 1, true, gen_random_uuid())")
        .bind(band)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO rr_intervals (band_id, ts, seq, rr_ms, accepted, batch_id) VALUES ($1, '2026-10-07 10:00:00+00', 0, 812.5, true, gen_random_uuid())")
        .bind(band)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO band_events (band_id, ts, kind, payload, batch_id) VALUES ($1, '2026-10-07 10:00:01+00', 'wrist_off', '{}', gen_random_uuid())")
        .bind(band)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO minute_metrics (user_id, minute, hr_avg, algo_version, sync_rev) VALUES ($1, '2026-10-07 10:00:00+00', 60, 1, 1)")
        .bind(user)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO daily_summaries (user_id, day, rhr, algo_version, computed_at) VALUES ($1, '2026-10-07', 52, 1, now())")
        .bind(user)
        .execute(&pool)
        .await
        .unwrap();

    let res = send(&app, web("GET", "/v1/export", &cookie, None)).await;
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(res.headers()["content-type"], "application/x-ndjson");
    let text = String::from_utf8(body_bytes(res).await).unwrap();

    let mut kinds = BTreeSet::new();
    let mut lines: Vec<Value> = Vec::new();
    for line in text.lines() {
        let value: Value =
            serde_json::from_str(line).unwrap_or_else(|e| panic!("line is not JSON ({e}): {line}"));
        kinds.insert(
            value["kind"]
                .as_str()
                .expect("every line has a kind")
                .to_owned(),
        );
        lines.push(value);
    }
    for kind in KINDS {
        assert!(kinds.contains(kind), "missing {kind}: {kinds:?}");
    }
    assert!(!text.contains(&secret), "the hook secret is never exported");
    assert!(!text.contains("secret_ciphertext"));
    assert!(!text.contains("password_hash"));

    let hr = lines.iter().find(|l| l["kind"] == "hr").unwrap();
    assert_eq!(
        hr["ts"], "2026-10-07T10:00:00.250Z",
        "time series keep milliseconds"
    );
    let event = lines.iter().find(|l| l["kind"] == "event").unwrap();
    assert_eq!(
        event["event_kind"], "wrist_off",
        "the band event's own kind is renamed"
    );
    let alarm_line = lines.iter().find(|l| l["kind"] == "alarm").unwrap();
    assert_eq!(alarm_line["alarm_kind"], "webhook");
    let me = lines.iter().find(|l| l["kind"] == "me").unwrap();
    assert_eq!(me["email"], EMAIL);
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn export_needs_a_web_session(pool: PgPool) {
    setup_user(&pool).await;
    let app = app(pool.clone());
    let cookie = login(&app).await;
    let (_, token) = pair_device(&app, &cookie, "iPhone").await;
    expect_problem(
        send(&app, device("GET", "/v1/export", &token, None)).await,
        StatusCode::FORBIDDEN,
        "forbidden",
    )
    .await;
}
