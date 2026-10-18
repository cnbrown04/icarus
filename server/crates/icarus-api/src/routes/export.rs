//! `GET /v1/export`: every row the account owns, one JSON object per line (api-contract.md "Data rights").
//!
//! Rows are read with a streaming query and written through a bounded channel, so a large account
//! does not load into memory. Secrets are not exported: webhook ciphertext and the hook secret stay
//! out, and the slug is the only identifier a hook has in the export.

use std::io;

use axum::{
    body::{Body, Bytes},
    extract::State,
    http::header::{CONTENT_DISPOSITION, CONTENT_TYPE},
    response::{IntoResponse, Response},
};
use chrono::{DateTime, SecondsFormat, Utc};
use futures_util::{StreamExt, TryStreamExt, stream};
use icarus_core::time::rfc3339;
use serde::Serialize;
use serde_json::Value;
use sqlx::{FromRow, PgPool, postgres::PgRow};
use tokio::sync::mpsc;
use uuid::Uuid;

use crate::{auth::WebUser, error::ApiError, routes::me::load_me, state::AppState};

const CHUNK_BYTES: usize = 64 * 1024;
const CHANNEL_DEPTH: usize = 8;

#[utoipa::path(
    get,
    path = "/v1/export",
    operation_id = "export_data",
    tag = "Data",
    security(("session" = [])),
    responses(
        (status = 200, description = "One JSON object per line, each with a kind field.", content_type = "application/x-ndjson", body = String),
        (status = "default", description = "An error as application/problem+json (api-contract.md Errors).", body = crate::openapi::Problem, content_type = "application/problem+json")
    )
)]
pub async fn export(
    State(state): State<AppState>,
    WebUser(user_id): WebUser,
) -> Result<Response, ApiError> {
    let (tx, rx) = mpsc::channel::<Result<Bytes, io::Error>>(CHANNEL_DEPTH);
    let pool = state.pool.clone();
    tokio::spawn(async move {
        let mut sink = Sink {
            tx,
            buf: Vec::with_capacity(CHUNK_BYTES),
        };
        if let Err(err) = write_all(&pool, user_id, &mut sink).await {
            // The client sees a cut-off body, which is how a failed export must look.
            tracing::error!(kind = err.kind(), "export stopped early");
            sink.fail().await;
        }
    });

    // Fused: compression polls the body once more after the last chunk, and `unfold` panics on that.
    let body = Body::from_stream(
        stream::unfold(rx, |mut rx| async move {
            rx.recv().await.map(|item| (item, rx))
        })
        .fuse(),
    );
    Ok((
        [
            (CONTENT_TYPE, "application/x-ndjson"),
            (
                CONTENT_DISPOSITION,
                "attachment; filename=\"icarus-export.ndjson\"",
            ),
        ],
        body,
    )
        .into_response())
}

#[derive(Debug, thiserror::Error)]
enum ExportError {
    #[error("database")]
    Db(#[from] sqlx::Error),
    #[error("encode")]
    Encode(#[from] serde_json::Error),
    #[error("profile")]
    Api(ApiError),
    #[error("client disconnected")]
    ClientGone,
}

impl ExportError {
    fn kind(&self) -> &'static str {
        match self {
            ExportError::Db(_) => "database",
            ExportError::Encode(_) => "encode",
            ExportError::Api(_) => "api",
            ExportError::ClientGone => "client-gone",
        }
    }
}

/// Batches lines into chunks of about 64 KB and sends them to the response body.
struct Sink {
    tx: mpsc::Sender<Result<Bytes, io::Error>>,
    buf: Vec<u8>,
}

#[derive(Serialize)]
struct Line<'a, T: Serialize> {
    kind: &'static str,
    #[serde(flatten)]
    row: &'a T,
}

impl Sink {
    async fn line<T: Serialize>(&mut self, kind: &'static str, row: &T) -> Result<(), ExportError> {
        serde_json::to_writer(&mut self.buf, &Line { kind, row })?;
        self.buf.push(b'\n');
        if self.buf.len() >= CHUNK_BYTES {
            self.flush().await?;
        }
        Ok(())
    }

    async fn flush(&mut self) -> Result<(), ExportError> {
        if self.buf.is_empty() {
            return Ok(());
        }
        let chunk = Bytes::from(std::mem::take(&mut self.buf));
        self.tx
            .send(Ok(chunk))
            .await
            .map_err(|_| ExportError::ClientGone)
    }

