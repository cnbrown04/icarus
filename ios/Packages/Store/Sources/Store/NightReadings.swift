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
    /// Cost: reads every band record of the night (about 39,000 for ten hours). Only the four columns the readings
    /// use are read, through a cursor, and R-R lists are parsed by hand: decoding whole rows and their JSON took
    /// seconds per night.
    public func nightReadings(_ kind: MetricKind, night: VitalNight) throws -> [MetricPoint] {
        guard kind.isNightly else { return [] }
        // The same records the deriver summarised: the window's start through its end, inclusive.
        let records = try readingRecords(bandID: night.bandID, from: night.startMs, to: night.endMs + 1)
        let vital: SleepDeriver.NightVital
        switch kind {
        case .restingHR: vital = .restingHR
        case .hrv: vital = .hrv
        default: vital = .respiratoryRate
        }
        return SleepDeriver.readings(vital, records, startUnix: night.startMs / 1000, endUnix: night.endMs / 1000).map { MetricPoint(tsMs: $0.unixSeconds * 1000, value: $0.value) }
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
