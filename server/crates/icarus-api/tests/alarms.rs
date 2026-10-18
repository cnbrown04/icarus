mod common;

use axum::{Router, http::StatusCode};
use common::*;
use serde_json::{Value, json};
use sqlx::PgPool;

fn wake_up() -> Value {
    json!({
        "kind": "scheduled", "label": "Wake up",
        "schedule": { "time": "06:30", "weekdays": [1, 2, 3, 4, 5] },
        "rhythm": "double", "channels": ["phone", "band"]
    })
}

async fn setup(pool: &PgPool) -> (Router, String, String) {
    setup_user(pool).await;
    let app = app(pool.clone());
    let cookie = login(&app).await;
    let (_, token) = pair_device(&app, &cookie, "Caleb's iPhone").await;
    (app, cookie, token)
}

fn with_header(
    method: &str,
    uri: &str,
    cookie: &str,
    if_match: Option<i64>,
    body: Option<Value>,
) -> axum::http::Request<axum::body::Body> {
    let version = if_match.map(|v| v.to_string());
    let mut headers = vec![("cookie", cookie), ("x-icarus-csrf", "1")];
    if let Some(v) = version.as_deref() {
        headers.push(("if-match", v));
    }
    request(method, uri, &headers, body)
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn alarm_crud_uses_if_match_and_soft_deletes(pool: PgPool) {
    let (app, cookie, token) = setup(&pool).await;

    let created = send(&app, web("POST", "/v1/alarms", &cookie, Some(wake_up()))).await;
    assert_eq!(created.status(), StatusCode::CREATED);
    let alarm = json(created).await;
    let id = alarm["id"].as_str().unwrap().to_owned();
    let version = alarm["version"].as_i64().unwrap();
    assert_eq!(alarm["schedule"]["time"], "06:30");
    assert_eq!(alarm["rhythm"], "double");
    assert!(alarm["deleted_at"].is_null());

    let list = json(send(&app, web("GET", "/v1/alarms", &cookie, None)).await).await;
    assert_eq!(list["alarms"].as_array().unwrap().len(), 1);

    // PATCH needs If-Match: 428 without it, 409 with a stale version.
    let uri = format!("/v1/alarms/{id}");
    let no_header = send(
        &app,
        web("PATCH", &uri, &cookie, Some(json!({ "label": "Up" }))),
    )
    .await;
    expect_problem(no_header, StatusCode::PRECONDITION_REQUIRED, "validation").await;
    let stale = send(
        &app,
        with_header(
            "PATCH",
            &uri,
            &cookie,
            Some(version + 5),
            Some(json!({ "label": "Up" })),
        ),
    )
    .await;
    let conflict = expect_problem(stale, StatusCode::CONFLICT, "conflict").await;
    assert_eq!(conflict["current"]["version"], version);

    let patched = send(
        &app,
        with_header(
            "PATCH",
            &uri,
            &cookie,
            Some(version),
            Some(json!({ "label": "Up" })),
        ),
    )
    .await;
    assert_eq!(patched.status(), StatusCode::OK);
    let patched = json(patched).await;
    assert_eq!(patched["label"], "Up");
    assert!(
        patched["version"].as_i64().unwrap() > version,
        "version bumps"
    );
    let new_version = patched["version"].as_i64().unwrap();

    // Clearing the schedule on a scheduled alarm is invalid.
    let bad = send(
        &app,
        with_header(
            "PATCH",
            &uri,
            &cookie,
            Some(new_version),
            Some(json!({ "schedule": null })),
        ),
    )
    .await;
    expect_problem(bad, StatusCode::BAD_REQUEST, "validation").await;

    // DELETE: a stale If-Match conflicts, a correct one soft-deletes.
    let stale_delete = send(&app, with_header("DELETE", &uri, &cookie, Some(1), None)).await;
    expect_problem(stale_delete, StatusCode::CONFLICT, "conflict").await;
    let deleted = send(
        &app,
        with_header("DELETE", &uri, &cookie, Some(new_version), None),
    )
    .await;
    assert_eq!(deleted.status(), StatusCode::NO_CONTENT);

    let list = json(send(&app, web("GET", "/v1/alarms", &cookie, None)).await).await;
    assert!(
        list["alarms"].as_array().unwrap().is_empty(),
        "tombstones are hidden"
    );

    // The sync config still returns the tombstone with a newer version, so the app can drop it.
    let config =
        json(send(&app, device("GET", "/v1/sync/config?since=0", &token, None)).await).await;
    let tomb = &config["alarms"][0];
    assert_eq!(tomb["id"], id);
    assert!(tomb["deleted_at"].is_string());
    assert!(tomb["version"].as_i64().unwrap() > new_version);

    // A deleted alarm cannot be edited, deleted again or tested.
    let gone = send(
        &app,
        with_header(
            "PATCH",
            &uri,
            &cookie,
            Some(0),
            Some(json!({ "label": "x" })),
        ),
    )
    .await;
    expect_problem(gone, StatusCode::NOT_FOUND, "not-found").await;
    let test = send(
        &app,
        web("POST", &format!("/v1/alarms/{id}/test"), &cookie, None),
    )
    .await;
    expect_problem(test, StatusCode::NOT_FOUND, "not-found").await;
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn alarm_validation_follows_the_rhythm_and_schedule_rules(pool: PgPool) {
    let (app, cookie, _) = setup(&pool).await;
    let cases = [
        // Rhythm longer than 30 s: 31 loops.
        json!({ "kind": "webhook", "label": "x", "rhythm": [{ "type": "buzz", "preset": 2, "loops": 31 }], "channels": ["phone"] }),
        // More than 10 steps.
        json!({ "kind": "webhook", "label": "x", "rhythm": vec![json!({ "type": "pause", "ms": 1 }); 11], "channels": ["phone"] }),
        // A scheduled alarm without a schedule.
        json!({ "kind": "scheduled", "label": "x", "rhythm": "single", "channels": ["phone"] }),
        // A webhook alarm with a schedule.
        json!({ "kind": "webhook", "label": "x", "schedule": { "time": "06:30", "weekdays": [] }, "rhythm": "single", "channels": ["phone"] }),
        // Bad schedule time.
        json!({ "kind": "scheduled", "label": "x", "schedule": { "time": "25:00", "weekdays": [] }, "rhythm": "single", "channels": ["phone"] }),
        // No channels, and a repeated channel.
        json!({ "kind": "relay", "label": "x", "rhythm": "single", "channels": [] }),
        json!({ "kind": "relay", "label": "x", "rhythm": "single", "channels": ["band", "band"] }),
        // Unknown rhythm name and unknown fields.
        json!({ "kind": "relay", "label": "x", "rhythm": "polka", "channels": ["phone"] }),
        json!({ "kind": "relay", "label": "x", "rhythm": "single", "channels": ["phone"], "version": 3 }),
        json!({ "kind": "relay", "label": "  ", "rhythm": "single", "channels": ["phone"] }),
    ];
    for case in cases {
        let res = send(&app, web("POST", "/v1/alarms", &cookie, Some(case.clone()))).await;
        assert_eq!(res.status(), StatusCode::BAD_REQUEST, "{case}");
    }
    let valid = json!({
        "kind": "relay", "label": "Door",
        "rhythm": [{ "type": "buzz", "preset": 2, "loops": 1 }, { "type": "pause", "ms": 300 }],
        "channels": ["band"]
    });
    assert_eq!(
        send(&app, web("POST", "/v1/alarms", &cookie, Some(valid)))
            .await
            .status(),
        StatusCode::CREATED
    );
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn creating_the_same_id_twice_conflicts_with_the_stored_alarm(pool: PgPool) {
    let (app, cookie, _) = setup(&pool).await;
    let id = "0190a3c4-0000-7000-8000-000000000001";
    let mut body = wake_up();
    body["id"] = json!(id);
    assert_eq!(
        send(&app, web("POST", "/v1/alarms", &cookie, Some(body.clone())))
            .await
            .status(),
        StatusCode::CREATED
    );
    let again = send(&app, web("POST", "/v1/alarms", &cookie, Some(body))).await;
    let conflict = expect_problem(again, StatusCode::CONFLICT, "conflict").await;
    assert_eq!(conflict["current"]["id"], id);
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn test_push_flows_through_pending_ack_and_history(pool: PgPool) {
    let (app, cookie, token) = setup(&pool).await;
    let alarm = json(send(&app, web("POST", "/v1/alarms", &cookie, Some(wake_up()))).await).await;
    let alarm_id = alarm["id"].as_str().unwrap().to_owned();

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
    let dispatch_id = json(queued).await["dispatch_id"]
        .as_str()
        .unwrap()
        .to_owned();

    // Pull list: the app sees the unacked test dispatch with the alarm's rhythm.
    let pending = json(send(&app, device("GET", "/v1/alarms/pending", &token, None)).await).await;
    let dispatches = pending["dispatches"].as_array().unwrap();
    assert_eq!(dispatches.len(), 1);
    assert_eq!(dispatches[0]["id"], dispatch_id);
    assert_eq!(dispatches[0]["status"], "pending");
    assert_eq!(dispatches[0]["rhythm"], "double");
    assert_eq!(dispatches[0]["alarm_id"], alarm_id);

    // The pull list is for the app only.
    let web_pull = send(&app, web("GET", "/v1/alarms/pending", &cookie, None)).await;
    expect_problem(web_pull, StatusCode::FORBIDDEN, "forbidden").await;

    let ack_uri = format!("/v1/alarm-dispatches/{dispatch_id}/ack");
    let bad = send(
        &app,
        device(
            "POST",
            &ack_uri,
            &token,
            Some(json!({ "phone": "maybe", "band": "ok" })),
        ),
    )
    .await;
    expect_problem(bad, StatusCode::BAD_REQUEST, "validation").await;
    let acked = send(
        &app,
        device(
            "POST",
            &ack_uri,
            &token,
            Some(json!({ "phone": "shown", "band": "not_connected" })),
        ),
    )
    .await;
    assert_eq!(acked.status(), StatusCode::NO_CONTENT);
    let missing = send(
        &app,
        device(
            "POST",
            "/v1/alarm-dispatches/0190a3c4-0000-7000-8000-000000000009/ack",
            &token,
            Some(json!({ "phone": "shown", "band": "ok" })),
        ),
    )
    .await;
    expect_problem(missing, StatusCode::NOT_FOUND, "not-found").await;

    let pending = json(send(&app, device("GET", "/v1/alarms/pending", &token, None)).await).await;
    assert!(
        pending["dispatches"].as_array().unwrap().is_empty(),
        "acked dispatches leave the pull list"
    );

    let history = json(
        send(
            &app,
            web("GET", "/v1/alarm-dispatches?limit=5", &cookie, None),
        )
        .await,
    )
    .await;
    let row = &history["dispatches"][0];
    assert_eq!(row["status"], "acked");
    assert_eq!(row["phone_status"], "shown");
    assert_eq!(row["band_status"], "not_connected");
    assert!(row["acked_at"].is_string());

    let too_many = send(
        &app,
        web("GET", "/v1/alarm-dispatches?limit=500", &cookie, None),
    )
    .await;
    expect_problem(too_many, StatusCode::BAD_REQUEST, "validation").await;
}
