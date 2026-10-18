//! WHOOP routes (api-contract.md "WHOOP", PLAN.md §5.2, §6.3, §12.3). Every route answers 404
//! `not-found` unless `WHOOP_CLIENT_ID` and `WHOOP_CLIENT_SECRET` are set. The check runs before
//! authentication, so a disabled integration reveals nothing.

use crate::{
    auth::WebUser,
    error::ApiError,
    extract::{ApiQuery, JSON_BODY_LIMIT, read_limited},
    state::AppState,
    whoop::{Summary, WhoopError, tokens, webhook},
};
use axum::{
    Json, Router,
    body::Body,
    extract::{Request, State},
    http::{HeaderMap, StatusCode, header::CACHE_CONTROL, header::LOCATION},
    middleware::{Next, from_fn_with_state},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use chrono::{DateTime, Datelike, NaiveDate, Utc};
use chrono_tz::Tz;
use icarus_core::{
    metrics::local_time::{LocalDay, adding_days, local_time},
    time::format as format_time,
};
use serde::{Deserialize, Serialize};

const SETTINGS_PATH: &str = "/integrations/whoop";
const CALLBACK_PATH: &str = "/v1/integrations/whoop/callback";

pub fn router(state: &AppState) -> Router<AppState> {
    Router::new()
        .route("/v1/integrations/whoop", get(status).delete(disconnect))
        .route("/v1/integrations/whoop/connect", get(connect))
        .route("/v1/integrations/whoop/callback", get(callback))
        .route("/v1/integrations/whoop/webhook", post(webhook))
        .route("/v1/integrations/whoop/summary", get(summary))
        .layer(from_fn_with_state(state.clone(), require_enabled))
}

async fn require_enabled(State(state): State<AppState>, request: Request, next: Next) -> Response {
    if state.whoop.is_none() {
        return ApiError::NotFound.into_response();
    }
    next.run(request).await
}

fn callback_uri(state: &AppState) -> String {
    format!(
        "{}{CALLBACK_PATH}",
        state.config.public_base_url.trim_end_matches('/')
    )
}

fn back_to_settings() -> Response {
    (StatusCode::FOUND, [(LOCATION, SETTINGS_PATH)]).into_response()
}

#[derive(Serialize, utoipa::ToSchema)]
pub struct StatusBody {
    connected: bool,
    scopes: Vec<String>,
    connected_at: Option<String>,
    last_webhook_at: Option<String>,
}

/// `GET /v1/integrations/whoop`. Only our own bookkeeping: no WHOOP values.
#[utoipa::path(
    get,
    path = "/v1/integrations/whoop",
    operation_id = "get_whoop_status",
    tag = "WHOOP",
    security(("session" = [])),
    responses(
        (status = 200, description = "Connection state. No WHOOP values.", body = StatusBody),
        (status = 404, description = "WHOOP is off on this server."),
        (status = "default", description = "An error as application/problem+json (api-contract.md Errors).", body = crate::openapi::Problem, content_type = "application/problem+json")
    )
)]
pub async fn status(
    State(state): State<AppState>,
    WebUser(user_id): WebUser,
) -> Result<Json<StatusBody>, ApiError> {
    let connection: Option<(Vec<String>, DateTime<Utc>, i64)> = sqlx::query_as(
        "SELECT scopes, created_at, whoop_user_id FROM whoop_connections WHERE user_id = $1",
    )
    .bind(user_id)
    .fetch_optional(&state.pool)
    .await?;
    let Some((scopes, connected_at, whoop_user_id)) = connection else {
        return Ok(Json(StatusBody {
            connected: false,
            scopes: Vec::new(),
            connected_at: None,
            last_webhook_at: None,
        }));
    };
    let last_webhook: Option<DateTime<Utc>> = sqlx::query_scalar(
        "SELECT max(received_at) FROM whoop_webhook_events WHERE whoop_user_id = $1",
    )
    .bind(whoop_user_id)
    .fetch_one(&state.pool)
    .await?;
    Ok(Json(StatusBody {
        connected: true,
        scopes,
        connected_at: Some(format_time(&connected_at)),
        last_webhook_at: last_webhook.as_ref().map(format_time),
    }))
}

