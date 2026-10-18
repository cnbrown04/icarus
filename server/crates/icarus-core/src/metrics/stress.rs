//! Icarus Stress (PLAN.md 8.3). Our own model, explicitly not WHOOP's Stress Monitor.

use chrono_tz::Tz;
use libm::erfc;

use super::five_minute_windows::FiveMinuteWindow;
use super::heart_rate_zones;
use super::local_time::{self, LocalDay};
use super::statistics::{mad, median};

/// Scale that makes MAD a consistent sigma estimate for normal data.
pub const MAD_SCALE: f64 = 1.4826;
/// Calibration: at least this many qualifying days (PLAN.md 8.3).
pub const MIN_QUALIFYING_DAYS: usize = 7;
/// A day qualifies with at least this many night windows.
pub const MIN_NIGHT_WINDOWS_PER_DAY: usize = 12;
pub const LOOKBACK_DAYS: i64 = 14;

/// Stress state (PLAN.md 8.3). `as_str` gives the `stress_state` strings in PLAN.md 10.2.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StressState {
    Value,
    Calibrating,
    Exertion,
    Insufficient,
    HrOnly,
}

impl StressState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Value => "value",
            Self::Calibrating => "calibrating",
            Self::Exertion => "exertion",
            Self::Insufficient => "insufficient",
            Self::HrOnly => "hr_only",
        }
    }
}

/// Band for UI copy (PLAN.md 8.3): 0-33 low, 34-66 moderate, 67-100 high.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StressBand {
    Low,
    Moderate,
    High,
}

