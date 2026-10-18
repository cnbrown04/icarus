//! Public webhook ingress (api-contract.md "Webhook ingress", PLAN.md §12.4).
//!
//! Order: look up the endpoint, read the body (16 KB), verify the signature or secret, apply the
//! per-endpoint rate limit, parse the body, then insert the delivery and dispatch in one
//! transaction. Rejected requests leave a delivery row with no body, so the web page can show them.

use std::{future::Future, net::IpAddr, time::Duration};

use axum::{
    Json,
    body::Body,
    extract::{Path, State},
    http::{HeaderMap, StatusCode, header::USER_AGENT},
    response::{IntoResponse, Response},
};
use chrono::{DateTime, Utc};
use hmac::{Hmac, Mac};
use icarus_core::{Channel, Rhythm};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::{FromRow, PgPool};
use subtle::ConstantTimeEq;
use uuid::Uuid;

use crate::{
    error::ApiError,
    extract::{ClientIp, read_limited},
    routes::{
        dispatches::{DispatchIdResponse, enqueue},
        hooks::open_secret,
    },
    state::AppState,
};

/// PLAN.md §12.1: 16 KB for hook bodies.
pub const BODY_LIMIT: usize = 16 * 1024;
/// PLAN.md §12.1: 2 s for webhook ingress.
const REQUEST_DEADLINE: Duration = Duration::from_secs(2);
const SIGNATURE_HEADER: &str = "x-icarus-signature";
const SIGNATURE_WINDOW_SECS: i64 = 300;
/// PLAN.md §18: pre-auth budget per client IP, across all endpoints.
const INGRESS_PER_IP_PER_MIN: u32 = 60;
const KEY_MAX_CHARS: usize = 200;
const MESSAGE_MAX_CHARS: usize = 120;
const USER_AGENT_MAX_CHARS: usize = 128;

#[derive(FromRow)]
struct Endpoint {
    id: Uuid,
    alarm_id: Uuid,
    auth_mode: String,
    secret_ciphertext: Vec<u8>,
    rate_limit_per_min: i16,
    alarm_rhythm: Value,
    alarm_channels: Vec<String>,
}

#[derive(Deserialize, Default, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
struct IngressBody {
    idempotency_key: Option<String>,
    rhythm: Option<Rhythm>,
    message: Option<String>,
    channels: Option<Vec<Channel>>,
}

/// A repeated idempotency key: the original dispatch, with `duplicate` set.
#[derive(Serialize, utoipa::ToSchema)]
pub struct DuplicateDispatch {
    pub duplicate: bool,
    pub dispatch_id: Uuid,
}

#[derive(Clone, Copy)]
enum Auth<'a> {
    Signature,
    Secret(&'a str),
}

/// `POST /v1/hooks/{key}`: HMAC-signed, for endpoints in `hmac` mode.
#[utoipa::path(
    post,
    path = "/v1/hooks/{id}",
    operation_id = "post_hook_ingress",
    tag = "Webhook ingress",
    params(
        ("id" = String, Path, description = "Hook id for management routes. For ingress, the endpoint slug."),
        ("X-Icarus-Signature" = String, Header, description = "t=<unix>,v1=<hex HMAC-SHA256(secret, t + \".\" + body)>. Timestamp within 300 s."),
    ),
    request_body = IngressBody,
    responses(
        (status = 202, description = "Queued.", body = DispatchIdResponse),
        (status = 200, description = "Repeated idempotency_key. The original dispatch.", body = DuplicateDispatch),
        (status = 429, description = "Over the per-IP budget (60 per minute) or the endpoint budget. No delivery row is written for the per-IP case."),
        (status = 408, description = "Did not finish within 2 s. Empty body."),
        (status = "default", description = "An error as application/problem+json (api-contract.md Errors).", body = crate::openapi::Problem, content_type = "application/problem+json")
    )
)]
pub async fn post_signed(
    State(state): State<AppState>,
    ClientIp(ip): ClientIp,
    Path(slug): Path<String>,
    headers: HeaderMap,
    body: Body,
) -> Result<Response, ApiError> {
    within_deadline(receive(&state, ip, &slug, Auth::Signature, &headers, body)).await
}