/// `GET /v1/integrations/whoop/connect`: 302 to WHOOP's authorize page with a fresh 8-character state.
#[utoipa::path(
    get,
    path = "/v1/integrations/whoop/connect",
    operation_id = "connect_whoop",
    tag = "WHOOP",
    security(("session" = [])),
    responses(
        (status = 302, description = "Redirect to WHOOP authorization.", headers(("location" = String, description = "WHOOP authorize URL."))),
        (status = "default", description = "An error as application/problem+json (api-contract.md Errors).", body = crate::openapi::Problem, content_type = "application/problem+json")
    )
)]
pub async fn connect(
    State(state): State<AppState>,
    WebUser(user_id): WebUser,
) -> Result<Response, ApiError> {
    let whoop = state.whoop()?;
    // Without the key the callback could not store tokens, so do not send the user away first.
    state.secrets()?;
    let oauth_state = tokens::new_state(&state.pool, user_id).await?;
    let url = whoop.authorize_url(&callback_uri(&state), &oauth_state);
    Ok((StatusCode::FOUND, [(LOCATION, url.to_string())]).into_response())
}

#[derive(Deserialize)]
pub struct CallbackQuery {
    code: Option<String>,
    state: Option<String>,
    error: Option<String>,
}

/// `GET /v1/integrations/whoop/callback`. The state names the user, so no session cookie is needed.
#[utoipa::path(
    get,
    path = "/v1/integrations/whoop/callback",
    operation_id = "whoop_callback",
    tag = "WHOOP",
    params(
        ("code" = String, Query, description = "WHOOP authorization code."),
        ("state" = String, Query, description = "The 8-character state from connect."),
    ),
    responses(
        (status = 302, description = "Redirect to /integrations/whoop."),
        (status = "default", description = "An error as application/problem+json (api-contract.md Errors).", body = crate::openapi::Problem, content_type = "application/problem+json")
    )
)]
pub async fn callback(
    State(state): State<AppState>,
    ApiQuery(query): ApiQuery<CallbackQuery>,
) -> Result<Response, ApiError> {
    let whoop = state.whoop()?;
    // Checked before the state is spent, so a missing key does not burn the link.
    state.secrets()?;
    let oauth_state = query
        .state
        .filter(|s| !s.is_empty())
        .ok_or_else(|| ApiError::Validation("The sign-in link is missing its state.".into()))?;
    let user_id = tokens::consume_state(&state.pool, &oauth_state)
        .await?
        .ok_or_else(|| {
            ApiError::Validation(
                "The sign-in link has expired or was already used. Connect WHOOP again.".into(),
            )
        })?;
    if query.error.is_some() {
        // The user declined at WHOOP. Nothing to store.
        return Ok(back_to_settings());
    }
    let code = query.code.filter(|c| !c.is_empty()).ok_or_else(|| {
        ApiError::Validation("WHOOP did not send a code. Connect WHOOP again.".into())
    })?;
    let set = whoop
        .exchange_code(&code, &callback_uri(&state))
        .await
        .map_err(|err| match err {
            WhoopError::Rejected => ApiError::Validation(
                "WHOOP did not accept the sign-in. Connect WHOOP again.".into(),
            ),
            other => other.into(),
        })?;
    let whoop_user_id = whoop.fetch_whoop_user_id(&set.access_token).await?;
    tokens::store_connection(&state, user_id, whoop_user_id, &set).await?;
    Ok(back_to_settings())
}