impl StressBand {
    pub fn of(stress: i64) -> Self {
        if stress <= 33 {
            Self::Low
        } else if stress <= 66 {
            Self::Moderate
        } else {
            Self::High
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StressResult {
    /// `None` unless `state` is `Value` or `HrOnly`.
    pub stress: Option<i64>,
    pub state: StressState,
}

/// Personal baselines from the 14 local days before the scored day (PLAN.md 8.3).
///
/// Night windows are those starting in [00:00, 06:00) local. Windows in exertion are excluded.
/// Two baselines exist. The R-R baseline uses valid windows and drives the value state.
/// The HR-only baseline uses every window with HR and drives the hr_only fallback.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StressBaseline {
    /// Days in the lookback with at least 12 valid night windows.
    pub valid_days: usize,
    pub hr_median: Option<f64>,
    pub hr_mad: Option<f64>,
    pub ln_rmssd_median: Option<f64>,
    pub ln_rmssd_mad: Option<f64>,
    /// Days in the lookback with at least 12 night windows that have HR.
    pub hr_only_days: usize,
    pub hr_only_median: Option<f64>,
    pub hr_only_mad: Option<f64>,
}

impl StressBaseline {
    /// Baseline for scoring windows on local `day`. The lookback is the 14 days before `day`.
    /// `day`'s own night is excluded, so a window is never scored against itself.
    pub fn build(
        windows: &[FiveMinuteWindow],
        day: LocalDay,
        tz: Tz,
        resting_hr: Option<f64>,
        max_hr: f64,
    ) -> Self {
        let mut valid_days = 0;
        let mut hr_only_days = 0;
        let mut rr_hr: Vec<f64> = Vec::new();
        let mut rr_ln_rmssd: Vec<f64> = Vec::new();
        let mut hr_only_hr: Vec<f64> = Vec::new();

        for offset in 1..=LOOKBACK_DAYS {
            let night = local_time::night_window(local_time::adding_days(-offset, day), tz);
            let night_windows: Vec<&FiveMinuteWindow> = windows
                .iter()
                .filter(|w| {
                    night.contains(&w.start_ms)
                        && !heart_rate_zones::is_exertion(w.hr_mean, resting_hr, max_hr)
                })
                .collect();
            let valid_nights: Vec<&FiveMinuteWindow> =
                night_windows.iter().copied().filter(|w| w.valid).collect();
            if valid_nights.len() >= MIN_NIGHT_WINDOWS_PER_DAY {
                valid_days += 1;
            }
            let hr_nights: Vec<f64> = night_windows.iter().filter_map(|w| w.hr_mean).collect();
            if hr_nights.len() >= MIN_NIGHT_WINDOWS_PER_DAY {
                hr_only_days += 1;
            }
            rr_hr.extend(valid_nights.iter().filter_map(|w| w.hr_mean));
            rr_ln_rmssd.extend(valid_nights.iter().filter_map(|w| w.ln_rmssd));
            hr_only_hr.extend(hr_nights);
        }

        Self {
            valid_days,
            hr_median: median(&rr_hr),
            hr_mad: mad(&rr_hr),
            ln_rmssd_median: median(&rr_ln_rmssd),
            ln_rmssd_mad: mad(&rr_ln_rmssd),
            hr_only_days,
            hr_only_median: median(&hr_only_hr),
            hr_only_mad: mad(&hr_only_hr),
        }
    }
}

/// Standard normal CDF, via erfc.
pub fn normal_cdf(z: f64) -> f64 {
    0.5 * erfc(-z / 2.0_f64.sqrt())
}

/// Robust z-score. The caller must check that `mad` is positive.
pub fn z_score(value: f64, median: f64, mad: f64) -> f64 {
    (value - median) / (MAD_SCALE * mad)
}

/// Scores one window (PLAN.md 8.3). Precedence: exertion, then calibrating, then insufficient.
///
/// - Valid R-R window: value = round(100 * Phi(0.5 z_HR - 0.5 z_HRV)). Needs the R-R baseline.
/// - No valid R-R: hr_only = round(100 * Phi(z_HR)). Needs the HR-only baseline.
/// - A zero MAD in a needed component is insufficient. The components are not dropped silently.
pub fn score(
    window: &FiveMinuteWindow,
    resting_hr: Option<f64>,
    max_hr: f64,
    baseline: &StressBaseline,
) -> StressResult {
    let result = |stress, state| StressResult { stress, state };
    if heart_rate_zones::is_exertion(window.hr_mean, resting_hr, max_hr) {
        return result(None, StressState::Exertion);
    }

    if window.valid {
        if baseline.valid_days < MIN_QUALIFYING_DAYS {
            return result(None, StressState::Calibrating);
        }
        let (
            Some(hr),
            Some(ln_rmssd),
            Some(hr_median),
            Some(hr_mad),
            Some(ln_median),
            Some(ln_mad),
        ) = (
            window.hr_mean,
            window.ln_rmssd,
            baseline.hr_median,
            baseline.hr_mad,
            baseline.ln_rmssd_median,
            baseline.ln_rmssd_mad,
        )
        else {
            return result(None, StressState::Insufficient);
        };
        if hr_mad <= 0.0 || ln_mad <= 0.0 {
            return result(None, StressState::Insufficient);
        }
        let z_hr = z_score(hr, hr_median, hr_mad);
        let z_hrv = z_score(ln_rmssd, ln_median, ln_mad);
        return result(Some(scaled(0.5 * z_hr - 0.5 * z_hrv)), StressState::Value);
    }

    if baseline.hr_only_days < MIN_QUALIFYING_DAYS {
        return result(None, StressState::Calibrating);
    }
    let (Some(hr), Some(median), Some(mad)) = (
        window.hr_mean,
        baseline.hr_only_median,
        baseline.hr_only_mad,
    ) else {
        return result(None, StressState::Insufficient);
    };
    if mad <= 0.0 {
        return result(None, StressState::Insufficient);
    }
    result(Some(scaled(z_score(hr, median, mad))), StressState::HrOnly)
}

fn scaled(raw: f64) -> i64 {
    (100.0 * normal_cdf(raw)).round() as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn window(hr: Option<f64>, valid: bool, ln_rmssd: Option<f64>) -> FiveMinuteWindow {
        FiveMinuteWindow {
            start_ms: 0,
            hr_mean: hr,
            rr_count: 0,
            rr_sum_ms: 0.0,
            valid,
            rmssd: None,
            sdnn: None,
            ln_rmssd,
            baevsky_sqrt: None,
        }
    }

    fn full_baseline(hr_mad: f64, ln_mad: f64) -> StressBaseline {
        StressBaseline {
            valid_days: 7,
            hr_median: Some(60.0),
            hr_mad: Some(hr_mad),
            ln_rmssd_median: Some(3.4),
            ln_rmssd_mad: Some(ln_mad),
            hr_only_days: 7,
            hr_only_median: Some(60.0),
            hr_only_mad: Some(hr_mad),
        }
    }

    #[test]
    fn zero_mad_is_insufficient_not_a_division_by_zero() {
        let result = score(
            &window(Some(61.0), true, Some(3.45)),
            Some(60.0),
            180.0,
            &full_baseline(0.0, 0.06),
        );
        assert_eq!(
            result,
            StressResult {
                stress: None,
                state: StressState::Insufficient
            }
        );
    }

    #[test]
    fn empty_history_is_calibrating() {
        let baseline = StressBaseline::build(
            &[],
            LocalDay {
                year: 2026,
                month: 10,
                day: 8,
            },
            chrono_tz::America::Chicago,
            Some(60.0),
            180.0,
        );
        assert_eq!(baseline.valid_days, 0);
        assert_eq!(baseline.hr_median, None);
        assert_eq!(baseline.hr_mad, None);
        let result = score(
            &window(Some(61.0), false, None),
            Some(60.0),
            180.0,
            &baseline,
        );
        assert_eq!(result.state, StressState::Calibrating);
        assert_eq!(result.stress, None);
    }
}
