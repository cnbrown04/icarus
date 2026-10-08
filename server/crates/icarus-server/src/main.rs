use std::{net::SocketAddr, path::PathBuf};

use anyhow::{Context, bail};
use icarus_api::{AppState, Config, CreateUserError, Secrets, create_user, router};
use icarus_push::{AnySender, ApnsSender, ApnsSettings, DispatchConfig, LogOnlySender};
use sqlx::PgPool;
use tokio::{net::TcpListener, signal};

const USAGE: &str =
    "usage: icarus-server [create-user <email>]  (ICARUS_PASSWORD is read for create-user)";

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .json()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    let args: Vec<String> = std::env::args().skip(1).collect();
    let database_url = std::env::var("DATABASE_URL").context("DATABASE_URL is not set")?;

    let pool = icarus_db::connect(&database_url)
        .await
        .context("connecting to Postgres")?;
    icarus_db::migrate(&pool)
        .await
        .context("running migrations")?;

    match args.as_slice() {
        [] => serve(pool).await,
        [command, email] if command == "create-user" => create_user_command(&pool, email).await,
        _ => bail!(USAGE),
    }
}

/// `icarus-server create-user <email>`: prints the new user id. The password comes from ICARUS_PASSWORD.
async fn create_user_command(pool: &PgPool, email: &str) -> anyhow::Result<()> {
    let password = std::env::var("ICARUS_PASSWORD").context("ICARUS_PASSWORD is not set")?;
    match create_user(pool, email, &password).await {
        Ok(id) => {
            println!("{id}");
            Ok(())
        }
        Err(CreateUserError::EmailTaken) => bail!("a user with this email already exists"),
        Err(err) => Err(err).context("creating the user"),
    }
}

fn env_flag(name: &str) -> bool {
    matches!(std::env::var(name).as_deref(), Ok("1") | Ok("true"))
}

/// `ICARUS_ENC_KEY`: base64 for 32 bytes. Unset is allowed, with a warning, because webhooks are
/// optional. A malformed key stops the server, since a wrong key would fail later and quietly.
fn secrets_from_env() -> anyhow::Result<Option<Secrets>> {
    match std::env::var("ICARUS_ENC_KEY") {
        Ok(raw) if !raw.trim().is_empty() => Secrets::from_base64(&raw)
            .map(Some)
            .context("ICARUS_ENC_KEY must be base64 for exactly 32 bytes"),
        _ => {
            tracing::warn!("ICARUS_ENC_KEY is not set; webhook hooks are unavailable");
            Ok(None)
        }
    }
}

/// APNs needs all four `APNS_*` values. Anything missing means log-only (PLAN.md §12.5).
fn sender_from_env() -> anyhow::Result<AnySender> {
    let key = std::env::var("APNS_KEY_P8")
        .ok()
        .filter(|v| !v.trim().is_empty());
    let key_id = std::env::var("APNS_KEY_ID")
        .ok()
        .filter(|v| !v.trim().is_empty());
    let team_id = std::env::var("APNS_TEAM_ID")
        .ok()
        .filter(|v| !v.trim().is_empty());
    let topic = std::env::var("APNS_TOPIC")
        .ok()
        .filter(|v| !v.trim().is_empty());
    let missing: Vec<&str> = [
        ("APNS_KEY_P8", key.is_none()),
        ("APNS_KEY_ID", key_id.is_none()),
        ("APNS_TEAM_ID", team_id.is_none()),
        ("APNS_TOPIC", topic.is_none()),
    ]
    .into_iter()
    .filter_map(|(name, absent)| absent.then_some(name))
    .collect();
    let (Some(key), Some(key_id), Some(team_id), Some(topic)) = (key, key_id, team_id, topic)
    else {
        if missing.len() < 4 {
            tracing::warn!(missing = ?missing, "APNs settings are incomplete");
        }
        LogOnlySender::announce();
        return Ok(AnySender::LogOnly(LogOnlySender));
    };
    // APNS_KEY_P8 holds the key itself or a path to the .p8 file.
    let key_pem = if key.trim_start().starts_with("-----BEGIN") {
        key.into_bytes()
    } else {
        std::fs::read(&key).context("reading the APNs key file named by APNS_KEY_P8")?
    };
    let settings = ApnsSettings {
        key_pem,
        key_id,
        team_id,
        topic,
    };
    let sender = ApnsSender::new(&settings).context("building the APNs clients")?;
    Ok(AnySender::Apns(Box::new(sender)))
}

async fn serve(pool: PgPool) -> anyhow::Result<()> {
    let bind = std::env::var("ICARUS_BIND").unwrap_or_else(|_| "0.0.0.0:8080".to_owned());
    let addr: SocketAddr = bind
        .parse()
        .with_context(|| format!("ICARUS_BIND is not a socket address: {bind}"))?;
    let config = Config {
        cookie_secure: !env_flag("ICARUS_INSECURE_COOKIES"),
        trust_proxy: env_flag("ICARUS_TRUST_PROXY"),
        public_base_url: std::env::var("PUBLIC_BASE_URL")
            .unwrap_or_else(|_| "http://localhost:8080".to_owned()),
        web_dir: Some(PathBuf::from(
            std::env::var("ICARUS_WEB_DIR").unwrap_or_else(|_| "../web/dist".to_owned()),
        )),
        secrets: secrets_from_env()?,
    };
    let sender = sender_from_env()?;

    // Partitions for this month and next, before traffic arrives. The daily job keeps them current.
    if let Err(err) = icarus_jobs::run_maintenance(&pool).await {
        tracing::error!(error = %err, "startup maintenance failed; inserts fall back to the default partitions");
    }
    icarus_jobs::spawn_daily(pool.clone());
    let dispatcher_pool = pool.clone();
    tokio::spawn(async move {
        if let Err(err) =
            icarus_push::dispatch::run(dispatcher_pool, sender, DispatchConfig::default()).await
        {
            tracing::error!(error = %err, "alarm dispatcher stopped");
        }
    });

    let listener = TcpListener::bind(addr)
        .await
        .with_context(|| format!("binding {addr}"))?;
    tracing::info!(service = icarus_core::SERVICE_NAME, %addr, "listening");

    axum::serve(
        listener,
        router(AppState::with_config(pool, config))
            .into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(shutdown_signal())
    .await
    .context("serving HTTP")?;

    tracing::info!(service = icarus_core::SERVICE_NAME, "stopped");
    Ok(())
}

async fn shutdown_signal() {
    let ctrl_c = async {
        signal::ctrl_c().await.expect("installing ctrl-c handler");
    };

    #[cfg(unix)]
    let terminate = async {
        signal::unix::signal(signal::unix::SignalKind::terminate())
            .expect("installing SIGTERM handler")
            .recv()
            .await;
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        () = ctrl_c => {},
        () = terminate => {},
    }
    tracing::info!("shutdown signal received");
}
