//! `GET`, `PATCH` and `DELETE /v1/me` (api-contract.md "Auth").

use axum::{
    Json,
    extract::State,
    http::{HeaderMap, StatusCode, header::SET_COOKIE},
    response::{IntoResponse, Response},
};
use icarus_core::{FormulaSex, Me};
use serde::{Deserialize, Deserializer};
use sqlx::FromRow;
use uuid::Uuid;

use crate::{
    auth::{Either, WebUser, clear_cookie_header},
    error::ApiError,
    extract::ApiJson,
    routes::if_match_version,
    state::AppState,
};

#[derive(FromRow)]
struct MeRow {
    id: Uuid,
    email: String,
    tz: String,
    formula_sex: Option<String>,
    birth_year: Option<i16>,
    height_cm: Option<f32>,
    weight_kg: Option<f32>,
    hr_max: Option<i16>,
    version: i64,
}

const ME_COLUMNS: &str =
    "id, email::text AS email, tz, formula_sex, birth_year, height_cm, weight_kg, hr_max, version";

impl TryFrom<MeRow> for Me {
    type Error = ApiError;

    fn try_from(row: MeRow) -> Result<Self, ApiError> {
        let formula_sex = match row.formula_sex.as_deref() {
            None => None,
            Some("male") => Some(FormulaSex::Male),
            Some("female") => Some(FormulaSex::Female),
            Some(_) => return Err(ApiError::Internal),
        };
        Ok(Me {
            id: row.id,
            email: row.email,
            tz: row.tz,
            formula_sex,
            birth_year: row.birth_year,
            height_cm: row.height_cm,
            weight_kg: row.weight_kg,
            hr_max: row.hr_max,
            version: row.version,
        })
    }
}

fn formula_sex_str(sex: FormulaSex) -> &'static str {
    match sex {
        FormulaSex::Male => "male",
        FormulaSex::Female => "female",
    }
}

pub(crate) async fn load_me(pool: &sqlx::PgPool, user_id: Uuid) -> Result<Me, ApiError> {
    let row: Option<MeRow> =
        sqlx::query_as(&format!("SELECT {ME_COLUMNS} FROM users WHERE id = $1"))
            .bind(user_id)
            .fetch_optional(pool)
            .await?;
    row.ok_or(ApiError::NotFound)?.try_into()
}

pub async fn get_me(
    State(state): State<AppState>,
    Either(principal): Either,
) -> Result<Json<Me>, ApiError> {
    Ok(Json(load_me(&state.pool, principal.user_id()).await?))
}

/// Distinguishes "absent" (`None`) from "explicit null" (`Some(None)`) in PATCH bodies.
fn double_option<'de, T, D>(deserializer: D) -> Result<Option<Option<T>>, D::Error>
where
    T: Deserialize<'de>,
    D: Deserializer<'de>,
{
    Option::<T>::deserialize(deserializer).map(Some)
}

#[derive(Deserialize, Default)]
pub struct MePatch {
    #[serde(default, deserialize_with = "double_option")]
    tz: Option<Option<String>>,
    #[serde(default, deserialize_with = "double_option")]
    formula_sex: Option<Option<FormulaSex>>,
    #[serde(default, deserialize_with = "double_option")]
    birth_year: Option<Option<i16>>,
    #[serde(default, deserialize_with = "double_option")]
    height_cm: Option<Option<f32>>,
    #[serde(default, deserialize_with = "double_option")]
    weight_kg: Option<Option<f32>>,
    #[serde(default, deserialize_with = "double_option")]
    hr_max: Option<Option<i16>>,
}

fn check_range<T: PartialOrd + std::fmt::Display + Copy>(
    value: T,
    min: T,
    max: T,
    what: &str,
) -> Result<(), ApiError> {
    if value < min || value > max {
        return Err(ApiError::Validation(format!(
            "{what} must be between {min} and {max}."
        )));
    }
    Ok(())
}

