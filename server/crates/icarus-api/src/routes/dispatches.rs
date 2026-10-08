//! Alarm dispatches: queueing, the app's pull list, listing and acks (api-contract.md "Alarms").

use axum::{
    Json,
    extract::{Path, Query, State},
    http::StatusCode,
};
use chrono::{DateTime, Utc};
use icarus_core::{Dispatch, Rhythm};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sqlx::{FromRow, Postgres, Transaction};
use uuid::Uuid;

use crate::{
    auth::{AppDevice, Either},
    error::ApiError,
    extract::ApiJson,
    routes::{stored, uuid_or_not_found},
    state::AppState,
};

const DEFAULT_LIMIT: i64 = 50;
const MAX_LIMIT: i64 = 200;
const PENDING_WINDOW: &str = "10 minutes";
const DETAIL_MAX_CHARS: usize = 1000;

#[derive(FromRow)]
pub(crate) struct DispatchRow {
    id: Uuid,
    alarm_id: Option<Uuid>,
    pub(crate) delivery_id: Option<Uuid>,
    created_at: DateTime<Utc>,
    attempts: i16,
    phone_status: Option<String>,
    band_status: Option<String>,
    acked_at: Option<DateTime<Utc>>,
    status: String,
    message: Option<String>,
    rhythm: Value,
}

/// Select list for `DispatchRow`. The query must alias `alarm_dispatches` as `d`.
pub(crate) const DISPATCH_COLUMNS: &str =
    "d.id, d.alarm_id, d.delivery_id, d.created_at, d.attempts,
    d.phone_status, d.band_status, d.acked_at, d.status, d.message, d.rhythm";

pub(crate) fn dispatch_from_row(row: DispatchRow) -> Result<Dispatch, ApiError> {
    Ok(Dispatch {
        id: row.id,
        alarm_id: row.alarm_id,
        delivery_id: row.delivery_id,
        created_at: row.created_at,
        attempts: row.attempts,
        phone_status: row.phone_status,
        band_status: row.band_status,
        acked_at: row.acked_at,
        status: stored(Value::String(row.status))?,
        message: row.message,
        rhythm: stored::<Rhythm>(row.rhythm)?,
    })
}

/// Queues a dispatch and wakes the dispatcher with NOTIFY. The notify fires on commit, so the
/// dispatcher never sees a row that is not there yet.
pub(crate) async fn enqueue(
    tx: &mut Transaction<'_, Postgres>,
    id: Uuid,
    alarm_id: Uuid,
    delivery_id: Option<Uuid>,
    message: Option<&str>,
    rhythm: &Value,
    channels: &[String],
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO alarm_dispatches (id, alarm_id, delivery_id, status, message, rhythm, channels)
         VALUES ($1, $2, $3, 'pending', $4, $5, $6)",
    )
    .bind(id)
    .bind(alarm_id)
    .bind(delivery_id)
    .bind(message)
    .bind(rhythm)
    .bind(channels)
    .execute(&mut **tx)
    .await?;
    sqlx::query("SELECT pg_notify('alarm_dispatch', $1)")
        .bind(id.to_string())
        .execute(&mut **tx)
        .await?;
    Ok(())
}

/// Unacked dispatches from the last 10 minutes, for the app's pull (PLAN.md §9.3).
#[utoipa::path(
    get,
    path = "/v1/alarms/pending",
    operation_id = "pending_alarm_dispatches",
    tag = "Alarms",
    security(("device" = [])),
    responses(
        (status = 200, description = "Unacked dispatches from the last 10 minutes.", body = DispatchList),
        (status = "default", description = "An error as application/problem+json (api-contract.md Errors).", body = crate::openapi::Problem, content_type = "application/problem+json")
    )
)]
pub async fn pending(
    State(state): State<AppState>,
    AppDevice { user_id, .. }: AppDevice,
) -> Result<Json<DispatchList>, ApiError> {
    let rows: Vec<DispatchRow> = sqlx::query_as(&format!(
        "SELECT {DISPATCH_COLUMNS}
         FROM alarm_dispatches d JOIN alarms a ON a.id = d.alarm_id
         WHERE a.user_id = $1 AND d.acked_at IS NULL
           AND d.status IN ('pending', 'sent', 'unacked')
           AND d.created_at > now() - interval '{PENDING_WINDOW}'
         ORDER BY d.created_at"
    ))
    .bind(user_id)
    .fetch_all(&state.pool)
    .await?;
    let dispatches = rows
        .into_iter()
        .map(dispatch_from_row)
        .collect::<Result<Vec<_>, _>>()?;
    Ok(Json(DispatchList { dispatches }))
}

