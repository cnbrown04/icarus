//! Sync: batch upload, config download and state (PLAN.md §11.3 to §11.5, api-contract.md "Sync").

use std::collections::{BTreeMap, HashSet};

use axum::{
    Json,
    body::Body,
    extract::{Query, State},
    http::HeaderMap,
};
use chrono::{DateTime, Utc};
use icarus_core::{Alarm, Hook, Me, time::rfc3339};
use icarus_jobs::rollup;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sqlx::{FromRow, PgPool, Postgres, Transaction};
use uuid::Uuid;

use crate::{
    auth::{AppDevice, sha256},
    error::ApiError,
    extract::read_limited,
    routes::{
        alarms::{ALARM_COLUMNS, AlarmRow, alarm_from_row},
        hooks::{HOOK_COLUMNS, HookRow, hook_from_row},
        me::load_me,
    },
    state::AppState,
};

/// PLAN.md §12.1: 2 MB after decompression.
pub const BATCH_BODY_LIMIT: usize = 2 * 1024 * 1024;
/// api-contract.md: at most 20,000 time-series rows (HR plus R-R) per batch.
pub const MAX_SERIES_ROWS: usize = 20_000;
const ALARM_DELIVERY_CHANNELS: [&str; 2] = ["phone", "band"];
const ALARM_DELIVERY_STATUSES: [&str; 5] = ["shown", "ok", "not_connected", "disabled", "failed"];

// ---- wire types ----

#[derive(Deserialize)]
struct BatchBody {
    schema: i64,
    batch_id: Uuid,
    device_id: Uuid,
    created_at: String,
    #[serde(default)]
    bands: Vec<BandIn>,
    #[serde(default)]
    hr: Option<HrIn>,
    #[serde(default)]
    rr: Option<RrIn>,
    #[serde(default)]
    minute_metrics: Vec<MinuteIn>,
    #[serde(default)]
    events: Vec<EventIn>,
    #[serde(default)]
    alarm_deliveries: Vec<DeliveryIn>,
}

#[derive(Deserialize)]
struct BandIn {
    id: Uuid,
    name: String,
    firmware: Option<String>,
}

#[derive(Deserialize)]
struct HrIn {
    band_id: Uuid,
    ts_ms: Vec<i64>,
    bpm: Vec<i64>,
    source: Vec<i64>,
    contact: Vec<Option<bool>>,
}

#[derive(Deserialize)]
struct RrIn {
    band_id: Uuid,
    ts_ms: Vec<i64>,
    seq: Vec<i64>,
    rr_ms: Vec<f64>,
    accepted: Vec<bool>,
}

#[derive(Deserialize)]
struct MinuteIn {
    minute_ms: i64,
    hr_avg: Option<f64>,
    hr_min: Option<i64>,
    hr_max: Option<i64>,
    hr_n: Option<i64>,
    rmssd_ms: Option<f64>,
    sdnn_ms: Option<f64>,
    baevsky_sqrt: Option<f64>,
    stress: Option<i64>,
    stress_state: Option<String>,
    kcal: Option<f64>,
    active_kcal: Option<f64>,
    kcal_estimated: Option<bool>,
    algo_version: i64,
    sync_rev: i64,
}

#[derive(Deserialize)]
struct EventIn {
    band_id: Uuid,
    ts_ms: i64,
    kind: String,
    payload: Option<Value>,
}

#[derive(Deserialize)]
struct DeliveryIn {
    id: Uuid,
    alarm_id: Option<Uuid>,
    dispatch_id: Option<Uuid>,
    ts_ms: i64,
    channel: String,
    status: String,
    detail: Option<String>,
}

#[derive(Serialize, Deserialize, Default, Debug, PartialEq, Eq)]
pub struct Counts {
    pub hr: Inserted,
    pub rr: Inserted,
    pub minute_metrics: Upserted,
    pub events: Inserted,
    pub alarm_deliveries: Inserted,
}

#[derive(Serialize, Deserialize, Default, Debug, PartialEq, Eq)]
pub struct Inserted {
    pub inserted: u64,
    pub duplicate: u64,
}

#[derive(Serialize, Deserialize, Default, Debug, PartialEq, Eq)]
pub struct Upserted {
    pub upserted: u64,
    pub stale: u64,
}

