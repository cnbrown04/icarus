//! Account creation for the `create-user` subcommand. There is no sign-up route (api-contract.md).

use sqlx::PgPool;
use uuid::Uuid;

use crate::auth::hash_password;

pub const MIN_PASSWORD_LEN: usize = 12;

#[derive(Debug, thiserror::Error)]
pub enum CreateUserError {
    #[error("the email address is not valid")]
    InvalidEmail,
    #[error("the password must be at least {MIN_PASSWORD_LEN} characters")]
    WeakPassword,
    #[error("a user with this email already exists")]
    EmailTaken,
    #[error("could not hash the password")]
    Hash,
    #[error("database error")]
    Db(#[from] sqlx::Error),
}

/// Inserts the single user and returns its id.
pub async fn create_user(
    pool: &PgPool,
    email: &str,
    password: &str,
) -> Result<Uuid, CreateUserError> {
    let email = email.trim();
    let valid_email = email.len() <= 254
        && !email.contains(char::is_whitespace)
        && email.split_once('@').is_some_and(|(local, domain)| {
            !local.is_empty()
                && domain.contains('.')
                && !domain.starts_with('.')
                && !domain.ends_with('.')
        });
    if !valid_email {
        return Err(CreateUserError::InvalidEmail);
    }
    if password.chars().count() < MIN_PASSWORD_LEN {
        return Err(CreateUserError::WeakPassword);
    }
    let hash = hash_password(password).map_err(|_| CreateUserError::Hash)?;
    let id = Uuid::now_v7();
    let result = sqlx::query("INSERT INTO users (id, email, password_hash) VALUES ($1, $2, $3)")
        .bind(id)
        .bind(email)
        .bind(hash)
        .execute(pool)
        .await;
    match result {
        Ok(_) => Ok(id),
        Err(sqlx::Error::Database(db)) if db.is_unique_violation() => {
            Err(CreateUserError::EmailTaken)
        }
        Err(err) => Err(CreateUserError::Db(err)),
    }
}
