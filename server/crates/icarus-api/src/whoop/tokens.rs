//! WHOOP token storage and refresh (PLAN.md §5.2, §12.6, §18). Tokens are sealed with `ICARUS_ENC_KEY`
//! and bound to the user id and token kind. A refresh runs under `SELECT ... FOR UPDATE`: WHOOP rotates
//! both tokens on refresh, so a second concurrent refresh would spend the first one's refresh token.

use chrono::{DateTime, TimeDelta, Utc};
use sqlx::{Postgres, Transaction};
use uuid::Uuid;

use super::{SCOPES, WhoopError, api::TokenSet};
use crate::{auth::fill_random, error::ApiError, secrets::Secrets, state::AppState};

/// Refresh when the access token has less than this left.
const REFRESH_MARGIN: TimeDelta = TimeDelta::minutes(5);
const STATE_CHARS: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
const EXPIRED: &str = "WHOOP sign-in has expired. Connect WHOOP again.";

/// What a caller gets from the locked section.
pub(crate) enum Access {
    Token(String),
    NotConnected,
    /// WHOOP rejected the refresh token. The connection was removed in the same transaction.
    Revoked,
}

impl Access {
    pub(crate) fn into_token(self) -> Result<String, ApiError> {
        match self {
            Access::Token(token) => Ok(token),
            Access::NotConnected => Err(ApiError::NotFoundDetail("WHOOP is not connected.")),
            Access::Revoked => Err(ApiError::NotFoundDetail(EXPIRED)),
        }
    }
}

#[derive(Clone, Copy)]
enum Kind {
    Access,
    Refresh,
}

impl Kind {
    fn label(self) -> &'static str {
        match self {
            Kind::Access => "access",
            Kind::Refresh => "refresh",
        }
    }
}

fn aad(kind: Kind, user_id: Uuid) -> String {
    format!("whoop-{}:{user_id}", kind.label())
}

fn seal(secrets: &Secrets, user_id: Uuid, kind: Kind, plain: &str) -> Result<Vec<u8>, ApiError> {
    secrets
        .seal(aad(kind, user_id).as_bytes(), plain.as_bytes())
        .map_err(|_| ApiError::Internal)
}

fn open(secrets: &Secrets, user_id: Uuid, kind: Kind, sealed: &[u8]) -> Result<String, ApiError> {
    let plain = secrets
        .open(aad(kind, user_id).as_bytes(), sealed)
        .map_err(|_| {
            tracing::error!("WHOOP token does not open with the configured key");
            ApiError::Internal
        })?;
    String::from_utf8(plain).map_err(|_| ApiError::Internal)
}

fn is_fresh(expires_at: DateTime<Utc>) -> bool {
    expires_at > Utc::now() + REFRESH_MARGIN
}

/// The access token for a call to WHOOP. Refreshes first when the token is close to expiry.
pub async fn access_token(state: &AppState, user_id: Uuid) -> Result<String, ApiError> {
    let secrets = state.secrets()?;
    let cached: Option<(Vec<u8>, DateTime<Utc>)> = sqlx::query_as(
        "SELECT access_token_ct, expires_at FROM whoop_connections WHERE user_id = $1",
    )
    .bind(user_id)
    .fetch_optional(&state.pool)
    .await?;
    if let Some((sealed, expires_at)) = cached
        && is_fresh(expires_at)
    {
        return open(secrets, user_id, Kind::Access, &sealed);
    }
    let mut tx = state.pool.begin().await?;
    let access = lock_and_refresh(&mut tx, state, user_id, false).await?;
    tx.commit().await?;
    access.into_token()
}

