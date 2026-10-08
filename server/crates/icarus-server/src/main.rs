use std::net::SocketAddr;

use anyhow::Context;
use icarus_api::{AppState, router};
use tokio::{net::TcpListener, signal};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .json()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    let database_url = std::env::var("DATABASE_URL").context("DATABASE_URL is not set")?;
    let bind = std::env::var("ICARUS_BIND").unwrap_or_else(|_| "0.0.0.0:8080".to_owned());
    let addr: SocketAddr = bind
        .parse()
        .with_context(|| format!("ICARUS_BIND is not a socket address: {bind}"))?;

    let pool = icarus_db::connect(&database_url)
        .await
        .context("connecting to Postgres")?;
    icarus_db::migrate(&pool)
        .await
        .context("running migrations")?;

    let listener = TcpListener::bind(addr)
        .await
        .with_context(|| format!("binding {addr}"))?;
    tracing::info!(service = icarus_core::SERVICE_NAME, %addr, "listening");

    axum::serve(listener, router(AppState::new(pool)))
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