/// `POST /v1/hooks/{key}/{secret}`: secret-URL mode, for endpoints that opted in.
#[utoipa::path(
    post,
    path = "/v1/hooks/{id}/{secret}",
    operation_id = "post_hook_ingress_secret",
    tag = "Webhook ingress",
    params(
        ("id" = String, Path, description = "Endpoint slug."),
        ("secret" = String, Path, description = "The secret from the hook, for secret_url endpoints only."),
    ),
    request_body = IngressBody,
    responses(
        (status = 202, description = "Queued.", body = DispatchIdResponse),
        (status = 200, description = "Repeated idempotency_key. The original dispatch.", body = DuplicateDispatch),
        (status = 429, description = "Over the per-IP budget (60 per minute) or the endpoint budget."),
        (status = "default", description = "An error as application/problem+json (api-contract.md Errors).", body = crate::openapi::Problem, content_type = "application/problem+json")
    )
)]
pub async fn post_secret(
    State(state): State<AppState>,
    ClientIp(ip): ClientIp,
    Path((slug, secret)): Path<(String, String)>,
    headers: HeaderMap,
    body: Body,
) -> Result<Response, ApiError> {
    within_deadline(receive(
        &state,
        ip,
        &slug,
        Auth::Secret(&secret),
        &headers,
        body,
    ))
    .await
}

async fn within_deadline<F>(work: F) -> Result<Response, ApiError>
where
    F: Future<Output = Result<Response, ApiError>>,
{
    match tokio::time::timeout(REQUEST_DEADLINE, work).await {
        Ok(result) => result,
        Err(_) => Ok(StatusCode::REQUEST_TIMEOUT.into_response()),
    }
}

