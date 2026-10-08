//! RFC 9457 problem responses with the contract's slugs (api-contract.md "Conventions").

use axum::{
    Json,
    http::{HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
};
use icarus_db::ReadyError;
use serde::Serialize;
use serde_json::Value;

#[derive(Debug)]
pub enum ApiError {
    Unauthorized(String),
    Forbidden(String),
    NotFound,
    Validation(String),
    /// PATCH without `If-Match`. Uses the `validation` slug with status 428.
    PreconditionRequired,
    /// `current` is the stored entity, so the client can merge and retry.
    Conflict {
        detail: String,
        current: Value,
    },
    PayloadTooLarge(String),
    RateLimited,
    PairingCodeInvalid,
    /// Webhook signature or secret did not verify (api-contract.md "Errors").
    SignatureInvalid(String),
    /// A feature needs configuration that is not set, such as `ICARUS_ENC_KEY`. Uses the `internal` slug.
    NotConfigured(String),
    MigrationsPending,
    DatabaseUnavailable,
    Internal,
}

#[derive(Serialize)]
struct Problem<'a> {
    #[serde(rename = "type")]
    kind: String,
    title: &'a str,
    status: u16,
    detail: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    current: Option<&'a Value>,
}

impl ApiError {
    fn parts(&self) -> (StatusCode, &'static str, &'static str, &str) {
        match self {
            ApiError::Unauthorized(d) => {
                (StatusCode::UNAUTHORIZED, "unauthorized", "Unauthorized", d)
            }
            ApiError::Forbidden(d) => (StatusCode::FORBIDDEN, "forbidden", "Forbidden", d),
            ApiError::NotFound => (
                StatusCode::NOT_FOUND,
                "not-found",
                "Not found",
                "No such resource.",
            ),
            ApiError::Validation(d) => {
                (StatusCode::BAD_REQUEST, "validation", "Invalid request", d)
            }
            ApiError::PreconditionRequired => (
                StatusCode::PRECONDITION_REQUIRED,
                "validation",
                "Precondition required",
                "Send If-Match with the current version.",
            ),
            ApiError::Conflict { detail, .. } => {
                (StatusCode::CONFLICT, "conflict", "Conflict", detail)
            }
            ApiError::PayloadTooLarge(d) => (
                StatusCode::PAYLOAD_TOO_LARGE,
                "payload-too-large",
                "Payload too large",
                d,
            ),
            ApiError::RateLimited => (
                StatusCode::TOO_MANY_REQUESTS,
                "rate-limited",
                "Too many requests",
                "Try again in a minute.",
            ),
            ApiError::PairingCodeInvalid => (
                StatusCode::BAD_REQUEST,
                "pairing-code-invalid",
                "Pairing code invalid",
                "The code is wrong, expired or already used.",
            ),
            ApiError::SignatureInvalid(d) => (
                StatusCode::UNAUTHORIZED,
                "signature-invalid",
                "Signature invalid",
                d,
            ),
            ApiError::NotConfigured(d) => (
                StatusCode::SERVICE_UNAVAILABLE,
                "internal",
                "Not configured",
                d,
            ),
            ApiError::MigrationsPending => (
                StatusCode::SERVICE_UNAVAILABLE,
                "migrations-pending",
                "Migrations pending",
                "Database migrations have not been applied.",
            ),
            ApiError::DatabaseUnavailable => (
                StatusCode::SERVICE_UNAVAILABLE,
                "database-unavailable",
                "Database unavailable",
                "The database could not be reached.",
            ),
            ApiError::Internal => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "internal",
                "Internal error",
                "Something went wrong on the server.",
            ),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, slug, title, detail) = self.parts();
        let current = match &self {
            ApiError::Conflict { current, .. } => Some(current),
            _ => None,
        };
        let problem = Problem {
            kind: format!("urn:icarus:problem:{slug}"),
            title,
            status: status.as_u16(),
            detail,
            current,
        };
        let mut response = (status, Json(problem)).into_response();
        response.headers_mut().insert(
            header::CONTENT_TYPE,
            HeaderValue::from_static("application/problem+json"),
        );
        response
    }
}

impl From<sqlx::Error> for ApiError {
    fn from(err: sqlx::Error) -> Self {
        match &err {
            sqlx::Error::PoolTimedOut | sqlx::Error::PoolClosed | sqlx::Error::Io(_) => {
                tracing::warn!("database unreachable");
                ApiError::DatabaseUnavailable
            }
            // Log the SQLSTATE only. Driver messages can echo row values.
            sqlx::Error::Database(db) => {
                tracing::error!(code = ?db.code(), "database error");
                ApiError::Internal
            }
            _ => {
                tracing::error!("database error");
                ApiError::Internal
            }
        }
    }
}

impl From<ReadyError> for ApiError {
    fn from(err: ReadyError) -> Self {
        match err {
            ReadyError::Query(e) => e.into(),
            ReadyError::MigrationsPending(_) => ApiError::MigrationsPending,
        }
    }
}