#[derive(Serialize)]
pub struct BatchResponse {
    batch_id: Uuid,
    duplicate: bool,
    #[serde(with = "rfc3339")]
    server_time: DateTime<Utc>,
    counts: Counts,
}

// ---- validated batch ----

struct HrRows {
    band_id: Vec<Uuid>,
    ts: Vec<DateTime<Utc>>,
    bpm: Vec<i16>,
    source: Vec<i16>,
    contact: Vec<Option<bool>>,
}

struct RrRows {
    band_id: Vec<Uuid>,
    ts: Vec<DateTime<Utc>>,
    seq: Vec<i16>,
    rr_ms: Vec<f32>,
    accepted: Vec<bool>,
}

struct MinuteRow {
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
    sync_rev: i32,
}

struct EventRow {
    band_id: Uuid,
    ts: DateTime<Utc>,
    kind: String,
    payload: String,
}

struct DeliveryRow {
    id: Uuid,
    alarm_id: Option<Uuid>,
    dispatch_id: Option<Uuid>,
    ts: DateTime<Utc>,
    channel: String,
    status: String,
    detail: Option<String>,
}

struct Batch {
    id: Uuid,
    bands: Vec<(Uuid, String, Option<String>)>,
    hr: HrRows,
    rr: RrRows,
    minutes: Vec<MinuteRow>,
    events: Vec<EventRow>,
    deliveries: Vec<DeliveryRow>,
}

fn invalid(msg: impl Into<String>) -> ApiError {
    ApiError::Validation(msg.into())
}

fn ts_from_ms(ms: i64) -> Result<DateTime<Utc>, ApiError> {
    DateTime::from_timestamp_millis(ms).ok_or_else(|| invalid("a timestamp is out of range."))
}

fn small(value: i64, min: i64, max: i64, what: &str) -> Result<i16, ApiError> {
    if (min..=max).contains(&value) {
        Ok(value as i16)
    } else {
        Err(invalid(format!("{what} must be between {min} and {max}.")))
    }
}

fn small_opt(value: Option<i64>, min: i64, max: i64, what: &str) -> Result<Option<i16>, ApiError> {
    value.map(|v| small(v, min, max, what)).transpose()
}

fn finite(value: f64, what: &str) -> Result<f32, ApiError> {
    if value.is_finite() {
        Ok(value as f32)
    } else {
        Err(invalid(format!("{what} must be a finite number.")))
    }
}

fn finite_opt(value: Option<f64>, what: &str) -> Result<Option<f32>, ApiError> {
    value.map(|v| finite(v, what)).transpose()
}

fn equal_lengths(lens: &[usize], what: &str) -> Result<(), ApiError> {
    if lens.windows(2).all(|w| w[0] == w[1]) {
        Ok(())
    } else {
        Err(invalid(format!("{what} columns must have equal length.")))
    }
}

