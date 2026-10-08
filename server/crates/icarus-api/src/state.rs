use std::{net::IpAddr, path::PathBuf, sync::Arc, time::Duration};

use sqlx::PgPool;
use uuid::Uuid;

use crate::{
    error::ApiError,
    ratelimit::{RateLimiter, TokenBuckets},
    secrets::Secrets,
    whoop::{WhoopClient, WhoopConfig},
};

/// Runtime settings. `main` fills these from the environment.
#[derive(Debug, Clone)]
pub struct Config {
    /// `Secure` on the session cookie. Off only for local dev and tests (`ICARUS_INSECURE_COOKIES=1`).
    pub cookie_secure: bool,
    /// Trust `X-Forwarded-For` for the client IP (`ICARUS_TRUST_PROXY=1`).
    pub trust_proxy: bool,
    pub public_base_url: String,
    /// Static web build. Served only if the directory exists.
    pub web_dir: Option<PathBuf>,
    /// Webhook secrets and hook URLs need this key (`ICARUS_ENC_KEY`). Without it, those routes
    /// answer 503 `internal`.
    pub secrets: Option<Secrets>,
    /// WHOOP integration. `None` leaves every WHOOP route answering 404 (PLAN.md §5.2).
    pub whoop: Option<WhoopConfig>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            cookie_secure: true,
            trust_proxy: false,
            public_base_url: "http://localhost:8080".to_owned(),
            web_dir: None,
            secrets: None,
            whoop: None,
        }
    }
}

#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    pub config: Arc<Config>,
    pub login_limiter: Arc<RateLimiter>,
    pub pairing_limiter: Arc<RateLimiter>,
    pub hook_buckets: Arc<TokenBuckets<Uuid>>,
    /// Pre-auth budget for all webhook ingress from one client IP (PLAN.md §18).
    pub ingress_ip_buckets: Arc<TokenBuckets<IpAddr>>,
    pub whoop: Option<Arc<WhoopClient>>,
}

impl AppState {
    pub fn new(pool: PgPool) -> Self {
        Self::with_config(pool, Config::default())
    }

    pub fn with_config(pool: PgPool, config: Config) -> Self {
        Self {
            pool,
            // PLAN.md §12.2: 5 login attempts per minute per IP.
            login_limiter: Arc::new(RateLimiter::new(5, Duration::from_secs(60))),
            pairing_limiter: Arc::new(RateLimiter::new(30, Duration::from_secs(60))),
            hook_buckets: Arc::new(TokenBuckets::default()),
            ingress_ip_buckets: Arc::new(TokenBuckets::default()),
            whoop: config
                .whoop
                .clone()
                .map(|whoop| Arc::new(WhoopClient::new(whoop))),
            config: Arc::new(config),
        }
    }

    /// The WHOOP client, or 404 when the integration is off.
    pub fn whoop(&self) -> Result<&WhoopClient, ApiError> {
        self.whoop.as_deref().ok_or(ApiError::NotFound)
    }

    pub fn secrets(&self) -> Result<&Secrets, ApiError> {
        self.config.secrets.as_ref().ok_or_else(|| {
            ApiError::NotConfigured(
                "ICARUS_ENC_KEY is not set, so webhook secrets cannot be used.".into(),
            )
        })
    }
}
