//! Dispatcher behaviour with a recording sender. Time is passed in, so no test waits for the clock.

use std::{
    collections::VecDeque,
    sync::{Arc, Mutex},
    time::Duration,
};

use chrono::{DateTime, Duration as ChronoDuration, Utc};
use icarus_push::{
    Alert, Background, DispatchConfig, LogOnlySender, Outcome, PushError, PushSender, Target,
    dispatch,
};
use sqlx::PgPool;
use uuid::Uuid;

#[derive(Default)]
struct Inner {
    alerts: Vec<Alert>,
    backgrounds: Vec<Background>,
    /// Results for the next alert calls. Once empty, `default_alert` applies.
    script: VecDeque<Result<Outcome, PushError>>,
    default_alert: Option<Result<Outcome, PushError>>,
}

/// Records every push. Cloning shares the record, so the dispatcher task and the test see the same calls.
#[derive(Clone, Default)]
struct Recorder {
    inner: Arc<Mutex<Inner>>,
}

impl Recorder {
    fn script(&self, results: Vec<Result<Outcome, PushError>>) {
        self.inner.lock().unwrap().script = results.into();
    }
    fn fail_alerts_with(&self, err: PushError) {
        self.inner.lock().unwrap().default_alert = Some(Err(err));
    }
    fn alerts(&self) -> usize {
        self.inner.lock().unwrap().alerts.len()
    }
    fn backgrounds(&self) -> Vec<Background> {
        self.inner.lock().unwrap().backgrounds.clone()
    }
}

fn accepted() -> Outcome {
    Outcome::Accepted {
        apns_id: Some("apns-id".into()),
    }
}

impl PushSender for Recorder {
    async fn alert(&self, _target: &Target, alert: &Alert) -> Result<Outcome, PushError> {
        let mut inner = self.inner.lock().unwrap();
        inner.alerts.push(alert.clone());
        if let Some(next) = inner.script.pop_front() {
            return next;
        }
        inner.default_alert.clone().unwrap_or(Ok(accepted()))
    }

    async fn background(&self, _target: &Target, push: &Background) -> Result<Outcome, PushError> {
        self.inner.lock().unwrap().backgrounds.push(push.clone());
        Ok(accepted())
    }
}

fn cfg() -> DispatchConfig {
    DispatchConfig::default()
}

struct Seed {
    user: Uuid,
    dispatch: Uuid,
}

/// One user with one phone (sandbox token) and one pending dispatch on a webhook alarm.
async fn seed(pool: &PgPool) -> Seed {
    let user = Uuid::now_v7();
    sqlx::query("INSERT INTO users (id, email, password_hash) VALUES ($1, $2, 'x')")
        .bind(user)
        .bind(format!("{user}@example.com"))
        .execute(pool)
        .await
        .unwrap();
    let alarm = Uuid::now_v7();
    sqlx::query("INSERT INTO alarms (id, user_id, kind, label, rhythm, channels) VALUES ($1, $2, 'webhook', 'Front door', '\"double\"', ARRAY['phone', 'band'])")
        .bind(alarm)
        .bind(user)
        .execute(pool)
        .await
        .unwrap();
    let device = Uuid::now_v7();
    sqlx::query(
        "INSERT INTO devices (id, user_id, name, token_hash) VALUES ($1, $2, 'iPhone', $3)",
    )
    .bind(device)
    .bind(user)
    .bind(Uuid::now_v7().as_bytes().to_vec())
    .execute(pool)
    .await
    .unwrap();
    sqlx::query("INSERT INTO push_tokens (device_id, apns_token, environment) VALUES ($1, 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4', 'sandbox')")
        .bind(device)
        .execute(pool)
        .await
        .unwrap();
    let dispatch = Uuid::now_v7();
    sqlx::query("INSERT INTO alarm_dispatches (id, alarm_id, status, message) VALUES ($1, $2, 'pending', 'Front door opened')")
        .bind(dispatch)
        .bind(alarm)
        .execute(pool)
        .await
        .unwrap();
    Seed { user, dispatch }
}