fn validate(body: BatchBody) -> Result<Batch, ApiError> {
    if body.schema != 1 {
        return Err(invalid("schema must be 1."));
    }
    DateTime::parse_from_rfc3339(&body.created_at)
        .map_err(|_| invalid("created_at must be RFC 3339."))?;

    let mut seen = HashSet::new();
    let mut bands = Vec::with_capacity(body.bands.len());
    for band in body.bands {
        if !seen.insert(band.id) {
            return Err(invalid("bands contains the same id twice."));
        }
        let name = band.name.trim().to_owned();
        if name.is_empty() || name.chars().count() > 100 {
            return Err(invalid("band name must be 1 to 100 characters."));
        }
        if band
            .firmware
            .as_ref()
            .is_some_and(|f| f.chars().count() > 100)
        {
            return Err(invalid("band firmware must be at most 100 characters."));
        }
        bands.push((band.id, name, band.firmware));
    }

    let (hr_in, rr_in) = (body.hr, body.rr);
    if let Some(hr) = &hr_in {
        equal_lengths(
            &[
                hr.ts_ms.len(),
                hr.bpm.len(),
                hr.source.len(),
                hr.contact.len(),
            ],
            "hr",
        )?;
    }
    if let Some(rr) = &rr_in {
        equal_lengths(
            &[
                rr.ts_ms.len(),
                rr.seq.len(),
                rr.rr_ms.len(),
                rr.accepted.len(),
            ],
            "rr",
        )?;
    }
    let series_rows =
        hr_in.as_ref().map_or(0, |h| h.ts_ms.len()) + rr_in.as_ref().map_or(0, |r| r.ts_ms.len());
    if series_rows > MAX_SERIES_ROWS {
        return Err(ApiError::PayloadTooLarge(format!(
            "The batch has more than {MAX_SERIES_ROWS} time-series rows. Split it into smaller batches."
        )));
    }

    let hr = match hr_in {
        Some(h) => {
            let mut rows = HrRows {
                band_id: vec![],
                ts: vec![],
                bpm: vec![],
                source: vec![],
                contact: h.contact,
            };
            for i in 0..h.ts_ms.len() {
                rows.ts.push(ts_from_ms(h.ts_ms[i])?);
                rows.bpm.push(small(h.bpm[i], 20, 250, "bpm")?);
                rows.source.push(small(h.source[i], 1, 3, "source")?);
                rows.band_id.push(h.band_id);
            }
            rows
        }
        None => HrRows {
            band_id: vec![],
            ts: vec![],
            bpm: vec![],
            source: vec![],
            contact: vec![],
        },
    };
    let rr = match rr_in {
        Some(r) => {
            let mut rows = RrRows {
                band_id: vec![],
                ts: vec![],
                seq: vec![],
                rr_ms: vec![],
                accepted: r.accepted,
            };
            for i in 0..r.ts_ms.len() {
                rows.ts.push(ts_from_ms(r.ts_ms[i])?);
                rows.seq
                    .push(small(r.seq[i], 0, i64::from(i16::MAX), "seq")?);
                let rr_ms = finite(r.rr_ms[i], "rr_ms")?;
                if rr_ms <= 0.0 {
                    return Err(invalid("rr_ms must be positive."));
                }
                rows.rr_ms.push(rr_ms);
                rows.band_id.push(r.band_id);
            }
            rows
        }
        None => RrRows {
            band_id: vec![],
            ts: vec![],
            seq: vec![],
            rr_ms: vec![],
            accepted: vec![],
        },
    };

    let mut minutes = Vec::with_capacity(body.minute_metrics.len());
    for m in body.minute_metrics {
        if m.minute_ms < 0 || m.minute_ms % 60_000 != 0 {
            return Err(invalid("minute_ms must be a whole minute since the epoch."));
        }
        minutes.push(MinuteRow {
            minute: ts_from_ms(m.minute_ms)?,
            hr_avg: finite_opt(m.hr_avg, "hr_avg")?,
            hr_min: small_opt(m.hr_min, 0, 300, "hr_min")?,
            hr_max: small_opt(m.hr_max, 0, 300, "hr_max")?,
            hr_n: small_opt(m.hr_n, 0, 60, "hr_n")?,
            rmssd_ms: finite_opt(m.rmssd_ms, "rmssd_ms")?,
            sdnn_ms: finite_opt(m.sdnn_ms, "sdnn_ms")?,
            baevsky_sqrt: finite_opt(m.baevsky_sqrt, "baevsky_sqrt")?,
            stress: small_opt(m.stress, 0, 100, "stress")?,
            stress_state: m.stress_state.filter(|s| s.len() <= 32),
            kcal: finite_opt(m.kcal, "kcal")?,
            active_kcal: finite_opt(m.active_kcal, "active_kcal")?,
            kcal_estimated: m.kcal_estimated,
            algo_version: small(m.algo_version, 0, i64::from(i16::MAX), "algo_version")?,
            sync_rev: i32::try_from(m.sync_rev)
                .ok()
                .filter(|v| *v >= 0)
                .ok_or_else(|| invalid("sync_rev must be a non-negative integer."))?,
        });
    }

    let mut events = Vec::with_capacity(body.events.len());
    for e in body.events {
        if e.kind.is_empty() || e.kind.len() > 64 {
            return Err(invalid("event kind must be 1 to 64 characters."));
        }
        events.push(EventRow {
            band_id: e.band_id,
            ts: ts_from_ms(e.ts_ms)?,
            kind: e.kind,
            payload: serde_json::to_string(
                &e.payload
                    .unwrap_or_else(|| Value::Object(Default::default())),
            )
            .map_err(|_| invalid("event payload is not valid JSON."))?,
        });
    }

    let mut deliveries = Vec::with_capacity(body.alarm_deliveries.len());
    for d in body.alarm_deliveries {
        if !ALARM_DELIVERY_CHANNELS.contains(&d.channel.as_str()) {
            return Err(invalid("alarm delivery channel must be phone or band."));
        }
        if !ALARM_DELIVERY_STATUSES.contains(&d.status.as_str()) {
            return Err(invalid("alarm delivery status is not recognised."));
        }
        if d.detail.as_ref().is_some_and(|s| s.len() > 1000) {
            return Err(invalid(
                "alarm delivery detail must be at most 1000 characters.",
            ));
        }
        deliveries.push(DeliveryRow {
            id: d.id,
            alarm_id: d.alarm_id,
            dispatch_id: d.dispatch_id,
            ts: ts_from_ms(d.ts_ms)?,
            channel: d.channel,
            status: d.status,
            detail: d.detail,
        });
    }

    // Band references are checked in the transaction, once this batch's band rows exist.
    Ok(Batch {
        id: body.batch_id,
        bands,
        hr,
        rr,
        minutes,
        events,
        deliveries,
    })
}

