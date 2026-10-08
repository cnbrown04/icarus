//! Pairing, device list, revocation and push tokens (PLAN.md §11.6, §12.5).

use axum::{
    Json,
    extract::{Path, State},
    http::StatusCode,
    response::{IntoResponse, Response},
};
use chrono::{DateTime, Duration, Utc};
use icarus_core::{Band, Device};
use qrcode::{QrCode, render::svg};
use serde::{Deserialize, Serialize};
use sqlx::FromRow;
use uuid::Uuid;

use crate::{
    auth::{Either, WebUser, fill_random, random_token, sha256},
    error::ApiError,
    extract::{ApiJson, ClientIp},
    state::AppState,
};

/// 31 characters: no 0, 1, I, L or O. A code is 8 of them. PLAN.md §11.6.
const PAIRING_ALPHABET: &[u8] = b"ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const PAIRING_LEN: usize = 8;
const PAIRING_TTL_MINUTES: i64 = 10;
const NAME_MAX: usize = 100;

fn new_pairing_code() -> String {
    // Rejection sampling: 248 = 31 * 8, so every accepted byte maps to the alphabet uniformly.
    let mut code = String::with_capacity(PAIRING_LEN);
    let mut buf = [0u8; 32];
    while code.len() < PAIRING_LEN {
        fill_random(&mut buf);
        for byte in buf {
            if usize::from(byte) < 248 && code.len() < PAIRING_LEN {
                code.push(char::from(
                    PAIRING_ALPHABET[usize::from(byte) % PAIRING_ALPHABET.len()],
                ));
            }
        }
    }
    code
}

/// Uppercases and checks the shape. Returns `None` for anything that cannot be a valid code.
fn normalise_code(raw: &str) -> Option<String> {
    let code = raw.trim().to_ascii_uppercase();
    let valid = code.len() == PAIRING_LEN && code.bytes().all(|b| PAIRING_ALPHABET.contains(&b));
    valid.then_some(code)
}

#[derive(Serialize)]
pub struct PairingCodeResponse {
    code: String,
    qr_svg: String,
    #[serde(with = "icarus_core::time::rfc3339")]
    expires_at: DateTime<Utc>,
}

pub async fn create_pairing_code(
    State(state): State<AppState>,
    WebUser(user_id): WebUser,
) -> Result<Json<PairingCodeResponse>, ApiError> {
    let code = new_pairing_code();
    let expires_at = Utc::now() + Duration::minutes(PAIRING_TTL_MINUTES);
    sqlx::query("INSERT INTO pairing_codes (code_hash, user_id, expires_at) VALUES ($1, $2, $3)")
        .bind(sha256(code.as_bytes()))
        .bind(user_id)
        .bind(expires_at)
        .execute(&state.pool)
        .await?;

    let payload = format!(
        "icarus://pair?code={code}&server={}",
        state.config.public_base_url
    );
    let qr = QrCode::new(payload.as_bytes()).map_err(|_| ApiError::Internal)?;
    let qr_svg = qr.render::<svg::Color>().min_dimensions(192, 192).build();
    Ok(Json(PairingCodeResponse {
        code,
        qr_svg,
        expires_at,
    }))
}

#[derive(Deserialize)]
pub struct PairBody {
    code: String,
    name: String,
    model: Option<String>,
    os_version: Option<String>,
    app_version: Option<String>,
}

#[derive(Serialize)]
pub struct PairResponse {
    device_id: Uuid,
    token: String,
}

fn check_text(value: &str, what: &str, max: usize, required: bool) -> Result<(), ApiError> {
    if required && value.trim().is_empty() {
        return Err(ApiError::Validation(format!("{what} is required.")));
    }
    if value.chars().count() > max {
        return Err(ApiError::Validation(format!(
            "{what} must be at most {max} characters."
        )));
    }
    Ok(())
}

/// Exchanges a single-use pairing code for a device token. The token is returned once.
pub async fn pair(
    State(state): State<AppState>,
    ClientIp(ip): ClientIp,
    ApiJson(body): ApiJson<PairBody>,
) -> Result<Response, ApiError> {
    if !state.pairing_limiter.allow(ip) {
        return Err(ApiError::RateLimited);
    }
    check_text(&body.name, "name", NAME_MAX, true)?;
    for (value, what) in [
        (&body.model, "model"),
        (&body.os_version, "os_version"),
        (&body.app_version, "app_version"),
    ] {
        if let Some(value) = value {
            check_text(value, what, NAME_MAX, false)?;
        }
    }
    let code = normalise_code(&body.code).ok_or(ApiError::PairingCodeInvalid)?;

    let mut tx = state.pool.begin().await?;
    // The conditional update makes the code single use, even with two requests in flight.
    let user: Option<(Uuid,)> = sqlx::query_as(
        "UPDATE pairing_codes SET used_at = now()
         WHERE code_hash = $1 AND used_at IS NULL AND expires_at > now()
         RETURNING user_id",
    )
    .bind(sha256(code.as_bytes()))
    .fetch_optional(&mut *tx)
    .await?;
    let (user_id,) = user.ok_or(ApiError::PairingCodeInvalid)?;

    let device_id = Uuid::now_v7();
    let token = random_token();
    sqlx::query(
        "INSERT INTO devices (id, user_id, name, model, os_version, app_version, token_hash)
         VALUES ($1, $2, $3, $4, $5, $6, $7)",
    )
    .bind(device_id)
    .bind(user_id)
    .bind(body.name.trim())
    .bind(body.model)
    .bind(body.os_version)
    .bind(body.app_version)
    .bind(sha256(token.as_bytes()))
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;

    Ok((StatusCode::CREATED, Json(PairResponse { device_id, token })).into_response())
}

