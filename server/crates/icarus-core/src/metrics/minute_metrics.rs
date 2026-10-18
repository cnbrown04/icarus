//! One `minute_metric` row per UTC minute (PLAN.md 10.2), built from samples and R-R.

use std::collections::BTreeMap;
use std::ops::Range;

use super::algo_version::AlgoVersion;
use super::calories::{self, UserProfile};
use super::five_minute_windows::{self, FiveMinuteWindow};
use super::local_time::{MS_PER_MINUTE, MS_PER_WINDOW, round_down, round_up, starts};
use super::minute_aggregation::{self, MinuteAggregate};
use super::samples::{HeartRateSample, RRSample};
use super::stress::{self, StressBaseline, StressResult, StressState};

/// One row of the `minute_metric` table (PLAN.md 10.2), without the store-only columns
/// `computed_at` and `sync_rev`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MinuteMetric {
    pub minute_ms: i64,
    pub hr_avg: Option<f64>,
    pub hr_min: Option<i64>,
    pub hr_max: Option<i64>,
    pub hr_n: usize,
    pub rmssd_ms: Option<f64>,
    pub sdnn_ms: Option<f64>,
    pub baevsky_sqrt: Option<f64>,
    pub stress: Option<i64>,
    pub stress_state: StressState,
    pub kcal: f64,
    pub active_kcal: f64,
    pub kcal_estimated: bool,
    /// TODO(PLAN.md 10.2 vs 8.5): the table has one `algo_version` column, but 8.5 versions each
    /// family. The store must decide how to encode this.
    pub algo_version: AlgoVersion,
}

/// Inputs that are the same for every minute in a calculation.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MinuteMetricsContext {
    pub profile: UserProfile,
    /// `None` until a night's RHR exists. Kcal then uses the HR_flex floor of 90 bpm.
    pub resting_hr: Option<f64>,
    pub max_hr: f64,
    pub baseline: StressBaseline,
}

pub struct MinuteMetricsCalculator;

impl MinuteMetricsCalculator {
    /// HR_flex used when RHR is unknown. This is the floor of the PLAN.md 8.4 formula.
    pub const FALLBACK_HEART_RATE_FLEX: f64 = 90.0;

    /// One row per UTC minute in `range`. `range` must be minute-aligned.
    ///
    /// HRV and stress come from the 5-minute window that contains the minute.
    /// Kcal comes from the minute's own hr_avg. A minute with no HR is charged BMR and marked estimated.
    /// `rr` must be accepted intervals in arrival order.
    pub fn rows(
        range: Range<i64>,
        samples: &[HeartRateSample],
        rr: &[RRSample],
        context: &MinuteMetricsContext,
    ) -> Vec<MinuteMetric> {
        let minutes: BTreeMap<i64, MinuteAggregate> = minute_aggregation::aggregate(samples)
            .into_iter()
            .map(|minute| (minute.minute_ms, minute))
            .collect();
        let window_range =
            round_down(range.start, MS_PER_WINDOW)..round_up(range.end, MS_PER_WINDOW);

        let mut scores: BTreeMap<i64, StressResult> = BTreeMap::new();
        let mut hrv_by_start: BTreeMap<i64, FiveMinuteWindow> = BTreeMap::new();
        for window in five_minute_windows::build(samples, rr, window_range) {
            hrv_by_start.insert(window.start_ms, window);
            scores.insert(
                window.start_ms,
                stress::score(
                    &window,
                    context.resting_hr,
                    context.max_hr,
                    &context.baseline,
                ),
            );
        }

        let heart_rate_flex = context
            .resting_hr
            .map_or(Self::FALLBACK_HEART_RATE_FLEX, |resting_hr| {
                calories::heart_rate_flex(resting_hr, context.max_hr)
            });

        starts(range.start, range.end, MS_PER_MINUTE)
            .into_iter()
            .map(|minute_ms| {
                let minute = minutes.get(&minute_ms);
                let window_start = round_down(minute_ms, MS_PER_WINDOW);
                let window = hrv_by_start.get(&window_start);
                let stress = scores.get(&window_start).copied().unwrap_or(StressResult {
                    stress: None,
                    state: StressState::Insufficient,
                });
                let energy = calories::minute_energy_with_flex(
                    minute.map(|m| m.hr_avg),
                    &context.profile,
                    heart_rate_flex,
                );
                MinuteMetric {
                    minute_ms,
                    hr_avg: minute.map(|m| m.hr_avg),
                    hr_min: minute.map(|m| m.hr_min),
                    hr_max: minute.map(|m| m.hr_max),
                    hr_n: minute.map_or(0, |m| m.hr_n),
                    rmssd_ms: window.and_then(|w| w.rmssd),
                    sdnn_ms: window.and_then(|w| w.sdnn),
                    baevsky_sqrt: window.and_then(|w| w.baevsky_sqrt),
                    stress: stress.stress,
                    stress_state: stress.state,
                    kcal: energy.kcal,
                    active_kcal: energy.active_kcal,
                    kcal_estimated: energy.estimated,
                    algo_version: AlgoVersion::CURRENT,
                }
            })
            .collect()
    }
}
