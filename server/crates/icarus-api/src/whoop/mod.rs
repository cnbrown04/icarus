//! Optional WHOOP integration (PLAN.md §5.2, §6.3, §12.6; api-contract.md "WHOOP").
//!
//! Only tokens and webhook trace ids are stored. Recovery, cycle and sleep values are fetched for the
//! requested day and returned without being written anywhere (PLAN.md §6.3).

pub mod api;
pub mod limiter;
pub mod reconcile;
pub mod tokens;
pub mod webhook;

use std::{fmt, time::Duration};

use crate::error::ApiError;
pub use api::Summary;
pub use limiter::WhoopLimiter;
pub use reconcile::{reconcile_once, spawn_reconcile};

/// Scopes requested at connect time (PLAN.md §5.2). `offline` makes WHOOP issue a refresh token.
pub const SCOPES: [&str; 7] = [
    "offline",
    "read:recovery",
    "read:cycles",
    "read:workout",
    "read:sleep",
    "read:profile",
    "read:body_measurement",
];

pub const DEFAULT_API_BASE: &str = "https://api.prod.whoop.com";
/// PLAN.md §5.2: 100 requests per minute and 10,000 per day.
pub const DEFAULT_PER_MINUTE: usize = 100;
pub const DEFAULT_PER_DAY: usize = 10_000;

/// Settings from `WHOOP_CLIENT_ID`, `WHOOP_CLIENT_SECRET` and `WHOOP_API_BASE`.
#[derive(Clone)]
pub struct WhoopConfig {
    pub client_id: String,
    pub client_secret: String,
    /// Scheme and host. Tests point this at a local mock.
    pub api_base: String,
    /// TODO [Unverified] PLAN §5.2 gives "Get Basic User Profile" without its path. Confirm against the OpenAPI spec.
    pub profile_path: String,
    /// TODO [Unverified] PLAN §5.2 names `revokeUserOAuthAccess` without its path or method. Placeholder until confirmed.
    pub revoke_path: String,
    pub per_minute: usize,
    pub per_day: usize,
}

impl WhoopConfig {
    pub fn new(client_id: impl Into<String>, client_secret: impl Into<String>) -> Self {
        Self {
            client_id: client_id.into(),
            client_secret: client_secret.into(),
            api_base: DEFAULT_API_BASE.to_owned(),
            profile_path: "/developer/v2/user/profile/basic".to_owned(),
            revoke_path: "/developer/v2/oauth/revoke".to_owned(),
            per_minute: DEFAULT_PER_MINUTE,
            per_day: DEFAULT_PER_DAY,
        }
    }
}

impl WhoopConfig {
    /// Replaces the API base (`WHOOP_API_BASE`). Only http or https URLs are accepted.
    pub fn with_api_base(mut self, base: &str) -> Result<Self, String> {
        let base = base.trim().trim_end_matches('/');
        let url =
            reqwest::Url::parse(base).map_err(|_| "WHOOP_API_BASE is not a URL.".to_owned())?;
        if !matches!(url.scheme(), "http" | "https") {
            return Err("WHOOP_API_BASE must be an http or https URL.".to_owned());
        }
        self.api_base = base.to_owned();
        Ok(self)
    }
}

impl fmt::Debug for WhoopConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("WhoopConfig")
            .field("client_id", &self.client_id)
            .field("client_secret", &"<redacted>")
            .field("api_base", &self.api_base)
            .field("per_minute", &self.per_minute)
            .field("per_day", &self.per_day)
            .finish()
    }
}

/// HTTP client for WHOOP with the local call budget. Built once and shared through `AppState`.
pub struct WhoopClient {
    config: WhoopConfig,
    http: reqwest::Client,
    limiter: WhoopLimiter,
}

impl WhoopClient {
    pub fn new(mut config: WhoopConfig) -> Self {
        config.api_base = config.api_base.trim_end_matches('/').to_owned();
        let http = reqwest::Client::builder()
            // The server calls WHOOP directly. Environment proxies are not used.
            .no_proxy()
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(10))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .expect("the WHOOP HTTP client builds with rustls");
        let limiter = WhoopLimiter::new(config.per_minute, config.per_day);
        Self {
            config,
            http,
            limiter,
        }
    }

    pub fn config(&self) -> &WhoopConfig {
        &self.config
    }
}

/// Failures of a call to WHOOP. The variant decides the client-facing answer.
#[derive(Debug)]
pub enum WhoopError {
    /// WHOOP refused the grant or the token (HTTP 400 or 401).
    Rejected,
    /// Over the local budget, or WHOOP answered 429. The text is safe to show.
    Limited(&'static str),
    /// Network failure, timeout, or a response that is not what the contract expects.
    Upstream,
}

impl From<WhoopError> for ApiError {
    fn from(err: WhoopError) -> Self {
        match err {
            // 404 rather than 401: a 401 would sign the web app out.
            WhoopError::Rejected => {
                ApiError::NotFoundDetail("WHOOP sign-in has expired. Connect WHOOP again.")
            }
            WhoopError::Limited(detail) => ApiError::RateLimitedDetail(detail),
            WhoopError::Upstream => ApiError::Upstream("WHOOP did not answer. Try again later."),
        }
    }
}