#[derive(FromRow)]
struct DeviceRow {
    id: Uuid,
    name: String,
    model: Option<String>,
    os_version: Option<String>,
    app_version: Option<String>,
    created_at: DateTime<Utc>,
    last_seen_at: Option<DateTime<Utc>>,
    revoked_at: Option<DateTime<Utc>>,
}

#[derive(FromRow)]
struct BandRow {
    id: Uuid,
    name: Option<String>,
    firmware: Option<String>,
    created_at: DateTime<Utc>,
    last_seen_at: Option<DateTime<Utc>>,
}

#[derive(Serialize)]
pub struct DeviceList {
    devices: Vec<Device>,
    bands: Vec<Band>,
}

pub async fn list(
    State(state): State<AppState>,
    Either(principal): Either,
) -> Result<Json<DeviceList>, ApiError> {
    let user_id = principal.user_id();
    let devices: Vec<DeviceRow> = sqlx::query_as(
        "SELECT id, name, model, os_version, app_version, created_at, last_seen_at, revoked_at
         FROM devices WHERE user_id = $1 ORDER BY created_at",
    )
    .bind(user_id)
    .fetch_all(&state.pool)
    .await?;
    let bands: Vec<BandRow> = sqlx::query_as(
        "SELECT id, name, firmware, created_at, last_seen_at FROM bands WHERE user_id = $1 ORDER BY created_at",
    )
    .bind(user_id)
    .fetch_all(&state.pool)
    .await?;

    Ok(Json(DeviceList {
        devices: devices
            .into_iter()
            .map(|d| Device {
                id: d.id,
                name: d.name,
                model: d.model,
                os_version: d.os_version,
                app_version: d.app_version,
                created_at: d.created_at,
                last_seen_at: d.last_seen_at,
                revoked_at: d.revoked_at,
            })
            .collect(),
        bands: bands
            .into_iter()
            .map(|b| Band {
                id: b.id,
                name: b.name,
                firmware: b.firmware,
                created_at: b.created_at,
                last_seen_at: b.last_seen_at,
            })
            .collect(),
    }))
}

/// Revokes a device. Its token gets 401 from the next request on.
pub async fn revoke(
    State(state): State<AppState>,
    WebUser(user_id): WebUser,
    Path(raw_id): Path<String>,
) -> Result<StatusCode, ApiError> {
    let device_id = Uuid::parse_str(&raw_id).map_err(|_| ApiError::NotFound)?;
    let mut tx = state.pool.begin().await?;
    let found: Option<(Uuid,)> = sqlx::query_as(
        "UPDATE devices SET revoked_at = COALESCE(revoked_at, now())
         WHERE id = $1 AND user_id = $2
         RETURNING id",
    )
    .bind(device_id)
    .bind(user_id)
    .fetch_optional(&mut *tx)
    .await?;
    found.ok_or(ApiError::NotFound)?;
    sqlx::query("DELETE FROM push_tokens WHERE device_id = $1")
        .bind(device_id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
pub struct PushTokenBody {
    apns_token: String,
    environment: String,
}

pub async fn put_push_token(
    State(state): State<AppState>,
    crate::auth::AppDevice { device_id, .. }: crate::auth::AppDevice,
    ApiJson(body): ApiJson<PushTokenBody>,
) -> Result<StatusCode, ApiError> {
    let token = body.apns_token.trim();
    let hex_ok = (32..=200).contains(&token.len()) && token.bytes().all(|b| b.is_ascii_hexdigit());
    if !hex_ok {
        return Err(ApiError::Validation(
            "apns_token must be hex, 32 to 200 characters.".into(),
        ));
    }
    if !matches!(body.environment.as_str(), "sandbox" | "production") {
        return Err(ApiError::Validation(
            "environment must be sandbox or production.".into(),
        ));
    }
    sqlx::query(
        "INSERT INTO push_tokens (device_id, apns_token, environment, updated_at)
         VALUES ($1, $2, $3, now())
         ON CONFLICT (device_id) DO UPDATE SET
           apns_token = EXCLUDED.apns_token, environment = EXCLUDED.environment, updated_at = now()",
    )
    .bind(device_id)
    .bind(token)
    .bind(&body.environment)
    .execute(&state.pool)
    .await?;
    Ok(StatusCode::NO_CONTENT)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pairing_codes_use_the_alphabet_and_length() {
        for _ in 0..200 {
            let code = new_pairing_code();
            assert_eq!(code.len(), PAIRING_LEN);
            assert!(
                code.bytes().all(|b| PAIRING_ALPHABET.contains(&b)),
                "{code}"
            );
        }
    }

    #[test]
    fn normalise_accepts_lowercase_and_rejects_confusable_characters() {
        assert_eq!(normalise_code(" k7q2m9xd "), Some("K7Q2M9XD".into()));
        assert_eq!(
            normalise_code("K7Q2M9X0"),
            None,
            "zero is not in the alphabet"
        );
        assert_eq!(normalise_code("K7Q2M9X"), None, "too short");
    }
}
