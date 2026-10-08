//! The 6-hourly WHOOP job (PLAN.md §12.6): refresh every connection under the lock, mark webhook
//! events processed, and prune old state. No WHOOP data is fetched or stored here.

use std::time::Duration;

use uuid::Uuid;

use super::tokens::lock_and_refresh;
use crate::{error::ApiError, state::AppState};

const PERIOD: Duration = Duration::from_secs(6 * 60 * 60);

pub fn spawn_reconcile(state: AppState) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(PERIOD);
        // The first tick fires at once. The job waits one full period after startup.
        tick.tick().await;
        loop {
            tick.tick().await;
            if let Err(err) = reconcile_once(&state).await {
                tracing::error!(error = ?err, "WHOOP reconcile failed");
            }
        }
    })
}

/// One pass. A connection that fails is logged and skipped, so one account cannot block the others.
pub async fn reconcile_once(state: &AppState) -> Result<(), ApiError> {
    if state.whoop.is_none() {
        return Ok(());
    }
    let users: Vec<(Uuid,)> = sqlx::query_as("SELECT user_id FROM whoop_connections")
        .fetch_all(&state.pool)
        .await?;
    for (user_id,) in users {
        let mut tx = state.pool.begin().await?;
        match lock_and_refresh(&mut tx, state, user_id, true).await {
            Ok(_) => tx.commit().await?,
            Err(err) => tracing::warn!(error = ?err, "WHOOP refresh failed in reconcile"),
        }
    }
    sqlx::query("UPDATE whoop_webhook_events SET processed_at = now() WHERE processed_at IS NULL")
        .execute(&state.pool)
        .await?;
    sqlx::query("DELETE FROM oauth_states WHERE created_at < now() - interval '10 minutes'")
        .execute(&state.pool)
        .await?;
    // Trace ids stay well past WHOOP's retry window (about an hour), then go.
    sqlx::query("DELETE FROM whoop_webhook_events WHERE processed_at < now() - interval '7 days'")
        .execute(&state.pool)
        .await?;
    Ok(())
}
