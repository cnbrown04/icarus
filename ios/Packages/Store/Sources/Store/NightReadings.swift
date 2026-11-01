import Foundation
import GRDB
import Metrics

// The readings behind a nightly vital. Resting HR, HRV and respiratory rate are one number per night, each a
// summary of window readings across the main sleep (`SleepDeriver.readings`). These reads give a metric page
// those readings, recomputed from the same records and window the deriver summarised, so the night's value is
// always the floor (resting HR), mean (HRV) or median (respiratory rate) of what is listed.

/// One main sleep and its value for a nightly vital.
public struct VitalNight: Sendable, Equatable, Identifiable {
    public let bandID: String
    public let startMs: Int64
    public let endMs: Int64
    /// The local day the sleep ended on, the day its value belongs to.
    public let day: LocalDay
    /// The night's value: the same number `metricDays` and `metricLatest` give for that day.
    public let value: Double?

    public var id: Int64 { startMs }
}

extension SleepSessionRow {
    /// The session's value for a nightly vital. Nil for any other metric.
    func nightlyValue(_ kind: MetricKind) -> Double? {
        switch kind {
        case .restingHR: restingHr
        case .hrv: rmssdMs
        case .respiratoryRate: respRateBrpm
        default: nil
        }
    }
}

extension MetricKind {
    /// Resting HR, HRV and respiratory rate: one value per night, summarising readings across the main sleep.
    public var isNightly: Bool {
        switch self {
        case .restingHR, .hrv, .respiratoryRate: true
        default: false
        }
    }
}

extension Database {
    /// Main sleeps that ended by `nowMs`, newest first, at most `limit`: one per local day by the
    /// `mainSleepByDay` rule (the longest non-nap session ending that day), which is the night each day's value
    /// comes from.
    public func vitalNights(_ kind: MetricKind, nowMs: Int64, limit: Int, in timeZone: TimeZone) throws -> [VitalNight] {
        let rows = try SleepSessionRow.fetchAll(self, sql: """
        SELECT * FROM sleep_session WHERE is_nap = 0 AND end_ms <= ? ORDER BY end_ms DESC, rowid DESC
        """, arguments: [nowMs])
        var byDay: [LocalDay: SleepSessionRow] = [:]
        for row in rows {
            let key = LocalTime.localDay(containing: row.endMs, in: timeZone)
            if let kept = byDay[key], kept.durationS >= row.durationS { continue }
            byDay[key] = row
        }
        return byDay
            .sorted { $0.value.endMs > $1.value.endMs }
            .prefix(limit)
            .map { day, row in
                VitalNight(
                    bandID: row.bandID,
                    startMs: row.startMs,
                    endMs: row.endMs,
                    day: day,
                    value: row.nightlyValue(kind)
                )
            }
    }

    /// The window readings behind `night`'s value for `kind`, oldest first: 5-minute heart rate for resting HR,
    /// 5-minute RMSSD for HRV, 30-minute respiratory rate. Empty for any other metric.
    ///
    /// Read from `night_reading`, stored when the night was derived. A night derived before readings were stored
    /// (until the launch re-derive reaches it) is recomputed from its records instead: same values, but it reads
    /// the whole night (about 39,000 records) and, for respiratory rate, computes its spectra.
    public func nightReadings(_ kind: MetricKind, night: VitalNight) throws -> [MetricPoint] {
        guard let vital = Self.nightVital(kind) else { return [] }
        let stored = try storedReadings(vital, bandID: night.bandID, sessionStartMs: night.startMs)
        if !stored.isEmpty { return stored }
        let records = try readingRecords(bandID: night.bandID, from: night.startMs, to: night.endMs + 1)
        return SleepDeriver.readings(vital, records, startUnix: night.startMs / 1000, endUnix: night.endMs / 1000)
            .map { MetricPoint(tsMs: $0.unixSeconds * 1000, value: $0.value) }
    }

    /// Every stored window reading of the main sleeps that ended from `first` through `last` (one per day, the
    /// `mainSleepByDay` rule), oldest first: what each day's value on the W, M and 6M charts summarises. Nights
    /// without stored readings yet contribute none.
    public func vitalReadings(
        _ kind: MetricKind,
        from first: LocalDay,
        through last: LocalDay,
        in timeZone: TimeZone
    ) throws -> [MetricPoint] {
        guard let vital = Self.nightVital(kind) else { return [] }
        return try mainSleepByDay(from: first, through: last, in: timeZone).values
            .sorted { $0.startMs < $1.startMs }
            .flatMap { try storedReadings(vital, bandID: $0.bandID, sessionStartMs: $0.startMs) }
    }