#[derive(Serialize, utoipa::ToSchema)]
pub struct DispatchList {
    pub dispatches: Vec<Dispatch>,
}

/// Returned by the test route and by webhook ingress.
#[derive(Serialize, utoipa::ToSchema)]
pub struct DispatchIdResponse {
    pub dispatch_id: Uuid,
}

#[derive(Deserialize)]
pub struct ListQuery {
    limit: Option<i64>,
}

#[utoipa::path(
    get,
    path = "/v1/alarm-dispatches",
    operation_id = "list_alarm_dispatches",
    tag = "Alarms",
    security(("session" = []), ("device" = [])),
    params(
        ("limit" = Option<i64>, Query, description = "1 to 200. Default 50."),
    ),
    responses(
        (status = 200, description = "Newest first.", body = DispatchList),
        (status = "default", description = "An error as application/problem+json (api-contract.md Errors).", body = crate::openapi::Problem, content_type = "application/problem+json")
    )
)]
pub async fn list(
    State(state): State<AppState>,
    Either(principal): Either,
    Query(query): Query<ListQuery>,
) -> Result<Json<DispatchList>, ApiError> {
    let limit = query.limit.unwrap_or(DEFAULT_LIMIT);
    if !(1..=MAX_LIMIT).contains(&limit) {
        return Err(ApiError::Validation(format!(
            "limit must be between 1 and {MAX_LIMIT}."
        )));
    }
    let rows: Vec<DispatchRow> = sqlx::query_as(&format!(
        "SELECT {DISPATCH_COLUMNS}
         FROM alarm_dispatches d JOIN alarms a ON a.id = d.alarm_id
         WHERE a.user_id = $1
         ORDER BY d.created_at DESC, d.id DESC
         LIMIT $2"
    ))
    .bind(principal.user_id())
    .bind(limit)
    .fetch_all(&state.pool)
    .await?;
    let dispatches = rows
        .into_iter()
        .map(dispatch_from_row)
        .collect::<Result<Vec<_>, _>>()?;
    Ok(Json(DispatchList { dispatches }))
}

#[derive(Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub struct AckBody {
    phone: String,
    band: String,
    detail: Option<String>,
}

/// The app reports what the phone and band did. The first ack sets `acked_at`; later acks replace
/// the statuses.
#[utoipa::path(
    post,
    path = "/v1/alarm-dispatches/{id}/ack",
    operation_id = "ack_alarm_dispatch",
    tag = "Alarms",
    security(("device" = [])),
    params(
        ("id" = Uuid, Path, description = "Id of the resource."),
    ),
    request_body = AckBody,
    responses(
        (status = 204, description = "Recorded. The first ack sets acked_at."),
        (status = "default", description = "An error as application/problem+json (api-contract.md Errors).", body = crate::openapi::Problem, content_type = "application/problem+json")
    )
)]
pub async fn ack(
    State(state): State<AppState>,
    AppDevice { user_id, .. }: AppDevice,
    Path(raw_id): Path<String>,
    ApiJson(body): ApiJson<AckBody>,
) -> Result<StatusCode, ApiError> {
    let id = uuid_or_not_found(&raw_id)?;
    if !matches!(body.phone.as_str(), "shown" | "failed") {
        return Err(ApiError::Validation(
            "phone must be shown or failed.".into(),
        ));
    }
    if !matches!(
        body.band.as_str(),
        "ok" | "not_connected" | "disabled" | "failed"
    ) {
        return Err(ApiError::Validation(
            "band must be ok, not_connected, disabled or failed.".into(),
        ));
    }
    if body
        .detail
        .as_ref()
        .is_some_and(|d| d.chars().count() > DETAIL_MAX_CHARS)
    {
        return Err(ApiError::Validation(format!(
            "detail must be at most {DETAIL_MAX_CHARS} characters."
        )));
    }

    let updated: Option<(Uuid,)> = sqlx::query_as(
        "UPDATE alarm_dispatches d
         SET acked_at = COALESCE(d.acked_at, now()), phone_status = $3, band_status = $4,
             ack_detail = $5, status = 'acked'
         FROM alarms a
         WHERE d.id = $1 AND a.id = d.alarm_id AND a.user_id = $2
         RETURNING d.id",
    )
    .bind(id)
    .bind(user_id)
    .bind(&body.phone)
    .bind(&body.band)
    .bind(&body.detail)
    .fetch_optional(&state.pool)
    .await?;
    updated.ok_or(ApiError::NotFound)?;
    Ok(StatusCode::NO_CONTENT)
}
