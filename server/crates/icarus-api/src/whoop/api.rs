//! Calls to WHOOP: OAuth token endpoint, profile, and the day's recovery, cycle and sleep values.
//! Every call passes the local budget first. Response values are read into `Summary` and dropped.

use std::ops::Range;

use chrono::{DateTime, Utc};
use reqwest::{StatusCode, Url};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{SCOPES, WhoopClient, WhoopError, limiter::Exhausted};

const AUTH_PATH: &str = "/oauth/oauth2/auth";
const TOKEN_PATH: &str = "/oauth/oauth2/token";
/// TODO [Unverified] PLAN §5.2 gives only the per-cycle paths (`/v2/cycle/{id}`, `.../recovery`, `.../sleep`)
/// and the collection names. The collection path and the record and field names below come from the OpenAPI spec and must be checked there.
const CYCLES_PATH: &str = "/developer/v2/cycle";
const LIMIT_MESSAGE_MINUTE: &str = "WHOOP limit reached for this minute. Try again shortly.";
const LIMIT_MESSAGE_DAY: &str = "WHOOP daily limit reached. Try again tomorrow.";
const LIMIT_MESSAGE_UPSTREAM: &str = "WHOOP is rate limiting this server. Try again in a minute.";

#[derive(Deserialize)]
pub struct TokenSet {
    pub access_token: String,
    pub refresh_token: String,
    pub expires_in: i64,
    #[serde(default)]
    pub scope: Option<String>,
}

/// The day's values as the API contract shows them. Any may be null.
#[derive(Debug, Default, Serialize, PartialEq, utoipa::ToSchema)]
pub struct Summary {
    pub recovery_score: Option<f64>,
    pub hrv_rmssd_milli: Option<f64>,
    pub resting_heart_rate: Option<f64>,
    pub strain: Option<f64>,
    pub kilojoule: Option<f64>,
    pub sleep_performance: Option<f64>,
}

impl WhoopClient {
    fn url(&self, path: &str) -> String {
        format!("{}{path}", self.config.api_base)
    }

    fn spend(&self) -> Result<(), WhoopError> {
        self.limiter.acquire().map_err(|err| {
            WhoopError::Limited(match err {
                Exhausted::Minute => LIMIT_MESSAGE_MINUTE,
                Exhausted::Day => LIMIT_MESSAGE_DAY,
            })
        })
    }

    /// The URL the browser is sent to (PLAN.md §5.2).
    pub fn authorize_url(&self, redirect_uri: &str, state: &str) -> Url {
        let scope = SCOPES.join(" ");
        Url::parse_with_params(
            &self.url(AUTH_PATH),
            [
                ("client_id", self.config.client_id.as_str()),
                ("redirect_uri", redirect_uri),
                ("response_type", "code"),
                ("scope", scope.as_str()),
                ("state", state),
            ],
        )
        .expect("WHOOP_API_BASE is a valid URL, checked at startup")
    }

