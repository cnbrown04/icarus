//! Alarm CRUD, soft delete and the test push (api-contract.md "Alarms", PLAN.md §9).

use axum::{
    Json,
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
};
use chrono::{DateTime, Utc};
use icarus_core::{
    Alarm, AlarmKind, Channel, Rhythm, Schedule, ValidationError, alarm::validate_alarm,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sqlx::{FromRow, PgPool};
use uuid::Uuid;

use crate::{
    auth::Either,
    error::ApiError,
    extract::ApiJson,
    routes::{
        dispatches::{DispatchIdResponse, enqueue},
        if_match_version,
        me::double_option,
        notify_config_changed, optional_if_match, stored, uuid_or_not_found,
    },
    state::AppState,
};

const LABEL_MAX_CHARS: usize = 100;

#[derive(FromRow)]
pub(crate) struct AlarmRow {
    id: Uuid,
    kind: String,
    label: String,
    schedule: Option<Value>,
    rhythm: Value,
    channels: Vec<String>,
    enabled: bool,
    version: i64,
    updated_at: DateTime<Utc>,
    deleted_at: Option<DateTime<Utc>>,
}

pub(crate) const ALARM_COLUMNS: &str =
    "id, kind, label, schedule, rhythm, channels, enabled, version, updated_at, deleted_at";

pub(crate) fn alarm_from_row(row: AlarmRow) -> Result<Alarm, ApiError> {
    let channels = row
        .channels
        .into_iter()
        .map(|c| stored::<Channel>(Value::String(c)))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(Alarm {
        id: row.id,
        kind: stored::<AlarmKind>(Value::String(row.kind))?,
        label: row.label,
        schedule: row
            .schedule
            .filter(|v| !v.is_null())
            .map(stored::<Schedule>)
            .transpose()?,
        rhythm: stored::<Rhythm>(row.rhythm)?,
        channels,
        enabled: row.enabled,
        version: row.version,
        updated_at: row.updated_at,
        deleted_at: row.deleted_at,
    })
}

fn kind_str(kind: AlarmKind) -> &'static str {
    match kind {
        AlarmKind::Scheduled => "scheduled",
        AlarmKind::Webhook => "webhook",
        AlarmKind::Relay => "relay",
    }
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

fn invalid(err: ValidationError) -> ApiError {
    ApiError::Validation(err.0)
}

fn clean_label(raw: &str) -> Result<String, ApiError> {
    let label = raw.trim();
    if label.is_empty() || label.chars().count() > LABEL_MAX_CHARS {
        return Err(ApiError::Validation(
            "label must be 1 to 100 characters.".into(),
        ));
    }
    Ok(label.to_owned())
}

fn to_json<T: serde::Serialize>(value: &T) -> Result<Value, ApiError> {
    serde_json::to_value(value).map_err(|_| ApiError::Internal)
}

/// Locks one live or deleted alarm of this user, for writes that compare versions.
async fn lock_alarm(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    user_id: Uuid,
    id: Uuid,
) -> Result<Alarm, ApiError> {
    let row: Option<AlarmRow> = sqlx::query_as(&format!(
        "SELECT {ALARM_COLUMNS} FROM alarms WHERE id = $1 AND user_id = $2 FOR UPDATE"
    ))
    .bind(id)
    .bind(user_id)
    .fetch_optional(&mut **tx)
    .await?;
    match row {
        Some(row) if row.deleted_at.is_none() => alarm_from_row(row),
        _ => Err(ApiError::NotFound),
    }
}

#[derive(Serialize, utoipa::ToSchema)]
pub struct AlarmList {
    alarms: Vec<Alarm>,
}

#[utoipa::path(
    get,
    path = "/v1/alarms",
    operation_id = "list_alarms",
    tag = "Alarms",
    security(("session" = []), ("device" = [])),
    responses(
        (status = 200, description = "Alarms that are not deleted.", body = AlarmList),
        (status = "default", description = "An error as application/problem+json (api-contract.md Errors).", body = crate::openapi::Problem, content_type = "application/problem+json")
    )
)]
pub async fn list(
    State(state): State<AppState>,
    Either(principal): Either,
) -> Result<Json<AlarmList>, ApiError> {
    let rows: Vec<AlarmRow> = sqlx::query_as(&format!(
        "SELECT {ALARM_COLUMNS} FROM alarms WHERE user_id = $1 AND deleted_at IS NULL ORDER BY id"
    ))
    .bind(principal.user_id())
    .fetch_all(&state.pool)
    .await?;
    let alarms = rows
        .into_iter()
        .map(alarm_from_row)
        .collect::<Result<Vec<_>, _>>()?;
    Ok(Json(AlarmList { alarms }))
}

#[derive(Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub struct AlarmCreate {
    #[serde(default)]
    id: Option<Uuid>,
    kind: AlarmKind,
    label: String,
    #[serde(default)]
    schedule: Option<Schedule>,
    rhythm: Rhythm,
    channels: Vec<Channel>,
    #[serde(default = "enabled_default")]
    enabled: bool,
}

