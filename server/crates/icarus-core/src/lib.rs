//! Domain types shared by the server crates (api-contract.md, PLAN.md §9, §10).
//!
//! Serde shapes here are the wire format. Keep them in step with `shared/api-contract.md`.

pub mod alarm;
pub mod model;
pub mod time;

pub use alarm::{Alarm, AlarmKind, Channel, NamedRhythm, Rhythm, Schedule, Step};
pub use model::{AuthMode, Band, Device, Dispatch, DispatchStatus, FormulaSex, Hook, Me};

/// Service name used in logs.
pub const SERVICE_NAME: &str = "icarus-server";

/// Input that breaks a documented rule. The message is safe to return to clients.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{0}")]
pub struct ValidationError(pub String);

pub(crate) fn invalid<T>(msg: impl Into<String>) -> Result<T, ValidationError> {
    Err(ValidationError(msg.into()))
}
