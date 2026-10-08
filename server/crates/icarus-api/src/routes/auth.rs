//! `POST /v1/auth/login` and `POST /v1/auth/logout` (PLAN.md §12.2).

use axum::{
    extract::State,
    http::{
        HeaderMap, StatusCode,
        header::{SET_COOKIE, USER_AGENT},
    },
    response::{IntoResponse, Response},
};
use serde::Deserialize;
use uuid::Uuid;

use crate::{
    auth::{
        clear_cookie_header, csrf_header_ok, dummy_password_hash, random_token,
        session_cookie_value, set_cookie_header, sha256, verify_password,
    },
    error::ApiError,
    extract::{ApiJson, ClientIp},
    state::AppState,
};

#[derive(Deserialize)]
pub struct LoginBody {
    email: String,
    password: String,
}

pub async fn login(
    State(state): State<AppState>,
    ClientIp(ip): ClientIp,
    headers: HeaderMap,
    ApiJson(body): ApiJson<LoginBody>,
) -> Result<Response, ApiError> {
    if !state.login_limiter.allow(ip) {
        return Err(ApiError::RateLimited);
    }
    let email = body.email.trim();
    let row: Option<(Uuid, String)> =
        sqlx::query_as("SELECT id, password_hash FROM users WHERE email = $1")
            .bind(email)
            .fetch_optional(&state.pool)
            .await?;
    let user_id = match row {
        Some((id, hash)) if verify_password(&body.password, &hash) => Some(id),
        Some(_) => None,
        None => {
            // Spend the same time as a real check so an unknown email is not detectable.
            verify_password(&body.password, dummy_password_hash());
            None
        }
    };
    let user_id =
        user_id.ok_or_else(|| ApiError::Unauthorized("Wrong email or password.".into()))?;

    let token = random_token();
    let user_agent: Option<String> = headers
        .get(USER_AGENT)
        .and_then(|v| v.to_str().ok())
        .map(|v| v.chars().take(256).collect());
    let ip_text = (!ip.is_unspecified()).then(|| ip.to_string());
    sqlx::query(
        "INSERT INTO sessions (id, user_id, expires_at, user_agent, ip)
         VALUES ($1, $2, now() + interval '30 days', $3, $4::inet)",
    )
    .bind(sha256(token.as_bytes()))
    .bind(user_id)
    .bind(user_agent)
    .bind(ip_text)
    .execute(&state.pool)
    .await?;

    Ok((
        StatusCode::NO_CONTENT,
        [(SET_COOKIE, set_cookie_header(&token, &state.config))],
    )
        .into_response())
}

pub async fn logout(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    if let Some(token) = session_cookie_value(&headers) {
        if !csrf_header_ok(&headers) {
            return Err(ApiError::Forbidden(
                "Send X-Icarus-CSRF: 1 with cookie requests that change data.".into(),
            ));
        }
        sqlx::query("DELETE FROM sessions WHERE id = $1")
            .bind(sha256(token.as_bytes()))
            .execute(&state.pool)
            .await?;
    }
    Ok((
        StatusCode::NO_CONTENT,
        [(SET_COOKIE, clear_cookie_header(&state.config))],
    )
        .into_response())
}
