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
    /// The record's skin-contact byte was non-zero. NOT a wear flag: OpenStrap's PROTOCOL.md §5
    /// (validated by per-byte variance) calls it a contact-QUALITY value (0–198), and on the real
    /// strap it reads 0 on ~3.5 % of records that carry a heart rate. Use `isOnWrist`.
    public let skinContact: Bool
    /// Respiratory rate raw (no verified raw-to-breaths-per-minute mapping exists). [Unverified]
    public let respRateRaw: Double?
    /// Skin temperature raw (no verified raw-to-celsius mapping exists). [Unverified]
    public let skinTempRaw: Double?
    /// Accelerometer gravity vector in g, or nil for rows written before gravity was stored. Sleep
    /// detection's stillness spine (`SleepDetector`) runs on it.
    public let gravity: Gravity?

    /// On-wrist = the strap recorded a physiological heart rate. OpenStrap PROTOCOL.md §8: the
    /// record's HR is 0 (stored nil) when off-wrist; the WRIST_ON/OFF events are the other
    /// authoritative source.
    public var isOnWrist: Bool {
        bpm.map { SleepDeriver.bpmRange.contains($0) } ?? false
    }

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
    /// Lowest gated 5-minute bin mean HR over the contact-on records (NOOP sessionRestingHR), or nil
    /// when no contact-on record carried a valid reading.
    public let restingHeartRate: Double?
    /// Mean of the per-5-minute-window RMSSD over the session's cleaned R-R intervals (PLAN.md 8.3), or
    /// nil when no window had enough successive differences.
    public let rmssdMs: Double?
    /// Median of the raw respiratory-rate bytes. [Unverified] mapping to breaths/minute.
    public let respRateRawMedian: Double?
    /// Median of the raw skin-temperature bytes. [Unverified] mapping to celsius.
    public let skinTempRawMedian: Double?
    /// Whole-session respiratory rate, breaths/min, estimated from the on-wrist R-R intervals by
    /// `RespiratoryRate.nightEstimate` (RSA). Nil when the R-R coverage or agreement is too weak. This is an
    /// on-device estimate from heart-timing modulation, not a clinical measurement.
    public let respiratoryRateBrpm: Double?
    /// Fraction of session records that saw skin contact, 0...1.
    public let contactFraction: Double
    public let quality: SleepQuality
    /// Number of records in the session, contact on and off combined.
    public let recordCount: Int
    /// True for a daytime nap; false for the night's main sleep. Last night is the newest main sleep.
    public let isNap: Bool
    /// The window readings the nightly vitals summarise (`SleepDeriver.NightReadings`).
    public let readings: SleepDeriver.NightReadings
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
    /// Algorithm version stored with every derived row (PLAN.md 8.5). 5 = the window readings behind each nightly
    /// vital are stored with the session (same values); 4 = session respiratory rate from the
    /// on-wrist R-R (RSA); 3 = session RHR is the lowest gated
    /// 5-minute bin and RMSSD is the mean of per-window RMSSD, plus the nap flag; 2 = `SleepDetector`
    /// windows with the older median RHR and whole-session RMSSD; 1 was "any contiguous worn run touching
    /// 21:00–06:00", which made whole days into nights.
    public static let algoVersion = 5

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
            return summarize(inside, startUnix: window.startUnix, endUnix: window.endUnix, isNap: window.isNap)
        }
    }

    /// Summarises the records of one detected window, or nil when the window holds no records.
    ///
    /// Resting HR and RMSSD follow the published session methods (NOOP `sessionRestingHR` and
    /// `sessionAvgHRV`, OpenStrap `sleepSessionWindowedRmssd`): the floor of gated 5-minute HR bins, and
    /// the mean of per-window RMSSD, each window cleaned on its own. A median over the whole night would
    /// let one stretch of restless sleep set the value for everything.
    public static func summarize(
        _ records: [SleepRecord],
        startUnix: Int64,
        endUnix: Int64,
        isNap: Bool = false
    ) -> SleepSession? {
        guard !records.isEmpty, endUnix > startUnix else { return nil }
        let sorted = records.sorted { $0.unixSeconds < $1.unixSeconds }
        // Stored as `contact_fraction`: the share of records that carried a heart rate.
        let onWrist = sorted.filter(\.isOnWrist)
        let contactFraction = Double(onWrist.count) / Double(sorted.count)

        // Each nightly vital is a summary of its window readings, which are kept with the session so a chart can
        // show them: resting HR the lowest 5-minute bin, RMSSD the mean of 5-minute windows, respiratory rate the
        // median of 30-minute windows.
        let inputs = vitalInputs(onWrist)
        let restingBins = SleepDetector.sessionRestingBins(inputs.heartRate, startUnix: startUnix, endUnix: endUnix)
        let rmssdWindows = HRV.rmssdWindows(inputs.beats, startUnix: startUnix)
        let respiratoryWindows = RespiratoryRate.nightWindows(inputs.rrSamples)
        let restingHeartRate = restingBins.map(\.bpm).min()
        let rmssd = rmssdWindows.isEmpty ? nil : rmssdWindows.map(\.ms).reduce(0, +) / Double(rmssdWindows.count)
        let readings = NightReadings(
            restingHR: restingBins.map { Reading(unixSeconds: $0.start, value: $0.bpm) },
            hrv: rmssdWindows.map { Reading(unixSeconds: $0.startUnix, value: $0.ms) },
            respiratoryRate: (respiratoryWindows?.estimates ?? []).map { Reading(unixSeconds: $0.startMs / 1000, value: $0.brpm) }
        )

        return SleepSession(
            startUnix: startUnix,
            endUnix: endUnix,
            durationSeconds: endUnix - startUnix,
            restingHeartRate: restingHeartRate,
            rmssdMs: rmssd,
            respRateRawMedian: Statistics.median(onWrist.compactMap(\.respRateRaw)),
            skinTempRawMedian: Statistics.median(onWrist.compactMap(\.skinTempRaw)),
            respiratoryRateBrpm: respiratoryWindows.flatMap { RespiratoryRate.nightEstimate($0) }?.brpm,
            contactFraction: contactFraction,
            quality: quality(contactFraction: contactFraction),
            recordCount: sorted.count,
            isNap: isNap,
            readings: readings
        )
    }

    /// One reading behind a nightly vital: a window's start and its value.
    public struct Reading: Sendable, Equatable {
        public let unixSeconds: Int64
        public let value: Double

        public init(unixSeconds: Int64, value: Double) {
            self.unixSeconds = unixSeconds
            self.value = value
        }
    }

    /// A nightly vital and the readings it summarises: resting HR is the lowest 5-minute heart rate, RMSSD the mean
    /// of 5-minute RMSSD, respiratory rate the median of 30-minute estimates (when enough windows have one).
    public enum NightVital: String, Sendable, CaseIterable {
        case restingHR = "resting_hr"
        case hrv = "rmssd"
        case respiratoryRate = "resp_rate"
    }

    /// One night's window readings per vital, in time order.
    public struct NightReadings: Sendable, Equatable {
        public let restingHR: [Reading]
        public let hrv: [Reading]
        public let respiratoryRate: [Reading]

        public static let empty = NightReadings(restingHR: [], hrv: [], respiratoryRate: [])

        public subscript(vital: NightVital) -> [Reading] {
            switch vital {
            case .restingHR: restingHR
            case .hrv: hrv
            case .respiratoryRate: respiratoryRate
            }
        }
    }

    /// The window readings behind `summarize`'s value for `vital`, in time order, for the same records and window
    /// and computed by the same functions, so the readings and the nightly value always agree. Only `vital` is
    /// computed: respiratory rate's spectra cost far more than the other two.
    public static func readings(
        _ vital: NightVital,
        _ records: [SleepRecord],
        startUnix: Int64,
        endUnix: Int64
    ) -> [Reading] {
        let sorted = records.sorted { $0.unixSeconds < $1.unixSeconds }
        let inputs = vitalInputs(sorted.filter(\.isOnWrist))
        switch vital {
        case .restingHR:
            return SleepDetector.sessionRestingBins(inputs.heartRate, startUnix: startUnix, endUnix: endUnix)
                .map { Reading(unixSeconds: $0.start, value: $0.bpm) }
        case .hrv:
            return HRV.rmssdWindows(inputs.beats, startUnix: startUnix)
                .map { Reading(unixSeconds: $0.startUnix, value: $0.ms) }
        case .respiratoryRate:
            return (RespiratoryRate.nightWindows(inputs.rrSamples)?.estimates ?? [])
                .map { Reading(unixSeconds: $0.startMs / 1000, value: $0.brpm) }
        }
    }

    /// HRV and respiratory rate across any stretch of time, awake or asleep: the same 5-minute RMSSD and 30-minute
    /// respiratory windows the nightly values use, counted from `startUnix` (callers align it to a clock boundary
    /// so windows from separate passes line up). Windows without enough clean beats are absent, which is most of
    /// an active day: the strap sends far fewer R-R intervals while you move.
    public static func allDayReadings(
        _ records: [SleepRecord],
        startUnix: Int64
    ) -> (hrv: [Reading], respiratoryRate: [Reading]) {
        let sorted = records.sorted { $0.unixSeconds < $1.unixSeconds }
        let inputs = vitalInputs(sorted.filter(\.isOnWrist))
        let hrv = HRV.rmssdWindows(inputs.beats, startUnix: startUnix)
            .map { Reading(unixSeconds: $0.startUnix, value: $0.ms) }
        let respiratory = (RespiratoryRate.nightWindows(inputs.rrSamples, originMs: startUnix * 1000)?.estimates ?? [])
            .map { Reading(unixSeconds: $0.startMs / 1000, value: $0.brpm) }
        return (hrv, respiratory)
    }

    /// The on-wrist inputs every nightly vital reads. Off-wrist and invalid readings pollute every aggregate,
    /// so only on-wrist records contribute. `onWrist` must be sorted by time.
    private static func vitalInputs(_ onWrist: [SleepRecord]) -> (
        heartRate: [SleepDetector.HRPoint],
        beats: [(unixSeconds: Int64, rrMs: [Double])],
        rrSamples: [RRSample]
    ) {
        let heartRate = onWrist.compactMap { record -> SleepDetector.HRPoint? in
            guard let bpm = record.bpm, bpmRange.contains(bpm) else { return nil }
            return SleepDetector.HRPoint(ts: record.unixSeconds, bpm: bpm)
        }
        let beats = onWrist.map { (unixSeconds: $0.unixSeconds, rrMs: $0.rrMs) }
        // Each R-R value carries its record's timestamp. The estimator clocks beats within a run, so the
        // record time is the only wall-clock anchor it gets, and it must not be re-stamped.
        let rrSamples = onWrist.flatMap { record in
            record.rrMs.map { RRSample(tsMs: record.unixSeconds * 1000, rrMs: $0) }
        }
        return (heartRate, beats, rrSamples)
    }

    private static func quality(contactFraction: Double) -> SleepQuality {
        if contactFraction >= goodContactFraction {
            return .good
        }
        return contactFraction >= fairContactFraction ? .fair : .poor
    }
}
