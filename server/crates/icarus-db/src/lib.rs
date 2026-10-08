//! Postgres access: pool setup, embedded migrations and the readiness check.

use std::time::Duration;

use sqlx::{
    PgPool,
    migrate::{MigrateError, Migrator},
    postgres::PgPoolOptions,
};

/// Migrations from `server/migrations`, embedded at compile time.
pub static MIGRATOR: Migrator = sqlx::migrate!("../../migrations");

/// Postgres error code for "relation does not exist".
const UNDEFINED_TABLE: &str = "42P01";

#[derive(Debug, thiserror::Error)]
pub enum ReadyError {
    #[error("database query failed: {0}")]
    Query(#[from] sqlx::Error),
    #[error("migrations not applied: {0:?}")]
    MigrationsPending(Vec<i64>),
}

pub async fn connect(url: &str) -> Result<PgPool, sqlx::Error> {
    PgPoolOptions::new()
        .max_connections(10)
        .acquire_timeout(Duration::from_secs(5))
        .connect(url)
        .await
}

pub async fn migrate(pool: &PgPool) -> Result<(), MigrateError> {
    MIGRATOR.run(pool).await
}

/// Succeeds when the database answers and every embedded migration is applied.
pub async fn check_ready(pool: &PgPool) -> Result<(), ReadyError> {
    sqlx::query("SELECT 1").execute(pool).await?;

    let applied: Vec<i64> =
        match sqlx::query_scalar("SELECT version FROM _sqlx_migrations WHERE success")
            .fetch_all(pool)
            .await
        {
            Ok(versions) => versions,
            // Fresh database: sqlx has not created its bookkeeping table yet.
            Err(sqlx::Error::Database(e)) if e.code().as_deref() == Some(UNDEFINED_TABLE) => {
                Vec::new()
            }
            Err(e) => return Err(e.into()),
        };

    let missing: Vec<i64> = MIGRATOR
        .iter()
        .map(|m| m.version)
        .filter(|v| !applied.contains(v))
        .collect();

    if missing.is_empty() {
        Ok(())
    } else {
        Err(ReadyError::MigrationsPending(missing))
    }
}
