//! Account, device, band, webhook and dispatch shapes (api-contract.md "Routes").

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::alarm::Rhythm;
use crate::time::rfc3339;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum FormulaSex {
    Male,
    Female,
}

/// `GET /v1/me`. Profile fields may be null.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Me {
    pub id: Uuid,
    pub email: String,
    pub tz: String,
    pub formula_sex: Option<FormulaSex>,
    pub birth_year: Option<i16>,
    pub height_cm: Option<f32>,
    pub weight_kg: Option<f32>,
    pub hr_max: Option<i16>,
    pub version: i64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Device {
    pub id: Uuid,
    pub name: String,
    pub model: Option<String>,
    pub os_version: Option<String>,
    pub app_version: Option<String>,
    #[serde(with = "rfc3339")]
    pub created_at: DateTime<Utc>,
    #[serde(with = "rfc3339::opt")]
    pub last_seen_at: Option<DateTime<Utc>>,
    #[serde(with = "rfc3339::opt")]
    pub revoked_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Band {
    pub id: Uuid,
    pub name: Option<String>,
    pub firmware: Option<String>,
    #[serde(with = "rfc3339")]
    pub created_at: DateTime<Utc>,
    #[serde(with = "rfc3339::opt")]
    pub last_seen_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AuthMode {
    Hmac,
    SecretUrl,
}

/// `Hook` in api-contract.md. `url` is built from `PUBLIC_BASE_URL` at read time.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Hook {
    pub id: Uuid,
    pub slug: String,
    pub label: String,
    pub alarm_id: Option<Uuid>,
    pub auth_mode: AuthMode,
    pub rate_limit_per_min: i16,
    pub enabled: bool,
    pub url: String,
    #[serde(with = "rfc3339")]
    pub created_at: DateTime<Utc>,
    #[serde(with = "rfc3339::opt")]
    pub last_triggered_at: Option<DateTime<Utc>>,
    pub version: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DispatchStatus {
    Pending,
    Sent,
    Acked,
    Unacked,
    Failed,
}

/// `Dispatch` in api-contract.md.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Dispatch {
    pub id: Uuid,
    pub alarm_id: Option<Uuid>,
    pub delivery_id: Option<Uuid>,
    #[serde(with = "rfc3339")]
    pub created_at: DateTime<Utc>,
    pub attempts: i16,
    pub phone_status: Option<String>,
    pub band_status: Option<String>,
    #[serde(with = "rfc3339::opt")]
    pub acked_at: Option<DateTime<Utc>>,
    pub status: DispatchStatus,
    pub message: Option<String>,
    pub rhythm: Rhythm,
}