async fn receive(
    state: &AppState,
    ip: IpAddr,
    slug: &str,
    auth: Auth<'_>,
    headers: &HeaderMap,
    body: Body,
) -> Result<Response, ApiError> {
    admit_client(state, ip)?;
    let secrets = state.secrets()?;
    let endpoint = load_endpoint(&state.pool, slug)
        .await?
        .ok_or(ApiError::NotFound)?;
    match (auth, endpoint.auth_mode.as_str()) {
        (Auth::Signature, "hmac") | (Auth::Secret(_), "secret_url") => {}
        (Auth::Secret(_), _) => return Err(ApiError::NotFound),
        (Auth::Signature, _) => {
            return Err(ApiError::SignatureInvalid(
                "This endpoint takes its secret in the URL, not a signature.".into(),
            ));
        }
    }

    let raw = read_limited(body, BODY_LIMIT).await?;
    let secret = open_secret(secrets, endpoint.id, &endpoint.secret_ciphertext)?;
    let now = Utc::now();
    let (timestamp, verified) = match auth {
        Auth::Signature => match verify_signature(headers, &secret, &raw, now) {
            Ok(ts) => (ts, Ok(())),
            Err(reason) => (String::new(), Err(reason)),
        },
        Auth::Secret(given) => (
            String::new(),
            if bool::from(given.as_bytes().ct_eq(secret.as_bytes())) {
                Ok(())
            } else {
                Err("The secret in the URL does not match.")
            },
        ),
    };
    if let Err(reason) = verified {
        record(
            &state.pool,
            endpoint.id,
            "rejected",
            false,
            with_reason(request_meta(headers, raw.len()), reason),
        )
        .await;
        return Err(ApiError::SignatureInvalid(reason.into()));
    }

    if !state
        .hook_buckets
        .take(endpoint.id, rate_budget(endpoint.rate_limit_per_min))
    {
        record(
            &state.pool,
            endpoint.id,
            "rate_limited",
            true,
            request_meta(headers, raw.len()),
        )
        .await;
        return Err(ApiError::RateLimited);
    }

    let body = match parse_body(&raw) {
        Ok(body) => body,
        Err(err) => {
            record(
                &state.pool,
                endpoint.id,
                "rejected",
                true,
                with_reason(request_meta(headers, raw.len()), "The body is not valid."),
            )
            .await;
            return Err(err);
        }
    };

    let key = match body.idempotency_key.clone() {
        Some(key) => key,
        None => match auth {
            Auth::Signature => default_key(slug, &timestamp, &raw),
            // Secret URLs carry no timestamp, so identical bodies are separate events unless the
            // sender supplies a key.
            Auth::Secret(_) => format!("unkeyed:{}", Uuid::now_v7()),
        },
    };
    let rhythm = match &body.rhythm {
        Some(rhythm) => serde_json::to_value(rhythm).map_err(|_| ApiError::Internal)?,
        None => endpoint.alarm_rhythm.clone(),
    };
    let channels = match &body.channels {
        Some(channels) => channel_strings(channels),
        None => endpoint.alarm_channels.clone(),
    };
    let meta = request_meta(headers, raw.len());

    let delivery_id = Uuid::now_v7();
    let mut tx = state.pool.begin().await?;
    let inserted: Option<(Uuid,)> = sqlx::query_as(
        "INSERT INTO webhook_deliveries (id, endpoint_id, idempotency_key, signature_valid, status, request_meta)
         VALUES ($1, $2, $3, true, 'accepted', $4)
         ON CONFLICT (endpoint_id, idempotency_key) DO NOTHING
         RETURNING id",
    )
    .bind(delivery_id)
    .bind(endpoint.id)
    .bind(&key)
    .bind(&meta)
    .fetch_optional(&mut *tx)
    .await?;

    if inserted.is_none() {
        // Same key as an earlier accepted delivery: answer with that dispatch and record the repeat.
        let original: Option<(Uuid,)> = sqlx::query_as(
            "SELECT a.id
             FROM webhook_deliveries w JOIN alarm_dispatches a ON a.delivery_id = w.id
             WHERE w.endpoint_id = $1 AND w.idempotency_key = $2 AND w.status = 'accepted'",
        )
        .bind(endpoint.id)
        .bind(&key)
        .fetch_optional(&mut *tx)
        .await?;
        let (dispatch_id,) = original.ok_or(ApiError::Internal)?;
        sqlx::query(
            "INSERT INTO webhook_deliveries (id, endpoint_id, idempotency_key, signature_valid, status, request_meta)
             VALUES ($1, $2, $3, true, 'duplicate', $4)",
        )
        .bind(Uuid::now_v7())
        .bind(endpoint.id)
        .bind(format!("duplicate:{}", Uuid::now_v7()))
        .bind(&meta)
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        return Ok((
            StatusCode::OK,
            Json(DuplicateDispatch {
                duplicate: true,
                dispatch_id,
            }),
        )
            .into_response());
    }

    let dispatch_id = Uuid::now_v7();
    enqueue(
        &mut tx,
        dispatch_id,
        endpoint.alarm_id,
        Some(delivery_id),
        body.message.as_deref(),
        &rhythm,
        &channels,
    )
    .await?;
    sqlx::query("UPDATE webhook_endpoints SET last_triggered_at = now() WHERE id = $1")
        .bind(endpoint.id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok((
        StatusCode::ACCEPTED,
        Json(DispatchIdResponse { dispatch_id }),
    )
        .into_response())
}

async fn load_endpoint(pool: &PgPool, slug: &str) -> Result<Option<Endpoint>, ApiError> {
    let endpoint = sqlx::query_as(
        "SELECT e.id, e.alarm_id, e.auth_mode, e.secret_ciphertext, e.rate_limit_per_min,
                a.rhythm AS alarm_rhythm, a.channels AS alarm_channels
         FROM webhook_endpoints e JOIN alarms a ON a.id = e.alarm_id
         WHERE e.slug = $1 AND e.enabled AND a.deleted_at IS NULL",
    )
    .bind(slug)
    .fetch_optional(pool)
    .await?;
    Ok(endpoint)
}

/// Runs before any database work or signature check, so floods cost little. A rejected request
/// writes no delivery row. The log line is the only record, and it carries no address or body.
fn admit_client(state: &AppState, ip: IpAddr) -> Result<(), ApiError> {
    if state.ingress_ip_buckets.take(ip, INGRESS_PER_IP_PER_MIN) {
        return Ok(());
    }
    tracing::warn!("webhook ingress rejected a request: per-IP rate limit");
    Err(ApiError::RateLimited)
}

fn rate_budget(per_minute: i16) -> u32 {
    u32::try_from(per_minute.max(1)).unwrap_or(1)
}

/// `t=<unix>,v1=<hex HMAC-SHA256(secret, t "." body)>`. Returns the timestamp as sent. The secret's
/// UTF-8 bytes are the HMAC key. The comparison is constant time (`hmac::Mac::verify_slice`).
fn verify_signature(
    headers: &HeaderMap,
    secret: &str,
    body: &[u8],
    now: DateTime<Utc>,
) -> Result<String, &'static str> {
    let header = headers
        .get(SIGNATURE_HEADER)
        .and_then(|v| v.to_str().ok())
        .ok_or("The X-Icarus-Signature header is missing.")?;
    let mut timestamp = None;
    let mut signature = None;
    for part in header.split(',') {
        let part = part.trim();
        if let Some(value) = part.strip_prefix("t=") {
            timestamp = Some(value);
        } else if let Some(value) = part.strip_prefix("v1=") {
            signature = Some(value);
        }
    }
    let timestamp = timestamp.ok_or("The signature header has no timestamp.")?;
    let signature = signature
        .and_then(from_hex)
        .ok_or("The signature header has no valid v1 value.")?;
    let sent_at: i64 = timestamp
        .parse()
        .map_err(|_| "The timestamp is not a Unix time.")?;
    if (now.timestamp() - sent_at).abs() > SIGNATURE_WINDOW_SECS {
        return Err("The timestamp is outside the 300 s window.");
    }

    let mut mac =
        Hmac::<Sha256>::new_from_slice(secret.as_bytes()).expect("HMAC accepts keys of any length");
    mac.update(timestamp.as_bytes());
    mac.update(b".");
    mac.update(body);
    mac.verify_slice(&signature)
        .map_err(|_| "The signature does not match.")?;
    Ok(timestamp.to_owned())
}

