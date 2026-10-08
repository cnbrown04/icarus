import Foundation
import GRDB
import Metrics

/// Row types for the v1 tables (PLAN.md 10.2). Times are epoch ms UTC.

public struct ProfileRow: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "profile"

    public var id: Int64
    /// "male" or "female", as the CHECK constraint requires.
    public var formulaSex: String?
    public var birthYear: Int?
    public var heightCm: Double?
    public var weightKg: Double?
    public var hrMax: Int?
    public var tz: String
    public var version: Int64
    public var updatedAt: Int64

    public init(
        formulaSex: String? = nil,
        birthYear: Int? = nil,
        heightCm: Double? = nil,
        weightKg: Double? = nil,
        hrMax: Int? = nil,
        tz: String = "America/Chicago",
        version: Int64 = 0,
        updatedAt: Int64 = 0
    ) {
        self.id = 1
        self.formulaSex = formulaSex
        self.birthYear = birthYear
        self.heightCm = heightCm
        self.weightKg = weightKg
        self.hrMax = hrMax
        self.tz = tz
        self.version = version
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case formulaSex = "formula_sex"
        case birthYear = "birth_year"
        case heightCm = "height_cm"
        case weightKg = "weight_kg"
        case hrMax = "hr_max"
        case tz
        case version
        case updatedAt = "updated_at"
    }

    public var timeZone: TimeZone {
        TimeZone(identifier: tz) ?? TimeZone(identifier: "America/Chicago")!
    }

    public var formula: FormulaSex? {
        switch formulaSex {
        case "male": .male
        case "female": .female
        default: nil
        }
    }

    /// Metrics inputs for calories and HR zones in `year`. Nil until sex, birth year, height and weight are set.
    public func userProfile(year: Int) -> UserProfile? {
        guard let formula, let birthYear, let heightCm, let weightKg else { return nil }
        return UserProfile(sex: formula, ageYears: max(0, year - birthYear), heightCm: heightCm, weightKg: weightKg)
    }
}

public struct BandRow: Codable, Equatable, Sendable, FetchableRecord {
    public static let databaseTableName = "band"

    public var id: String
    public var peripheralUUID: String
    public var name: String?
    public var firmware: String?
    public var tierBEnabled: Bool
    public var createdAt: Int64
    public var lastSeenAt: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case peripheralUUID = "peripheral_uuid"
        case name
        case firmware
        case tierBEnabled = "tier_b_enabled"
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
    }
}

public struct HeartRateRow: Codable, Equatable, Sendable, FetchableRecord {
    public static let databaseTableName = "hr_sample"

    public var rowid: Int64
    public var bandID: String
    public var tsMs: Int64
    public var bpm: Int
    public var source: Int
    /// Nil when the band did not say.
    public var contact: Bool?

    enum CodingKeys: String, CodingKey {
        case rowid
        case bandID = "band_id"
        case tsMs = "ts_ms"
        case bpm
        case source
        case contact
    }
}

public struct RRIntervalRow: Codable, Equatable, Sendable, FetchableRecord {
    public static let databaseTableName = "rr_interval"

    public var rowid: Int64
    public var bandID: String
    public var tsMs: Int64
    public var seq: Int
    public var rrMs: Double
    public var accepted: Bool

    enum CodingKeys: String, CodingKey {
        case rowid
        case bandID = "band_id"
        case tsMs = "ts_ms"
        case seq
        case rrMs = "rr_ms"
        case accepted
    }
}

public struct BandEventRow: Codable, Equatable, Sendable, FetchableRecord {
    public static let databaseTableName = "band_event"

    public var rowid: Int64
    public var bandID: String
    public var tsMs: Int64
    public var kind: String
    public var payload: String?

    enum CodingKeys: String, CodingKey {
        case rowid
        case bandID = "band_id"
        case tsMs = "ts_ms"
        case kind
        case payload
    }
}