/// `POST /v1/integrations/whoop/webhook`: verify, dedupe by trace id, store the row, answer 204.
#[utoipa::path(
    post,
    path = "/v1/integrations/whoop/webhook",
    operation_id = "whoop_webhook",
    tag = "WHOOP",
    request_body(content = Object, content_type = "application/json", description = "WHOOP event. Verified against the signature header, never stored raw."),
    responses(
        (status = 204, description = "Accepted. Verified with WHOOP's signature header."),
        (status = "default", description = "An error as application/problem+json (api-contract.md Errors).", body = crate::openapi::Problem, content_type = "application/problem+json")
    )
)]
pub async fn webhook(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Body,
) -> Result<StatusCode, ApiError> {
    let whoop = state.whoop()?;
    let raw = read_limited(body, JSON_BODY_LIMIT).await?;
    webhook::verify(&whoop.config().client_secret, &headers, &raw)?;
    if let Some(event) = webhook::parse(&raw)? {
        tokens::record_event(&state.pool, &event).await?;
    }
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
pub struct SummaryQuery {
    day: Option<String>,
}

/// `GET /v1/integrations/whoop/summary?day=`: live fetch, nothing written except refreshed tokens.
#[utoipa::path(
    get,
    path = "/v1/integrations/whoop/summary",
    operation_id = "get_whoop_summary",
    tag = "WHOOP",
    security(("session" = [])),
    params(
        ("day" = Option<String>, Query, description = "YYYY-MM-DD. Defaults to today in the user time zone."),
    ),
    responses(
        (status = 200, description = "Live from WHOOP, not stored. Any value may be null.", body = Summary),
        (status = "default", description = "An error as application/problem+json (api-contract.md Errors).", body = crate::openapi::Problem, content_type = "application/problem+json")
    )
)]
pub async fn summary(
    State(state): State<AppState>,
    WebUser(user_id): WebUser,
    ApiQuery(query): ApiQuery<SummaryQuery>,
) -> Result<Response, ApiError> {
    let whoop = state.whoop()?;
    let tz_name: String = sqlx::query_scalar("SELECT tz FROM users WHERE id = $1")
        .bind(user_id)
        .fetch_one(&state.pool)
        .await?;
    let tz: Tz = tz_name.parse().map_err(|_| ApiError::Internal)?;
    let day = match query.day {
        Some(raw) => parse_day(&raw)?,
        None => Utc::now().with_timezone(&tz).date_naive(),
    };
    let access = tokens::access_token(&state, user_id).await?;
    let fields: Summary = whoop.fetch_day(&access, day_window(day, tz)?).await?;
    Ok(([(CACHE_CONTROL, "no-store")], Json(fields)).into_response())
}

fn parse_day(raw: &str) -> Result<NaiveDate, ApiError> {
    if raw.len() != 10 {
        return Err(ApiError::Validation("day must be YYYY-MM-DD.".into()));
    }
    NaiveDate::parse_from_str(raw, "%Y-%m-%d")
        .map_err(|_| ApiError::Validation("day must be YYYY-MM-DD.".into()))
}

/// The user's local day as a UTC window: midnight to midnight in `tz`.
fn day_window(day: NaiveDate, tz: Tz) -> Result<std::ops::Range<DateTime<Utc>>, ApiError> {
    let local = LocalDay {
        year: day.year(),
        month: day.month(),
        day: day.day(),
    };
    let to_utc = |ms: i64| DateTime::<Utc>::from_timestamp_millis(ms).ok_or(ApiError::Internal);
    Ok(to_utc(local_time(local, 0, tz))?..to_utc(local_time(adding_days(1, local), 0, tz))?)
}

/// `DELETE /v1/integrations/whoop`: revoke at WHOOP, then delete tokens and webhook rows. 204.
#[utoipa::path(
    delete,
    path = "/v1/integrations/whoop",
    operation_id = "disconnect_whoop",
    tag = "WHOOP",
    security(("session" = [])),
    responses(
        (status = 204, description = "Revoked at WHOOP and tokens deleted."),
        (status = "default", description = "An error as application/problem+json (api-contract.md Errors).", body = crate::openapi::Problem, content_type = "application/problem+json")
    )
)]
pub async fn disconnect(
    State(state): State<AppState>,
    WebUser(user_id): WebUser,
) -> Result<StatusCode, ApiError> {
    state.whoop()?;
    tokens::disconnect(&state, user_id).await?;
    Ok(StatusCode::NO_CONTENT)
}
