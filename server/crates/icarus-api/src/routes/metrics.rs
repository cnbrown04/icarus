//! Read routes for heart rate, minutes, days and the live value (api-contract.md "Metrics", PLAN.md §10.4).
//!
//! Source by range: raw samples up to 6 h, minute metrics up to 14 d, daily summaries beyond that.
//! Estimates only; nothing here is a medical reading.

use axum::{Json, extract::State};
use chrono::{DateTime, Duration, NaiveDate, SecondsFormat, Utc};
use icarus_core::time::rfc3339;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sqlx::FromRow;

use crate::{auth::Either, error::ApiError, extract::ApiQuery, state::AppState};

const RAW_MAX: Duration = Duration::hours(6);
const MINUTES_MAX: Duration = Duration::days(14);
/// Ten years of days. Daily summaries are kept indefinitely, so the route needs its own cap.
const DAILY_MAX_DAYS: i64 = 3660;

#[derive(Deserialize)]
pub struct RangeQuery {
    from: Option<String>,
    to: Option<String>,
}

#[derive(Deserialize)]
pub struct HrQuery {
    from: Option<String>,
    to: Option<String>,
    res: Option<String>,
}

#[derive(Deserialize)]
pub struct DailyQuery {
    from: Option<String>,
    to: Option<String>,
}

#[derive(Clone, Copy)]
enum Resolution {
    Raw,
    Minute,
    FiveMinutes,
    Hour,
}

fn parse_time(raw: Option<&str>, name: &str) -> Result<DateTime<Utc>, ApiError> {
    let raw = raw.ok_or_else(|| ApiError::Validation(format!("{name} is required (RFC 3339).")))?;
    DateTime::parse_from_rfc3339(raw)
        .map(|t| t.with_timezone(&Utc))
        .map_err(|_| ApiError::Validation(format!("{name} must be an RFC 3339 time.")))
}

/// `from` < `to`, and the span at most `max`.
fn time_range(
    from: Option<&str>,
    to: Option<&str>,
    max: Duration,
) -> Result<(DateTime<Utc>, DateTime<Utc>), ApiError> {
    let from = parse_time(from, "from")?;
    let to = parse_time(to, "to")?;
    if to <= from {
        return Err(ApiError::Validation("to must be after from.".into()));
    }
    if to - from > max {
        return Err(ApiError::Validation(format!(
            "The range is longer than {} hours.",
            max.num_hours()
        )));
    }
    Ok((from, to))
}

fn round1(value: f64) -> f64 {
    (value * 10.0).round() / 10.0
}

#[derive(Serialize, FromRow)]
pub struct HrPoint {
    #[serde(with = "rfc3339")]
    t: DateTime<Utc>,
    avg: Option<f64>,
    min: Option<i32>,
    max: Option<i32>,
}

pub async fn hr(
    State(state): State<AppState>,
    Either(principal): Either,
    ApiQuery(query): ApiQuery<HrQuery>,
) -> Result<Json<Value>, ApiError> {
    let res = match query.res.as_deref() {
        Some("raw") => Resolution::Raw,
        Some("1m") => Resolution::Minute,
        Some("5m") => Resolution::FiveMinutes,
        Some("1h") => Resolution::Hour,
        _ => {
            return Err(ApiError::Validation(
                "res must be raw, 1m, 5m or 1h.".into(),
            ));
        }
    };
    let max = match res {
        Resolution::Raw => RAW_MAX,
        _ => MINUTES_MAX,
    };
    let (from, to) = time_range(query.from.as_deref(), query.to.as_deref(), max)?;
    let user_id = principal.user_id();
    let pool = &state.pool;

    let mut points: Vec<HrPoint> = match res {
        Resolution::Raw => {
            sqlx::query_as(
                "SELECT date_trunc('second', h.ts) AS t,
                        avg(h.bpm)::float8 AS avg, min(h.bpm)::int4 AS min, max(h.bpm)::int4 AS max
                 FROM hr_samples h JOIN bands b ON b.id = h.band_id
                 WHERE b.user_id = $1 AND h.ts >= $2 AND h.ts < $3
                 GROUP BY 1 ORDER BY 1",
            )
            .bind(user_id)
            .bind(from)
            .bind(to)
            .fetch_all(pool)
            .await?
        }
        Resolution::Minute => sqlx::query_as(
            "SELECT minute AS t, hr_avg::float8 AS avg, hr_min::int4 AS min, hr_max::int4 AS max
                 FROM minute_metrics
                 WHERE user_id = $1 AND minute >= $2 AND minute < $3 AND hr_avg IS NOT NULL
                 ORDER BY minute",
        )
        .bind(user_id)
        .bind(from)
        .bind(to)
        .fetch_all(pool)
        .await?,
        Resolution::FiveMinutes | Resolution::Hour => {
            let width = match res {
                Resolution::FiveMinutes => "5 minutes",
                _ => "1 hour",
            };
            // Averages weight each minute by its sample count, as the contract's `hr_avg` does.
            sqlx::query_as(&format!(
                "SELECT date_bin(interval '{width}', minute, 'epoch'::timestamptz) AS t,
                        (sum(hr_avg::float8 * GREATEST(COALESCE(hr_n, 1), 1))
                           / NULLIF(sum(GREATEST(COALESCE(hr_n, 1), 1)) FILTER (WHERE hr_avg IS NOT NULL), 0))
                           AS avg,
                        min(hr_min)::int4 AS min, max(hr_max)::int4 AS max
                 FROM minute_metrics
                 WHERE user_id = $1 AND minute >= $2 AND minute < $3
                 GROUP BY 1
                 HAVING count(hr_avg) > 0
                 ORDER BY 1"
            ))
            .bind(user_id)
            .bind(from)
            .bind(to)
            .fetch_all(pool)
            .await?
        }
    };
    for point in &mut points {
        point.avg = point.avg.map(round1);
    }

    let res_name = match res {
        Resolution::Raw => "raw",
        Resolution::Minute => "1m",
        Resolution::FiveMinutes => "5m",
        Resolution::Hour => "1h",
    };
    Ok(Json(json!({ "res": res_name, "points": points })))
}

