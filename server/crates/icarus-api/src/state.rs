use std::{path::PathBuf, sync::Arc, time::Duration};

use sqlx::PgPool;

use crate::{
    error::ApiError,
    ratelimit::{RateLimiter, TokenBuckets},
    secrets::Secrets,
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
}

impl Default for Config {
    fn default() -> Self {
        Self {
            cookie_secure: true,
            trust_proxy: false,
            public_base_url: "http://localhost:8080".to_owned(),
            web_dir: None,
            secrets: None,
        }
    }
}

#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    pub config: Arc<Config>,
    pub login_limiter: Arc<RateLimiter>,
    pub pairing_limiter: Arc<RateLimiter>,
    pub hook_buckets: Arc<TokenBuckets>,
}

impl AppState {
    pub fn new(pool: PgPool) -> Self {
        Self::with_config(pool, Config::default())
    }

    pub fn with_config(pool: PgPool, config: Config) -> Self {
        Self {
            pool,
            config: Arc::new(config),
            // PLAN.md §12.2: 5 login attempts per minute per IP.
            login_limiter: Arc::new(RateLimiter::new(5, Duration::from_secs(60))),
            pairing_limiter: Arc::new(RateLimiter::new(30, Duration::from_secs(60))),
            hook_buckets: Arc::new(TokenBuckets::default()),
        }
    }

    pub fn secrets(&self) -> Result<&Secrets, ApiError> {
        self.config.secrets.as_ref().ok_or_else(|| {
            ApiError::NotConfigured(
                "ICARUS_ENC_KEY is not set, so webhook secrets cannot be used.".into(),
            )
        })
    }
}
