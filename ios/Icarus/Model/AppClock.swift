import Foundation

/// Wall clock, or the fixed instant from -IcarusNow in DEBUG UI-test runs.
struct AppClock: Sendable {
    let fixedNow: Date?

    var now: Date {
        fixedNow ?? Date()
    }

    /// Epoch milliseconds, the unit the store uses (PLAN.md 10.1).
    var nowMs: Int64 {
        Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
    }
}

extension Date {
    /// Date from epoch milliseconds.
    init(epochMs: Int64) {
        self.init(timeIntervalSince1970: Double(epochMs) / 1000)
    }
}
