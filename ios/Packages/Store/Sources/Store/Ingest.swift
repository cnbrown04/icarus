import Foundation
import GRDB
import Metrics

/// Validates readings and cleans R-R before they reach the store (PLAN.md 7.3, 8.2).
///
/// `RRCleaner` judges a whole array, so the last accepted intervals carry over as a prefix to the next
/// notification. Re-judging that prefix can differ from the original decision in rare cases. The
/// tradeoff keeps the cleaning in Metrics instead of a second copy here.
public struct ReadingPreparer: Sendable {
    /// Physiological bpm range (PLAN.md 7.3). Readings outside it are dropped with their R-R.
    public static let bpmRange = 20...250

    private var recentAccepted: [Double] = []

    public init() {}

    /// Returns nil when the bpm is outside 20-250. Otherwise every R-R interval gets an accepted flag.
    public mutating func prepare(
        peripheralUUID: UUID,
        tsMs: Int64,
        bpm: Int,
        contact: SensorContact?,
        rrMs: [Double]
    ) -> Database.Reading? {
        guard Self.bpmRange.contains(bpm) else { return nil }
        let prefix = recentAccepted
        let flags = RRCleaner.acceptedFlags(prefix + rrMs).dropFirst(prefix.count)
        var intervals: [Database.Interval] = []
        intervals.reserveCapacity(rrMs.count)
        for (seq, (value, accepted)) in zip(rrMs, flags).enumerated() {
            intervals.append(Database.Interval(seq: seq, rrMs: value, accepted: accepted))
            if accepted {
                recentAccepted.append(value)
            }
        }
        if recentAccepted.count > RRCleaner.medianWindow {
            recentAccepted.removeFirst(recentAccepted.count - RRCleaner.medianWindow)
        }
        return Database.Reading(
            peripheralUUID: peripheralUUID,
            tsMs: tsMs,
            bpm: bpm,
            contact: contact.map { $0 == .detected },
            rr: intervals
        )
    }
}