// ---- POST /v1/sync/batches ----

pub async fn post_batch(
    State(state): State<AppState>,
    AppDevice { user_id, device_id }: AppDevice,
    headers: HeaderMap,
    body: Body,
) -> Result<Json<BatchResponse>, ApiError> {
    let key = headers
        .get("idempotency-key")
        .and_then(|v| v.to_str().ok())
        .ok_or_else(|| invalid("Idempotency-Key header is required."))?;
    let key = Uuid::parse_str(key).map_err(|_| invalid("Idempotency-Key must be a UUID."))?;

    let raw = read_limited(body, BATCH_BODY_LIMIT).await?;
    let parsed: BatchBody =
        serde_json::from_slice(&raw).map_err(|e| invalid(format!("Invalid JSON: {e}.")))?;
    if parsed.batch_id != key {
        return Err(invalid("Idempotency-Key must equal batch_id."));
    }
    if parsed.device_id != device_id {
        return Err(ApiError::Forbidden(
            "device_id must be the device that signed in.".into(),
        ));
    }
    let batch = validate(parsed)?;

    let mut tx = state.pool.begin().await?;
    let inserted: Option<(Uuid,)> = sqlx::query_as(
        "INSERT INTO sync_batches (id, device_id, payload_sha256, schema_version, counts, status)
         VALUES ($1, $2, $3, 1, '{}'::jsonb, 'pending')
         ON CONFLICT (id) DO NOTHING
         RETURNING id",
    )
    .bind(batch.id)
    .bind(device_id)
    .bind(sha256(&raw))
    .fetch_optional(&mut *tx)
    .await?;

    if inserted.is_none() {
        // Already received. Return what was stored. Nothing is written twice.
        drop(tx);
        let (stored_device, stored_counts): (Uuid, Value) =
            sqlx::query_as("SELECT device_id, counts FROM sync_batches WHERE id = $1")
                .bind(batch.id)
                .fetch_one(&state.pool)
                .await?;
        if stored_device != device_id {
            return Err(ApiError::Forbidden(
                "This batch_id belongs to another device.".into(),
            ));
        }
        let counts: Counts =
            serde_json::from_value(stored_counts).map_err(|_| ApiError::Internal)?;
        return Ok(Json(BatchResponse {
            batch_id: batch.id,
            duplicate: true,
            server_time: Utc::now(),
            counts,
        }));
    }

    let minute_times: Vec<DateTime<Utc>> = batch.minutes.iter().map(|m| m.minute).collect();
    let counts = write_batch(&mut tx, user_id, &batch).await?;
    sqlx::query("UPDATE sync_batches SET counts = $2, status = 'accepted' WHERE id = $1")
        .bind(batch.id)
        .bind(serde_json::to_value(&counts).map_err(|_| ApiError::Internal)?)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;

    // Daily summaries are recomputed after commit, so a rollup failure never loses the batch.
    // The daily job repairs any day that was missed.
    if let Some(err) = refresh_rollups_if_any(&state.pool, user_id, &minute_times)
        .await
        .err()
    {
        tracing::error!(error = %err, "daily rollup after sync batch failed; the daily job will retry");
    }

    Ok(Json(BatchResponse {
        batch_id: batch.id,
        duplicate: false,
        server_time: Utc::now(),
        counts,
    }))
}

