//! HRmax, heart-rate reserve and display zones (PLAN.md 8.1).

/// Exertion gate on HRR% (PLAN.md 8.2 step 4). HRR% is a fraction, so 0.40 means 40%.
pub const EXERTION_THRESHOLD: f64 = 0.40;

/// Tanaka 208 - 0.7 * age. The original paper was not fetched, so the citation is [Unverified].
pub fn tanaka_max_hr(age_years: i64) -> f64 {
    208.0 - 0.7 * age_years as f64
}

/// User-entered HRmax wins. Otherwise Tanaka.
pub fn max_hr(user_entered: Option<i64>, age_years: i64) -> f64 {
    match user_entered {
        Some(value) => value as f64,
        None => tanaka_max_hr(age_years),
    }
}

/// HRR% as a fraction: (hr - rhr) / (hr_max - rhr). `None` when the reserve is not positive.
pub fn hrr_fraction(hr: f64, resting_hr: f64, max_hr: f64) -> Option<f64> {
    let reserve = max_hr - resting_hr;
    if reserve <= 0.0 {
        return None;
    }
    Some((hr - resting_hr) / reserve)
}

/// True when HRR% is above the exertion threshold. Unknown inputs are not exertion.
pub fn is_exertion(hr: Option<f64>, resting_hr: Option<f64>, max_hr: f64) -> bool {
    let (Some(hr), Some(resting_hr)) = (hr, resting_hr) else {
        return false;
    };
    hrr_fraction(hr, resting_hr, max_hr).is_some_and(|fraction| fraction > EXERTION_THRESHOLD)
}

/// Karvonen zones: lower bounds 50, 60, 70, 80 and 90 % of HRR. Lower bounds are inclusive.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HeartRateZone {
    Below,
    Zone1,
    Zone2,
    Zone3,
    Zone4,
    Zone5,
}

impl HeartRateZone {
    pub fn of_hrr_fraction(fraction: f64) -> Self {
        if fraction < 0.5 {
            Self::Below
        } else if fraction < 0.6 {
            Self::Zone1
        } else if fraction < 0.7 {
            Self::Zone2
        } else if fraction < 0.8 {
            Self::Zone3
        } else if fraction < 0.9 {
            Self::Zone4
        } else {
            Self::Zone5
        }
    }
}