    /// HRV or respiratory rate readings taken awake in `[fromMs, toMs)`, oldest first: the all-day windows
    /// (`day_reading`) that do not overlap a main sleep, whose own readings (`vitalReadings`, `nightReadings`) stand
    /// for that time. Empty for resting HR, which is a sleep measure only.
    public func awakeReadings(_ kind: MetricKind, fromMs: Int64, toMs: Int64, in timeZone: TimeZone) throws -> [MetricPoint] {
        guard let vital = Self.nightVital(kind), vital != .restingHR else { return [] }
        let windowMs = Self.dayWindowMs(vital)
        let first = LocalTime.localDay(containing: fromMs, in: timeZone)
        let last = LocalTime.adding(days: 1, to: LocalTime.localDay(containing: toMs, in: timeZone))
        let sleeps = try mainSleepByDay(from: first, through: last, in: timeZone).values.map { ($0.startMs, $0.endMs) }
        return try Row.fetchAll(self, sql: """
            SELECT ts_ms, value FROM day_reading WHERE vital = ? AND ts_ms >= ? AND ts_ms < ? ORDER BY ts_ms
            """, arguments: [vital.rawValue, fromMs, toMs])
            .map { MetricPoint(tsMs: $0[0], value: $0[1]) }
            .filter { point in !sleeps.contains { point.tsMs < $0.1 && point.tsMs + windowMs > $0.0 } }
    }

    /// Rewrites the all-day HRV and respiratory readings for `[fromMs, toMs)`, widened to whole 30-minute clock
    /// windows so every window is computed from all of its records. Returns the readings written.
    ///
    /// Cost: reads the range's records and computes a respiratory spectrum per 30 minutes with beats, about half a
    /// second per day in a release build.
    @discardableResult
    public func deriveDayReadings(from fromMs: Int64, to toMs: Int64, bandID: String) throws -> Int {
        let step = Self.dayWindowMs(.respiratoryRate)
        let start = fromMs - ((fromMs % step) + step) % step
        let end = toMs + (step - ((toMs % step) + step) % step) % step
        guard end > start else { return 0 }
        let records = try readingRecords(bandID: bandID, from: start, to: end)
        let readings = SleepDeriver.allDayReadings(records, startUnix: start / 1000)
        try execute(sql: "DELETE FROM day_reading WHERE band_id = ? AND ts_ms >= ? AND ts_ms < ?",
                    arguments: [bandID, start, end])
        let statement = try makeStatement(sql: "INSERT OR REPLACE INTO day_reading (band_id, vital, ts_ms, value) VALUES (?, ?, ?, ?)")
        var written = 0
        for (vital, list) in [(SleepDeriver.NightVital.hrv, readings.hrv), (.respiratoryRate, readings.respiratoryRate)] {
            for reading in list {
                statement.setUncheckedArguments([bandID, vital.rawValue, reading.unixSeconds * 1000, reading.value])
                try statement.execute()
                written += 1
            }
        }
        return written
    }

    /// The window each all-day reading covers: 5 minutes for HRV, 30 for respiratory rate.
    static func dayWindowMs(_ vital: SleepDeriver.NightVital) -> Int64 {
        vital == .respiratoryRate ? Int64(RespiratoryRate.nightWindowSec * 1000) : 300_000
    }

    private func storedReadings(_ vital: SleepDeriver.NightVital, bandID: String, sessionStartMs: Int64) throws -> [MetricPoint] {
        try Row.fetchAll(self, sql: """
            SELECT ts_ms, value FROM night_reading WHERE band_id = ? AND session_start_ms = ? AND vital = ? ORDER BY ts_ms
            """, arguments: [bandID, sessionStartMs, vital.rawValue]).map { MetricPoint(tsMs: $0[0], value: $0[1]) }
    }

    static func nightVital(_ kind: MetricKind) -> SleepDeriver.NightVital? {
        switch kind {
        case .restingHR: .restingHR
        case .hrv: .hrv
        case .respiratoryRate: .respiratoryRate
        default: nil
        }
    }

    /// Time, heart rate, contact and R-R for `[fromMs, toMs)`, ascending: the inputs `SleepDeriver.readings` reads,
    /// equal to `HistoricalRecordRow.sleepRecord` for those fields.
    func readingRecords(bandID: String, from fromMs: Int64, to toMs: Int64) throws -> [SleepRecord] {
        let cursor = try Row.fetchCursor(self, sql: """
            SELECT ts_ms, bpm, contact, rr_ms FROM historical_record
            WHERE band_id = ? AND ts_ms >= ? AND ts_ms < ? ORDER BY ts_ms, rowid
            """, arguments: [bandID, fromMs, toMs])
        var records: [SleepRecord] = []
        while let row = try cursor.next() {
            let tsMs: Int64 = row[0]
            let bpm: Int? = row[1]
            let contact: Bool? = row[2]
            let rr: String? = row[3]
            records.append(SleepRecord(
                unixSeconds: tsMs / 1000,
                bpm: bpm.map { Double($0) },
                rrMs: rr.map(Self.parseIntervals) ?? [],
                skinContact: contact ?? false
            ))
        }
        return records
    }

    /// A stored R-R list ("[812,830]") as numbers. Same values as decoding the JSON, at a fraction of the cost; a
    /// malformed list yields the numbers it does contain.
    static func parseIntervals(_ text: String) -> [Double] {
        var values: [Double] = []
        var current = 0.0
        var fraction = 0.0
        var digits = false
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                let digit = Double(byte - UInt8(ascii: "0"))
                if fraction > 0 {
                    current += digit * fraction
                    fraction /= 10
                } else {
                    current = current * 10 + digit
                }
                digits = true
            case UInt8(ascii: "."):
                fraction = 0.1
            default:
                if digits { values.append(current) }
                current = 0
                fraction = 0
                digits = false
            }
        }
        if digits { values.append(current) }
        return values
    }
}
