import Foundation

/// One stored sleep session as plain values, in epoch ms (Store's `sleep_session` row, reduced).
public struct SleepSpan: Sendable, Equatable {
    public let startMs: Int64
    public let endMs: Int64
    public let isNap: Bool

    public init(startMs: Int64, endMs: Int64, isNap: Bool) {
        self.startMs = startMs
        self.endMs = endMs
        self.isNap = isNap
    }
}

/// The night that belongs to each local day (PLAN.md 8.1, CONTEXT lesson 7).
///
/// For local day D the night is the main sleep whose END falls on D: the night you woke up from on D.
/// Naps never anchor a night. A day with no detected main sleep falls back to the fixed 00:00–06:00
/// window, so the night-scoped numbers do not go blank before sleep is detected. Metrics takes the
/// windows as plain values; Store reads them from `sleep_session` and passes them in.
public struct SleepNights: Sendable, Equatable {
    /// The zone the nights are keyed in. Stress places its windows on local days with it.
    public let timeZone: TimeZone
    private let windows: [LocalDay: Range<Int64>]

    /// Keys each main sleep by the local day it ends on. Naps are ignored. When two main sleeps end on
    /// the same day (a stale row beside its extension), the longer one is kept.
    public init(sleep: [SleepSpan], in timeZone: TimeZone) {
        self.timeZone = timeZone
        var byWakeDay: [LocalDay: SleepSpan] = [:]
        for span in sleep where !span.isNap && span.endMs > span.startMs {
            let day = LocalTime.localDay(containing: span.endMs, in: timeZone)
            if let current = byWakeDay[day], current.endMs - current.startMs >= span.endMs - span.startMs {
                continue
            }
            byWakeDay[day] = span
        }
        windows = byWakeDay.mapValues { $0.startMs..<$0.endMs }
    }

    /// The epoch-ms range of local `day`'s night: its detected main sleep, else 00:00–06:00 local.
    public func window(of day: LocalDay) -> Range<Int64> {
        windows[day] ?? LocalTime.nightWindow(of: day, in: timeZone)
    }

    /// True when `day`'s night came from a detected main sleep rather than the clock fallback.
    public func isDetected(_ day: LocalDay) -> Bool {
        windows[day] != nil
    }
}