/// Default idempotency key: sha256 over slug, timestamp and body (PLAN.md §12.4).
fn default_key(slug: &str, timestamp: &str, body: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(slug.as_bytes());
    hasher.update(timestamp.as_bytes());
    hasher.update(body);
    to_hex(&hasher.finalize())
}

fn to_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn from_hex(raw: &str) -> Option<Vec<u8>> {
    if !raw.len().is_multiple_of(2) || !raw.is_ascii() {
        return None;
    }
    (0..raw.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&raw[i..i + 2], 16).ok())
        .collect()
}

/// Empty bodies mean `{}`. Anything else must be a JSON object that follows the contract.
fn parse_body(raw: &[u8]) -> Result<IngressBody, ApiError> {
    if raw.iter().all(u8::is_ascii_whitespace) {
        return Ok(IngressBody::default());
    }
    let mut body: IngressBody = serde_json::from_slice(raw)
        .map_err(|e| ApiError::Validation(format!("Invalid JSON: {e}.")))?;

    body.idempotency_key = body
        .idempotency_key
        .map(|k| k.trim().to_owned())
        .filter(|k| !k.is_empty());
    if body
        .idempotency_key
        .as_ref()
        .is_some_and(|k| k.chars().count() > KEY_MAX_CHARS)
    {
        return Err(ApiError::Validation(format!(
            "idempotency_key must be at most {KEY_MAX_CHARS} characters."
        )));
    }
    body.message = body
        .message
        .map(|m| m.trim().to_owned())
        .filter(|m| !m.is_empty());
    if body
        .message
        .as_ref()
        .is_some_and(|m| m.chars().count() > MESSAGE_MAX_CHARS)
    {
        return Err(ApiError::Validation(format!(
            "message must be at most {MESSAGE_MAX_CHARS} characters."
        )));
    }
    if let Some(rhythm) = &body.rhythm {
        rhythm.validate().map_err(|e| ApiError::Validation(e.0))?;
    }
    if let Some(channels) = &body.channels {
        let names = channel_strings(channels);
        if names.is_empty()
            || names
                .iter()
                .enumerate()
                .any(|(i, c)| names[..i].contains(c))
        {
            return Err(ApiError::Validation(
                "channels must name phone, band or both, each once.".into(),
            ));
        }
    }
    Ok(body)
}

