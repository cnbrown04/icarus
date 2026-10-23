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
    /// Accelerometer gravity vector in g, or nil for rows written before gravity was stored. Sleep
    /// detection's stillness spine (`SleepDetector`) runs on it.
    public let gravity: Gravity?

    public struct Gravity: Sendable, Equatable {
        public let x: Double
        public let y: Double
        public let z: Double

        public init(x: Double, y: Double, z: Double) {
            self.x = x
            self.y = y
            self.z = z
        }
    }

    public init(
        unixSeconds: Int64,
        bpm: Double?,
        rrMs: [Double],
        skinContact: Bool,
        respRateRaw: Double? = nil,
        skinTempRaw: Double? = nil,
        gravity: Gravity? = nil
    ) {
        self.unixSeconds = unixSeconds
        self.bpm = bpm
        self.rrMs = rrMs
        self.skinContact = skinContact
        self.respRateRaw = respRateRaw
        self.skinTempRaw = skinTempRaw
        self.gravity = gravity
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

/// Nightly sleep sessions from the strap's historical records (PLAN.md 8.1).
///
/// `SleepDetector` decides WHERE sleep was (gravity stillness corroborated by heart rate); this
/// type summarises each detected window into the stored session row. Off-wrist records inside a
/// window count toward its contact fraction but contribute nothing to the aggregates.
///
/// This is a clearly-labelled proxy derived from published methods, not a WHOOP sleep score
/// (PLAN.md §79 "we compute our own clearly labelled metrics").
public enum SleepDeriver {
    /// Algorithm version stored with every derived row (PLAN.md 8.5). 2 = `SleepDetector` windows;
    /// 1 was "any contiguous worn run touching 21:00–06:00", which made whole days into nights.
    public static let algoVersion = 2

    /// Context a derivation must read on each side of the span it rewrites: the longest window
    /// (`SleepDetector.maxSleepSeconds`) plus the detector's day of HR baseline context.
    public static let contextSeconds: Int64 = SleepDetector.maxSleepSeconds + SleepDetector.baselineHalfWindowSeconds

    /// Contact fraction at or above this is `.good` (the band hardly ever lost the wrist).
    public static let goodContactFraction = 0.95
    /// Contact fraction at or above this is `.fair`; below is `.poor`.
    public static let fairContactFraction = 0.8

    /// Physiological bpm range, matching the ingest gate (PLAN.md 7.3: 20–250).
    public static let bpmRange = 20.0...250.0

    /// Detects and summarises sessions in `records`. Order does not matter; duplicates by unix time
    /// (a replayed batch) are collapsed to the first occurrence. Returns sessions sorted by start.
    public static func derive(_ records: [SleepRecord], in timeZone: TimeZone) -> [SleepSession] {
        let sorted = SleepDetector.deduplicatedSorted(records)
        return SleepDetector.detect(sorted, in: timeZone).compactMap { window in
            let inside = sorted.filter { $0.unixSeconds >= window.startUnix && $0.unixSeconds <= window.endUnix }
            return summarize(inside, startUnix: window.startUnix, endUnix: window.endUnix)
        }
    }

    /// Summarises the records of one detected window, or nil when the window holds no records.
    public static func summarize(_ records: [SleepRecord], startUnix: Int64, endUnix: Int64) -> SleepSession? {
        guard !records.isEmpty, endUnix > startUnix else { return nil }
        let onWrist = records.filter(\.skinContact)
        let contactFraction = Double(onWrist.count) / Double(records.count)

        // Off-wrist and invalid readings pollute every aggregate, so only clean contact-on
        // records contribute.
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
            startUnix: startUnix,
            endUnix: endUnix,
            durationSeconds: endUnix - startUnix,
            restingHeartRate: restingHeartRate,
            rmssdMs: rmssd,
            respRateRawMedian: Statistics.median(onWrist.compactMap(\.respRateRaw)),
            skinTempRawMedian: Statistics.median(onWrist.compactMap(\.skinTempRaw)),
            contactFraction: contactFraction,
            quality: quality(contactFraction: contactFraction),
            recordCount: records.count
        )
    }

    private static func quality(contactFraction: Double) -> SleepQuality {
        if contactFraction >= goodContactFraction {
            return .good
        }
        return contactFraction >= fairContactFraction ? .fair : .poor
    }
}
