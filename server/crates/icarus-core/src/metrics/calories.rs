//! Energy expenditure (PLAN.md 8.4). Mifflin-St Jeor at rest, Keytel et al. (2005) without VO2max when active.

/// Formula sex. Both published equations need a binary sex input (PLAN.md 8.4).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FormulaSex {
    Male,
    Female,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct UserProfile {
    pub sex: FormulaSex,
    pub age_years: i64,
    pub height_cm: f64,
    pub weight_kg: f64,
}

/// One minute of energy use (PLAN.md 8.4, per-minute rule).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MinuteEnergy {
    /// Total kcal for the minute, never below the resting rate.
    pub kcal: f64,
    /// kcal above the resting rate, never negative.
    pub active_kcal: f64,
    /// True when there was no heart rate sample for the minute.
    pub estimated: bool,
}

/// Mifflin-St Jeor basal metabolic rate per day, kcal.
pub fn mifflin_bmr_per_day(profile: &UserProfile) -> f64 {
    let base = 10.0 * profile.weight_kg + 6.25 * profile.height_cm - 5.0 * profile.age_years as f64;
    match profile.sex {
        FormulaSex::Male => base + 5.0,
        FormulaSex::Female => base - 161.0,
    }
}

pub fn mifflin_bmr_per_minute(profile: &UserProfile) -> f64 {
    mifflin_bmr_per_day(profile) / 1440.0
}

/// Keytel et al. (2005) without VO2max, energy expenditure in kJ per minute.
pub fn keytel_kj_per_minute(profile: &UserProfile, heart_rate: f64) -> f64 {
    let weight = profile.weight_kg;
    let age = profile.age_years as f64;
    match profile.sex {
        FormulaSex::Male => -55.0969 + 0.6309 * heart_rate + 0.1988 * weight + 0.2017 * age,
        FormulaSex::Female => -20.4022 + 0.4472 * heart_rate - 0.1263 * weight + 0.074 * age,
    }
}

/// Keytel kJ per minute converted to kcal per minute (1 kcal = 4.184 kJ).
pub fn keytel_kcal_per_minute(profile: &UserProfile, heart_rate: f64) -> f64 {
    keytel_kj_per_minute(profile, heart_rate) / 4.184
}

/// HR_flex = max(90, RHR + 0.30 * (HRmax - RHR)). Below this, Keytel is not used.
pub fn heart_rate_flex(resting_hr: f64, max_hr: f64) -> f64 {
    f64::max(90.0, resting_hr + 0.30 * (max_hr - resting_hr))
}

/// Per-minute kcal rule (PLAN.md 8.4). Below HR_flex, or with no heart rate, the minute is charged
/// at the resting rate.
pub fn minute_energy(
    heart_rate: Option<f64>,
    profile: &UserProfile,
    resting_hr: f64,
    max_hr: f64,
) -> MinuteEnergy {
    minute_energy_with_flex(heart_rate, profile, heart_rate_flex(resting_hr, max_hr))
}

/// Per-minute kcal rule with HR_flex already resolved.
pub fn minute_energy_with_flex(
    heart_rate: Option<f64>,
    profile: &UserProfile,
    flex: f64,
) -> MinuteEnergy {
    let bmr_minute = mifflin_bmr_per_minute(profile);
    let Some(heart_rate) = heart_rate else {
        return MinuteEnergy {
            kcal: bmr_minute,
            active_kcal: 0.0,
            estimated: true,
        };
    };
    let kcal = if heart_rate >= flex {
        f64::max(bmr_minute, keytel_kcal_per_minute(profile, heart_rate))
    } else {
        bmr_minute
    };
    MinuteEnergy {
        kcal,
        active_kcal: f64::max(0.0, kcal - bmr_minute),
        estimated: false,
    }
}
