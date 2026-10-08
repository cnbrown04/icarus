//! Request body and client IP extractors. Errors are problem responses, not axum rejections.

use std::net::{IpAddr, Ipv4Addr, SocketAddr};

use axum::{
    body::{Body, Bytes},
    extract::{ConnectInfo, FromRequest, FromRequestParts, Request},
    http::request::Parts,
};
use http_body_util::{BodyExt, LengthLimitError, Limited};
use serde::de::DeserializeOwned;

use crate::{error::ApiError, state::AppState};

/// Limit for small JSON bodies (PLAN.md §12.1 uses 16 KB for hook bodies).
pub const JSON_BODY_LIMIT: usize = 16 * 1024;

/// Reads at most `limit` bytes. Oversize bodies give 413 `payload-too-large`.
pub async fn read_limited(body: Body, limit: usize) -> Result<Bytes, ApiError> {
    match Limited::new(body, limit).collect().await {
        Ok(collected) => Ok(collected.to_bytes()),
        Err(err) if err.is::<LengthLimitError>() => Err(ApiError::PayloadTooLarge(format!(
            "The body is larger than {limit} bytes."
        ))),
        Err(_) => Err(ApiError::Validation(
            "The request body could not be read.".into(),
        )),
    }
}

/// JSON body with a 16 KB limit and problem-shaped errors.
pub struct ApiJson<T>(pub T);

impl<T: DeserializeOwned> FromRequest<AppState> for ApiJson<T> {
    type Rejection = ApiError;

    async fn from_request(req: Request, _state: &AppState) -> Result<Self, ApiError> {
        let bytes = read_limited(req.into_body(), JSON_BODY_LIMIT).await?;
        serde_json::from_slice(&bytes)
            .map(ApiJson)
            .map_err(|err| ApiError::Validation(format!("Invalid JSON: {err}.")))
    }
}

/// Client IP for rate limits. Uses the rightmost `X-Forwarded-For` entry when the proxy is trusted.
pub struct ClientIp(pub IpAddr);

impl FromRequestParts<AppState> for ClientIp {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, ApiError> {
        if state.config.trust_proxy {
            let forwarded = parts
                .headers
                .get("x-forwarded-for")
                .and_then(|v| v.to_str().ok())
                .and_then(|v| v.rsplit(',').next())
                .and_then(|v| v.trim().parse::<IpAddr>().ok());
            if let Some(ip) = forwarded {
                return Ok(ClientIp(ip));
            }
        }
        let ip = parts
            .extensions
            .get::<ConnectInfo<SocketAddr>>()
            .map(|info| info.0.ip())
            .unwrap_or(IpAddr::V4(Ipv4Addr::UNSPECIFIED));
        Ok(ClientIp(ip))
    }
}
