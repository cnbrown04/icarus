//! The dispatcher (PLAN.md §9.3, §12.5).
//!
//! A `pending` dispatch is sent to every phone of its user: an alert, then a silent push to wake the
//! app. A `sent` dispatch waits for an ack. Without one after `ack_timeout`, the alert goes out
//! again, up to `max_attempts` alerts; after that the dispatch is `unacked`. Transient APNs failures
//! leave a dispatch `pending` for a later sweep. A 410 deletes that device's token.
//!
//! NOTIFY (`alarm_dispatch`, `config_changed`) wakes the loop at once. The sweep runs regardless,
//! so a missed notification delays a dispatch and never loses it.

use std::time::Duration;

use chrono::{DateTime, Utc};
use icarus_core::{NamedRhythm, Rhythm};
use serde_json::Value;
use sqlx::{FromRow, PgPool, postgres::PgListener};
use tokio::sync::mpsc;
use tracing::{error, info, warn};
use uuid::Uuid;

use crate::sender::{Alert, Background, Environment, Outcome, PushError, PushSender, Target};

const SWEEP_BATCH: i64 = 100;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    /// How often the sweep runs without a notification.
    pub sweep_every: Duration,
    /// A `pending` dispatch is retried this long after a transient failure.
    pub retry_after: Duration,
    /// How long to wait for an ack before resending the alert.
    pub ack_timeout: Duration,
    /// Alerts sent before the dispatch is marked `unacked`.
    pub max_attempts: i16,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            sweep_every: Duration::from_secs(15),
            retry_after: Duration::from_secs(15),
            ack_timeout: Duration::from_secs(60),
            max_attempts: 3,
        }
    }
}

#[derive(FromRow)]
struct Due {
    id: Uuid,
    status: String,
    attempts: i16,
    user_id: Uuid,
    label: String,
    message: Option<String>,
    rhythm: Value,
}

#[derive(FromRow)]
struct TargetRow {
    device_id: Uuid,
    token: String,
    environment: String,
}

/// Runs until the listener fails for good. The database connection is re-established by sqlx; a
/// failed listen call is returned to the caller.
pub async fn run<S: PushSender>(pool: PgPool, sender: S, cfg: Config) -> Result<(), sqlx::Error> {
    let mut listener = PgListener::connect_with(&pool).await?;
    listener
        .listen_all(["alarm_dispatch", "config_changed"])
        .await?;

    // `recv` is not cancel-safe inside `select!`, so it runs on its own task. The task ends when
    // this function does, which releases the LISTEN connection.
    let (tx, mut notes) = mpsc::channel(256);
    tokio::spawn(async move {
        loop {
            let received = tokio::select! {
                received = listener.recv() => received,
                () = tx.closed() => return,
            };
            match received {
                Ok(note) => {
                    if tx.send(note).await.is_err() {
                        return;
                    }
                }
                Err(err) => {
                    warn!(error = %err, "dispatcher listener error; retrying");
                    tokio::time::sleep(Duration::from_secs(1)).await;
                }
            }
        }
    });

    let mut sweep = tokio::time::interval(cfg.sweep_every);
    loop {
        tokio::select! {
            note = notes.recv() => {
                let Some(note) = note else { return Ok(()) };
                handle_notification(&pool, &sender, &cfg, note.channel(), note.payload()).await;
            }
            _ = sweep.tick() => {
                if let Err(err) = sweep_once(&pool, &sender, &cfg, Utc::now()).await {
                    error!(error = %err, "dispatcher sweep failed");
                }
            }
        }
    }
}

async fn handle_notification<S: PushSender>(
    pool: &PgPool,
    sender: &S,
    cfg: &Config,
    channel: &str,
    payload: &str,
) {
    let Ok(id) = Uuid::parse_str(payload) else {
        warn!(channel, "notification payload is not an id");
        return;
    };
    let result = match channel {
        "alarm_dispatch" => process(pool, sender, cfg, id, Utc::now()).await,
        "config_changed" => config_push(pool, sender, id).await,
        _ => return,
    };
    if let Err(err) = result {
        error!(channel, error = %err, "dispatcher could not handle a notification");
    }
}