async fn write_batch(
    tx: &mut Transaction<'_, Postgres>,
    user_id: Uuid,
    batch: &Batch,
) -> Result<Counts, ApiError> {
    if !batch.bands.is_empty() {
        let ids: Vec<Uuid> = batch.bands.iter().map(|b| b.0).collect();
        let names: Vec<String> = batch.bands.iter().map(|b| b.1.clone()).collect();
        let firmware: Vec<Option<String>> = batch.bands.iter().map(|b| b.2.clone()).collect();
        // A band id owned by another account is left alone (the WHERE clause), and the
        // ownership check below rejects the batch.
        sqlx::query(
            "INSERT INTO bands (id, user_id, name, firmware, last_seen_at)
             SELECT t.id, $1::uuid, t.name, t.firmware, now()
             FROM UNNEST($2::uuid[], $3::text[], $4::text[]) AS t(id, name, firmware)
             ON CONFLICT (id) DO UPDATE SET
               name = EXCLUDED.name, firmware = EXCLUDED.firmware, last_seen_at = now()
             WHERE bands.user_id = EXCLUDED.user_id",
        )
        .bind(user_id)
        .bind(&ids)
        .bind(&names)
        .bind(&firmware)
        .execute(&mut **tx)
        .await?;
    }

    let mut referenced: HashSet<Uuid> = batch
        .hr
        .band_id
        .iter()
        .chain(&batch.rr.band_id)
        .copied()
        .collect();
    referenced.extend(batch.events.iter().map(|e| e.band_id));
    if !referenced.is_empty() {
        let ids: Vec<Uuid> = referenced.iter().copied().collect();
        let (owned,): (i64,) =
            sqlx::query_as("SELECT count(*) FROM bands WHERE user_id = $1 AND id = ANY($2)")
                .bind(user_id)
                .bind(&ids)
                .fetch_one(&mut **tx)
                .await?;
        if owned as usize != ids.len() {
            return Err(invalid(
                "A time series or event refers to a band that is not paired to this account.",
            ));
        }
    }

    let mut counts = Counts::default();

    let hr = &batch.hr;
    if !hr.ts.is_empty() {
        let result = sqlx::query(
            "INSERT INTO hr_samples (band_id, ts, bpm, source, contact, batch_id)
             SELECT t.band_id, t.ts, t.bpm, t.source, t.contact, $6::uuid
             FROM UNNEST($1::uuid[], $2::timestamptz[], $3::smallint[], $4::smallint[], $5::bool[])
               AS t(band_id, ts, bpm, source, contact)
             ON CONFLICT (band_id, ts, source) DO NOTHING",
        )
        .bind(&hr.band_id)
        .bind(&hr.ts)
        .bind(&hr.bpm)
        .bind(&hr.source)
        .bind(&hr.contact)
        .bind(batch.id)
        .execute(&mut **tx)
        .await?;
        counts.hr = split_counts(result.rows_affected(), hr.ts.len());
    }

    let rr = &batch.rr;
    if !rr.ts.is_empty() {
        let result = sqlx::query(
            "INSERT INTO rr_intervals (band_id, ts, seq, rr_ms, accepted, batch_id)
             SELECT t.band_id, t.ts, t.seq, t.rr_ms, t.accepted, $6::uuid
             FROM UNNEST($1::uuid[], $2::timestamptz[], $3::smallint[], $4::real[], $5::bool[])
               AS t(band_id, ts, seq, rr_ms, accepted)
             ON CONFLICT (band_id, ts, seq) DO NOTHING",
        )
        .bind(&rr.band_id)
        .bind(&rr.ts)
        .bind(&rr.seq)
        .bind(&rr.rr_ms)
        .bind(&rr.accepted)
        .bind(batch.id)
        .execute(&mut **tx)
        .await?;
        counts.rr = split_counts(result.rows_affected(), rr.ts.len());
    }

    counts.minute_metrics = upsert_minutes(tx, user_id, &batch.minutes).await?;

    if !batch.events.is_empty() {
        let band_ids: Vec<Uuid> = batch.events.iter().map(|e| e.band_id).collect();
        let times: Vec<DateTime<Utc>> = batch.events.iter().map(|e| e.ts).collect();
        let kinds: Vec<String> = batch.events.iter().map(|e| e.kind.clone()).collect();
        let payloads: Vec<String> = batch.events.iter().map(|e| e.payload.clone()).collect();
        let result = sqlx::query(
            "INSERT INTO band_events (band_id, ts, kind, payload, batch_id)
             SELECT t.band_id, t.ts, t.kind, t.payload::jsonb, $5::uuid
             FROM UNNEST($1::uuid[], $2::timestamptz[], $3::text[], $4::text[])
               AS t(band_id, ts, kind, payload)
             ON CONFLICT (band_id, ts, kind) DO NOTHING",
        )
        .bind(&band_ids)
        .bind(&times)
        .bind(&kinds)
        .bind(&payloads)
        .bind(batch.id)
        .execute(&mut **tx)
        .await?;
        counts.events = split_counts(result.rows_affected(), batch.events.len());
    }

    if !batch.deliveries.is_empty() {
        let d = &batch.deliveries;
        let ids: Vec<Uuid> = d.iter().map(|x| x.id).collect();
        let alarm_ids: Vec<Option<Uuid>> = d.iter().map(|x| x.alarm_id).collect();
        let dispatch_ids: Vec<Option<Uuid>> = d.iter().map(|x| x.dispatch_id).collect();
        let times: Vec<DateTime<Utc>> = d.iter().map(|x| x.ts).collect();
        let channels: Vec<String> = d.iter().map(|x| x.channel.clone()).collect();
        let statuses: Vec<String> = d.iter().map(|x| x.status.clone()).collect();
        let details: Vec<Option<String>> = d.iter().map(|x| x.detail.clone()).collect();
        let result = sqlx::query(
            "INSERT INTO alarm_deliveries (id, user_id, batch_id, alarm_id, dispatch_id, ts, channel, status, detail)
             SELECT t.id, $1::uuid, $2::uuid, t.alarm_id, t.dispatch_id, t.ts, t.channel, t.status, t.detail
             FROM UNNEST($3::uuid[], $4::uuid[], $5::uuid[], $6::timestamptz[], $7::text[], $8::text[], $9::text[])
               AS t(id, alarm_id, dispatch_id, ts, channel, status, detail)
             ON CONFLICT (id) DO NOTHING",
        )
        .bind(user_id)
        .bind(batch.id)
        .bind(&ids)
        .bind(&alarm_ids)
        .bind(&dispatch_ids)
        .bind(&times)
        .bind(&channels)
        .bind(&statuses)
        .bind(&details)
        .execute(&mut **tx)
        .await?;
        counts.alarm_deliveries = split_counts(result.rows_affected(), d.len());
    }

    Ok(counts)
}

