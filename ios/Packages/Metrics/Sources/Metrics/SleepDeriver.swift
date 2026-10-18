import Foundation

/// One decoded historical record, reduced to the fields sleep derivation needs.
/// Deliberately protocol-free: callers convert BandProtocol's `HistoricalRecord` (version 24) into
/// this, so Metrics stays a pure package with no BLE dependencies (PLAN.md 8).
public struct SleepRecord: Sendable, Equatable {
    /// Record time, unix seconds.
    public let unixSeconds: Int64
    /// Heart rate in bpm, or nil when the strap recorded no reading.
    public let bpm: Double?
    /// R-R intervals in milliseconds carried by the record.
    public let rrMs: [Double]
    /// True when the strap saw skin contact (on-wrist).
    public let skinContact: Bool
    /// Respiratory rate raw (no verified raw-to-breaths-per-minute mapping exists). [Unverified]
    public let respRateRaw: Double?
    /// Skin temperature raw (no verified raw-to-celsius mapping exists). [Unverified]
    public let skinTempRaw: Double?

    public init(
        unixSeconds: Int64,
        bpm: Double?,
        rrMs: [Double],
        skinContact: Bool,
        respRateRaw: Double? = nil,
        skinTempRaw: Double? = nil
    ) {
        self.unixSeconds = unixSeconds
        self.bpm = bpm
        self.rrMs = rrMs
        self.skinContact = skinContact
        self.respRateRaw = respRateRaw
        self.skinTempRaw = skinTempRaw
    }
}

/// How trustworthy a derived session is, judged by how much of it the band saw skin contact.
/// Stored as its raw value string (PLAN.md 10.2 value-column convention).
public enum SleepQuality: String, Sendable, Equatable {
    case good
    case fair
    case poor
}

/// One derived nightly sleep session (PLAN.md 8.1's night, extended by sleep detection).
public struct SleepSession: Sendable, Equatable {
    /// First record of the session, unix seconds.
    public let startUnix: Int64
    /// Last record of the session, unix seconds. The session may extend a little past it.
    public let endUnix: Int64
    /// `endUnix - startUnix`, so a session with a single record has duration 0.
    public let durationSeconds: Int64
    /// Median heart rate over the contact-on records, or nil when none qualified.
    public let restingHeartRate: Double?
    /// RMSSD over the session's cleaned R-R intervals (PLAN.md 8.3), or nil when too few survived.
    public let rmssdMs: Double?
    /// Median of the raw respiratory-rate bytes. [Unverified] mapping to breaths/minute.
    public let respRateRawMedian: Double?
    /// Median of the raw skin-temperature bytes. [Unverified] mapping to celsius.
    public let skinTempRawMedian: Double?
    /// Fraction of session records that saw skin contact, 0...1.
    public let contactFraction: Double
    public let quality: SleepQuality
    /// Number of records in the session, contact on and off combined.
    public let recordCount: Int
}

/// Nightly sleep sessions from the strap's historical records (PLAN.md 8.1; the sleep detection
/// that PLAN.md 8.1's resting heart rate calls "a proxy until sleep detection exists").
///
/// A session is a contiguous run of records where consecutive records are never more than
/// `maxGapSeconds` apart. A run becomes a session when it is long enough, mostly saw skin contact,
/// and overlaps the local night window. Off-wrist records keep the run contiguous (a short
/// bathroom break does not split the night) but contribute nothing to the aggregates.
///
/// This is a clearly-labelled proxy derived from published methods, not a WHOOP sleep score
/// (PLAN.md §79 "we compute our own clearly labelled metrics").
public enum SleepDeriver {
    /// Algorithm version stored with every derived row (PLAN.md 8.5).
    public static let algoVersion = 1

    /// Largest gap between consecutive records that stays inside one session, in seconds.
    /// 30 min tolerates a short bathroom break or a wrist-off stretch while splitting genuinely
    /// separate sleeps (a mid-day nap 4 h away from the night is its own run, then rejected by
    /// the night-overlap rule). Tunable: shorter makes sessions fragment, longer merges naps.
    public static let maxGapSeconds: Int64 = 30 * 60

    /// Shortest session worth reporting, in seconds. 30 min keeps single stray on-wrist minutes
    /// (dinner, reading) out while keeping real naps. Tunable with `maxGapSeconds`.
    public static let minDurationSeconds: Int64 = 30 * 60

    /// A run must see skin contact on at least this fraction of its records to count as sleep.
    /// 0.5 = "mostly present": a run that is mostly off-wrist is not sleep even if it is long.
    public static let minContactFraction = 0.5

    /// The local window a session must overlap. PLAN.md 8.1 defines the resting-HR night as
    /// 00:00–06:00; sleep sessions use a wider evening-to-morning window so an early bedtime
    /// (21:30) is kept, while a same-evening on-wrist stretch before 21:00 is not. Tunable.
    public static let nightStartHour = 21
    /// Matches the package's night-end convention (LocalTime.nightEndHour).
    public static let nightEndHour = LocalTime.nightEndHour

