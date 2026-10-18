/// HRmax, heart-rate reserve and display zones (PLAN.md 8.1).
public enum HeartRateZones {
    /// Exertion gate on HRR% (PLAN.md 8.2 step 4). HRR% is a fraction, so 0.40 means 40%.
    public static let exertionThreshold = 0.40

    /// Tanaka 208 - 0.7 * age. The original paper was not fetched, so the citation is [Unverified].
    public static func tanakaMaxHR(ageYears: Int) -> Double {
        208 - 0.7 * Double(ageYears)
    }

    /// User-entered HRmax wins. Otherwise Tanaka.
    public static func maxHR(userEntered: Int?, ageYears: Int) -> Double {
        userEntered.map(Double.init) ?? tanakaMaxHR(ageYears: ageYears)
    }

    /// HRR% as a fraction: (hr - rhr) / (hrMax - rhr). Nil when the reserve is not positive.
    public static func hrrFraction(hr: Double, restingHR: Double, maxHR: Double) -> Double? {
        let reserve = maxHR - restingHR
        guard reserve > 0 else { return nil }
        return (hr - restingHR) / reserve
    }

    /// True when HRR% is above the exertion threshold. Unknown inputs are not exertion.
    public static func isExertion(hr: Double?, restingHR: Double?, maxHR: Double) -> Bool {
        guard let hr, let restingHR, let fraction = hrrFraction(hr: hr, restingHR: restingHR, maxHR: maxHR) else {
            return false
        }
        return fraction > exertionThreshold
    }
}

/// Karvonen zones: lower bounds 50, 60, 70, 80 and 90 % of HRR. Lower bounds are inclusive.
public enum HeartRateZone: Sendable, Equatable {
    case below
    case zone1
    case zone2
    case zone3
    case zone4
    case zone5

    public static func of(hrrFraction fraction: Double) -> HeartRateZone {
        switch fraction {
        case ..<0.5: return .below
        case ..<0.6: return .zone1
        case ..<0.7: return .zone2
        case ..<0.8: return .zone3
        case ..<0.9: return .zone4
        default: return .zone5
        }
    }
}