    pub async fn exchange_code(
        &self,
        code: &str,
        redirect_uri: &str,
    ) -> Result<TokenSet, WhoopError> {
        self.post_token(&[
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirect_uri),
        ])
        .await
    }

    /// Rotates both tokens. The refresh token passed in is spent whether or not this succeeds.
    pub async fn refresh(&self, refresh_token: &str) -> Result<TokenSet, WhoopError> {
        self.post_token(&[
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh_token),
        ])
        .await
    }

    async fn post_token(&self, grant: &[(&str, &str)]) -> Result<TokenSet, WhoopError> {
        self.spend()?;
        // TODO [Unverified] PLAN §5.2 does not say how WHOOP expects client credentials. Sent in the form body.
        let mut form = grant.to_vec();
        form.push(("client_id", &self.config.client_id));
        form.push(("client_secret", &self.config.client_secret));
        let response = self
            .http
            .post(self.url(TOKEN_PATH))
            .form(&form)
            .send()
            .await
            .map_err(|_| WhoopError::Upstream)?;
        match response.status() {
            StatusCode::BAD_REQUEST | StatusCode::UNAUTHORIZED => Err(WhoopError::Rejected),
            StatusCode::TOO_MANY_REQUESTS => Err(WhoopError::Limited(LIMIT_MESSAGE_UPSTREAM)),
            status if status.is_success() => {
                let set: TokenSet = response.json().await.map_err(|_| WhoopError::Upstream)?;
                if set.access_token.is_empty() || set.refresh_token.is_empty() {
                    return Err(WhoopError::Upstream);
                }
                Ok(set)
            }
            _ => Err(WhoopError::Upstream),
        }
    }

    /// GET with the access token. `Ok(None)` for a 404, which WHOOP uses for a record that is not there.
    async fn get_json(
        &self,
        access: &str,
        path: &str,
        query: &[(&str, String)],
    ) -> Result<Option<Value>, WhoopError> {
        self.spend()?;
        let response = self
            .http
            .get(self.url(path))
            .bearer_auth(access)
            .query(query)
            .send()
            .await
            .map_err(|_| WhoopError::Upstream)?;
        match response.status() {
            StatusCode::NOT_FOUND => Ok(None),
            StatusCode::UNAUTHORIZED => Err(WhoopError::Rejected),
            StatusCode::TOO_MANY_REQUESTS => Err(WhoopError::Limited(LIMIT_MESSAGE_UPSTREAM)),
            status if status.is_success() => response
                .json::<Value>()
                .await
                .map(Some)
                .map_err(|_| WhoopError::Upstream),
            _ => Err(WhoopError::Upstream),
        }
    }

    /// The WHOOP user id, stored so webhooks can be matched to the connection.
    pub async fn fetch_whoop_user_id(&self, access: &str) -> Result<i64, WhoopError> {
        let body = self
            .get_json(access, &self.config.profile_path, &[])
            .await?
            .ok_or(WhoopError::Upstream)?;
        // TODO [Unverified] PLAN §5.2 does not give the profile field name. `user_id` follows the webhook payload.
        body.get("user_id")
            .and_then(Value::as_i64)
            .ok_or(WhoopError::Upstream)
    }

    /// Revokes the grant at WHOOP. The caller deletes local tokens whatever the answer.
    pub async fn revoke(&self, access: &str) -> Result<(), WhoopError> {
        self.spend()?;
        // TODO [Unverified] method and path: PLAN §5.2 names `revokeUserOAuthAccess` only.
        let response = self
            .http
            .delete(self.url(&self.config.revoke_path))
            .bearer_auth(access)
            .send()
            .await
            .map_err(|_| WhoopError::Upstream)?;
        if response.status().is_success() {
            Ok(())
        } else {
            Err(WhoopError::Upstream)
        }
    }

    /// Live fetch for the cycle that starts in `window`: the cycle, then its recovery and sleep.
    pub async fn fetch_day(
        &self,
        access: &str,
        window: Range<DateTime<Utc>>,
    ) -> Result<Summary, WhoopError> {
        let query = [
            ("start", icarus_core::time::format(&window.start)),
            ("end", icarus_core::time::format(&window.end)),
            ("limit", "25".to_owned()),
        ];
        let Some(cycles) = self.get_json(access, CYCLES_PATH, &query).await? else {
            return Ok(Summary::default());
        };
        let Some(cycle) = cycles.get("records").and_then(|r| r.get(0)) else {
            return Ok(Summary::default());
        };
        let mut summary = Summary {
            strain: number(cycle, "/score/strain"),
            kilojoule: number(cycle, "/score/kilojoule"),
            ..Summary::default()
        };
        let Some(cycle_id) = path_segment(cycle.get("id")) else {
            return Ok(summary);
        };
        let cycle_path = format!("{CYCLES_PATH}/{cycle_id}");

        if let Some(recovery) = self
            .get_json(access, &format!("{cycle_path}/recovery"), &[])
            .await?
        {
            summary.recovery_score = number(&recovery, "/score/recovery_score");
            summary.hrv_rmssd_milli = number(&recovery, "/score/hrv_rmssd_milli");
            summary.resting_heart_rate = number(&recovery, "/score/resting_heart_rate");
        }
        if let Some(sleep) = self
            .get_json(access, &format!("{cycle_path}/sleep"), &[])
            .await?
        {
            summary.sleep_performance = number(&sleep, "/score/sleep_performance_percentage");
        }
        Ok(summary)
    }
}

fn number(value: &Value, pointer: &str) -> Option<f64> {
    value.pointer(pointer).and_then(Value::as_f64)
}

/// A WHOOP id as a URL path segment. Anything that could change the path is refused.
fn path_segment(id: Option<&Value>) -> Option<String> {
    let raw = match id? {
        Value::Number(n) => n.to_string(),
        Value::String(s) => s.clone(),
        _ => return None,
    };
    let safe = !raw.is_empty() && raw.chars().all(|c| c.is_ascii_alphanumeric() || c == '-');
    safe.then_some(raw)
}
