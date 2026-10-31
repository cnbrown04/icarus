import Foundation

// StrainCoach.swift: the day-strain target band for the Strain Coach card.
//
// OUR HEURISTIC, not WHOOP's. WHOOP's Strain Coach model is proprietary. This maps the recovery colour
// band (`Recovery.band(for:)`, red below 34, yellow below 67, green otherwise) to a band on WHOOP's
// 0 to 21 Day Strain axis:
//
//   green  (>= 67)   14 to 18   "Push"
//   yellow (34-66)   10 to 14   "Maintain"
//   red    (< 34)     6 to 10   "Restore"
//   no usable recovery          10 to 14   "Calibrating", flagged so the UI can say so
//
// The bands are round numbers chosen for this app. They are not fitted to any data and are not validated
// against WHOOP's targets. The rule ignores yesterday's load on purpose; a later version can add it.

/// A day-strain target on WHOOP's 0 to 21 scale.
public struct StrainTarget: Equatable, Sendable {
    /// Lower edge of the band, inclusive.
    public let low: Double
    /// Upper edge of the band, inclusive.
    public let high: Double
    /// One word for the state: "Push", "Maintain", "Restore" or "Calibrating".
    public let label: String
    /// True when there was no usable recovery, so the band is the neutral default.
    public let isCalibrating: Bool
    /// The recovery band the target came from. Nil when calibrating.
    public let recoveryBand: Recovery.Band?
}

public enum StrainCoach {
    /// Top of WHOOP's Day Strain axis.
    public static let scaleMax: Double = 21

    /// The target for a recovery value. `recoveryPercent` is 0 to 100 (`Recovery.Score.score`). Nil means
    /// there is no usable recovery yet, and the neutral 10 to 14 band applies with `isCalibrating` set.
    public static func target(recoveryPercent: Double?) -> StrainTarget {
        guard let recoveryPercent, recoveryPercent.isFinite else {
            return StrainTarget(low: 10, high: 14, label: "Calibrating", isCalibrating: true, recoveryBand: nil)
        }
        let band = Recovery.band(for: recoveryPercent)
        switch band {
        case .green:
            return StrainTarget(low: 14, high: 18, label: "Push", isCalibrating: false, recoveryBand: band)
        case .yellow:
            return StrainTarget(low: 10, high: 14, label: "Maintain", isCalibrating: false, recoveryBand: band)
        case .red:
            return StrainTarget(low: 6, high: 10, label: "Restore", isCalibrating: false, recoveryBand: band)
        }
    }

    /// True when `strain` (0 to 21) has reached the band's lower edge.
    public static func hasReached(strain: Double, target: StrainTarget) -> Bool {
        strain >= target.low
    }
}

/// Fires once per local day, the first time day strain reaches the target during the session.
///
/// It only fires on a transition it observes. The first strain value seen each day is the starting point,
/// so a day that is already in the band when the app opens does not buzz. The caller persists `firedDay`
/// and passes it back in, so a relaunch on the same day does not buzz again.
public struct TargetBuzzGate: Equatable, Sendable {
    /// The day the gate is tracking.
    public private(set) var day: LocalDay?
    /// The last strain value observed on `day`.
    public private(set) var lastStrain: Double?
    /// The day a buzz was last sent, which may be from an earlier launch.
    public private(set) var firedDay: LocalDay?

    public init(firedDay: LocalDay? = nil) {
        self.firedDay = firedDay
    }

    /// Records one observation. Returns true when the caller should play the buzz now.
    public mutating func observe(strain: Double?, target: StrainTarget?, day observedDay: LocalDay) -> Bool {
        if day != observedDay {
            day = observedDay
            lastStrain = nil
        }
        let previous = lastStrain
        if let strain { lastStrain = strain }
        guard let strain, let target else { return false }
        if firedDay == observedDay { return false }
        guard let previous else { return false }
        let crossed = !StrainCoach.hasReached(strain: previous, target: target)
            && StrainCoach.hasReached(strain: strain, target: target)
        guard crossed else { return false }
        firedDay = observedDay
        return true
    }
}
