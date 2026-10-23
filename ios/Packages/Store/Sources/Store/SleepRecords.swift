import Foundation
import GRDB
import Metrics

/// Row types for the v2 tables: history offload and derived sleep (PLAN.md 5.3.4, 8.1).
/// See Schema.v2 for the column rationale.

/// One offloaded type-47 record. Scalar sensor bytes are stored raw; `rrMsJSON` is a JSON array of
/// R-R values in milliseconds so the record stays one row.
public struct HistoricalRecordRow: Codable, Equatable, Sendable, FetchableRecord {
    public static let databaseTableName = "historical_record"

    public var rowid: Int64
    public var bandID: String
    /// Record unix time in ms (PLAN.md 10.1 convention; the record itself is second-granular).
    public var tsMs: Int64
    /// Record layout version (the frame `seq` byte). 24 = WHOOP 4.0 DSP record.
    public var version: Int
    /// Raw heart rate byte; nil means the strap recorded 0 (no reading).
    public var bpm: Int?
    /// True on-wrist, false off-wrist; nil should not occur (the parser always sets it).
    public var contact: Bool?
    /// JSON array of R-R values in ms.
    public var rrMsJSON: String?
    /// Raw sensor bytes, nil when the strap wrote 0 (see `HistoricalSample` normalization).
    public var ppgGreen: Int?
    public var ppgRedIr: Int?
    public var spo2Red: Int?
    public var spo2Ir: Int?
    public var skinTempRaw: Int?
    public var respRateRaw: Int?
    public var signalQuality: Int?
    /// Both gravity triplets, in g (v3). NULL in rows written before v3.
    public var gravityX: Double?
    public var gravityY: Double?
    public var gravityZ: Double?
    public var gravity2X: Double?
    public var gravity2Y: Double?
    public var gravity2Z: Double?
    /// Raw ambient-light and LED drive bytes (v3). NULL in rows written before v3.
    public var ambientDrive: Int?
    public var ledDrive1: Int?
    public var ledDrive2: Int?

    enum CodingKeys: String, CodingKey {
        case rowid
        case bandID = "band_id"
        case tsMs = "ts_ms"
        case version
        case bpm
        case contact
        case rrMsJSON = "rr_ms"
        case ppgGreen = "ppg_green"
        case ppgRedIr = "ppg_red_ir"
        case spo2Red = "spo2_red"
        case spo2Ir = "spo2_ir"
        case skinTempRaw = "skin_temp_raw"
        case respRateRaw = "resp_rate_raw"
        case signalQuality = "signal_quality"
        case gravityX = "gravity_x"
        case gravityY = "gravity_y"
        case gravityZ = "gravity_z"
        case gravity2X = "gravity2_x"
        case gravity2Y = "gravity2_y"
        case gravity2Z = "gravity2_z"
        case ambientDrive = "ambient_drive"
        case ledDrive1 = "led_drive1"
        case ledDrive2 = "led_drive2"
    }

    /// The stored R-R values, or nil when the JSON did not decode.
    public var rrMs: [Double]? {
        guard let data = rrMsJSON?.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [Double]
        else { return nil }
        return values
    }

    /// Summary input for `SleepDeriver` (the full row, R-R included).
    public var sleepRecord: SleepRecord {
        SleepRecord(
            unixSeconds: tsMs / 1000,
            bpm: bpm.map { Double($0) },
            rrMs: rrMs ?? [],
            skinContact: contact ?? false,
            respRateRaw: respRateRaw.map { Double($0) },
            skinTempRaw: skinTempRaw.map { Double($0) },
            gravity: gravity
        )
    }

    /// The primary gravity vector, or nil for rows written before v3.
    public var gravity: SleepRecord.Gravity? {
        guard let gravityX, let gravityY, let gravityZ else { return nil }
        return SleepRecord.Gravity(x: gravityX, y: gravityY, z: gravityZ)
    }
}

/// One derived nightly sleep session. Values come from Metrics `SleepSession` (PLAN.md 8.1).
public struct SleepSessionRow: Codable, Equatable, Sendable, FetchableRecord {
    public static let databaseTableName = "sleep_session"

    public var rowid: Int64
    public var bandID: String
    public var startMs: Int64
    public var endMs: Int64
    public var durationS: Int64
    /// Median heart rate over the session's contact-on records (PLAN.md 8.1 resting-HR convention).
    public var restingHr: Double?
    public var rmssdMs: Double?
    /// Median of the raw respiratory-rate bytes ([Unverified] mapping to breaths/minute).
    public var respRateRaw: Double?
    /// Median of the raw skin-temperature bytes ([Unverified] mapping to celsius).
    public var skinTempRaw: Double?
    /// Fraction of session records with skin contact, 0...1.
    public var contactFraction: Double
    /// Raw `SleepQuality` value.
    public var quality: String
    public var recordCount: Int
    /// True for a daytime nap (v5). Last night is the newest row with `isNap == false`.
    public var isNap: Bool
    public var algoVersion: Int
    public var computedAt: Int64

    enum CodingKeys: String, CodingKey {
        case rowid
        case bandID = "band_id"
        case startMs = "start_ms"
        case endMs = "end_ms"
        case durationS = "duration_s"
        case restingHr = "resting_hr"
        case rmssdMs = "rmssd_ms"
        case respRateRaw = "resp_rate_raw"
        case skinTempRaw = "skin_temp_raw"
        case contactFraction = "contact_fraction"
        case quality
        case recordCount = "record_count"
        case isNap = "is_nap"
        case algoVersion = "algo_version"
        case computedAt = "computed_at"
    }

    public var qualityValue: SleepQuality {
        SleepQuality(rawValue: quality) ?? .poor
    }

    /// The session as the plain span `SleepNights` takes, so Metrics never sees a row type.
    public var span: SleepSpan {
        SleepSpan(startMs: startMs, endMs: endMs, isNap: isNap)
    }
}