    async fn fail(&mut self) {
        let _ = self
            .tx
            .send(Err(io::Error::other("export stopped early")))
            .await;
    }
}

async fn write_all(pool: &PgPool, user_id: Uuid, out: &mut Sink) -> Result<(), ExportError> {
    let me = load_me(pool, user_id).await.map_err(ExportError::Api)?;
    out.line("me", &me).await?;
    stream_rows::<DeviceRow>(pool, user_id, "device", DEVICES_SQL, out).await?;
    stream_rows::<BandRow>(pool, user_id, "band", BANDS_SQL, out).await?;
    stream_rows::<HrRow>(pool, user_id, "hr", HR_SQL, out).await?;
    stream_rows::<RrRow>(pool, user_id, "rr", RR_SQL, out).await?;
    stream_rows::<MinuteRow>(pool, user_id, "minute_metric", MINUTES_SQL, out).await?;
    stream_rows::<DayRow>(pool, user_id, "daily_summary", DAYS_SQL, out).await?;
    stream_rows::<EventRow>(pool, user_id, "event", EVENTS_SQL, out).await?;
    stream_rows::<AlarmRow>(pool, user_id, "alarm", ALARMS_SQL, out).await?;
    stream_rows::<HookRow>(pool, user_id, "hook", HOOKS_SQL, out).await?;
    stream_rows::<DispatchRow>(pool, user_id, "dispatch", DISPATCHES_SQL, out).await?;
    out.flush().await
}

/// Every query takes the user id as `$1`.
async fn stream_rows<T>(
    pool: &PgPool,
    user_id: Uuid,
    kind: &'static str,
    sql: &str,
    out: &mut Sink,
) -> Result<(), ExportError>
where
    T: for<'r> FromRow<'r, PgRow> + Serialize + Send + Unpin,
{
    let mut rows = sqlx::query_as::<_, T>(sql).bind(user_id).fetch(pool);
    while let Some(row) = rows.try_next().await? {
        out.line(kind, &row).await?;
    }
    Ok(())
}

const DEVICES_SQL: &str =
    "SELECT id, name, model, os_version, app_version, created_at, last_seen_at, revoked_at
    FROM devices WHERE user_id = $1";
const BANDS_SQL: &str =
    "SELECT id, name, firmware, created_at, last_seen_at FROM bands WHERE user_id = $1";
const HR_SQL: &str = "SELECT h.band_id, h.ts, h.bpm, h.source, h.contact
    FROM hr_samples h JOIN bands b ON b.id = h.band_id WHERE b.user_id = $1";
const RR_SQL: &str = "SELECT r.band_id, r.ts, r.seq, r.rr_ms, r.accepted
    FROM rr_intervals r JOIN bands b ON b.id = r.band_id WHERE b.user_id = $1";
const MINUTES_SQL: &str =
    "SELECT minute, hr_avg, hr_min, hr_max, hr_n, rmssd_ms, sdnn_ms, baevsky_sqrt, stress,
    stress_state, kcal, active_kcal, kcal_estimated, algo_version, origin, sync_rev
    FROM minute_metrics WHERE user_id = $1";
const DAYS_SQL: &str = "SELECT day, rhr, hr_avg, hr_max, rmssd_night_ms, stress_avg, stress_high_minutes,
    kcal_total, kcal_active, coverage, algo_version, computed_at FROM daily_summaries WHERE user_id = $1";
const EVENTS_SQL: &str = "SELECT e.band_id, e.ts, e.kind AS event_kind, e.payload
    FROM band_events e JOIN bands b ON b.id = e.band_id WHERE b.user_id = $1";
const ALARMS_SQL: &str =
    "SELECT id, kind AS alarm_kind, label, schedule, rhythm, channels, enabled, version,
    updated_at, deleted_at FROM alarms WHERE user_id = $1";
const HOOKS_SQL: &str =
    "SELECT id, slug, label, alarm_id, auth_mode, rate_limit_per_min, enabled, version,
    created_at, last_triggered_at FROM webhook_endpoints WHERE user_id = $1";
const DISPATCHES_SQL: &str =
    "SELECT d.id, d.alarm_id, d.delivery_id, d.created_at, d.attempts, d.phone_status,
    d.band_status, d.acked_at, d.status, d.message, d.rhythm
    FROM alarm_dispatches d JOIN alarms a ON a.id = d.alarm_id WHERE a.user_id = $1";

