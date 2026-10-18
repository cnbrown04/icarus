//! Credentials: argon2id passwords, hashed session and device tokens, cookies, CSRF and the
//! extractors routes use to require a web session, a device token, or either (PLAN.md §12.2).

use std::sync::OnceLock;

use argon2::{Argon2, PasswordHash, PasswordHasher, PasswordVerifier};
use axum::{
    extract::{FromRequestParts, Request, State},
    http::{
        HeaderMap, HeaderValue, Method,
        header::{AUTHORIZATION, COOKIE, SET_COOKIE},
        request::Parts,
    },
    middleware::Next,
    response::Response,
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::{
    error::ApiError,
    state::{AppState, Config},
};

pub const SESSION_COOKIE: &str = "icarus_session";
pub const CSRF_HEADER: &str = "x-icarus-csrf";
/// Cookie and session lifetime, sliding: each authenticated request extends it.
pub const SESSION_MAX_AGE_SECS: i64 = 30 * 24 * 60 * 60;

/// 32 random bytes, base64url without padding.
pub fn random_token() -> String {
    let mut bytes = [0u8; 32];
    fill_random(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

pub fn fill_random(buf: &mut [u8]) {
    // The OS RNG is unavailable only in broken environments, where no token could be safe.
    getrandom::fill(buf).expect("OS randomness is available");
}

/// Stored form of a token or code. Only the hash is kept.
pub fn sha256(data: &[u8]) -> Vec<u8> {
    Sha256::digest(data).to_vec()
}

/// argon2id with the crate defaults. The salt is random and stored in the PHC string.
pub fn hash_password(password: &str) -> Result<String, argon2::password_hash::Error> {
    Ok(Argon2::default()
        .hash_password(password.as_bytes())?
        .to_string())
}

pub fn verify_password(password: &str, phc: &str) -> bool {
    PasswordHash::new(phc)
        .map(|hash| {
            Argon2::default()
                .verify_password(password.as_bytes(), &hash)
                .is_ok()
        })
        .unwrap_or(false)
}

/// Hash checked when the email is unknown, so a miss takes as long as a wrong password.
pub fn dummy_password_hash() -> &'static str {
    static DUMMY: OnceLock<String> = OnceLock::new();
    DUMMY.get_or_init(|| hash_password(&random_token()).expect("argon2 hashing works"))
}

pub fn session_cookie_value(headers: &HeaderMap) -> Option<&str> {
    headers
        .get_all(COOKIE)
        .iter()
        .filter_map(|raw| raw.to_str().ok())
        .flat_map(|raw| raw.split(';'))
        .filter_map(|pair| pair.trim().strip_prefix("icarus_session="))
        .find(|value| !value.is_empty())
}

pub fn set_cookie_header(token: &str, config: &Config) -> HeaderValue {
    let secure = if config.cookie_secure { "; Secure" } else { "" };
    HeaderValue::from_str(&format!(
        "{SESSION_COOKIE}={token}; HttpOnly; SameSite=Lax; Path=/; Max-Age={SESSION_MAX_AGE_SECS}{secure}"
    ))
    .expect("cookie header is ASCII")
}

pub fn clear_cookie_header(config: &Config) -> HeaderValue {
    let secure = if config.cookie_secure { "; Secure" } else { "" };
    HeaderValue::from_str(&format!(
        "{SESSION_COOKIE}=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0{secure}"
    ))
    .expect("cookie header is ASCII")
}

/// Cookie-authenticated changes must send `X-Icarus-CSRF: 1`. The custom header cannot be sent
/// cross-site without a CORS preflight.
pub fn csrf_header_ok(headers: &HeaderMap) -> bool {
    headers
        .get(CSRF_HEADER)
        .is_some_and(|v| v.as_bytes() == b"1")
}

fn is_safe_method(method: &Method) -> bool {
    matches!(*method, Method::GET | Method::HEAD | Method::OPTIONS)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Principal {
    Web { user_id: Uuid },
    Device { user_id: Uuid, device_id: Uuid },
}

impl Principal {
    pub fn user_id(&self) -> Uuid {
        match *self {
            Principal::Web { user_id } | Principal::Device { user_id, .. } => user_id,
        }
    }
}

/// Bearer token wins over a cookie when both are sent.
async fn authenticate(parts: &Parts, state: &AppState) -> Result<Principal, ApiError> {
    if let Some(auth) = parts.headers.get(AUTHORIZATION) {
        let token = auth
            .to_str()
            .ok()
            .and_then(|v| v.strip_prefix("Bearer "))
            .map(str::trim)
            .filter(|t| !t.is_empty())
            .ok_or_else(|| {
                ApiError::Unauthorized("Send Authorization: Bearer <device token>.".into())
            })?;
        return device_principal(state, token).await;
    }
    if let Some(token) = session_cookie_value(&parts.headers) {
        if !is_safe_method(&parts.method) && !csrf_header_ok(&parts.headers) {
            return Err(ApiError::Forbidden(
                "Send X-Icarus-CSRF: 1 with cookie requests that change data.".into(),
            ));
        }
        return session_principal(state, token).await;
    }
    Err(ApiError::Unauthorized(
        "Sign in or pair this device.".into(),
    ))
}

async fn session_principal(state: &AppState, token: &str) -> Result<Principal, ApiError> {
    // Sliding expiry: every authenticated request pushes the session out 30 days.
    let row: Option<(Uuid,)> = sqlx::query_as(
        "UPDATE sessions SET expires_at = now() + interval '30 days'
         WHERE id = $1 AND expires_at > now()
         RETURNING user_id",
    )
    .bind(sha256(token.as_bytes()))
    .fetch_optional(&state.pool)
    .await?;
    row.map(|(user_id,)| Principal::Web { user_id })
        .ok_or_else(|| ApiError::Unauthorized("The session has expired. Sign in again.".into()))
}

async fn device_principal(state: &AppState, token: &str) -> Result<Principal, ApiError> {
    let row: Option<(Uuid, Uuid)> = sqlx::query_as(
        "UPDATE devices SET last_seen_at = now()
         WHERE token_hash = $1 AND revoked_at IS NULL
         RETURNING id, user_id",
    )
    .bind(sha256(token.as_bytes()))
    .fetch_optional(&state.pool)
    .await?;
    row.map(|(device_id, user_id)| Principal::Device { user_id, device_id })
        .ok_or_else(|| {
            ApiError::Unauthorized(
                "The device token is invalid or revoked. Pair the device again.".into(),
            )
        })
}

/// Web session or device token.
pub struct Either(pub Principal);

impl FromRequestParts<AppState> for Either {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, ApiError> {
        authenticate(parts, state).await.map(Either)
    }
}

/// Cookie session only (PLAN.md §12.2, "web").
pub struct WebUser(pub Uuid);

impl FromRequestParts<AppState> for WebUser {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, ApiError> {
        match authenticate(parts, state).await? {
            Principal::Web { user_id } => Ok(WebUser(user_id)),
            Principal::Device { .. } => Err(ApiError::Forbidden(
                "This route needs a web session.".into(),
            )),
        }
    }
}

/// Device bearer token only (PLAN.md §12.2, "app").
pub struct AppDevice {
    pub user_id: Uuid,
    pub device_id: Uuid,
}

impl FromRequestParts<AppState> for AppDevice {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, ApiError> {
        match authenticate(parts, state).await? {
            Principal::Device { user_id, device_id } => Ok(AppDevice { user_id, device_id }),
            Principal::Web { .. } => Err(ApiError::Forbidden(
                "This route needs a device token.".into(),
            )),
        }
    }
}

/// Keeps the session cookie's `Max-Age` fresh on successful cookie requests, so an active browser
/// stays signed in. Responses that already set a cookie (login, logout) are left alone.
pub async fn refresh_session_cookie(
    State(state): State<AppState>,
    request: Request,
    next: Next,
) -> Response {
    let token = if request.headers().contains_key(AUTHORIZATION) {
        None
    } else {
        session_cookie_value(request.headers()).map(str::to_owned)
    };
    let mut response = next.run(request).await;
    if let Some(token) = token
        .filter(|_| response.status().is_success() && !response.headers().contains_key(SET_COOKIE))
    {
        response
            .headers_mut()
            .append(SET_COOKIE, set_cookie_header(&token, &state.config));
    }
    response
}
