//! Alarm delivery to the phone: APNs sender, log-only fallback and the dispatcher (PLAN.md §9.3, §12.5).

pub mod apns;
pub mod dispatch;
pub mod sender;

pub use apns::{AnySender, ApnsSender, ApnsSettings, LogOnlySender};
pub use dispatch::Config as DispatchConfig;
pub use sender::{Alert, Background, Environment, Outcome, PushError, PushSender, Target};