/// Sends the first alert for a `pending` dispatch. Other statuses are left alone.
pub async fn process<S: PushSender>(
    pool: &PgPool,
    sender: &S,
    cfg: &Config,
    dispatch_id: Uuid,
    now: DateTime<Utc>,
) -> Result<(), sqlx::Error> {
    let Some(due) = load_due(pool, dispatch_id).await? else {
        return Ok(());
    };
    if due.status != "pending" {
        return Ok(());
    }
    send_round(pool, sender, cfg, &due, now).await
}

/// One pass: sends first alerts and retries that are due, then resends or closes dispatches that
/// were not acked. Returns the number of dispatches touched.
pub async fn sweep_once<S: PushSender>(
    pool: &PgPool,
    sender: &S,
    cfg: &Config,
    now: DateTime<Utc>,
) -> Result<usize, sqlx::Error> {
    let retry_before = now - chrono::Duration::from_std(cfg.retry_after).unwrap_or_default();
    let pending: Vec<(Uuid,)> = sqlx::query_as(
        "SELECT id FROM alarm_dispatches
         WHERE status = 'pending' AND (last_attempt_at IS NULL OR last_attempt_at <= $1)
         ORDER BY created_at LIMIT $2",
    )
    .bind(retry_before)
    .bind(SWEEP_BATCH)
    .fetch_all(pool)
    .await?;
    let mut touched = 0;
    for (id,) in &pending {
        process(pool, sender, cfg, *id, now).await?;
        touched += 1;
    }

    let ack_before = now - chrono::Duration::from_std(cfg.ack_timeout).unwrap_or_default();
    let stale: Vec<(Uuid,)> = sqlx::query_as(
        "SELECT id FROM alarm_dispatches
         WHERE status = 'sent' AND acked_at IS NULL AND last_attempt_at <= $1
         ORDER BY last_attempt_at LIMIT $2",
    )
    .bind(ack_before)
    .bind(SWEEP_BATCH)
    .fetch_all(pool)
    .await?;
    for (id,) in &stale {
        let Some(due) = load_due(pool, *id).await? else {
            continue;
        };
        touched += 1;
        if due.attempts >= cfg.max_attempts {
            sqlx::query(
                "UPDATE alarm_dispatches SET status = 'unacked' WHERE id = $1 AND status = 'sent'",
            )
            .bind(due.id)
            .execute(pool)
            .await?;
            info!(attempts = due.attempts, "dispatch unacked");
        } else {
            send_round(pool, sender, cfg, &due, now).await?;
        }
    }
    Ok(touched)
}

/// Pushes to the user's phones: the alert on every attempt, and the silent push on the first.
async fn send_round<S: PushSender>(
    pool: &PgPool,
    sender: &S,
    cfg: &Config,
    due: &Due,
    now: DateTime<Utc>,
) -> Result<(), sqlx::Error> {
    let targets = load_targets(pool, due.user_id).await?;
    let rhythm: Rhythm =
        serde_json::from_value(due.rhythm.clone()).unwrap_or(Rhythm::Named(NamedRhythm::Double));
    let alert = Alert {
        dispatch_id: due.id,
        title: due.label.clone(),
        body: due.message.clone().unwrap_or_default(),
        rhythm: rhythm.clone(),
    };
    let silent = Background {
        dispatch_id: Some(due.id),
        rhythm: Some(rhythm),
        config_changed: false,
    };
    let first_round = due.status == "pending" && due.attempts == 0;
    let attempts = due.attempts.saturating_add(1);

    let mut round = Round::default();
    for target in &targets {
        match sender.alert(target, &alert).await {
            Ok(Outcome::Accepted { apns_id }) => {
                round.accepted += 1;
                round.apns_ids.extend(apns_id);
            }
            Ok(Outcome::Disabled) => round.disabled += 1,
            Err(err) => round.record_error(err, target, pool).await?,
        }
        if first_round {
            // Best effort: the alert already decides the outcome.
            if let Err(PushError::Unregistered) = sender.background(target, &silent).await {
                delete_token(pool, target).await?;
            }
        }
    }

    let (status, phone_status) = round.decide(due, attempts, targets.len(), cfg.max_attempts);
    sqlx::query(
        "UPDATE alarm_dispatches
         SET status = $2, phone_status = COALESCE($3, phone_status), attempts = $4,
             last_attempt_at = $5, apns_ids = COALESCE(apns_ids, '{}') || $6::text[]
         WHERE id = $1",
    )
    .bind(due.id)
    .bind(status)
    .bind(phone_status)
    .bind(attempts)
    .bind(now)
    .bind(&round.apns_ids)
    .execute(pool)
    .await?;
    info!(
        status,
        attempts,
        devices = targets.len(),
        "dispatch attempt finished"
    );
    Ok(())
}

