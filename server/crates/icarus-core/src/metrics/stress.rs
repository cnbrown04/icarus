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
/// A day qualifies for the R-R baseline with at least this many valid awake windows (1 h of 5-minute windows).
pub const MIN_AWAKE_RR_WINDOWS_PER_DAY: usize = 12;
/// A day qualifies for the HR-only baseline with at least this many awake windows that have HR (2 h).
pub const MIN_AWAKE_WINDOWS_PER_DAY: usize = 24;
pub const LOOKBACK_DAYS: i64 = 14;
/// Floor on the HR sigma, in bpm. A steady baseline has MAD 0, which would make any deviation infinitely
/// large.
pub const HR_SIGMA_FLOOR: f64 = 4.0;
/// Floor on the ln(RMSSD) sigma (about 16 % of RMSSD), for the same reason as `HR_SIGMA_FLOOR`.
pub const LN_RMSSD_SIGMA_FLOOR: f64 = 0.15;
/// Shifts the scale so the median awake window scores about 33, the top of Low (PLAN.md 8.3).
/// Raw scores are z-based, so a raw score of 0 is the baseline median. Phi(-0.44) is about 0.33.
pub const CENTER_OFFSET: f64 = -0.44;

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

/// Personal baselines from the awake windows of the 14 local days before the scored day (PLAN.md 8.3).
///
/// A lookback day's windows start inside that local day, outside its sleep and outside exertion.
/// The Rust core has no sleep sessions, so the sleep that touches a day is its 00:00-06:00 fallback
/// night, on that morning and the next. A day qualifies for the R-R baseline with
/// `MIN_AWAKE_RR_WINDOWS_PER_DAY` valid windows, and for the HR-only baseline with `MIN_AWAKE_WINDOWS_PER_DAY`.
/// The Rust core has no medication data, so it never builds the Swift medicated or unmedicated baselines.
/// Two baselines exist. The R-R baseline uses valid windows and drives the value state.
/// The HR-only baseline uses every window with HR and drives the hr_only fallback.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StressBaseline {
    /// Days in the lookback with at least `MIN_AWAKE_WINDOWS_PER_DAY` valid awake windows.
    pub valid_days: usize,
    pub hr_median: Option<f64>,
    pub hr_mad: Option<f64>,
    pub ln_rmssd_median: Option<f64>,
    pub ln_rmssd_mad: Option<f64>,
    /// Days in the lookback with at least `MIN_AWAKE_WINDOWS_PER_DAY` awake windows that have HR.
    pub hr_only_days: usize,
    pub hr_only_median: Option<f64>,
    pub hr_only_mad: Option<f64>,
}

impl StressBaseline {
    /// Baseline for scoring windows on local `day`. The lookback is the 14 days before `day`.
    /// `day` itself is excluded, so a window is never scored against itself.
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
            let lookback_day = local_time::adding_days(-offset, day);
            let day_start = local_time::local_time(lookback_day, 0, tz);
            let day_end = local_time::local_time(local_time::adding_days(1, lookback_day), 0, tz);
            let morning_sleep = local_time::night_window(lookback_day, tz);
            let next_day = local_time::adding_days(1, lookback_day);
            let evening_sleep = local_time::night_window(next_day, tz);
            let eligible: Vec<&FiveMinuteWindow> = windows
                .iter()
                .filter(|w| {
                    w.start_ms >= day_start
                        && w.start_ms < day_end
                        && !morning_sleep.contains(&w.start_ms)
                        && !evening_sleep.contains(&w.start_ms)
                        && !heart_rate_zones::is_exertion(w.hr_mean, resting_hr, max_hr)
                })
                .collect();
            let valid_windows: Vec<&FiveMinuteWindow> =
                eligible.iter().copied().filter(|w| w.valid).collect();
            if valid_windows.len() >= MIN_AWAKE_RR_WINDOWS_PER_DAY {
                valid_days += 1;
            }
            let hr_windows: Vec<f64> = eligible.iter().filter_map(|w| w.hr_mean).collect();
            if hr_windows.len() >= MIN_AWAKE_WINDOWS_PER_DAY {
                hr_only_days += 1;
            }
            rr_hr.extend(valid_windows.iter().filter_map(|w| w.hr_mean));
            rr_ln_rmssd.extend(valid_windows.iter().filter_map(|w| w.ln_rmssd));
            hr_only_hr.extend(hr_windows);
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

/// The sigma for a z-score: the scaled MAD, but never below `floor`.
pub fn sigma(mad: f64, floor: f64) -> f64 {
    (MAD_SCALE * mad).max(floor)
}

/// Robust z-score against a sigma from `sigma`.
pub fn z_score(value: f64, median: f64, sigma: f64) -> f64 {
    (value - median) / sigma
}

/// Scores one window (PLAN.md 8.3). Precedence: exertion, then calibrating, then insufficient.
///
/// - Valid R-R window: value = round(100 * Phi(0.5 z_HR - 0.5 z_HRV + CENTER_OFFSET)). Needs the
///   R-R baseline.
/// - No valid R-R: hr_only = round(100 * Phi(0.5 z_HR + CENTER_OFFSET)). Needs the HR-only baseline.
/// - Insufficient only when a needed input or baseline median is missing. Sigma floors cover a zero
///   MAD.
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