pub async fn patch_me(
    State(state): State<AppState>,
    Either(principal): Either,
    headers: HeaderMap,
    ApiJson(patch): ApiJson<MePatch>,
) -> Result<Json<Me>, ApiError> {
    let if_match = if_match_version(&headers)?;
    let user_id = principal.user_id();

    // Validate the patch before taking the row lock.
    if let Some(Some(tz)) = &patch.tz {
        let known: bool =
            sqlx::query_scalar("SELECT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = $1)")
                .bind(tz)
                .fetch_one(&state.pool)
                .await?;
        if !known {
            return Err(ApiError::Validation(
                "tz must be an IANA timezone name, such as America/Chicago.".into(),
            ));
        }
    }
    if matches!(patch.tz, Some(None)) {
        return Err(ApiError::Validation("tz cannot be null.".into()));
    }
    if let Some(Some(year)) = patch.birth_year {
        check_range(year, 1900, 2100, "birth_year")?;
    }
    if let Some(Some(cm)) = patch.height_cm {
        check_range(cm, 50.0, 300.0, "height_cm")?;
    }
    if let Some(Some(kg)) = patch.weight_kg {
        check_range(kg, 20.0, 400.0, "weight_kg")?;
    }
    if let Some(Some(hr)) = patch.hr_max {
        check_range(hr, 60, 250, "hr_max")?;
    }

    let mut tx = state.pool.begin().await?;
    let row: Option<MeRow> = sqlx::query_as(&format!(
        "SELECT {ME_COLUMNS} FROM users WHERE id = $1 FOR UPDATE"
    ))
    .bind(user_id)
    .fetch_optional(&mut *tx)
    .await?;
    let current: Me = row.ok_or(ApiError::NotFound)?.try_into()?;
    if current.version != if_match {
        let current = serde_json::to_value(&current).map_err(|_| ApiError::Internal)?;
        return Err(ApiError::Conflict {
            detail: "The profile changed since you loaded it. Reload and try again.".into(),
            current,
        });
    }

    let mut next = current;
    if let Some(tz) = patch.tz {
        next.tz = tz.unwrap_or_default();
    }
    if let Some(sex) = patch.formula_sex {
        next.formula_sex = sex;
    }
    if let Some(year) = patch.birth_year {
        next.birth_year = year;
    }
    if let Some(cm) = patch.height_cm {
        next.height_cm = cm;
    }
    if let Some(kg) = patch.weight_kg {
        next.weight_kg = kg;
    }
    if let Some(hr) = patch.hr_max {
        next.hr_max = hr;
    }

    sqlx::query(
        "UPDATE users SET tz = $2, formula_sex = $3, birth_year = $4, height_cm = $5, weight_kg = $6,
           hr_max = $7, version = version + 1, updated_at = now()
         WHERE id = $1 AND version = $8",
    )
    .bind(user_id)
    .bind(&next.tz)
    .bind(next.formula_sex.map(formula_sex_str))
    .bind(next.birth_year)
    .bind(next.height_cm)
    .bind(next.weight_kg)
    .bind(next.hr_max)
    .bind(if_match)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;

    next.version += 1;
    Ok(Json(next))
}

#[derive(Deserialize)]
pub struct DeleteBody {
    confirm: String,
}

/// Deletes the account and, through cascades, every row that belongs to it.
pub async fn delete_me(
    State(state): State<AppState>,
    WebUser(user_id): WebUser,
    ApiJson(body): ApiJson<DeleteBody>,
) -> Result<Response, ApiError> {
    let email: String = sqlx::query_scalar("SELECT email::text FROM users WHERE id = $1")
        .bind(user_id)
        .fetch_one(&state.pool)
        .await?;
    if body.confirm.trim() != email {
        return Err(ApiError::Validation(
            "confirm must be your account email.".into(),
        ));
    }
    sqlx::query("DELETE FROM users WHERE id = $1")
        .bind(user_id)
        .execute(&state.pool)
        .await?;
    Ok((
        StatusCode::NO_CONTENT,
        [(SET_COOKIE, clear_cookie_header(&state.config))],
    )
        .into_response())
}
