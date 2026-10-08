//! Background jobs: time-series partitions and daily rollups (PLAN.md §10.3, §10.4, §11.3).

pub mod partitions;
pub mod rollup;

use std::time::Duration;

use chrono::Utc;
use sqlx::PgPool;

/// Partitions for this month and next, the day rollups for the last three local days, and removal
/// of expired sessions and pairing codes. Safe to run repeatedly.
pub async fn run_maintenance(pool: &PgPool) -> Result<(), sqlx::Error> {
    let now = Utc::now();
    partitions::ensure_current_and_next(pool, now).await?;
    rollup::recompute_recent_for_all_users(pool, now).await?;
    prune_expired(pool).await?;
    Ok(())
}

/// Deletes sessions past their expiry, and pairing codes that expired more than an hour ago.
/// Returns the number of rows removed.
pub async fn prune_expired(pool: &PgPool) -> Result<u64, sqlx::Error> {
    let sessions = sqlx::query("DELETE FROM sessions WHERE expires_at < now()")
        .execute(pool)
        .await?
        .rows_affected();
    let codes =
        sqlx::query("DELETE FROM pairing_codes WHERE expires_at < now() - interval '1 hour'")
            .execute(pool)
            .await?
            .rows_affected();
    Ok(sessions + codes)
}

/// Runs `run_maintenance` every 24 h. Partitions are also created at startup.
pub fn spawn_daily(pool: PgPool) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(24 * 60 * 60)).await;
            if let Err(err) = run_maintenance(&pool).await {
                tracing::error!(error = %err, "daily maintenance failed");
            }
        }
    })
}
