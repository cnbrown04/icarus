//! Route handlers, grouped as in api-contract.md.

pub mod alarms;
pub mod auth;
pub mod devices;
pub mod dispatches;
pub mod export;
pub mod hooks;
pub mod ingress;
pub mod me;
pub mod metrics;
pub mod sync;
pub mod whoop;

use std::str::FromStr;

use axum::http::HeaderMap;
use sqlx::{Postgres, Transaction};
use uuid::Uuid;

use crate::error::ApiError;

/// Parses a required `If-Match: <version>` header. Missing gives 428, a bad value 400.
pub fn if_match_version(headers: &HeaderMap) -> Result<i64, ApiError> {
    optional_if_match(headers)?.ok_or(ApiError::PreconditionRequired)
}

/// `If-Match` when the client sent one. DELETE treats it as optional.
pub fn optional_if_match(headers: &HeaderMap) -> Result<Option<i64>, ApiError> {
    let Some(raw) = headers.get("if-match") else {
        return Ok(None);
    };
    raw.to_str()
        .ok()
        .map(|v| v.trim().trim_matches('"'))
        .and_then(|v| i64::from_str(v).ok())
        .map(Some)
        .ok_or_else(|| {
            ApiError::Validation("If-Match must be the entity version as an integer.".into())
        })
}

/// Path segments that must be UUIDs. Anything else is simply not found.
pub fn uuid_or_not_found(raw: &str) -> Result<Uuid, ApiError> {
    Uuid::parse_str(raw).map_err(|_| ApiError::NotFound)
}

/// Tells the dispatcher that the user's alarms or hooks changed, so the app re-syncs config
/// (PLAN.md §12.5). The dispatcher sends the push; the write does not depend on it.
pub async fn notify_config_changed(
    tx: &mut Transaction<'_, Postgres>,
    user_id: Uuid,
) -> Result<(), sqlx::Error> {
    sqlx::query("SELECT pg_notify('config_changed', $1)")
        .bind(user_id.to_string())
        .execute(&mut **tx)
        .await
        .map(|_| ())
}

/// Decodes a JSON value stored in a column the server wrote itself. A failure is a server bug.
pub fn stored<T: serde::de::DeserializeOwned>(value: serde_json::Value) -> Result<T, ApiError> {
    serde_json::from_value(value).map_err(|_| ApiError::Internal)
}
