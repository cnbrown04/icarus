import Foundation

// HealthMonitor.swift: nightly vitals against the user's own recent range (the Health Monitor).
//
// Pure statistics. Store gathers the nightly values (main sleep per local day) and passes them here.
// A range is the 30-night median with a typical band of median ± 1.4826 · MAD, widened to a minimum
// half-width so a very steady history does not flag ordinary nights. Labelled as a personal range,
// not a clinical reference range.

public enum HealthMonitor {

    /// One nightly vital the monitor tracks.
    public enum Vital: String, CaseIterable, Sendable, Equatable {
        /// Resting heart rate, bpm.
        case restingHR
        /// Nightly RMSSD, ms.
        case hrv
        /// Respiratory rate, breaths/min.
        case respiratoryRate
        /// Nightly skin temperature in raw counts (frame 76, `SkinTemperature.nightly`). Relative only: it is
        /// judged against the user's own range and never shown as degrees.
        case skinTemp
    }

    /// Nights before the day that form the range.
    public static let baselineNights = 30
    /// Fewest nights with a value before a range is shown. Below this a vital is `calibrating`.
    public static let minimumNights = 7
    /// MAD to sigma for a normal distribution.
    static let madToSigma = 1.4826

    /// Smallest half-width of the typical band, in the vital's own unit.
    public static func minimumHalfWidth(for vital: Vital) -> Double {
        switch vital {
        case .restingHR: 2
        case .hrv: 5
        case .respiratoryRate: 1
        // Counts. Nights vary by about ±7 (1.4826·MAD over the first 8 nights); a half-width under 5 would flag
        // ordinary nights.
        case .skinTemp: 5
        }
    }

    /// A personal range for one vital.
    public struct Baseline: Sendable, Equatable {
        public let vital: Vital
        /// Nights with a value in the window.
        public let nights: Int
        /// The reference value: the median of the nights.
        public let center: Double
        /// Lower edge of the typical band.
        public let low: Double
        /// Upper edge of the typical band.
        public let high: Double
    }

    /// Median of `values`, or nil when empty. Shared by the range and the Health screens' 30-day comparisons.
    public static func median(_ values: [Double]) -> Double? {
        Statistics.median(values)
    }

    /// Builds the range from the nightly values in the window (order irrelevant). Nil when fewer than
    /// `minimumNights` values are present.
    public static func baseline(for vital: Vital, nightly values: [Double]) -> Baseline? {
        guard values.count >= minimumNights, let median = Statistics.median(values),
              let mad = Statistics.mad(values) else { return nil }
        let center = median
        let halfWidth = max(minimumHalfWidth(for: vital), madToSigma * mad)
        return Baseline(
            vital: vital,
            nights: values.count,
            center: center,
            low: center - halfWidth,
            high: center + halfWidth
        )
    }

    /// Where tonight sits against the range.
    public enum State: Sendable, Equatable {
        case inRange
        case above
        case below
        /// The range exists but this night has no value.
        case noTonight
        /// Too few nights for a range.
        case calibrating
    }

    /// One vital's tonight value against its range.
    public struct Status: Sendable, Equatable, Identifiable {
        public let vital: Vital
        public let tonight: Double?
        /// Nil while calibrating.
        public let baseline: Baseline?
        public let state: State

        public var id: Vital { vital }

        /// Tonight minus the range's reference value. Nil without both a value and a range.
        public var deviation: Double? {
            guard let tonight, let baseline else { return nil }
            return tonight - baseline.center
        }
    }

    /// One status per vital, in `Vital.allCases` order. A vital is evaluated when it has both a range and a
    /// value for tonight. Missing or calibrating vitals are not counted by `summary(_:)`.
    public static func evaluate(tonight: [Vital: Double], baseline: [Vital: Baseline]) -> [Status] {
        Vital.allCases.map { vital in
            guard let range = baseline[vital] else {
                return Status(vital: vital, tonight: tonight[vital], baseline: nil, state: .calibrating)
            }
            guard let value = tonight[vital] else {
                return Status(vital: vital, tonight: nil, baseline: range, state: .noTonight)
            }
            let state: State
            if value < range.low {
                state = .below
            } else if value > range.high {
                state = .above
            } else {
                state = .inRange
            }
            return Status(vital: vital, tonight: value, baseline: range, state: state)
        }
    }

    /// "x of n in range": `evaluated` counts the statuses with a range and a value, `inRange` the in-range ones.
    public struct Summary: Sendable, Equatable {
        public let inRange: Int
        public let evaluated: Int

        public init(inRange: Int, evaluated: Int) {
            self.inRange = inRange
            self.evaluated = evaluated
        }
    }

    public static func summary(_ statuses: [Status]) -> Summary {
        let evaluated = statuses.filter { $0.state == .inRange || $0.state == .above || $0.state == .below }
        return Summary(inRange: evaluated.filter { $0.state == .inRange }.count, evaluated: evaluated.count)
    }
}