fn split_counts(inserted: u64, total: usize) -> Inserted {
    Inserted {
        inserted,
        duplicate: (total as u64).saturating_sub(inserted),
    }
}

/// Upserts minute metrics only where the incoming `sync_rev` is higher (PLAN.md §11.5).
/// Within one batch, the highest `sync_rev` per minute wins. Lower or equal revisions count as stale.
async fn upsert_minutes(
    tx: &mut Transaction<'_, Postgres>,
    user_id: Uuid,
    minutes: &[MinuteRow],
) -> Result<Upserted, ApiError> {
    if minutes.is_empty() {
        return Ok(Upserted::default());
    }
    let mut latest: BTreeMap<DateTime<Utc>, &MinuteRow> = BTreeMap::new();
    for row in minutes {
        latest
            .entry(row.minute)
            .and_modify(|kept| {
                if row.sync_rev > kept.sync_rev {
                    *kept = row;
                }
            })
            .or_insert(row);
    }
    let rows: Vec<&MinuteRow> = latest.into_values().collect();

    let result = sqlx::query(
        "INSERT INTO minute_metrics (user_id, minute, hr_avg, hr_min, hr_max, hr_n, rmssd_ms, sdnn_ms,
           baevsky_sqrt, stress, stress_state, kcal, active_kcal, kcal_estimated, algo_version, sync_rev, updated_at)
         SELECT $1::uuid, t.minute, t.hr_avg, t.hr_min, t.hr_max, t.hr_n, t.rmssd_ms, t.sdnn_ms,
           t.baevsky_sqrt, t.stress, t.stress_state, t.kcal, t.active_kcal, t.kcal_estimated, t.algo_version, t.sync_rev, now()
         FROM UNNEST($2::timestamptz[], $3::real[], $4::smallint[], $5::smallint[], $6::smallint[], $7::real[],
           $8::real[], $9::real[], $10::smallint[], $11::text[], $12::real[], $13::real[], $14::bool[],
           $15::smallint[], $16::integer[])
           AS t(minute, hr_avg, hr_min, hr_max, hr_n, rmssd_ms, sdnn_ms, baevsky_sqrt, stress, stress_state,
             kcal, active_kcal, kcal_estimated, algo_version, sync_rev)
         ON CONFLICT (user_id, minute) DO UPDATE SET
           hr_avg = EXCLUDED.hr_avg, hr_min = EXCLUDED.hr_min, hr_max = EXCLUDED.hr_max, hr_n = EXCLUDED.hr_n,
           rmssd_ms = EXCLUDED.rmssd_ms, sdnn_ms = EXCLUDED.sdnn_ms, baevsky_sqrt = EXCLUDED.baevsky_sqrt,
           stress = EXCLUDED.stress, stress_state = EXCLUDED.stress_state, kcal = EXCLUDED.kcal,
           active_kcal = EXCLUDED.active_kcal, kcal_estimated = EXCLUDED.kcal_estimated,
           algo_version = EXCLUDED.algo_version, sync_rev = EXCLUDED.sync_rev, updated_at = now()
         WHERE EXCLUDED.sync_rev > minute_metrics.sync_rev",
    )
    .bind(user_id)
    .bind(rows.iter().map(|r| r.minute).collect::<Vec<_>>())
    .bind(rows.iter().map(|r| r.hr_avg).collect::<Vec<_>>())
    .bind(rows.iter().map(|r| r.hr_min).collect::<Vec<_>>())
    .bind(rows.iter().map(|r| r.hr_max).collect::<Vec<_>>())
    .bind(rows.iter().map(|r| r.hr_n).collect::<Vec<_>>())
    .bind(rows.iter().map(|r| r.rmssd_ms).collect::<Vec<_>>())
    .bind(rows.iter().map(|r| r.sdnn_ms).collect::<Vec<_>>())
    .bind(rows.iter().map(|r| r.baevsky_sqrt).collect::<Vec<_>>())
    .bind(rows.iter().map(|r| r.stress).collect::<Vec<_>>())
    .bind(rows.iter().map(|r| r.stress_state.clone()).collect::<Vec<_>>())
    .bind(rows.iter().map(|r| r.kcal).collect::<Vec<_>>())
    .bind(rows.iter().map(|r| r.active_kcal).collect::<Vec<_>>())
    .bind(rows.iter().map(|r| r.kcal_estimated).collect::<Vec<_>>())
    .bind(rows.iter().map(|r| r.algo_version).collect::<Vec<_>>())
    .bind(rows.iter().map(|r| r.sync_rev).collect::<Vec<_>>())
    .execute(&mut **tx)
    .await?;

    let upserted = result.rows_affected();
    Ok(Upserted {
        upserted,
        stale: (minutes.len() as u64).saturating_sub(upserted),
    })
}