/// Locks the connection row and refreshes it unless another caller already did. Runs in the caller's
/// transaction, so the row lock holds until that transaction ends.
pub(crate) async fn lock_and_refresh(
    tx: &mut Transaction<'_, Postgres>,
    state: &AppState,
    user_id: Uuid,
    force: bool,
) -> Result<Access, ApiError> {
    let secrets = state.secrets()?;
    let whoop = state.whoop()?;
    let row: Option<(Vec<u8>, Vec<u8>, DateTime<Utc>)> = sqlx::query_as(
        "SELECT access_token_ct, refresh_token_ct, expires_at
         FROM whoop_connections WHERE user_id = $1 FOR UPDATE",
    )
    .bind(user_id)
    .fetch_optional(&mut **tx)
    .await?;
    let Some((access_ct, refresh_ct, expires_at)) = row else {
        return Ok(Access::NotConnected);
    };
    // Another caller may have refreshed while this one waited for the lock.
    if !force && is_fresh(expires_at) {
        return Ok(Access::Token(open(
            secrets,
            user_id,
            Kind::Access,
            &access_ct,
        )?));
    }

    let refresh = open(secrets, user_id, Kind::Refresh, &refresh_ct)?;
    match whoop.refresh(&refresh).await {
        Ok(set) => {
            let sealed_access = seal(secrets, user_id, Kind::Access, &set.access_token)?;
            let sealed_refresh = seal(secrets, user_id, Kind::Refresh, &set.refresh_token)?;
            let expires_at = Utc::now() + TimeDelta::seconds(set.expires_in.clamp(0, 86_400));
            sqlx::query(
                "UPDATE whoop_connections
                 SET access_token_ct = $2, refresh_token_ct = $3, expires_at = $4
                 WHERE user_id = $1",
            )
            .bind(user_id)
            .bind(sealed_access)
            .bind(sealed_refresh)
            .bind(expires_at)
            .execute(&mut **tx)
            .await?;
            Ok(Access::Token(set.access_token))
        }
        Err(WhoopError::Rejected) => {
            // A spent refresh token cannot recover. Keeping the row would retry on every call.
            sqlx::query("DELETE FROM whoop_webhook_events WHERE whoop_user_id IN (SELECT whoop_user_id FROM whoop_connections WHERE user_id = $1)")
                .bind(user_id)
                .execute(&mut **tx)
                .await?;
            sqlx::query("DELETE FROM whoop_connections WHERE user_id = $1")
                .bind(user_id)
                .execute(&mut **tx)
                .await?;
            tracing::warn!("WHOOP refresh was rejected; the connection was removed");
            Ok(Access::Revoked)
        }
        Err(err) => Err(err.into()),
    }
}

/// Random 8-character OAuth state (PLAN.md §5.2). Rejection sampling keeps the characters uniform.
fn random_state() -> String {
    let mut out = String::with_capacity(8);
    let mut buf = [0u8; 16];
    while out.len() < 8 {
        fill_random(&mut buf);
        for &b in &buf {
            if b < 248 && out.len() < 8 {
                out.push(char::from(STATE_CHARS[usize::from(b) % STATE_CHARS.len()]));
            }
        }
    }
    out
}

/// Stores a new OAuth state for `user_id` and returns it.
pub async fn new_state(pool: &sqlx::PgPool, user_id: Uuid) -> Result<String, ApiError> {
    for _ in 0..5 {
        let state = random_state();
        let inserted = sqlx::query(
            "INSERT INTO oauth_states (state, user_id) VALUES ($1, $2) ON CONFLICT (state) DO NOTHING",
        )
        .bind(&state)
        .bind(user_id)
        .execute(pool)
        .await?
        .rows_affected();
        if inserted == 1 {
            return Ok(state);
        }
    }
    Err(ApiError::Internal)
}

/// Single use: the row is deleted as it is read. Expired states are not found.
pub async fn consume_state(pool: &sqlx::PgPool, state: &str) -> Result<Option<Uuid>, ApiError> {
    let row: Option<(Uuid,)> = sqlx::query_as(
        "DELETE FROM oauth_states
         WHERE state = $1 AND created_at > now() - interval '10 minutes'
         RETURNING user_id",
    )
    .bind(state)
    .fetch_optional(pool)
    .await?;
    Ok(row.map(|(user_id,)| user_id))
}

