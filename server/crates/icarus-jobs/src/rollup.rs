//! Daily summaries from `minute_metrics`, computed in the user's timezone (PLAN.md §10.2, §11.3).
//!
//! Definitions:
//! - A minute qualifies for RHR when `hr_n >= 48`. A rolling 5-minute mean needs all 5 qualifying
//!   minutes in the window ending at that minute. `rhr` is the minimum of those means for windows
//!   ending between 00:00 and 06:00 local time.
//! - `hr_avg` is the `hr_n`-weighted mean of minute averages. `hr_max` is the maximum minute max.
//! - `rmssd_night_ms` is the mean of minute RMSSD between 00:00 and 06:00 local time.
//! - `stress_avg` and `stress_high_minutes` (stress >= 67) use minutes with `stress_state = 'value'`.
//! - `coverage` is minutes with `hr_n > 0` divided by 1440, as the contract states.

use chrono::{DateTime, NaiveDate, Utc};
use sqlx::{PgPool, Row};
use uuid::Uuid;

/// Days recomputed by the daily job, counting back from today in each user's timezone.
pub const RECENT_DAYS: i64 = 3;
const STRESS_HIGH: i16 = 67;

#[derive(Debug, Clone, PartialEq)]
pub struct DaySummary {
    pub rhr: Option<i16>,
    pub hr_avg: Option<f32>,
    pub hr_max: Option<i16>,
    pub rmssd_night_ms: Option<f32>,
    pub stress_avg: Option<f32>,
    pub stress_high_minutes: i32,
    pub kcal_total: Option<f32>,
    pub kcal_active: Option<f32>,
    pub coverage: f32,
    pub algo_version: i16,
}

/// Recomputes `daily_summaries` for each day in the user's local calendar. Days with no minutes lose
/// their row. Runs in one transaction and returns the number of days processed.
pub async fn recompute_days(
    pool: &PgPool,
    user_id: Uuid,
    tz: &str,
    days: &[NaiveDate],
) -> Result<usize, sqlx::Error> {
    let mut days = days.to_vec();
    days.sort_unstable();
    days.dedup();

    let mut tx = pool.begin().await?;
    for day in &days {
        match compute_day(&mut *tx, user_id, tz, *day).await? {
            Some(summary) => upsert(&mut *tx, user_id, *day, &summary).await?,
            None => {
                sqlx::query("DELETE FROM daily_summaries WHERE user_id = $1 AND day = $2")
                    .bind(user_id)
                    .bind(day)
                    .execute(&mut *tx)
                    .await?;
            }
        }
    }
    tx.commit().await?;
    Ok(days.len())
}

/// Recomputes the last `RECENT_DAYS` local days for every user. Used by the daily job.
pub async fn recompute_recent_for_all_users(
    pool: &PgPool,
    now: DateTime<Utc>,
) -> Result<(), sqlx::Error> {
    let users: Vec<(Uuid, String, NaiveDate)> =
        sqlx::query_as("SELECT id, tz, (($1::timestamptz) AT TIME ZONE tz)::date FROM users")
            .bind(now)
            .fetch_all(pool)
            .await?;
    for (user_id, tz, today) in users {
        let days: Vec<NaiveDate> = (0..RECENT_DAYS)
            .filter_map(|back| today.checked_sub_days(chrono::Days::new(back as u64)))
            .collect();
        recompute_days(pool, user_id, &tz, &days).await?;
    }
    Ok(())
}

/// Local calendar days (in `tz`) touched by these UTC minutes.
pub async fn local_days_for_minutes(
    pool: &PgPool,
    tz: &str,
    minutes: &[DateTime<Utc>],
) -> Result<Vec<NaiveDate>, sqlx::Error> {
    if minutes.is_empty() {
        return Ok(Vec::new());
    }
    let rows = sqlx::query(
        "SELECT DISTINCT (m AT TIME ZONE $1)::date AS day FROM UNNEST($2::timestamptz[]) AS m",
    )
    .bind(tz)
    .bind(minutes)
    .fetch_all(pool)
    .await?;
    rows.iter().map(|r| r.try_get("day")).collect()
}

