//! 5-minute windows of heart rate and R-R (PLAN.md 8.2 step 3, 8.3).

use std::collections::BTreeMap;
use std::ops::Range;

use super::baevsky;
use super::hrv;
use super::local_time::{MS_PER_WINDOW, round_down, round_up, starts};
use super::samples::{HeartRateSample, RRSample, SensorContact};

/// One 5-minute window. HRV fields are `None` unless `valid`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FiveMinuteWindow {
    /// Window start, epoch ms UTC, aligned to 5 minutes.
    pub start_ms: i64,
    /// Mean bpm of samples in the window, excluding contact `NotDetected`. `None` when there are none.
    pub hr_mean: Option<f64>,
    pub rr_count: usize,
    /// Sum of accepted R-R intervals in ms.
    pub rr_sum_ms: f64,
    /// True when the accepted R-R sum is at least 60% of 300 s.
    pub valid: bool,
    pub rmssd: Option<f64>,
    pub sdnn: Option<f64>,
    pub ln_rmssd: Option<f64>,
    pub baevsky_sqrt: Option<f64>,
}

/// 0.6 * 300 s (PLAN.md 8.2 step 3).
pub const MIN_VALID_RR_SUM_MS: f64 = 180_000.0;

/// Builds every window whose start lies in `range` (half-open). Starts are aligned to 5 minutes.
///
/// An R-R interval belongs to the window containing its `ts_ms`. `rr` must be the accepted
/// intervals in arrival order.
pub fn build(
    samples: &[HeartRateSample],
    rr: &[RRSample],
    range: Range<i64>,
) -> Vec<FiveMinuteWindow> {
    // Per window start: (sum of bpm, sample count).
    let mut hr_by_start: BTreeMap<i64, (f64, usize)> = BTreeMap::new();
    for sample in samples {
        if sample.contact == Some(SensorContact::NotDetected) {
            continue;
        }
        let entry = hr_by_start
            .entry(round_down(sample.ts_ms, MS_PER_WINDOW))
            .or_insert((0.0, 0));
        entry.0 += sample.bpm as f64;
        entry.1 += 1;
    }
    let mut rr_by_start: BTreeMap<i64, Vec<f64>> = BTreeMap::new();
    for interval in rr {
        rr_by_start
            .entry(round_down(interval.ts_ms, MS_PER_WINDOW))
            .or_default()
            .push(interval.rr_ms);
    }

    starts(
        round_up(range.start, MS_PER_WINDOW),
        range.end,
        MS_PER_WINDOW,
    )
    .into_iter()
    .map(|start_ms| {
        let values: &[f64] = rr_by_start.get(&start_ms).map_or(&[], Vec::as_slice);
        let rr_sum_ms = values.iter().fold(0.0, |acc, v| acc + v);
        let valid = rr_sum_ms >= MIN_VALID_RR_SUM_MS;
        FiveMinuteWindow {
            start_ms,
            hr_mean: hr_by_start.get(&start_ms).map(|(sum, n)| sum / *n as f64),
            rr_count: values.len(),
            rr_sum_ms,
            valid,
            rmssd: if valid { hrv::rmssd(values) } else { None },
            sdnn: if valid { hrv::sdnn(values) } else { None },
            ln_rmssd: if valid { hrv::ln_rmssd(values) } else { None },
            baevsky_sqrt: if valid {
                baevsky::sqrt_stress_index(values)
            } else {
                None
            },
        }
    })
    .collect()
}
