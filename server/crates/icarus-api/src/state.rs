use std::{path::PathBuf, sync::Arc, time::Duration};

use sqlx::PgPool;

use crate::ratelimit::RateLimiter;

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
}

impl Default for Config {
    fn default() -> Self {
        Self {
            cookie_secure: true,
            trust_proxy: false,
            public_base_url: "http://localhost:8080".to_owned(),
            web_dir: None,
        }
    }
}

#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    pub config: Arc<Config>,
    pub login_limiter: Arc<RateLimiter>,
    pub pairing_limiter: Arc<RateLimiter>,
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
        }
    }
}
