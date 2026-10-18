//! The seam between the dispatcher and APNs. Tests use a recording implementation.

use std::future::Future;

use icarus_core::Rhythm;
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Environment {
    Sandbox,
    Production,
}

/// One registered device. `token` is the APNs token; it is never logged.
#[derive(Clone)]
pub struct Target {
    pub device_id: Uuid,
    pub token: String,
    pub environment: Environment,
}

impl std::fmt::Debug for Target {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Target")
            .field("device_id", &self.device_id)
            .field("environment", &self.environment)
            .finish_non_exhaustive()
    }
}

/// Time-sensitive alert with the dispatch id, so the app can ack it.
#[derive(Debug, Clone, PartialEq)]
pub struct Alert {
    pub dispatch_id: Uuid,
    pub title: String,
    pub body: String,
    pub rhythm: Rhythm,
}

/// Silent push. The app wakes to buzz the band (dispatch) or re-sync config (`config_changed`).
#[derive(Debug, Clone, PartialEq)]
pub struct Background {
    pub dispatch_id: Option<Uuid>,
    pub rhythm: Option<Rhythm>,
    pub config_changed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// APNs accepted the push.
    Accepted { apns_id: Option<String> },
    /// APNs is not configured. Nothing was sent, but the dispatch lifecycle still runs.
    Disabled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum PushError {
    /// APNs says the token is gone (410 or `Unregistered`). The token is deleted.
    #[error("device token is no longer registered")]
    Unregistered,
    /// Network failure, timeout, 429 or 5xx. Worth retrying.
    #[error("temporary push failure")]
    Retryable,
    /// Any other refusal. Retrying will not help.
    #[error("push rejected")]
    Rejected,
}

pub trait PushSender: Send + Sync {
    fn alert(
        &self,
        target: &Target,
        alert: &Alert,
    ) -> impl Future<Output = Result<Outcome, PushError>> + Send;

    fn background(
        &self,
        target: &Target,
        push: &Background,
    ) -> impl Future<Output = Result<Outcome, PushError>> + Send;
}