fn enabled_default() -> bool {
    true
}

#[utoipa::path(
    post,
    path = "/v1/alarms",
    operation_id = "create_alarm",
    tag = "Alarms",
    security(("session" = []), ("device" = [])),
    request_body = AlarmCreate,
    responses(
        (status = 201, description = "The created alarm.", body = Alarm),
        (status = "default", description = "An error as application/problem+json (api-contract.md Errors).", body = crate::openapi::Problem, content_type = "application/problem+json")
    )
)]
pub async fn create(
    State(state): State<AppState>,
    Either(principal): Either,
    ApiJson(body): ApiJson<AlarmCreate>,
) -> Result<Response, ApiError> {
    let user_id = principal.user_id();
    let label = clean_label(&body.label)?;
    validate_alarm(
        body.kind,
        body.schedule.as_ref(),
        &body.rhythm,
        &body.channels,
    )
    .map_err(invalid)?;
    let id = body.id.unwrap_or_else(Uuid::now_v7);
    let schedule = body.schedule.as_ref().map(to_json).transpose()?;
    let rhythm = to_json(&body.rhythm)?;
    let channels = channel_strings(&body.channels);

    let mut tx = state.pool.begin().await?;
    let inserted: Option<AlarmRow> = sqlx::query_as(&format!(
        "INSERT INTO alarms (id, user_id, kind, label, schedule, rhythm, channels, enabled)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
         ON CONFLICT (id) DO NOTHING
         RETURNING {ALARM_COLUMNS}"
    ))
    .bind(id)
    .bind(user_id)
    .bind(kind_str(body.kind))
    .bind(&label)
    .bind(schedule)
    .bind(rhythm)
    .bind(&channels)
    .bind(body.enabled)
    .fetch_optional(&mut *tx)
    .await?;
    let Some(row) = inserted else {
        drop(tx);
        return Err(id_taken(&state.pool, user_id, id).await?);
    };
    let alarm = alarm_from_row(row)?;
    notify_config_changed(&mut tx, user_id).await?;
    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(alarm)).into_response())
}

/// The id is already used. Show the stored alarm only when this user owns it.
async fn id_taken(pool: &PgPool, user_id: Uuid, id: Uuid) -> Result<ApiError, ApiError> {
    let existing: Option<AlarmRow> = sqlx::query_as(&format!(
        "SELECT {ALARM_COLUMNS} FROM alarms WHERE id = $1 AND user_id = $2"
    ))
    .bind(id)
    .bind(user_id)
    .fetch_optional(pool)
    .await?;
    Ok(match existing {
        Some(row) => ApiError::Conflict {
            detail: "An alarm with this id already exists.".into(),
            current: to_json(&alarm_from_row(row)?)?,
        },
        None => ApiError::Validation("This id is already in use.".into()),
    })
}

#[derive(Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub struct AlarmPatch {
    #[serde(default)]
    kind: Option<AlarmKind>,
    #[serde(default)]
    label: Option<String>,
    #[serde(default, deserialize_with = "double_option")]
    schedule: Option<Option<Schedule>>,
    #[serde(default)]
    rhythm: Option<Rhythm>,
    #[serde(default)]
    channels: Option<Vec<Channel>>,
    #[serde(default)]
    enabled: Option<bool>,
}

