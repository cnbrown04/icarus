//! Monthly range partitions for `hr_samples` and `rr_intervals` (PLAN.md §10.3).
//!
//! Partitions are UTC calendar months. The `*_default` partition catches rows whose month has no
//! partition yet. When a partition is created later, rows already in the default for that month
//! are moved into it, because Postgres refuses to attach a partition over conflicting default rows.

use chrono::{DateTime, Datelike, NaiveDate, Utc};
use sqlx::{PgPool, Postgres, Transaction};

pub const PARTITIONED_TABLES: [&str; 2] = ["hr_samples", "rr_intervals"];

/// Creates the partitions for the month containing `now` and the month after it.
pub async fn ensure_current_and_next(pool: &PgPool, now: DateTime<Utc>) -> Result<(), sqlx::Error> {
    let this_month = month_start(now.date_naive());
    let next_month = next_month_start(this_month);
    for table in PARTITIONED_TABLES {
        ensure_month(pool, table, this_month).await?;
        ensure_month(pool, table, next_month).await?;
    }
    Ok(())
}

/// Creates `<table>_yYYYYmMM` for the month starting at `month` if it does not exist.
pub async fn ensure_month(pool: &PgPool, table: &str, month: NaiveDate) -> Result<(), sqlx::Error> {
    let mut tx = pool.begin().await?;
    create_partition_in_tx(&mut tx, table, month).await?;
    tx.commit().await
}

async fn create_partition_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    table: &str,
    month: NaiveDate,
) -> Result<(), sqlx::Error> {
    let name = partition_name(table, month);
    let from = month;
    let to = next_month_start(month);
    let from_ts = format!("{from} 00:00:00+00");
    let to_ts = format!("{to} 00:00:00+00");

    // Serialises concurrent callers for the same partition.
    sqlx::query("SELECT pg_advisory_xact_lock(hashtext($1))")
        .bind(&name)
        .execute(&mut **tx)
        .await?;

    let exists: bool = sqlx::query_scalar("SELECT to_regclass($1) IS NOT NULL")
        .bind(&name)
        .fetch_one(&mut **tx)
        .await?;
    if exists {
        return Ok(());
    }

    let default = format!("{table}_default");
    let overlap: bool = sqlx::query_scalar(&format!(
        "SELECT EXISTS (SELECT 1 FROM {default} WHERE ts >= $1::timestamptz AND ts < $2::timestamptz)"
    ))
    .bind(&from_ts)
    .bind(&to_ts)
    .fetch_one(&mut **tx)
    .await?;

    if !overlap {
        sqlx::query(&format!(
            "CREATE TABLE {name} PARTITION OF {table} FOR VALUES FROM ('{from_ts}') TO ('{to_ts}')"
        ))
        .execute(&mut **tx)
        .await?;
        return Ok(());
    }

    // Default rows already fall in this month. Build the partition standalone, move the rows,
    // then attach it.
    sqlx::query(&format!("CREATE TABLE {name} (LIKE {table} INCLUDING ALL)"))
        .execute(&mut **tx)
        .await?;
    sqlx::query(&format!(
        "INSERT INTO {name} SELECT * FROM {default} WHERE ts >= $1::timestamptz AND ts < $2::timestamptz"
    ))
    .bind(&from_ts)
    .bind(&to_ts)
    .execute(&mut **tx)
    .await?;
    sqlx::query(&format!(
        "DELETE FROM {default} WHERE ts >= $1::timestamptz AND ts < $2::timestamptz"
    ))
    .bind(&from_ts)
    .bind(&to_ts)
    .execute(&mut **tx)
    .await?;
    sqlx::query(&format!(
        "ALTER TABLE {table} ATTACH PARTITION {name} FOR VALUES FROM ('{from_ts}') TO ('{to_ts}')"
    ))
    .execute(&mut **tx)
    .await?;
    Ok(())
}

pub fn partition_name(table: &str, month: NaiveDate) -> String {
    format!("{table}_y{:04}m{:02}", month.year(), month.month())
}

pub fn month_start(day: NaiveDate) -> NaiveDate {
    NaiveDate::from_ymd_opt(day.year(), day.month(), 1).expect("first of month is valid")
}

pub fn next_month_start(month: NaiveDate) -> NaiveDate {
    let (year, m) = if month.month() == 12 {
        (month.year() + 1, 1)
    } else {
        (month.year(), month.month() + 1)
    };
    NaiveDate::from_ymd_opt(year, m, 1).expect("first of month is valid")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn month_arithmetic_wraps_the_year() {
        let dec = NaiveDate::from_ymd_opt(2026, 12, 1).unwrap();
        assert_eq!(
            next_month_start(dec),
            NaiveDate::from_ymd_opt(2027, 1, 1).unwrap()
        );
        assert_eq!(
            month_start(NaiveDate::from_ymd_opt(2026, 10, 31).unwrap()),
            NaiveDate::from_ymd_opt(2026, 10, 1).unwrap()
        );
        assert_eq!(
            partition_name("hr_samples", NaiveDate::from_ymd_opt(2026, 10, 1).unwrap()),
            "hr_samples_y2026m10"
        );
    }
}