/// Saves the connection after a successful code exchange. Replaces any earlier connection.
pub async fn store_connection(
    state: &AppState,
    user_id: Uuid,
    whoop_user_id: i64,
    set: &TokenSet,
) -> Result<(), ApiError> {
    let secrets = state.secrets()?;
    let scopes: Vec<String> = match &set.scope {
        Some(granted) => granted.split_whitespace().map(str::to_owned).collect(),
        None => SCOPES.iter().map(|s| (*s).to_owned()).collect(),
    };
    let sealed_access = seal(secrets, user_id, Kind::Access, &set.access_token)?;
    let sealed_refresh = seal(secrets, user_id, Kind::Refresh, &set.refresh_token)?;
    let expires_at = Utc::now() + TimeDelta::seconds(set.expires_in.clamp(0, 86_400));

    let mut tx = state.pool.begin().await?;
    sqlx::query("DELETE FROM whoop_webhook_events WHERE whoop_user_id IN (SELECT whoop_user_id FROM whoop_connections WHERE user_id = $1)")
        .bind(user_id)
        .execute(&mut *tx)
        .await?;
    sqlx::query(
        "INSERT INTO whoop_connections
            (user_id, whoop_user_id, scopes, access_token_ct, refresh_token_ct, expires_at)
         VALUES ($1, $2, $3, $4, $5, $6)
         ON CONFLICT (user_id) DO UPDATE SET
            whoop_user_id = EXCLUDED.whoop_user_id, scopes = EXCLUDED.scopes,
            access_token_ct = EXCLUDED.access_token_ct, refresh_token_ct = EXCLUDED.refresh_token_ct,
            expires_at = EXCLUDED.expires_at, refresh_lock_until = NULL, created_at = now()",
    )
    .bind(user_id)
    .bind(whoop_user_id)
    .bind(scopes)
    .bind(sealed_access)
    .bind(sealed_refresh)
    .bind(expires_at)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(())
}

/// Records a verified webhook for a connected WHOOP user. A repeated trace id is ignored.
pub async fn record_event(
    pool: &sqlx::PgPool,
    event: &super::webhook::Event,
) -> Result<(), ApiError> {
    sqlx::query(
        "INSERT INTO whoop_webhook_events (trace_id, whoop_user_id, type, object_id)
         SELECT $1::text, $2::bigint, $3::text, $4::text
         WHERE EXISTS (SELECT 1 FROM whoop_connections WHERE whoop_user_id = $2::bigint)
         ON CONFLICT (trace_id) DO NOTHING",
    )
    .bind(&event.trace_id)
    .bind(event.whoop_user_id)
    .bind(&event.kind)
    .bind(&event.object_id)
    .execute(pool)
    .await?;
    Ok(())
}

/// Removes the connection: revoke at WHOOP when possible, then delete the tokens and webhook rows.
/// Local deletion happens even when WHOOP does not answer, so the server stops using the tokens.
pub async fn disconnect(state: &AppState, user_id: Uuid) -> Result<(), ApiError> {
    let whoop = state.whoop()?;
    let mut tx = state.pool.begin().await?;
    let access = match lock_and_refresh(&mut tx, state, user_id, false).await {
        Ok(Access::Token(token)) => Some(token),
        Ok(Access::NotConnected | Access::Revoked) => None,
        Err(_) => {
            tracing::warn!("could not refresh WHOOP before revoking; removing local tokens only");
            None
        }
    };
    if let Some(token) = access
        && whoop.revoke(&token).await.is_err()
    {
        tracing::warn!("WHOOP did not confirm the revoke; local tokens are removed");
    }
    sqlx::query("DELETE FROM whoop_webhook_events WHERE whoop_user_id IN (SELECT whoop_user_id FROM whoop_connections WHERE user_id = $1)")
        .bind(user_id)
        .execute(&mut *tx)
        .await?;
    sqlx::query("DELETE FROM whoop_connections WHERE user_id = $1")
        .bind(user_id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(())
}
