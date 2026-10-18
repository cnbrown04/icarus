//! Retention (PLAN.md §10.4): raw time series for 400 days, webhook deliveries for 90 days.
//!
//! Raw partitions are dropped whole, which is O(1). A partition is dropped only when every row in
//! it is older than the cutoff. Minute metrics and daily summaries are kept indefinitely.

use chrono::{DateTime, Datelike, Duration, NaiveDate, TimeZone, Utc};
use sqlx::PgPool;

use crate::partitions::{PARTITIONED_TABLES, next_month_start};

pub const RAW_RETENTION_DAYS: i64 = 400;
pub const DELIVERY_RETENTION_DAYS: i64 = 90;

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct RetentionReport {
    pub partitions_dropped: Vec<String>,
    pub default_rows_deleted: u64,
    pub deliveries_deleted: u64,
}

/// Applies both retention rules as of `now`. Safe to run repeatedly.
pub async fn run(pool: &PgPool, now: DateTime<Utc>) -> Result<RetentionReport, sqlx::Error> {
    let raw_cutoff = now - Duration::days(RAW_RETENTION_DAYS);
    let mut report = RetentionReport::default();
    for table in PARTITIONED_TABLES {
        report
            .partitions_dropped
            .extend(drop_expired_partitions(pool, table, raw_cutoff).await?);
        // Rows that landed in the default partition before their month had one.
        report.default_rows_deleted +=
            sqlx::query(&format!("DELETE FROM {table}_default WHERE ts < $1"))
                .bind(raw_cutoff)
                .execute(pool)
                .await?
                .rows_affected();
    }

    let delivery_cutoff = now - Duration::days(DELIVERY_RETENTION_DAYS);
    report.deliveries_deleted =
        sqlx::query("DELETE FROM webhook_deliveries WHERE received_at < $1")
            .bind(delivery_cutoff)
            .execute(pool)
            .await?
            .rows_affected();
    Ok(report)
}

/// Drops monthly partitions of `table` whose whole month ends at or before `cutoff`.
async fn drop_expired_partitions(
    pool: &PgPool,
    table: &str,
    cutoff: DateTime<Utc>,
) -> Result<Vec<String>, sqlx::Error> {
    let children: Vec<(String,)> = sqlx::query_as(
        "SELECT c.relname::text
         FROM pg_inherits i
         JOIN pg_class c ON c.oid = i.inhrelid
         JOIN pg_class p ON p.oid = i.inhparent
         WHERE p.relname = $1",
    )
    .bind(table)
    .fetch_all(pool)
    .await?;

    let mut dropped = Vec::new();
    for (name,) in children {
        let Some(month) = partition_month(table, &name) else {
            continue;
        };
        let month_end = Utc.from_utc_datetime(
            &next_month_start(month)
                .and_hms_opt(0, 0, 0)
                .expect("midnight exists"),
        );
        if month_end <= cutoff {
            // The name matched the partition pattern above, so it is a plain identifier.
            sqlx::query(&format!("DROP TABLE IF EXISTS \"{name}\""))
                .execute(pool)
                .await?;
            dropped.push(name);
        }
    }
    Ok(dropped)
}

/// `hr_samples_y2026m10` -> 2026-10-01. Other names give `None`.
fn partition_month(table: &str, name: &str) -> Option<NaiveDate> {
    let rest = name.strip_prefix(table)?.strip_prefix("_y")?;
    let (year, month) = rest.split_once('m')?;
    if year.len() != 4 || month.len() != 2 {
        return None;
    }
    let year: i32 = year.parse().ok()?;
    let month: u32 = month.parse().ok()?;
    let day = NaiveDate::from_ymd_opt(year, month, 1)?;
    (day.year() == year).then_some(day)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_partition_names() {
        assert_eq!(
            partition_month("hr_samples", "hr_samples_y2026m10"),
            NaiveDate::from_ymd_opt(2026, 10, 1)
        );
        assert_eq!(partition_month("hr_samples", "hr_samples_default"), None);
        assert_eq!(partition_month("hr_samples", "rr_intervals_y2026m10"), None);
        assert_eq!(partition_month("hr_samples", "hr_samples_y2026m13"), None);
        assert_eq!(partition_month("hr_samples", "hr_samples_y26m10"), None);
    }
}