async fn row(pool: &PgPool, id: Uuid) -> (String, Option<String>, i16, Vec<String>) {
    let (status, phone, attempts, ids): (String, Option<String>, i16, Option<Vec<String>>) =
        sqlx::query_as(
            "SELECT status, phone_status, attempts, apns_ids FROM alarm_dispatches WHERE id = $1",
        )
        .bind(id)
        .fetch_one(pool)
        .await
        .unwrap();
    (status, phone, attempts, ids.unwrap_or_default())
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn first_send_is_an_alert_plus_a_silent_push(pool: PgPool) {
    let s = seed(&pool).await;
    let rec = Recorder::default();
    let now = Utc::now();
    dispatch::process(&pool, &rec, &cfg(), s.dispatch, now)
        .await
        .unwrap();

    let (status, phone, attempts, apns_ids) = row(&pool, s.dispatch).await;
    assert_eq!(
        (status.as_str(), phone.as_deref(), attempts),
        ("sent", Some("sent"), 1)
    );
    assert_eq!(apns_ids, vec!["apns-id".to_owned()]);

    let alerts = rec.inner.lock().unwrap().alerts.clone();
    assert_eq!(alerts.len(), 1);
    assert_eq!(alerts[0].title, "Front door");
    assert_eq!(alerts[0].body, "Front door opened");
    let backgrounds = rec.backgrounds();
    assert_eq!(backgrounds.len(), 1);
    assert_eq!(backgrounds[0].dispatch_id, Some(s.dispatch));
    assert!(!backgrounds[0].config_changed);
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn unacked_dispatches_resend_three_times_then_close(pool: PgPool) {
    let s = seed(&pool).await;
    let rec = Recorder::default();
    let t0 = Utc::now();
    dispatch::process(&pool, &rec, &cfg(), s.dispatch, t0)
        .await
        .unwrap();

    // Not yet 60 s: nothing happens.
    dispatch::sweep_once(&pool, &rec, &cfg(), t0 + ChronoDuration::seconds(30))
        .await
        .unwrap();
    assert_eq!(rec.alerts(), 1);

    dispatch::sweep_once(&pool, &rec, &cfg(), t0 + ChronoDuration::seconds(61))
        .await
        .unwrap();
    assert_eq!(row(&pool, s.dispatch).await.2, 2, "second alert");
    dispatch::sweep_once(&pool, &rec, &cfg(), t0 + ChronoDuration::seconds(122))
        .await
        .unwrap();
    assert_eq!(row(&pool, s.dispatch).await.2, 3, "third alert");
    assert_eq!(rec.alerts(), 3);

    dispatch::sweep_once(&pool, &rec, &cfg(), t0 + ChronoDuration::seconds(183))
        .await
        .unwrap();
    let (status, _, attempts, _) = row(&pool, s.dispatch).await;
    assert_eq!(status, "unacked");
    assert_eq!(attempts, 3);
    assert_eq!(rec.alerts(), 3, "no alert after the limit");
    assert_eq!(
        rec.backgrounds().len(),
        1,
        "silent push goes out once, with the first alert"
    );
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn an_ack_stops_resends(pool: PgPool) {
    let s = seed(&pool).await;
    let rec = Recorder::default();
    let t0 = Utc::now();
    dispatch::process(&pool, &rec, &cfg(), s.dispatch, t0)
        .await
        .unwrap();
    sqlx::query("UPDATE alarm_dispatches SET status = 'acked', acked_at = now(), phone_status = 'shown' WHERE id = $1")
        .bind(s.dispatch)
        .execute(&pool)
        .await
        .unwrap();

    dispatch::sweep_once(&pool, &rec, &cfg(), t0 + ChronoDuration::seconds(600))
        .await
        .unwrap();
    assert_eq!(rec.alerts(), 1);
    assert_eq!(row(&pool, s.dispatch).await.0, "acked");
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn transient_failures_retry_on_a_later_sweep(pool: PgPool) {
    let s = seed(&pool).await;
    let rec = Recorder::default();
    rec.script(vec![Err(PushError::Retryable)]);
    let t0 = Utc::now();
    dispatch::process(&pool, &rec, &cfg(), s.dispatch, t0)
        .await
        .unwrap();
    let (status, phone, attempts, _) = row(&pool, s.dispatch).await;
    assert_eq!(
        (status.as_str(), phone.as_deref(), attempts),
        ("pending", Some("retrying"), 1)
    );

    // Inside the 15 s retry window the sweep leaves it alone.
    dispatch::sweep_once(&pool, &rec, &cfg(), t0 + ChronoDuration::seconds(5))
        .await
        .unwrap();
    assert_eq!(rec.alerts(), 1);

    dispatch::sweep_once(&pool, &rec, &cfg(), t0 + ChronoDuration::seconds(16))
        .await
        .unwrap();
    assert_eq!(rec.alerts(), 2);
    assert_eq!(row(&pool, s.dispatch).await.0, "sent");
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn an_apns_gone_token_is_deleted_and_the_dispatch_fails(pool: PgPool) {
    let s = seed(&pool).await;
    let rec = Recorder::default();
    rec.script(vec![Err(PushError::Unregistered)]);
    dispatch::process(&pool, &rec, &cfg(), s.dispatch, Utc::now())
        .await
        .unwrap();

    let (status, phone, _, _) = row(&pool, s.dispatch).await;
    assert_eq!(
        (status.as_str(), phone.as_deref()),
        ("failed", Some("no_device"))
    );
    let tokens: i64 = sqlx::query_scalar("SELECT count(*) FROM push_tokens")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(tokens, 0, "the refused token is removed");
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn a_user_without_phones_fails_the_dispatch(pool: PgPool) {
    let s = seed(&pool).await;
    sqlx::query("DELETE FROM push_tokens")
        .execute(&pool)
        .await
        .unwrap();
    let rec = Recorder::default();
    dispatch::process(&pool, &rec, &cfg(), s.dispatch, Utc::now())
        .await
        .unwrap();
    let (status, phone, _, _) = row(&pool, s.dispatch).await;
    assert_eq!(
        (status.as_str(), phone.as_deref()),
        ("failed", Some("no_device"))
    );
    assert_eq!(rec.alerts(), 0);
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn a_rejected_push_fails_the_dispatch_without_retrying(pool: PgPool) {
    let s = seed(&pool).await;
    let rec = Recorder::default();
    rec.fail_alerts_with(PushError::Rejected);
    let t0 = Utc::now();
    dispatch::process(&pool, &rec, &cfg(), s.dispatch, t0)
        .await
        .unwrap();
    let (status, phone, _, _) = row(&pool, s.dispatch).await;
    assert_eq!(
        (status.as_str(), phone.as_deref()),
        ("failed", Some("apns_error"))
    );
    dispatch::sweep_once(&pool, &rec, &cfg(), t0 + ChronoDuration::seconds(600))
        .await
        .unwrap();
    assert_eq!(rec.alerts(), 1, "a refusal is not retried");
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn log_only_sender_keeps_the_lifecycle_going(pool: PgPool) {
    let s = seed(&pool).await;
    let t0: DateTime<Utc> = Utc::now();
    dispatch::process(&pool, &LogOnlySender, &cfg(), s.dispatch, t0)
        .await
        .unwrap();
    let (status, phone, attempts, apns_ids) = row(&pool, s.dispatch).await;
    assert_eq!(
        (status.as_str(), phone.as_deref(), attempts),
        ("sent", Some("apns_disabled"), 1)
    );
    assert!(apns_ids.is_empty());
    // It still reaches `unacked` without an ack, so the web page shows the truth.
    for n in 1..=3 {
        dispatch::sweep_once(
            &pool,
            &LogOnlySender,
            &cfg(),
            t0 + ChronoDuration::seconds(61 * n),
        )
        .await
        .unwrap();
    }
    assert_eq!(row(&pool, s.dispatch).await.0, "unacked");
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn config_changed_pushes_every_phone(pool: PgPool) {
    let s = seed(&pool).await;
    let rec = Recorder::default();
    dispatch::config_push(&pool, &rec, s.user).await.unwrap();
    let backgrounds = rec.backgrounds();
    assert_eq!(backgrounds.len(), 1);
    assert!(backgrounds[0].config_changed);
    assert_eq!(rec.alerts(), 0, "config pushes never alert");
}

#[sqlx::test(migrator = "icarus_db::MIGRATOR")]
async fn notify_wakes_the_running_dispatcher(pool: PgPool) {
    let s = seed(&pool).await;
    // Start with nothing pending: the first sweep runs at once, so the dispatch must come in later.
    sqlx::query("DELETE FROM alarm_dispatches")
        .execute(&pool)
        .await
        .unwrap();
    let rec = Recorder::default();
    // The sweep is set far away, so only LISTEN/NOTIFY can deliver this in time.
    let config = DispatchConfig {
        sweep_every: Duration::from_secs(3600),
        ..DispatchConfig::default()
    };
    let task = tokio::spawn(dispatch::run(pool.clone(), rec.clone(), config));
    // Give the listener time to subscribe before the notification is sent.
    tokio::time::sleep(Duration::from_millis(500)).await;

    let alarm: Uuid = sqlx::query_scalar("SELECT id FROM alarms WHERE user_id = $1")
        .bind(s.user)
        .fetch_one(&pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO alarm_dispatches (id, alarm_id, status) VALUES ($1, $2, 'pending')")
        .bind(s.dispatch)
        .bind(alarm)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("SELECT pg_notify('alarm_dispatch', $1)")
        .bind(s.dispatch.to_string())
        .execute(&pool)
        .await
        .unwrap();

    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while row(&pool, s.dispatch).await.0 != "sent" {
        assert!(
            tokio::time::Instant::now() < deadline,
            "dispatcher did not act on NOTIFY"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(rec.alerts(), 1);
    task.abort();
    let _ = task.await;
}