#[utoipa::path(
    patch,
    path = "/v1/alarms/{id}",
    operation_id = "patch_alarm",
    tag = "Alarms",
    security(("session" = []), ("device" = [])),
    params(
        ("id" = Uuid, Path, description = "Id of the resource."),
        ("If-Match" = i64, Header, description = "Current version. Required; a stale value gets 409."),
    ),
    request_body = AlarmPatch,
    responses(
        (status = 200, description = "The updated alarm.", body = Alarm),
        (status = "default", description = "An error as application/problem+json (api-contract.md Errors).", body = crate::openapi::Problem, content_type = "application/problem+json")
    )
)]
pub async fn patch(
    State(state): State<AppState>,
    Either(principal): Either,
    Path(raw_id): Path<String>,
    headers: HeaderMap,
    ApiJson(patch): ApiJson<AlarmPatch>,
) -> Result<Json<Alarm>, ApiError> {
    let if_match = if_match_version(&headers)?;
    let id = uuid_or_not_found(&raw_id)?;
    let user_id = principal.user_id();

    let mut tx = state.pool.begin().await?;
    let current = lock_alarm(&mut tx, user_id, id).await?;
    if current.version != if_match {
        return Err(ApiError::Conflict {
            detail: "The alarm changed since you loaded it. Reload and try again.".into(),
            current: to_json(&current)?,
        });
    }

    let mut next = current;
    if let Some(kind) = patch.kind {
        next.kind = kind;
    }
    if let Some(label) = patch.label {
        next.label = clean_label(&label)?;
    }
    if let Some(schedule) = patch.schedule {
        next.schedule = schedule;
    }
    if let Some(rhythm) = patch.rhythm {
        next.rhythm = rhythm;
    }
    if let Some(channels) = patch.channels {
        next.channels = channels;
    }
    if let Some(enabled) = patch.enabled {
        next.enabled = enabled;
    }
    validate_alarm(
        next.kind,
        next.schedule.as_ref(),
        &next.rhythm,
        &next.channels,
    )
    .map_err(invalid)?;

    let schedule = next.schedule.as_ref().map(to_json).transpose()?;
    let row: AlarmRow = sqlx::query_as(&format!(
        "UPDATE alarms SET kind = $3, label = $4, schedule = $5, rhythm = $6, channels = $7, enabled = $8,
           version = nextval('entity_version_seq'), updated_at = now()
         WHERE id = $1 AND user_id = $2
         RETURNING {ALARM_COLUMNS}"
    ))
    .bind(id)
    .bind(user_id)
    .bind(kind_str(next.kind))
    .bind(&next.label)
    .bind(schedule)
    .bind(to_json(&next.rhythm)?)
    .bind(channel_strings(&next.channels))
    .bind(next.enabled)
    .fetch_one(&mut *tx)
    .await?;
    notify_config_changed(&mut tx, user_id).await?;
    tx.commit().await?;
    Ok(Json(alarm_from_row(row)?))
}

/// Soft delete: the row stays as a tombstone with a new version, so the app learns of the deletion.
#[utoipa::path(
    delete,
    path = "/v1/alarms/{id}",
    operation_id = "delete_alarm",
    tag = "Alarms",
    security(("session" = []), ("device" = [])),
    params(
        ("id" = Uuid, Path, description = "Id of the resource."),
        ("If-Match" = Option<i64>, Header, description = "Optional. When sent, a stale value gets 409."),
    ),
    responses(
        (status = 204, description = "Soft-deleted. The version is bumped so the app sees a tombstone."),
        (status = "default", description = "An error as application/problem+json (api-contract.md Errors).", body = crate::openapi::Problem, content_type = "application/problem+json")
    )
)]
pub async fn delete(
    State(state): State<AppState>,
    Either(principal): Either,
    Path(raw_id): Path<String>,
    headers: HeaderMap,
) -> Result<StatusCode, ApiError> {
    let if_match = optional_if_match(&headers)?;
    let id = uuid_or_not_found(&raw_id)?;
    let user_id = principal.user_id();

    let mut tx = state.pool.begin().await?;
    let current = lock_alarm(&mut tx, user_id, id).await?;
    if if_match.is_some_and(|expected| expected != current.version) {
        return Err(ApiError::Conflict {
            detail: "The alarm changed since you loaded it. Reload and try again.".into(),
            current: to_json(&current)?,
        });
    }
    sqlx::query(
        "UPDATE alarms SET deleted_at = now(), version = nextval('entity_version_seq'), updated_at = now()
         WHERE id = $1 AND user_id = $2",
    )
    .bind(id)
    .bind(user_id)
    .execute(&mut *tx)
    .await?;
    notify_config_changed(&mut tx, user_id).await?;
    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

/// Queues a test dispatch with the alarm's own rhythm and channels. The app and dispatcher treat it
/// like a webhook dispatch.
#[utoipa::path(
    post,
    path = "/v1/alarms/{id}/test",
    operation_id = "test_alarm",
    tag = "Alarms",
    security(("session" = []), ("device" = [])),
    params(
        ("id" = Uuid, Path, description = "Id of the resource."),
    ),
    responses(
        (status = 202, description = "Queued with the alarm rhythm and channels.", body = DispatchIdResponse),
        (status = "default", description = "An error as application/problem+json (api-contract.md Errors).", body = crate::openapi::Problem, content_type = "application/problem+json")
    )
)]
pub async fn test(
    State(state): State<AppState>,
    Either(principal): Either,
    Path(raw_id): Path<String>,
) -> Result<Response, ApiError> {
    let id = uuid_or_not_found(&raw_id)?;
    let user_id = principal.user_id();

    let mut tx = state.pool.begin().await?;
    let row: Option<(Value, Vec<String>)> = sqlx::query_as(
        "SELECT rhythm, channels FROM alarms WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL",
    )
    .bind(id)
    .bind(user_id)
    .fetch_optional(&mut *tx)
    .await?;
    let (rhythm, channels) = row.ok_or(ApiError::NotFound)?;

    let dispatch_id = Uuid::now_v7();
    enqueue(&mut tx, dispatch_id, id, None, None, &rhythm, &channels).await?;
    tx.commit().await?;
    Ok((
        StatusCode::ACCEPTED,
        Json(DispatchIdResponse { dispatch_id }),
    )
        .into_response())
}