async fn refresh_rollups_if_any(
    pool: &PgPool,
    user_id: Uuid,
    minutes: &[DateTime<Utc>],
) -> Result<(), sqlx::Error> {
    if minutes.is_empty() {
        return Ok(());
    }
    let tz: String = sqlx::query_scalar("SELECT tz FROM users WHERE id = $1")
        .bind(user_id)
        .fetch_one(pool)
        .await?;
    let days = rollup::local_days_for_minutes(pool, &tz, minutes).await?;
    rollup::recompute_days(pool, user_id, &tz, &days).await?;
    Ok(())
}

// ---- GET /v1/sync/config ----

#[derive(Deserialize)]
pub struct ConfigQuery {
    since: Option<String>,
}

#[derive(Serialize)]
pub struct ConfigResponse {
    alarms: Vec<Alarm>,
    webhook_endpoints: Vec<Hook>,
    profile: Me,
    max_version: i64,
    #[serde(with = "rfc3339")]
    server_time: DateTime<Utc>,
}

/// Rows with `version > since`, tombstones included, plus the profile (api-contract.md).
pub async fn get_config(
    State(state): State<AppState>,
    AppDevice { user_id, .. }: AppDevice,
    Query(query): Query<ConfigQuery>,
) -> Result<Json<ConfigResponse>, ApiError> {
    let since: i64 = match query.since {
        None => 0,
        Some(raw) => raw
            .parse::<i64>()
            .ok()
            .filter(|v| *v >= 0)
            .ok_or_else(|| invalid("since must be a non-negative integer."))?,
    };

    let alarm_rows: Vec<AlarmRow> = sqlx::query_as(&format!(
        "SELECT {ALARM_COLUMNS} FROM alarms WHERE user_id = $1 AND version > $2 ORDER BY version"
    ))
    .bind(user_id)
    .bind(since)
    .fetch_all(&state.pool)
    .await?;
    let hook_rows: Vec<HookRow> = sqlx::query_as(&format!(
        "SELECT {HOOK_COLUMNS} FROM webhook_endpoints WHERE user_id = $1 AND version > $2 ORDER BY version"
    ))
    .bind(user_id)
    .bind(since)
    .fetch_all(&state.pool)
    .await?;
    let (max_version,): (i64,) = sqlx::query_as(
        "SELECT GREATEST(
           COALESCE((SELECT max(version) FROM alarms WHERE user_id = $1), 0),
           COALESCE((SELECT max(version) FROM webhook_endpoints WHERE user_id = $1), 0))",
    )
    .bind(user_id)
    .fetch_one(&state.pool)
    .await?;

    let alarms = alarm_rows
        .into_iter()
        .map(alarm_from_row)
        .collect::<Result<Vec<_>, _>>()?;
    let base = state.config.public_base_url.trim_end_matches('/');
    let webhook_endpoints = hook_rows
        .into_iter()
        .map(|row| hook_from_row(row, base, state.config.secrets.as_ref()))
        .collect::<Result<Vec<_>, _>>()?;

    Ok(Json(ConfigResponse {
        alarms,
        webhook_endpoints,
        profile: load_me(&state.pool, user_id).await?,
        max_version,
        server_time: Utc::now(),
    }))
}