fn channel_strings(channels: &[Channel]) -> Vec<String> {
    channels
        .iter()
        .map(|c| match c {
            Channel::Phone => "phone".to_owned(),
            Channel::Band => "band".to_owned(),
        })
        .collect()
}

/// Request metadata for the delivery row. Never the body.
fn request_meta(headers: &HeaderMap, content_length: usize) -> Value {
    let user_agent: Option<String> = headers
        .get(USER_AGENT)
        .and_then(|v| v.to_str().ok())
        .map(|v| v.chars().take(USER_AGENT_MAX_CHARS).collect());
    json!({ "content_length": content_length, "user_agent": user_agent })
}

fn with_reason(mut meta: Value, reason: &str) -> Value {
    meta["reason"] = json!(reason);
    meta
}

/// Writes a delivery row that is not an accepted dispatch. Its key is unique, so it never collides
/// with a real idempotency key. A failed write is logged and does not change the response.
async fn record(
    pool: &PgPool,
    endpoint_id: Uuid,
    status: &str,
    signature_valid: bool,
    meta: Value,
) {
    let result = sqlx::query(
        "INSERT INTO webhook_deliveries (id, endpoint_id, idempotency_key, signature_valid, status, request_meta)
         VALUES ($1, $2, $3, $4, $5, $6)",
    )
    .bind(Uuid::now_v7())
    .bind(endpoint_id)
    .bind(format!("{status}:{}", Uuid::now_v7()))
    .bind(signature_valid)
    .bind(status)
    .bind(meta)
    .execute(pool)
    .await;
    if result.is_err() {
        tracing::error!(status, "could not record a webhook delivery");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_round_trips_and_rejects_bad_input() {
        let bytes = [0x00, 0xab, 0xff];
        assert_eq!(to_hex(&bytes), "00abff");
        assert_eq!(from_hex("00abff"), Some(bytes.to_vec()));
        assert_eq!(from_hex("00ABFF"), Some(bytes.to_vec()));
        assert_eq!(from_hex("0"), None);
        assert_eq!(from_hex("zz"), None);
    }

    #[test]
    fn signature_checks_window_and_mac() {
        let now = DateTime::from_timestamp(1_800_000_000, 0).unwrap();
        let body = br#"{"message":"hi"}"#;
        let sign = |t: i64, secret: &str| {
            let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).unwrap();
            mac.update(format!("{t}.").as_bytes());
            mac.update(body);
            format!("t={t},v1={}", to_hex(&mac.finalize().into_bytes()))
        };
        let headers = |value: String| {
            let mut h = HeaderMap::new();
            h.insert(SIGNATURE_HEADER, value.parse().unwrap());
            h
        };

        let good = headers(sign(now.timestamp(), "s3cret"));
        assert_eq!(
            verify_signature(&good, "s3cret", body, now).unwrap(),
            now.timestamp().to_string()
        );
        assert_eq!(
            verify_signature(&good, "other", body, now),
            Err("The signature does not match.")
        );
        let stale = headers(sign(now.timestamp() - 301, "s3cret"));
        assert_eq!(
            verify_signature(&stale, "s3cret", body, now),
            Err("The timestamp is outside the 300 s window.")
        );
        let edge = headers(sign(now.timestamp() - 300, "s3cret"));
        assert!(verify_signature(&edge, "s3cret", body, now).is_ok());
        assert!(verify_signature(&headers("t=1".into()), "s3cret", body, now).is_err());
        assert!(verify_signature(&HeaderMap::new(), "s3cret", body, now).is_err());
    }
}