#[derive(Default)]
struct Round {
    accepted: usize,
    disabled: usize,
    retryable: usize,
    rejected: usize,
    unregistered: usize,
    apns_ids: Vec<String>,
}

impl Round {
    async fn record_error(
        &mut self,
        err: PushError,
        target: &Target,
        pool: &PgPool,
    ) -> Result<(), sqlx::Error> {
        match err {
            PushError::Unregistered => {
                self.unregistered += 1;
                delete_token(pool, target).await?;
            }
            PushError::Retryable => self.retryable += 1,
            PushError::Rejected => self.rejected += 1,
        }
        Ok(())
    }

    /// The new status and the phone status to record, if any.
    fn decide(
        &self,
        due: &Due,
        attempts: i16,
        devices: usize,
        max_attempts: i16,
    ) -> (&'static str, Option<&'static str>) {
        if self.accepted > 0 {
            ("sent", Some("sent"))
        } else if self.disabled > 0 {
            ("sent", Some("apns_disabled"))
        } else if due.status == "sent" {
            // A resend that failed. The dispatch stays `sent` until the attempt limit closes it.
            ("sent", None)
        } else if self.retryable > 0 && attempts < max_attempts {
            ("pending", Some("retrying"))
        } else if self.unregistered == devices {
            ("failed", Some("no_device"))
        } else {
            ("failed", Some("apns_error"))
        }
    }
}

/// A silent `config_changed` push to every phone of the user. Best effort.
pub async fn config_push<S: PushSender>(
    pool: &PgPool,
    sender: &S,
    user_id: Uuid,
) -> Result<(), sqlx::Error> {
    let push = Background {
        dispatch_id: None,
        rhythm: None,
        config_changed: true,
    };
    for target in load_targets(pool, user_id).await? {
        if let Err(err) = sender.background(&target, &push).await {
            match err {
                PushError::Unregistered => delete_token(pool, &target).await?,
                _ => warn!(error = %err, "config_changed push failed"),
            }
        }
    }
    Ok(())
}

async fn load_due(pool: &PgPool, dispatch_id: Uuid) -> Result<Option<Due>, sqlx::Error> {
    sqlx::query_as(
        "SELECT d.id, d.status, d.attempts, a.user_id, a.label, d.message, d.rhythm
         FROM alarm_dispatches d JOIN alarms a ON a.id = d.alarm_id
         WHERE d.id = $1",
    )
    .bind(dispatch_id)
    .fetch_optional(pool)
    .await
}

async fn load_targets(pool: &PgPool, user_id: Uuid) -> Result<Vec<Target>, sqlx::Error> {
    let rows: Vec<TargetRow> = sqlx::query_as(
        "SELECT p.device_id, p.apns_token AS token, p.environment
         FROM push_tokens p JOIN devices d ON d.id = p.device_id
         WHERE d.user_id = $1 AND d.revoked_at IS NULL",
    )
    .bind(user_id)
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|row| Target {
            device_id: row.device_id,
            token: row.token,
            environment: if row.environment == "sandbox" {
                Environment::Sandbox
            } else {
                Environment::Production
            },
        })
        .collect())
}

/// Deletes the token that APNs refused. A newer token for the same device stays.
async fn delete_token(pool: &PgPool, target: &Target) -> Result<(), sqlx::Error> {
    sqlx::query("DELETE FROM push_tokens WHERE device_id = $1 AND apns_token = $2")
        .bind(target.device_id)
        .bind(&target.token)
        .execute(pool)
        .await?;
    info!("removed a device token that APNs no longer accepts");
    Ok(())
}