async fn compute_day<'e, E>(
    executor: E,
    user_id: Uuid,
    tz: &str,
    day: NaiveDate,
) -> Result<Option<DaySummary>, sqlx::Error>
where
    E: sqlx::Executor<'e, Database = sqlx::Postgres>,
{
    // $1 tz, $2 day, $3 user. The rolling window looks back 4 minutes before 00:00 so the first
    // window of the day is complete.
    let row = sqlx::query(
        r#"
WITH bounds AS (
  SELECT ($2::date)::timestamp AT TIME ZONE $1                    AS day_start,
         (($2::date) + 1)::timestamp AT TIME ZONE $1              AS day_end,
         (($2::date)::timestamp + interval '6 hours') AT TIME ZONE $1 AS night_end
),
day_rows AS (
  SELECT m.* FROM minute_metrics m, bounds b
  WHERE m.user_id = $3 AND m.minute >= b.day_start AND m.minute < b.day_end
),
qualifying AS (
  SELECT m.minute, m.hr_avg FROM minute_metrics m, bounds b
  WHERE m.user_id = $3 AND m.hr_n >= 48 AND m.hr_avg IS NOT NULL
    AND m.minute >= b.day_start - interval '4 minutes' AND m.minute < b.night_end
),
rolling AS (
  SELECT minute, avg(hr_avg) OVER w AS m5, count(*) OVER w AS n
  FROM qualifying
  WINDOW w AS (ORDER BY minute RANGE BETWEEN interval '4 minutes' PRECEDING AND CURRENT ROW)
)
SELECT
  (SELECT min(r.m5)::float8 FROM rolling r, bounds b
     WHERE r.n = 5 AND r.minute >= b.day_start AND r.minute < b.night_end)       AS rhr,
  count(*)                                                                       AS minutes,
  count(*) FILTER (WHERE d.hr_n > 0)                                             AS hr_minutes,
  (sum(d.hr_avg::float8 * d.hr_n) FILTER (WHERE d.hr_avg IS NOT NULL AND d.hr_n > 0)
     / NULLIF(sum(d.hr_n) FILTER (WHERE d.hr_avg IS NOT NULL AND d.hr_n > 0), 0))::float8 AS hr_avg,
  max(d.hr_max)                                                                  AS hr_max,
  (avg(d.rmssd_ms) FILTER (WHERE d.minute < b.night_end AND d.rmssd_ms IS NOT NULL))::float8 AS rmssd_night_ms,
  (avg(d.stress) FILTER (WHERE d.stress_state = 'value' AND d.stress IS NOT NULL))::float8    AS stress_avg,
  count(*) FILTER (WHERE d.stress_state = 'value' AND d.stress >= $4)           AS stress_high_minutes,
  sum(d.kcal)::float8                                                            AS kcal_total,
  sum(d.active_kcal)::float8                                                     AS kcal_active,
  max(d.algo_version)                                                            AS algo_version
FROM day_rows d CROSS JOIN bounds b
"#,
    )
    .bind(tz)
    .bind(day)
    .bind(user_id)
    .bind(STRESS_HIGH)
    .fetch_one(executor)
    .await?;

    let minutes: i64 = row.try_get("minutes")?;
    if minutes == 0 {
        return Ok(None);
    }
    let hr_minutes: i64 = row.try_get("hr_minutes")?;
    let rhr: Option<f64> = row.try_get("rhr")?;
    let f32_of = |v: Option<f64>| v.map(|x| x as f32);
    Ok(Some(DaySummary {
        rhr: rhr.map(|x| x.round() as i16),
        hr_avg: f32_of(row.try_get("hr_avg")?),
        hr_max: row.try_get("hr_max")?,
        rmssd_night_ms: f32_of(row.try_get("rmssd_night_ms")?),
        stress_avg: f32_of(row.try_get("stress_avg")?),
        stress_high_minutes: row.try_get::<i64, _>("stress_high_minutes")? as i32,
        kcal_total: f32_of(row.try_get("kcal_total")?),
        kcal_active: f32_of(row.try_get("kcal_active")?),
        coverage: hr_minutes as f32 / 1440.0,
        algo_version: row.try_get::<Option<i16>, _>("algo_version")?.unwrap_or(0),
    }))
}

async fn upsert<'e, E>(
    executor: E,
    user_id: Uuid,
    day: NaiveDate,
    s: &DaySummary,
) -> Result<(), sqlx::Error>
where
    E: sqlx::Executor<'e, Database = sqlx::Postgres>,
{
    sqlx::query(
        r#"
INSERT INTO daily_summaries (user_id, day, rhr, hr_avg, hr_max, rmssd_night_ms, stress_avg,
  stress_high_minutes, kcal_total, kcal_active, coverage, algo_version, computed_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, now())
ON CONFLICT (user_id, day) DO UPDATE SET
  rhr = EXCLUDED.rhr, hr_avg = EXCLUDED.hr_avg, hr_max = EXCLUDED.hr_max,
  rmssd_night_ms = EXCLUDED.rmssd_night_ms, stress_avg = EXCLUDED.stress_avg,
  stress_high_minutes = EXCLUDED.stress_high_minutes, kcal_total = EXCLUDED.kcal_total,
  kcal_active = EXCLUDED.kcal_active, coverage = EXCLUDED.coverage,
  algo_version = EXCLUDED.algo_version, computed_at = EXCLUDED.computed_at
"#,
    )
    .bind(user_id)
    .bind(day)
    .bind(s.rhr)
    .bind(s.hr_avg)
    .bind(s.hr_max)
    .bind(s.rmssd_night_ms)
    .bind(s.stress_avg)
    .bind(s.stress_high_minutes)
    .bind(s.kcal_total)
    .bind(s.kcal_active)
    .bind(s.coverage)
    .bind(s.algo_version)
    .execute(executor)
    .await?;
    Ok(())
}