    // The R-R path needs a valid window and a ready R-R baseline (enough days and all four medians). A valid
    // window whose R-R baseline is not ready is scored on the HR-only path instead, as the Swift core does.
    let rr_ready = baseline.valid_days >= MIN_QUALIFYING_DAYS
        && baseline.hr_median.is_some()
        && baseline.hr_mad.is_some()
        && baseline.ln_rmssd_median.is_some()
        && baseline.ln_rmssd_mad.is_some();
    if window.valid && rr_ready {
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
        let z_hr = z_score(hr, hr_median, sigma(hr_mad, HR_SIGMA_FLOOR));
        let z_hrv = z_score(ln_rmssd, ln_median, sigma(ln_mad, LN_RMSSD_SIGMA_FLOOR));
        return result(Some(scaled(0.5 * z_hr - 0.5 * z_hrv)), StressState::Value);
    }

    // No valid R-R window, or the R-R baseline is not ready: the HR-only path.
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
    let z = z_score(hr, median, sigma(mad, HR_SIGMA_FLOOR));
    result(Some(scaled(0.5 * z)), StressState::HrOnly)
}

/// Maps a raw score to 0-100 with the centre offset (PLAN.md 8.3).
fn scaled(raw: f64) -> i64 {
    (100.0 * normal_cdf(raw + CENTER_OFFSET)).round() as i64
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
    fn zero_mad_uses_the_sigma_floor_instead_of_being_insufficient() {
        // sigma_HR = 4 (floor), z_HR = (61 - 60) / 4 = 0.25, z_HRV = 0.
        // raw = 0.125, Stress = round(100 * Phi(-0.315)) = 38.
        let result = score(
            &window(Some(61.0), true, Some(3.4)),
            Some(60.0),
            180.0,
            &full_baseline(0.0, 0.0),
        );
        assert_eq!(
            result,
            StressResult {
                stress: Some(38),
                state: StressState::Value
            }
        );
    }

    #[test]
    fn missing_rr_median_falls_back_to_hr_only() {
        // The R-R baseline lacks a median, so the valid window is scored on the HR-only path (Swift parity).
        // z = (61 - 60) / 4 = 0.25, raw = 0.125, Stress = 38.
        let mut baseline = full_baseline(1.0, 0.06);
        baseline.hr_median = None;
        let result = score(&window(Some(61.0), true, Some(3.45)), Some(60.0), 180.0, &baseline);
        assert_eq!(
            result,
            StressResult {
                stress: Some(38),
                state: StressState::HrOnly
            }
        );
    }

    #[test]
    fn short_rr_baseline_falls_back_to_hr_only_for_valid_windows() {
        // Six R-R days is short of seven, but the HR-only baseline has eight: the valid window is hr_only.
        let mut baseline = full_baseline(1.0, 0.06);
        baseline.valid_days = 6;
        baseline.hr_only_days = 8;
        let result = score(&window(Some(61.0), true, Some(3.45)), Some(60.0), 180.0, &baseline);
        assert_eq!(
            result,
            StressResult {
                stress: Some(38),
                state: StressState::HrOnly
            }
        );
    }

    #[test]
    fn short_rr_and_hr_only_baselines_stay_calibrating() {
        let mut baseline = full_baseline(1.0, 0.06);
        baseline.valid_days = 6;
        baseline.hr_only_days = 6;
        let result = score(&window(Some(61.0), true, Some(3.45)), Some(60.0), 180.0, &baseline);
        assert_eq!(
            result,
            StressResult {
                stress: None,
                state: StressState::Calibrating
            }
        );
    }

    #[test]
    fn median_window_scores_about_thirty_three() {
        // raw = 0, Phi(-0.44) = 0.330, Stress = 33.
        let result = score(
            &window(Some(60.0), true, Some(3.4)),
            Some(60.0),
            180.0,
            &full_baseline(1.0, 0.06),
        );
        assert_eq!(result.stress, Some(33));
    }

    #[test]
    fn hr_only_uses_half_the_z_score() {
        // z = (61 - 60) / 4 = 0.25, raw = 0.125, Stress = 38.
        let result = score(
            &window(Some(61.0), false, None),
            Some(60.0),
            180.0,
            &full_baseline(1.0, 0.06),
        );
        assert_eq!(
            result,
            StressResult {
                stress: Some(38),
                state: StressState::HrOnly
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
