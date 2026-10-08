//! Route handlers, grouped as in api-contract.md.

pub mod auth;
pub mod devices;
pub mod me;
pub mod sync;

use std::str::FromStr;

use axum::http::HeaderMap;

use crate::error::ApiError;

/// Parses a required `If-Match: <version>` header. Missing gives 428, a bad value 400.
pub fn if_match_version(headers: &HeaderMap) -> Result<i64, ApiError> {
    let raw = headers
        .get("if-match")
        .ok_or(ApiError::PreconditionRequired)?;
    raw.to_str()
        .ok()
        .map(|v| v.trim().trim_matches('"'))
        .and_then(|v| i64::from_str(v).ok())
        .ok_or_else(|| {
            ApiError::Validation("If-Match must be the entity version as an integer.".into())
        })
}
