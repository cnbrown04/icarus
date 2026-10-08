//! Derived metrics, ported 1:1 from the Swift `Metrics` package (PLAN.md 8).
//!
//! Pure functions over f64 and epoch ms UTC, with no I/O. Both implementations run against
//! `shared/golden/metrics_v1.json`, so a formula change must update both.
//!
//! Swift enums used as namespaces (`HRV`, `Calories`, `Stress`, ...) become modules of free functions.

pub mod algo_version;
pub mod baevsky;
pub mod calories;
pub mod five_minute_windows;
pub mod heart_rate_zones;
pub mod hrv;
pub mod local_time;
pub mod minute_aggregation;
pub mod minute_metrics;
pub mod resting_hr;
pub mod rr_cleaner;
pub mod samples;
pub(crate) mod statistics;
pub mod stress;