#[derive(Serialize, FromRow)]
pub struct MinuteOut {
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
}

/// Typed responses: going through `json!` would widen `f32` values and show their binary noise.
#[derive(Serialize)]
pub struct MinutesResponse {
    minutes: Vec<MinuteOut>,
}

pub async fn minutes(
    State(state): State<AppState>,
    Either(principal): Either,
    ApiQuery(query): ApiQuery<RangeQuery>,
) -> Result<Json<MinutesResponse>, ApiError> {
    let (from, to) = time_range(query.from.as_deref(), query.to.as_deref(), MINUTES_MAX)?;
    let rows: Vec<MinuteOut> = sqlx::query_as(
        "SELECT minute, hr_avg, hr_min, hr_max, hr_n, rmssd_ms, sdnn_ms, baevsky_sqrt, stress,
                stress_state, kcal, active_kcal, kcal_estimated
         FROM minute_metrics
         WHERE user_id = $1 AND minute >= $2 AND minute < $3
         ORDER BY minute",
    )
    .bind(principal.user_id())
    .bind(from)
    .bind(to)
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(MinutesResponse { minutes: rows }))
}

#[derive(Serialize, FromRow)]
pub struct DayOut {
    day: NaiveDate,
    rhr: Option<i16>,
    hr_avg: Option<f32>,
    hr_max: Option<i16>,
    rmssd_night_ms: Option<f32>,
    stress_avg: Option<f32>,
    stress_high_minutes: Option<i32>,
    kcal_total: Option<f32>,
    kcal_active: Option<f32>,
    coverage: Option<f32>,
}

fn parse_day(raw: Option<&str>, name: &str) -> Result<NaiveDate, ApiError> {
    let raw =
        raw.ok_or_else(|| ApiError::Validation(format!("{name} is required (YYYY-MM-DD).")))?;
    NaiveDate::parse_from_str(raw, "%Y-%m-%d")
        .map_err(|_| ApiError::Validation(format!("{name} must be a YYYY-MM-DD day.")))
}

#[derive(Serialize)]
pub struct DailyResponse {
    days: Vec<DayOut>,
}

pub async fn daily(
    State(state): State<AppState>,
    Either(principal): Either,
    ApiQuery(query): ApiQuery<DailyQuery>,
) -> Result<Json<DailyResponse>, ApiError> {
    let from = parse_day(query.from.as_deref(), "from")?;
    let to = parse_day(query.to.as_deref(), "to")?;
    if to < from {
        return Err(ApiError::Validation("to must be on or after from.".into()));
    }
    if (to - from).num_days() > DAILY_MAX_DAYS {
        return Err(ApiError::Validation(format!(
            "The range is longer than {DAILY_MAX_DAYS} days."
        )));
    }
    let rows: Vec<DayOut> = sqlx::query_as(
        "SELECT day, rhr, hr_avg, hr_max, rmssd_night_ms, stress_avg, stress_high_minutes,
                kcal_total, kcal_active, coverage
         FROM daily_summaries
         WHERE user_id = $1 AND day >= $2 AND day <= $3
         ORDER BY day",
    )
    .bind(principal.user_id())
    .bind(from)
    .bind(to)
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(DailyResponse { days: rows }))
}

/// Latest raw sample across the user's bands, or nulls when there is none.
pub async fn live(
    State(state): State<AppState>,
    Either(principal): Either,
) -> Result<Json<Value>, ApiError> {
    let row: Option<(DateTime<Utc>, i16)> = sqlx::query_as(
        "SELECT h.ts, h.bpm
         FROM hr_samples h JOIN bands b ON b.id = h.band_id
         WHERE b.user_id = $1
         ORDER BY h.ts DESC
         LIMIT 1",
    )
    .bind(principal.user_id())
    .fetch_optional(&state.pool)
    .await?;
    Ok(Json(match row {
        Some((ts, bpm)) => json!({
            "bpm": bpm,
            "ts": ts.to_rfc3339_opts(SecondsFormat::Secs, true),
        }),
        None => json!({ "bpm": null, "ts": null }),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn range_must_be_ordered_and_bounded() {
        let ok = time_range(
            Some("2026-10-07T00:00:00Z"),
            Some("2026-10-07T06:00:00Z"),
            RAW_MAX,
        );
        assert!(ok.is_ok());
        assert!(
            time_range(
                Some("2026-10-07T00:00:00Z"),
                Some("2026-10-07T06:00:01Z"),
                RAW_MAX
            )
            .is_err()
        );
        assert!(
            time_range(
                Some("2026-10-07T06:00:00Z"),
                Some("2026-10-07T06:00:00Z"),
                RAW_MAX
            )
            .is_err()
        );
        assert!(time_range(None, Some("2026-10-07T06:00:00Z"), RAW_MAX).is_err());
        assert!(time_range(Some("yesterday"), Some("2026-10-07T06:00:00Z"), RAW_MAX).is_err());
    }
}
