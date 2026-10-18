//! Resting heart rate per local night (PLAN.md 8.1). A proxy until sleep detection exists.

use std::collections::BTreeMap;
use std::ops::Range;

use chrono_tz::Tz;

use super::local_time::{self, LocalDay, MS_PER_MINUTE};
use super::minute_aggregation::MinuteAggregate;

pub const WINDOW_MINUTES: i64 = 5;
/// Every minute in the run must have coverage >= 0.8 (at least 48 of 60 samples).
pub const MIN_COVERAGE: f64 = 0.8;

/// Lowest mean of `hr_avg` over 5 consecutive minutes.
///
/// Each minute must lie inside `range` and have coverage >= 0.8. Windows slide one minute at a
/// time, so they are not aligned to 5-minute boundaries. Minutes absent from `minutes` break a run.
/// `None` when no run qualifies.
pub fn lowest_window_mean(minutes: &[MinuteAggregate], range: Range<i64>) -> Option<f64> {
    let mut eligible: BTreeMap<i64, f64> = BTreeMap::new();
    for minute in minutes {
        if range.contains(&minute.minute_ms) && minute.coverage() >= MIN_COVERAGE {
            eligible.insert(minute.minute_ms, minute.hr_avg);
        }
    }
    let mut lowest: Option<f64> = None;
    for &start in eligible.keys() {
        let keys: Vec<i64> = (0..WINDOW_MINUTES)
            .map(|k| start + k * MS_PER_MINUTE)
            .collect();
        if keys.iter().any(|key| !eligible.contains_key(key)) {
            continue;
        }
        let sum = keys.iter().fold(0.0, |acc, key| acc + eligible[key]);
        let mean = sum / WINDOW_MINUTES as f64;
        lowest = Some(lowest.map_or(mean, |current| current.min(mean)));
    }
    lowest
}

/// RHR for the local night of `day`, 00:00 to 06:00 in `tz`.
pub fn for_night(day: LocalDay, minutes: &[MinuteAggregate], tz: Tz) -> Option<f64> {
    lowest_window_mean(minutes, local_time::night_window(day, tz))
}