// ---- GET /v1/sync/state ----

#[derive(FromRow)]
struct BatchRow {
    id: Uuid,
    device_id: Uuid,
    received_at: DateTime<Utc>,
    counts: Value,
    status: String,
}

#[derive(Serialize)]
pub struct BatchSummary {
    id: Uuid,
    device_id: Uuid,
    #[serde(with = "rfc3339")]
    received_at: DateTime<Utc>,
    counts: Value,
    status: String,
}

#[derive(Serialize)]
pub struct StateResponse {
    #[serde(with = "rfc3339")]
    server_time: DateTime<Utc>,
    last_batch_at: Option<String>,
    batches: Vec<BatchSummary>,
}

pub async fn get_state(
    State(state): State<AppState>,
    crate::auth::Either(principal): crate::auth::Either,
) -> Result<Json<StateResponse>, ApiError> {
    let rows: Vec<BatchRow> = sqlx::query_as(
        "SELECT b.id, b.device_id, b.received_at, b.counts, b.status
         FROM sync_batches b JOIN devices d ON d.id = b.device_id
         WHERE d.user_id = $1
         ORDER BY b.received_at DESC, b.id DESC
         LIMIT 50",
    )
    .bind(principal.user_id())
    .fetch_all(&state.pool)
    .await?;

    Ok(Json(StateResponse {
        server_time: Utc::now(),
        last_batch_at: rows
            .first()
            .map(|r| icarus_core::time::format(&r.received_at)),
        batches: rows
            .into_iter()
            .map(|r| BatchSummary {
                id: r.id,
                device_id: r.device_id,
                received_at: r.received_at,
                counts: r.counts,
                status: r.status,
            })
            .collect(),
    }))
}
