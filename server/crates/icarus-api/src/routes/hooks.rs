//! Webhook endpoint management for the website (api-contract.md "Webhook management", PLAN.md §12.4).
//! The public receiving side is in `ingress.rs`.

use axum::{
    Json,
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{DateTime, SecondsFormat, Utc};
use icarus_core::{AuthMode, Dispatch, Hook, time::format as format_time};
use serde::Deserialize;
use serde_json::{Value, json};
use sqlx::{FromRow, PgPool};
use uuid::Uuid;

use crate::{
    auth::{WebUser, fill_random},
    error::ApiError,
    extract::{ApiJson, ApiQuery},
    routes::{
        dispatches::{DISPATCH_COLUMNS, DispatchRow, dispatch_from_row},
        if_match_version, notify_config_changed, uuid_or_not_found,
    },
    secrets::Secrets,
    state::AppState,
};

const LABEL_MAX_CHARS: usize = 100;
const RATE_DEFAULT: i16 = 10;
const RATE_MAX: i16 = 600;
const DELIVERIES_PAGE: usize = 50;

#[derive(FromRow)]
pub(crate) struct HookRow {
    id: Uuid,
    slug: String,
    label: String,
    alarm_id: Option<Uuid>,
    auth_mode: String,
    secret_ciphertext: Vec<u8>,
    rate_limit_per_min: i16,
    enabled: bool,
    version: i64,
    created_at: DateTime<Utc>,
    last_triggered_at: Option<DateTime<Utc>>,
}

pub(crate) const HOOK_COLUMNS: &str = "id, slug, label, alarm_id, auth_mode, secret_ciphertext, \
    rate_limit_per_min, enabled, version, created_at, last_triggered_at";

/// 22 characters: 16 random bytes, base64url without padding. The slug is in the public URL.
fn new_slug() -> String {
    let mut bytes = [0u8; 16];
    fill_random(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

/// 32 random bytes, base64url without padding. Shown once; the HMAC key is its UTF-8 bytes.
fn new_secret() -> String {
    let mut bytes = [0u8; 32];
    fill_random(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

/// The secret is bound to its row id, so a copied ciphertext does not open under another hook.
fn seal_secret(secrets: &Secrets, id: Uuid, secret: &str) -> Result<Vec<u8>, ApiError> {
    secrets
        .seal(id.as_bytes(), secret.as_bytes())
        .map_err(|_| ApiError::Internal)
}

pub(crate) fn open_secret(secrets: &Secrets, id: Uuid, sealed: &[u8]) -> Result<String, ApiError> {
    let plain = secrets.open(id.as_bytes(), sealed).map_err(|_| {
        tracing::error!("webhook secret does not open with the configured key");
        ApiError::Internal
    })?;
    String::from_utf8(plain).map_err(|_| ApiError::Internal)
}

/// Public URL of a hook. Secret-URL hooks carry the secret in the path.
pub(crate) fn hook_url(base: &str, slug: &str, mode: AuthMode, secret: Option<&str>) -> String {
    match (mode, secret) {
        (AuthMode::SecretUrl, Some(secret)) => format!("{base}/v1/hooks/{slug}/{secret}"),
        _ => format!("{base}/v1/hooks/{slug}"),
    }
}

fn auth_mode_str(mode: AuthMode) -> &'static str {
    match mode {
        AuthMode::Hmac => "hmac",
        AuthMode::SecretUrl => "secret_url",
    }
}

/// Builds the `Hook` shape. Secret-URL hooks need the key to build their URL.
pub(crate) fn hook_from_row(
    row: HookRow,
    base: &str,
    secrets: Option<&Secrets>,
) -> Result<Hook, ApiError> {
    let auth_mode: AuthMode = crate::routes::stored(Value::String(row.auth_mode))?;
    let secret = match auth_mode {
        AuthMode::Hmac => None,
        AuthMode::SecretUrl => {
            let secrets = secrets.ok_or_else(|| {
                ApiError::NotConfigured(
                    "ICARUS_ENC_KEY is not set, so secret URLs cannot be shown.".into(),
                )
            })?;
            Some(open_secret(secrets, row.id, &row.secret_ciphertext)?)
        }
    };
    Ok(Hook {
        id: row.id,
        url: hook_url(base, &row.slug, auth_mode, secret.as_deref()),
        slug: row.slug,
        label: row.label,
        alarm_id: row.alarm_id,
        auth_mode,
        rate_limit_per_min: row.rate_limit_per_min,
        enabled: row.enabled,
        created_at: row.created_at,
        last_triggered_at: row.last_triggered_at,
        version: row.version,
    })
}

fn base_url(state: &AppState) -> &str {
    state.config.public_base_url.trim_end_matches('/')
}

fn to_json<T: serde::Serialize>(value: &T) -> Result<Value, ApiError> {
    serde_json::to_value(value).map_err(|_| ApiError::Internal)
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

fn check_rate(rate: i16) -> Result<i16, ApiError> {
    if (1..=RATE_MAX).contains(&rate) {
        Ok(rate)
    } else {
        Err(ApiError::Validation(format!(
            "rate_limit_per_min must be between 1 and {RATE_MAX}."
        )))
    }
}

/// The alarm must belong to this user and not be deleted.
async fn check_alarm(pool: &PgPool, user_id: Uuid, alarm_id: Uuid) -> Result<(), ApiError> {
    let live: bool = sqlx::query_scalar(
        "SELECT EXISTS (SELECT 1 FROM alarms WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL)",
    )
    .bind(alarm_id)
    .bind(user_id)
    .fetch_one(pool)
    .await?;
    if live {
        Ok(())
    } else {
        Err(ApiError::Validation(
            "alarm_id must be one of your alarms.".into(),
        ))
    }
}

/// Loads one hook of this user. Management routes take the id; a non-UUID is not found.
async fn load_hook(pool: &PgPool, user_id: Uuid, id: Uuid) -> Result<HookRow, ApiError> {
    let row: Option<HookRow> = sqlx::query_as(&format!(
        "SELECT {HOOK_COLUMNS} FROM webhook_endpoints WHERE id = $1 AND user_id = $2"
    ))
    .bind(id)
    .bind(user_id)
    .fetch_optional(pool)
    .await?;
    row.ok_or(ApiError::NotFound)
}

pub async fn list(
    State(state): State<AppState>,
    WebUser(user_id): WebUser,
) -> Result<Json<Value>, ApiError> {
    let rows: Vec<HookRow> = sqlx::query_as(&format!(
        "SELECT {HOOK_COLUMNS} FROM webhook_endpoints WHERE user_id = $1 ORDER BY id"
    ))
    .bind(user_id)
    .fetch_all(&state.pool)
    .await?;
    let base = base_url(&state);
    let hooks = rows
        .into_iter()
        .map(|row| hook_from_row(row, base, state.config.secrets.as_ref()))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(Json(json!({ "hooks": hooks })))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HookCreate {
    label: String,
    alarm_id: Uuid,
    auth_mode: AuthMode,
    #[serde(default)]
    rate_limit_per_min: Option<i16>,
}

pub async fn create(
    State(state): State<AppState>,
    WebUser(user_id): WebUser,
    ApiJson(body): ApiJson<HookCreate>,
) -> Result<Response, ApiError> {
    let secrets = state.secrets()?;
    let label = clean_label(&body.label)?;
    let rate = check_rate(body.rate_limit_per_min.unwrap_or(RATE_DEFAULT))?;
    check_alarm(&state.pool, user_id, body.alarm_id).await?;

    let id = Uuid::now_v7();
    let slug = new_slug();
    let secret = new_secret();
    let sealed = seal_secret(secrets, id, &secret)?;

    let mut tx = state.pool.begin().await?;
    let row: HookRow = sqlx::query_as(&format!(
        "INSERT INTO webhook_endpoints (id, user_id, slug, label, alarm_id, auth_mode, secret_ciphertext, rate_limit_per_min)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
         RETURNING {HOOK_COLUMNS}"
    ))
    .bind(id)
    .bind(user_id)
    .bind(&slug)
    .bind(&label)
    .bind(body.alarm_id)
    .bind(auth_mode_str(body.auth_mode))
    .bind(&sealed)
    .bind(rate)
    .fetch_one(&mut *tx)
    .await?;
    notify_config_changed(&mut tx, user_id).await?;
    tx.commit().await?;

    let hook = hook_from_row(row, base_url(&state), Some(secrets))?;
    // The secret is returned here and never again. Only the ciphertext is stored.
    let mut body = to_json(&hook)?;
    body["secret"] = json!(secret);
    Ok((StatusCode::CREATED, Json(body)).into_response())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HookPatch {
    label: Option<String>,
    alarm_id: Option<Uuid>,
    enabled: Option<bool>,
    rate_limit_per_min: Option<i16>,
}

pub async fn patch(
    State(state): State<AppState>,
    WebUser(user_id): WebUser,
    Path(raw_id): Path<String>,
    headers: HeaderMap,
    ApiJson(patch): ApiJson<HookPatch>,
) -> Result<Json<Hook>, ApiError> {
    let if_match = if_match_version(&headers)?;
    let id = uuid_or_not_found(&raw_id)?;

    let mut tx = state.pool.begin().await?;
    let current: HookRow = sqlx::query_as(&format!(
        "SELECT {HOOK_COLUMNS} FROM webhook_endpoints WHERE id = $1 AND user_id = $2 FOR UPDATE"
    ))
    .bind(id)
    .bind(user_id)
    .fetch_optional(&mut *tx)
    .await?
    .ok_or(ApiError::NotFound)?;
    if current.version != if_match {
        let hook = hook_from_row(current, base_url(&state), state.config.secrets.as_ref())?;
        return Err(ApiError::Conflict {
            detail: "The webhook changed since you loaded it. Reload and try again.".into(),
            current: to_json(&hook)?,
        });
    }

    let label = match &patch.label {
        Some(label) => clean_label(label)?,
        None => current.label.clone(),
    };
    let alarm_id = match patch.alarm_id {
        Some(alarm_id) => {
            check_alarm(&state.pool, user_id, alarm_id).await?;
            alarm_id
        }
        None => current.alarm_id.ok_or(ApiError::Internal)?,
    };
    let enabled = patch.enabled.unwrap_or(current.enabled);
    let rate = check_rate(
        patch
            .rate_limit_per_min
            .unwrap_or(current.rate_limit_per_min),
    )?;

    let row: HookRow = sqlx::query_as(&format!(
        "UPDATE webhook_endpoints
         SET label = $3, alarm_id = $4, enabled = $5, rate_limit_per_min = $6,
             version = nextval('entity_version_seq')
         WHERE id = $1 AND user_id = $2
         RETURNING {HOOK_COLUMNS}"
    ))
    .bind(id)
    .bind(user_id)
    .bind(&label)
    .bind(alarm_id)
    .bind(enabled)
    .bind(rate)
    .fetch_one(&mut *tx)
    .await?;
    notify_config_changed(&mut tx, user_id).await?;
    tx.commit().await?;
    Ok(Json(hook_from_row(
        row,
        base_url(&state),
        state.config.secrets.as_ref(),
    )?))
}

/// Hard delete. Deliveries and their dispatches go with it. The sync config has no tombstone for
/// hooks (api-contract.md `Hook` has no `deleted_at`), so the app learns of it on its next full read.
pub async fn delete(
    State(state): State<AppState>,
    WebUser(user_id): WebUser,
    Path(raw_id): Path<String>,
) -> Result<StatusCode, ApiError> {
    let id = uuid_or_not_found(&raw_id)?;
    let mut tx = state.pool.begin().await?;
    let deleted: Option<(Uuid,)> =
        sqlx::query_as("DELETE FROM webhook_endpoints WHERE id = $1 AND user_id = $2 RETURNING id")
            .bind(id)
            .bind(user_id)
            .fetch_optional(&mut *tx)
            .await?;
    deleted.ok_or(ApiError::NotFound)?;
    notify_config_changed(&mut tx, user_id).await?;
    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn rotate(
    State(state): State<AppState>,
    WebUser(user_id): WebUser,
    Path(raw_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let secrets = state.secrets()?;
    let id = uuid_or_not_found(&raw_id)?;
    let secret = new_secret();
    let sealed = seal_secret(secrets, id, &secret)?;

    let mut tx = state.pool.begin().await?;
    let found: Option<(Uuid,)> = sqlx::query_as(
        "UPDATE webhook_endpoints
         SET secret_ciphertext = $3, version = nextval('entity_version_seq')
         WHERE id = $1 AND user_id = $2
         RETURNING id",
    )
    .bind(id)
    .bind(user_id)
    .bind(&sealed)
    .fetch_optional(&mut *tx)
    .await?;
    found.ok_or(ApiError::NotFound)?;
    notify_config_changed(&mut tx, user_id).await?;
    tx.commit().await?;
    Ok(Json(json!({ "secret": secret })))
}

/// Cursor: base64url of `<received_at, RFC 3339 with microseconds>|<delivery id>`.
fn encode_cursor(received_at: DateTime<Utc>, id: Uuid) -> String {
    let raw = format!(
        "{}|{id}",
        received_at.to_rfc3339_opts(SecondsFormat::Micros, true)
    );
    URL_SAFE_NO_PAD.encode(raw)
}

fn decode_cursor(raw: &str) -> Result<(DateTime<Utc>, Uuid), ApiError> {
    let invalid = || ApiError::Validation("cursor is not valid.".into());
    let bytes = URL_SAFE_NO_PAD.decode(raw).map_err(|_| invalid())?;
    let text = String::from_utf8(bytes).map_err(|_| invalid())?;
    let (ts, id) = text.split_once('|').ok_or_else(invalid)?;
    let ts = DateTime::parse_from_rfc3339(ts)
        .map_err(|_| invalid())?
        .with_timezone(&Utc);
    let id = Uuid::parse_str(id).map_err(|_| invalid())?;
    Ok((ts, id))
}

#[derive(FromRow)]
struct DeliveryRow {
    id: Uuid,
    received_at: DateTime<Utc>,
    status: String,
    signature_valid: bool,
}

#[derive(Deserialize)]
pub struct DeliveriesQuery {
    cursor: Option<String>,
}

pub async fn deliveries(
    State(state): State<AppState>,
    WebUser(user_id): WebUser,
    Path(raw_id): Path<String>,
    ApiQuery(query): ApiQuery<DeliveriesQuery>,
) -> Result<Json<Value>, ApiError> {
    let id = uuid_or_not_found(&raw_id)?;
    load_hook(&state.pool, user_id, id).await?;
    let cursor = query.cursor.as_deref().map(decode_cursor).transpose()?;
    let (cursor_ts, cursor_id) = match cursor {
        Some((ts, id)) => (Some(ts), Some(id)),
        None => (None, None),
    };

    // One extra row tells us whether another page exists.
    let mut rows: Vec<DeliveryRow> = sqlx::query_as(
        "SELECT id, received_at, status, signature_valid
         FROM webhook_deliveries
         WHERE endpoint_id = $1
           AND ($2::timestamptz IS NULL OR (received_at, id) < ($2::timestamptz, $3::uuid))
         ORDER BY received_at DESC, id DESC
         LIMIT $4",
    )
    .bind(id)
    .bind(cursor_ts)
    .bind(cursor_id)
    .bind(i64::try_from(DELIVERIES_PAGE + 1).unwrap_or(i64::MAX))
    .fetch_all(&state.pool)
    .await?;

    let next_cursor = if rows.len() > DELIVERIES_PAGE {
        rows.truncate(DELIVERIES_PAGE);
        rows.last().map(|r| encode_cursor(r.received_at, r.id))
    } else {
        None
    };

    let delivery_ids: Vec<Uuid> = rows.iter().map(|r| r.id).collect();
    let dispatch_rows: Vec<DispatchRow> = sqlx::query_as(&format!(
        "SELECT {DISPATCH_COLUMNS} FROM alarm_dispatches d WHERE d.delivery_id = ANY($1)"
    ))
    .bind(&delivery_ids)
    .fetch_all(&state.pool)
    .await?;
    let mut dispatches = std::collections::HashMap::new();
    for row in dispatch_rows {
        if let Some(delivery_id) = row.delivery_id {
            dispatches.insert(delivery_id, dispatch_from_row(row)?);
        }
    }

    let items = rows
        .into_iter()
        .map(|r| {
            let dispatch = dispatches.get(&r.id);
            delivery_json(r, dispatch)
        })
        .collect::<Vec<_>>();
    Ok(Json(
        json!({ "deliveries": items, "next_cursor": next_cursor }),
    ))
}

fn delivery_json(row: DeliveryRow, dispatch: Option<&Dispatch>) -> Value {
    json!({
        "id": row.id,
        "received_at": format_time(&row.received_at),
        "status": row.status,
        "signature_valid": row.signature_valid,
        "dispatch": dispatch,
    })
}