    /// Contact fraction at or above this is `.good` (the band hardly ever lost the wrist).
    public static let goodContactFraction = 0.95
    /// Contact fraction at or above this is `.fair`; below is `.poor`.
    public static let fairContactFraction = 0.8

    /// Physiological bpm range, matching the ingest gate (PLAN.md 7.3: 20–250).
    public static let bpmRange = 20.0...250.0

    /// Derives sessions from a stream of historical records. Order does not matter; duplicates by
    /// unix time (a replayed batch) are collapsed to the first occurrence. Returns sessions sorted
    /// by start time.
    public static func derive(_ records: [SleepRecord], in timeZone: TimeZone) -> [SleepSession] {
        let sorted = deduplicated(records).sorted { $0.unixSeconds < $1.unixSeconds }
        guard !sorted.isEmpty else { return [] }

        var sessions: [SleepSession] = []
        var runStart = 0
        for index in 1...sorted.count {
            let runEnded = index == sorted.count
                || sorted[index].unixSeconds - sorted[index - 1].unixSeconds >= maxGapSeconds
            if runEnded {
                if let session = session(sorted[runStart..<index], in: timeZone) {
                    sessions.append(session)
                }
                runStart = index
            }
        }
        return sessions
    }

    /// Keeps the first record per unix time.
    private static func deduplicated(_ records: [SleepRecord]) -> [SleepRecord] {
        var seen = Set<Int64>()
        var unique: [SleepRecord] = []
        unique.reserveCapacity(records.count)
        for record in records where seen.insert(record.unixSeconds).inserted {
            unique.append(record)
        }
        return unique
    }

    /// Builds one session from a run, or nil when the run does not qualify.
    private static func session(_ run: ArraySlice<SleepRecord>, in timeZone: TimeZone) -> SleepSession? {
        guard let first = run.first, let last = run.last else { return nil }
        let duration = last.unixSeconds - first.unixSeconds
        guard duration >= minDurationSeconds else { return nil }

        let onWrist = run.filter(\.skinContact)
        let contactFraction = Double(onWrist.count) / Double(run.count)
        guard contactFraction >= minContactFraction else { return nil }
        guard overlapsNight(from: first.unixSeconds, to: last.unixSeconds, in: timeZone) else {
            return nil
        }

        // Off-wrist and invalid readings pollute every aggregate, so only clean contact-on
        // records contribute. The off-wrist records already did their job: keeping the run whole.
        let beats = onWrist.compactMap { record -> Double? in
            guard let bpm = record.bpm, bpmRange.contains(bpm) else { return nil }
            return bpm
        }
        let restingHeartRate = Statistics.median(beats)

        let rr = onWrist.flatMap(\.rrMs)
        let flags = RRCleaner.acceptedFlags(rr)
        let accepted = zip(rr, flags).compactMap { $1 ? $0 : nil }
        let rmssd = HRV.rmssd(accepted)

        return SleepSession(
            startUnix: first.unixSeconds,
            endUnix: last.unixSeconds,
            durationSeconds: duration,
            restingHeartRate: restingHeartRate,
            rmssdMs: rmssd,
            respRateRawMedian: Statistics.median(onWrist.compactMap(\.respRateRaw)),
            skinTempRawMedian: Statistics.median(onWrist.compactMap(\.skinTempRaw)),
            contactFraction: contactFraction,
            quality: quality(contactFraction: contactFraction),
            recordCount: run.count
        )
    }

    private static func quality(contactFraction: Double) -> SleepQuality {
        if contactFraction >= goodContactFraction {
            return .good
        }
        return contactFraction >= fairContactFraction ? .fair : .poor
    }

    /// True when [from, to] (unix seconds) overlaps the night window of any local day it touches.
    ///
    /// The window on local day `d` is [21:00 on `d`, 06:00 on `d + 1`). A session from 23:00 to
    /// 07:00 overlaps day `d`'s window; one from 00:30 to 07:30 overlaps day `d - 1`'s. Days from
    /// one before the start's local day through the end's local day cover every case (the end's
    /// local day is never earlier than the start's, so the walk below terminates).
    static func overlapsNight(from: Int64, to: Int64, in timeZone: TimeZone) -> Bool {
        let startDay = LocalTime.localDay(containing: from * 1000, in: timeZone)
        let endDay = LocalTime.localDay(containing: to * 1000, in: timeZone)
        var day = LocalTime.adding(days: -1, to: startDay)
        while true {
            let windowStart = LocalTime.localTime(day, hour: nightStartHour, in: timeZone) / 1000
            let windowEnd = LocalTime.localTime(
                LocalTime.adding(days: 1, to: day),
                hour: nightEndHour,
                in: timeZone
            ) / 1000
            if from < windowEnd && to > windowStart {
                return true
            }
            if day == endDay {
                return false
            }
            day = LocalTime.adding(days: 1, to: day)
        }
    }
}