/// One `minute_metric` row. `stressState` holds the raw `StressState` string.
public struct MinuteMetricRow: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "minute_metric"

    public var minuteMs: Int64
    public var hrAvg: Double?
    public var hrMin: Int?
    public var hrMax: Int?
    public var hrN: Int
    public var rmssdMs: Double?
    public var sdnnMs: Double?
    public var baevskySqrt: Double?
    public var stress: Int?
    public var stressState: String
    public var kcal: Double
    public var activeKcal: Double
    public var kcalEstimated: Bool
    public var algoVersion: Int
    public var computedAt: Int64
    public var syncRev: Int64

    enum CodingKeys: String, CodingKey {
        case minuteMs = "minute_ms"
        case hrAvg = "hr_avg"
        case hrMin = "hr_min"
        case hrMax = "hr_max"
        case hrN = "hr_n"
        case rmssdMs = "rmssd_ms"
        case sdnnMs = "sdnn_ms"
        case baevskySqrt = "baevsky_sqrt"
        case stress
        case stressState = "stress_state"
        case kcal
        case activeKcal = "active_kcal"
        case kcalEstimated = "kcal_estimated"
        case algoVersion = "algo_version"
        case computedAt = "computed_at"
        case syncRev = "sync_rev"
    }

    public init(
        minuteMs: Int64,
        hrAvg: Double?,
        hrMin: Int?,
        hrMax: Int?,
        hrN: Int,
        rmssdMs: Double?,
        sdnnMs: Double?,
        baevskySqrt: Double?,
        stress: Int?,
        stressState: String,
        kcal: Double,
        activeKcal: Double,
        kcalEstimated: Bool,
        algoVersion: Int,
        computedAt: Int64,
        syncRev: Int64
    ) {
        self.minuteMs = minuteMs
        self.hrAvg = hrAvg
        self.hrMin = hrMin
        self.hrMax = hrMax
        self.hrN = hrN
        self.rmssdMs = rmssdMs
        self.sdnnMs = sdnnMs
        self.baevskySqrt = baevskySqrt
        self.stress = stress
        self.stressState = stressState
        self.kcal = kcal
        self.activeKcal = activeKcal
        self.kcalEstimated = kcalEstimated
        self.algoVersion = algoVersion
        self.computedAt = computedAt
        self.syncRev = syncRev
    }

    public init(_ metric: MinuteMetric, computedAt: Int64, syncRev: Int64) {
        minuteMs = metric.minuteMs
        hrAvg = metric.hrAvg
        hrMin = metric.hrMin
        hrMax = metric.hrMax
        hrN = metric.hrN
        rmssdMs = metric.rmssdMs
        sdnnMs = metric.sdnnMs
        baevskySqrt = metric.baevskySqrt
        stress = metric.stress
        stressState = metric.stressState.rawValue
        kcal = metric.kcal
        activeKcal = metric.activeKcal
        kcalEstimated = metric.kcalEstimated
        algoVersion = metric.algoVersion.storedValue
        self.computedAt = computedAt
        self.syncRev = syncRev
    }

    public var state: StressState {
        StressState(rawValue: stressState) ?? .insufficient
    }

    /// Heart-rate aggregate for `RestingHR`, or nil when the minute had no samples.
    public var minuteAggregate: MinuteAggregate? {
        guard let hrAvg else { return nil }
        return MinuteAggregate(minuteMs: minuteMs, hrAvg: hrAvg, hrMin: hrMin ?? 0, hrMax: hrMax ?? 0, hrN: hrN)
    }

    /// True when every value column matches. `computed_at` and `sync_rev` are bookkeeping, not values.
    public func hasSameValues(as other: MinuteMetricRow) -> Bool {
        var lhs = self
        var rhs = other
        lhs.computedAt = 0
        lhs.syncRev = 0
        rhs.computedAt = 0
        rhs.syncRev = 0
        return lhs == rhs
    }
}

public struct SyncCursorRow: Codable, Equatable, Sendable, FetchableRecord {
    public static let databaseTableName = "sync_cursor"

    public var stream: String
    public var lastRowid: Int64
    public var lastSuccessAt: Int64?

    enum CodingKeys: String, CodingKey {
        case stream
        case lastRowid = "last_rowid"
        case lastSuccessAt = "last_success_at"
    }
}

public struct SyncBatchRow: Codable, Equatable, Sendable, FetchableRecord {
    public static let databaseTableName = "sync_batch_log"

    public var batchID: String
    public var createdAt: Int64
    public var rows: Int
    public var status: String
    public var httpStatus: Int?
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case batchID = "batch_id"
        case createdAt = "created_at"
        case rows
        case status
        case httpStatus = "http_status"
        case error
    }
}
