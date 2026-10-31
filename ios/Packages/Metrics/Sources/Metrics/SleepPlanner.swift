import Foundation

// SleepPlanner.swift: bedtimes that land on a sleep target, given tonight's need and the wake time.
//
// OUR HEURISTIC. The three targets are the percentages of need the WHOOP app shows (Peak 100 %,
// Perform 85 %, Get by 70 %). The arithmetic is ours:
//
//   time in bed = need x target / efficiency + latency
//   bedtime     = wake time - time in bed
//
// Efficiency is asleep / in bed, and latency is the time from lying down to the first asleep epoch. Both
// come from recent staged nights (median). Without any, the defaults below are used and `Timing.isDefault`
// is set, so the UI can say the plan is an estimate.
//
// Times are unix seconds. Durations are absolute, so a night that crosses a DST change keeps the right
// length. Wall-clock labels are the caller's job, in the profile's zone.

public enum SleepPlanner {
    /// The three sleep targets, as shares of tonight's need.
    public enum Target: String, CaseIterable, Sendable {
        case peak
        case perform
        case getBy

        /// Share of the need this target asks for.
        public var fraction: Double {
            switch self {
            case .peak: 1.0
            case .perform: 0.85
            case .getBy: 0.70
            }
        }

        /// The label the UI shows.
        public var label: String {
            switch self {
            case .peak: "Peak"
            case .perform: "Perform"
            case .getBy: "Get by"
            }
        }
    }

    /// Latency used when no recent night was staged: 15 min. A typical adult figure, not measured.
    public static let defaultLatencySec: Double = 15 * 60
    /// Efficiency used when no recent night was staged: 90 %. A typical adult figure, not measured.
    public static let defaultEfficiency: Double = 0.90
    /// Bounds on the measured efficiency, so one odd night cannot make the plan absurd.
    public static let efficiencyRange: ClosedRange<Double> = 0.50...1.00
    /// Bounds on the measured latency, in seconds.
    public static let latencyRange: ClosedRange<Double> = 0...(60 * 60)

    /// Typical sleep timing used for the plan.
    public struct Timing: Equatable, Sendable {
        public let latencySec: Double
        /// Asleep / in bed, 0.5 to 1.0.
        public let efficiency: Double
        /// True when the defaults were used, because no recent night gave a value.
        public let isDefault: Bool

        public init(latencySec: Double, efficiency: Double, isDefault: Bool) {
            self.latencySec = latencySec
            self.efficiency = efficiency
            self.isDefault = isDefault
        }
    }

    /// One planned bedtime.
    public struct Plan: Equatable, Sendable {
        public let target: Target
        /// Tonight's need the plan was built on, in seconds.
        public let needSec: Double
        /// Time in bed the target needs, in seconds.
        public let timeInBedSec: Int64
        /// Unix seconds to get into bed.
        public let bedtimeSec: Int64
    }

    /// Median of `values`, nil when empty. Public so the Store glue can share it.
    public static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Timing from recent nights. Each array holds one value per staged night. Empty arrays give the defaults.
    public static func timing(latenciesSec: [Double], efficiencies: [Double]) -> Timing {
        let latency = median(latenciesSec.filter { $0.isFinite && $0 >= 0 })
        let efficiency = median(efficiencies.filter { $0.isFinite && $0 > 0 && $0 <= 1 })
        return Timing(
            latencySec: latency.map { min(max($0, latencyRange.lowerBound), latencyRange.upperBound) } ?? defaultLatencySec,
            efficiency: efficiency.map { min(max($0, efficiencyRange.lowerBound), efficiencyRange.upperBound) } ?? defaultEfficiency,
            isDefault: latency == nil && efficiency == nil
        )
    }

    /// Time in bed, in seconds, for `needSec` at `target`.
    public static func timeInBedSec(needSec: Double, target: Target, timing: Timing) -> Int64 {
        let seconds = needSec * target.fraction / timing.efficiency + timing.latencySec
        return Int64(seconds.rounded())
    }

    /// The Peak, Perform and Get by bedtimes for a wake time, in that order. A non-positive need gives no plans.
    public static func plans(wakeSec: Int64, needSec: Double, timing: Timing) -> [Plan] {
        guard needSec > 0, needSec.isFinite else { return [] }
        return Target.allCases.map { target in
            let inBed = timeInBedSec(needSec: needSec, target: target, timing: timing)
            return Plan(
                target: target,
                needSec: needSec,
                timeInBedSec: inBed,
                bedtimeSec: wakeSec - inBed
            )
        }
    }
}
