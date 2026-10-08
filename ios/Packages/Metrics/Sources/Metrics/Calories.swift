/// Formula sex. Both published equations need a binary sex input (PLAN.md 8.4).
public enum FormulaSex: Sendable, Equatable {
    case male
    case female
}

public struct UserProfile: Sendable, Equatable {
    public let sex: FormulaSex
    public let ageYears: Int
    public let heightCm: Double
    public let weightKg: Double

    public init(sex: FormulaSex, ageYears: Int, heightCm: Double, weightKg: Double) {
        self.sex = sex
        self.ageYears = ageYears
        self.heightCm = heightCm
        self.weightKg = weightKg
    }
}

/// One minute of energy use (PLAN.md 8.4, per-minute rule).
public struct MinuteEnergy: Sendable, Equatable {
    /// Total kcal for the minute, never below the resting rate.
    public let kcal: Double
    /// kcal above the resting rate, never negative.
    public let activeKcal: Double
    /// True when there was no heart rate sample for the minute.
    public let estimated: Bool
}

public enum Calories {
    /// Mifflin-St Jeor basal metabolic rate per day, kcal.
    public static func mifflinBMRPerDay(_ profile: UserProfile) -> Double {
        let base = 10 * profile.weightKg + 6.25 * profile.heightCm - 5 * Double(profile.ageYears)
        switch profile.sex {
        case .male: return base + 5
        case .female: return base - 161
        }
    }

    public static func mifflinBMRPerMinute(_ profile: UserProfile) -> Double {
        mifflinBMRPerDay(profile) / 1440
    }

    /// Keytel et al. (2005) without VO2max, energy expenditure in kJ per minute.
    public static func keytelKJPerMinute(_ profile: UserProfile, heartRate: Double) -> Double {
        let weight = profile.weightKg
        let age = Double(profile.ageYears)
        switch profile.sex {
        case .male:
            return -55.0969 + 0.6309 * heartRate + 0.1988 * weight + 0.2017 * age
        case .female:
            return -20.4022 + 0.4472 * heartRate - 0.1263 * weight + 0.074 * age
        }
    }

    /// Keytel kJ per minute converted to kcal per minute (1 kcal = 4.184 kJ).
    public static func keytelKcalPerMinute(_ profile: UserProfile, heartRate: Double) -> Double {
        keytelKJPerMinute(profile, heartRate: heartRate) / 4.184
    }

    /// HR_flex = max(90, RHR + 0.30 * (HRmax - RHR)). Below this, Keytel is not used.
    public static func heartRateFlex(restingHR: Double, maxHR: Double) -> Double {
        max(90, restingHR + 0.30 * (maxHR - restingHR))
    }

    /// Per-minute kcal rule (PLAN.md 8.4).
    /// Below HR_flex, or with no heart rate, the minute is charged at the resting rate.
    public static func minuteEnergy(
        heartRate: Double?,
        profile: UserProfile,
        restingHR: Double,
        maxHR: Double
    ) -> MinuteEnergy {
        let bmrMinute = mifflinBMRPerMinute(profile)
        guard let heartRate else {
            return MinuteEnergy(kcal: bmrMinute, activeKcal: 0, estimated: true)
        }
        let flex = heartRateFlex(restingHR: restingHR, maxHR: maxHR)
        let kcal: Double
        if heartRate >= flex {
            kcal = max(bmrMinute, keytelKcalPerMinute(profile, heartRate: heartRate))
        } else {
            kcal = bmrMinute
        }
        return MinuteEnergy(kcal: kcal, activeKcal: max(0, kcal - bmrMinute), estimated: false)
    }
}
