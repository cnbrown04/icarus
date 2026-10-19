import Foundation
import GRDB

/// Local retention windows (PLAN.md 10.2 "All windows configurable in Settings → Storage").
///
/// `rawDays` and `minuteDays` are user-configurable: stored in UserDefaults, clamped to the
/// bounds, with the original fixed constants as defaults so behavior is unchanged until the user
/// picks something else. Foundation only, so the Store package stays free of SwiftUI.
public enum RetentionPolicy {
    /// UserDefaults keys, shared with the Settings pickers through `@AppStorage`.
    public static let rawDaysKey = "retention.rawDays"
    public static let minuteDaysKey = "retention.minuteDays"

    /// The shipped defaults; also what an unset (or unrepresentable) stored value falls back to.
    public static let rawDaysDefault: Int64 = 30
    public static let minuteDaysDefault: Int64 = 400

    /// User-configurable bounds. They contain the defaults, so a stored value is never pushed
    /// out of range by a change here.
    public static let rawDaysBounds: ClosedRange<Int64> = 1...90
    public static let minuteDaysBounds: ClosedRange<Int64> = 7...730

    /// Raw HR and R-R are deleted only after this many days and only once acknowledged by the server.
    public static var rawDays: Int64 { rawDays(in: .standard) }
    public static var minuteDays: Int64 { minuteDays(in: .standard) }
    public static let rawFrameHours: Int64 = 72

    /// The configured raw window read from `defaults`. Out-of-range values clamp to the bounds;
    /// an unset key returns the default.
    public static func rawDays(in defaults: UserDefaults) -> Int64 {
        stored(rawDaysKey, default: rawDaysDefault, bounds: rawDaysBounds, from: defaults)
    }

    /// The configured minute-metric window read from `defaults`.
    public static func minuteDays(in defaults: UserDefaults) -> Int64 {
        stored(minuteDaysKey, default: minuteDaysDefault, bounds: minuteDaysBounds, from: defaults)
    }

    /// Stores the raw window clamped to `rawDaysBounds`.
    public static func setRawDays(_ days: Int64, in defaults: UserDefaults = .standard) {
        defaults.set(Int(clamp(days, rawDaysBounds)), forKey: rawDaysKey)
    }

    /// Stores the minute window clamped to `minuteDaysBounds`.
    public static func setMinuteDays(_ days: Int64, in defaults: UserDefaults = .standard) {
        defaults.set(Int(clamp(days, minuteDaysBounds)), forKey: minuteDaysKey)
    }

    private static func stored(
        _ key: String,
        default fallback: Int64,
        bounds: ClosedRange<Int64>,
        from defaults: UserDefaults
    ) -> Int64 {
        guard let value = defaults.object(forKey: key) as? Int64 else { return fallback }
        return clamp(value, bounds)
    }

    private static func clamp(_ value: Int64, _ bounds: ClosedRange<Int64>) -> Int64 {
        min(max(value, bounds.lowerBound), bounds.upperBound)
    }
}

public struct RetentionResult: Sendable, Equatable {
    public let heartRateRows: Int
    public let rrRows: Int
    public let minuteRows: Int
    public let rawFrameRows: Int
}

extension Database {
    /// Deletes rows past their retention window (PLAN.md 10.2 "Local retention"). The windows come
    /// from `RetentionPolicy`, read from `defaults` (the app passes its own UserDefaults).
    ///
    /// Raw HR and R-R go only when older than the configured raw window and at or below the
    /// acknowledged cursor. In offline mode nothing is acknowledged, so raw rows stay. The row with
    /// the largest rowid is always kept: deleting it would let SQLite reuse a rowid below the
    /// cursor, and new rows would never sync.
    @discardableResult
    public func purgeExpired(nowMs: Int64, defaults: UserDefaults = .standard) throws -> RetentionResult {
        let day: Int64 = 86_400_000
        let rawCutoff = nowMs - RetentionPolicy.rawDays(in: defaults) * day
        let hr = try purgeAcknowledged(table: "hr_sample", stream: .hrSample, cutoff: rawCutoff)
        let rr = try purgeAcknowledged(table: "rr_interval", stream: .rrInterval, cutoff: rawCutoff)

        try execute(
            sql: "DELETE FROM minute_metric WHERE minute_ms < ?",
            arguments: [nowMs - RetentionPolicy.minuteDays(in: defaults) * day]
        )
        let minutes = changesCount

        try execute(
            sql: "DELETE FROM raw_frame WHERE ts_ms < ?",
            arguments: [nowMs - RetentionPolicy.rawFrameHours * 3_600_000]
        )
        let frames = changesCount

        return RetentionResult(heartRateRows: hr, rrRows: rr, minuteRows: minutes, rawFrameRows: frames)
    }

    private func purgeAcknowledged(table: String, stream: SyncStream, cutoff: Int64) throws -> Int {
        let acknowledged = try syncCursor(stream)
        try execute(
            sql: """
            DELETE FROM \(table) WHERE ts_ms < ? AND rowid <= ?
              AND rowid < (SELECT MAX(rowid) FROM \(table))
            """,
            arguments: [cutoff, acknowledged]
        )
        return changesCount
    }
}