/// Milliseconds for time-series rows, where sub-second order matters. Other times use whole seconds.
mod millis {
    use super::*;
    use serde::Serializer;

    pub fn serialize<S: Serializer>(t: &DateTime<Utc>, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&t.to_rfc3339_opts(SecondsFormat::Millis, true))
    }
}

#[derive(FromRow, Serialize)]
struct DeviceRow {
    id: Uuid,
    name: String,
    model: Option<String>,
    os_version: Option<String>,
    app_version: Option<String>,
    #[serde(with = "rfc3339")]
    created_at: DateTime<Utc>,
    #[serde(with = "rfc3339::opt")]
    last_seen_at: Option<DateTime<Utc>>,
    #[serde(with = "rfc3339::opt")]
    revoked_at: Option<DateTime<Utc>>,
}

#[derive(FromRow, Serialize)]
struct BandRow {
    id: Uuid,
    name: Option<String>,
    firmware: Option<String>,
    #[serde(with = "rfc3339")]
    created_at: DateTime<Utc>,
    #[serde(with = "rfc3339::opt")]
    last_seen_at: Option<DateTime<Utc>>,
}

#[derive(FromRow, Serialize)]
struct HrRow {
    band_id: Uuid,
    #[serde(with = "millis")]
    ts: DateTime<Utc>,
    bpm: i16,
    source: i16,
    contact: Option<bool>,
}

#[derive(FromRow, Serialize)]
struct RrRow {
    band_id: Uuid,
    #[serde(with = "millis")]
    ts: DateTime<Utc>,
    seq: i16,
    rr_ms: f32,
    accepted: bool,
}

#[derive(FromRow, Serialize)]
struct MinuteRow {
    #[serde(with = "rfc3339")]
    minute: DateTime<Utc>,
    hr_avg: Option<f32>,
    hr_min: Option<i16>,
    hr_max: Option<i16>,
    hr_n: Option<i16>,
    rmssd_ms: Option<f32>,
    sdnn_ms: Option<f32>,
    baevsky_sqrt: Option<f32>,
    stress: Option<i16>,
    stress_state: Option<String>,
    kcal: Option<f32>,
    active_kcal: Option<f32>,
    kcal_estimated: Option<bool>,
    algo_version: i16,
    origin: String,
    sync_rev: i32,
}

#[derive(FromRow, Serialize)]
struct DayRow {
    day: chrono::NaiveDate,
    rhr: Option<i16>,
    hr_avg: Option<f32>,
    hr_max: Option<i16>,
    rmssd_night_ms: Option<f32>,
    stress_avg: Option<f32>,
    stress_high_minutes: Option<i32>,
    kcal_total: Option<f32>,
    kcal_active: Option<f32>,
    coverage: Option<f32>,
    algo_version: i16,
    #[serde(with = "rfc3339")]
    computed_at: DateTime<Utc>,
}

#[derive(FromRow, Serialize)]
struct EventRow {
    band_id: Uuid,
    #[serde(with = "millis")]
    ts: DateTime<Utc>,
    event_kind: String,
    payload: Option<Value>,
}

#[derive(FromRow, Serialize)]
struct AlarmRow {
    id: Uuid,
    alarm_kind: String,
    label: String,
    schedule: Option<Value>,
    rhythm: Value,
    channels: Vec<String>,
    enabled: bool,
    version: i64,
    #[serde(with = "rfc3339")]
    updated_at: DateTime<Utc>,
    #[serde(with = "rfc3339::opt")]
    deleted_at: Option<DateTime<Utc>>,
}

#[derive(FromRow, Serialize)]
struct HookRow {
    id: Uuid,
    slug: String,
    label: String,
    alarm_id: Option<Uuid>,
    auth_mode: String,
    rate_limit_per_min: i16,
    enabled: bool,
    version: i64,
    #[serde(with = "rfc3339")]
    created_at: DateTime<Utc>,
    #[serde(with = "rfc3339::opt")]
    last_triggered_at: Option<DateTime<Utc>>,
}

#[derive(FromRow, Serialize)]
struct DispatchRow {
    id: Uuid,
    alarm_id: Option<Uuid>,
    delivery_id: Option<Uuid>,
    #[serde(with = "rfc3339")]
    created_at: DateTime<Utc>,
    attempts: i16,
    phone_status: Option<String>,
    band_status: Option<String>,
    #[serde(with = "rfc3339::opt")]
    acked_at: Option<DateTime<Utc>>,
    status: String,
    message: Option<String>,
    rhythm: Value,
}
