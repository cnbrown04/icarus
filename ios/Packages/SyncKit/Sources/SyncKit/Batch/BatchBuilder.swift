import Foundation
import GRDB
import Store

/// Stream positions: the rowid for each stream, or sync_rev for minute_metric (PLAN.md 10.2).
public typealias StreamPositions = [SyncStream: Int64]

/// One batch as built: the contract JSON and the positions it covers (PLAN.md 11.3).
public struct PreparedBatch: Sendable, Equatable {
    public let id: String
    /// The contract body (api-contract.md, Sync), uncompressed.
    public let body: Data
    public let rowCount: Int
    /// Where the batch read from: the acknowledged cursor, or past a quarantined batch.
    public let from: StreamPositions
    /// Where the batch read to. Equal to `from` for a stream with no rows in the batch.
    public let to: StreamPositions
}

/// Builds upload batches from the store (PLAN.md 11.3). Reads only; the caller records the batch.
public struct BatchBuilder: Sendable {
    /// Time-series rows per batch across all streams (api-contract.md, Sync).
    public static let defaultRowLimit = 20_000
    /// The server accepts 2 MB after decompression. This stays well under it.
    public static let defaultByteLimit = 1_500_000

    public let rowLimit: Int
    public let byteLimit: Int

    public init(rowLimit: Int = BatchBuilder.defaultRowLimit, byteLimit: Int = BatchBuilder.defaultByteLimit) {
        self.rowLimit = max(1, rowLimit)
        self.byteLimit = byteLimit
    }

    /// The next batch after `from`, or nil when no stream has rows past it.
    ///
    /// A batch carries one band. Band rows are taken as a prefix of each stream, so a cursor never skips a row of
    /// another band. Batches over `byteLimit` are rebuilt with half the row limit.
    public func build(
        _ db: Database,
        deviceID: UUID,
        from: StreamPositions,
        batchID: UUID,
        nowMs: Int64
    ) throws -> PreparedBatch? {
        var limit = rowLimit
        while true {
            guard let collected = try collect(db, from: from, limit: limit) else { return nil }
            let body = try Self.encode(collected, deviceID: deviceID, batchID: batchID, nowMs: nowMs)
            if body.count <= byteLimit || limit == 1 {
                return PreparedBatch(
                    id: batchID.uuidString.lowercased(),
                    body: body,
                    rowCount: collected.rowCount,
                    from: from,
                    to: collected.to
                )
            }
            limit = max(1, limit / 2)
        }
    }

    // MARK: Reading

    private struct Collected {
        var band: BandRow?
        var hr: [HeartRateRow] = []
        var rr: [RRIntervalRow] = []
        var events: [BandEventRow] = []
        var minutes: [MinuteMetricRow] = []
        var alarms: [AlarmDeliveryItem] = []
        var to: StreamPositions

        var rowCount: Int { hr.count + rr.count + events.count + minutes.count + alarms.count }
    }

    private func collect(_ db: Database, from: StreamPositions, limit: Int) throws -> Collected? {
        let hrPosition = from[.hrSample] ?? 0
        let rrPosition = from[.rrInterval] ?? 0
        let eventPosition = from[.bandEvent] ?? 0
        let firstHR = try db.pendingHeartRateRows(after: hrPosition, limit: 1).first
        let firstRR = try db.pendingRRRows(after: rrPosition, limit: 1).first
        let firstEvent = try db.pendingBandEventRows(after: eventPosition, limit: 1).first
        let bandID = firstHR?.bandID ?? firstRR?.bandID ?? firstEvent?.bandID

        var collected = Collected(to: from)
        var remaining = limit
        if let bandID {
            collected.band = try BandRow.fetchOne(db, sql: "SELECT * FROM band WHERE id = ?", arguments: [bandID])
            collected.hr = Self.prefix(try db.pendingHeartRateRows(after: hrPosition, limit: remaining), band: bandID) { $0.bandID }
            remaining -= collected.hr.count
            collected.rr = Self.prefix(try db.pendingRRRows(after: rrPosition, limit: remaining), band: bandID) { $0.bandID }
            remaining -= collected.rr.count
            collected.events = Self.prefix(try db.pendingBandEventRows(after: eventPosition, limit: remaining), band: bandID) { $0.bandID }
            remaining -= collected.events.count
        }
        collected.minutes = try db.pendingMinuteMetricRows(afterSyncRev: from[.minuteMetric] ?? 0, limit: remaining)
        remaining -= collected.minutes.count
        collected.alarms = try alarmDeliveries(db, after: from[.alarmDelivery] ?? 0, limit: remaining)

        guard collected.rowCount > 0 else { return nil }
        collected.to[.hrSample] = collected.hr.last?.rowid ?? hrPosition
        collected.to[.rrInterval] = collected.rr.last?.rowid ?? rrPosition
        collected.to[.bandEvent] = collected.events.last?.rowid ?? eventPosition
        collected.to[.minuteMetric] = collected.minutes.last?.syncRev ?? (from[.minuteMetric] ?? 0)
        collected.to[.alarmDelivery] = collected.alarms.last?.seq ?? (from[.alarmDelivery] ?? 0)
        return collected
    }

    /// Rows up to the first one that belongs to another band.
    private static func prefix<Row>(_ rows: [Row], band: String, of bandOf: (Row) -> String) -> [Row] {
        Array(rows.prefix { bandOf($0) == band })
    }

    /// `alarm_delivery` has no row type in Store. This reads its columns and keeps the rowid as `seq`.
    private func alarmDeliveries(_ db: Database, after position: Int64, limit: Int) throws -> [AlarmDeliveryItem] {
        guard limit > 0 else { return [] }
        return try Row.fetchAll(db, sql: """
        SELECT rowid AS seq, id, alarm_id, dispatch_id, ts_ms, channel, status, detail
        FROM alarm_delivery WHERE rowid > ? ORDER BY rowid LIMIT ?
        """, arguments: [position, limit]).map { row in
            AlarmDeliveryItem(
                seq: row["seq"],
                id: row["id"],
                alarmID: row["alarm_id"],
                dispatchID: row["dispatch_id"],
                tsMs: row["ts_ms"],
                channel: row["channel"],
                status: row["status"],
                detail: row["detail"]
            )
        }
    }

    // MARK: Encoding

    private static func encode(_ collected: Collected, deviceID: UUID, batchID: UUID, nowMs: Int64) throws -> Data {
        let body = BatchBody(
            batchID: batchID.uuidString.lowercased(),
            deviceID: deviceID.uuidString.lowercased(),
            createdAt: RFC3339.string(Date(epochMs: nowMs)),
            bands: collected.band.map { [BandDTO(id: $0.id, name: $0.name, firmware: $0.firmware)] } ?? [],
            hr: collected.band == nil || collected.hr.isEmpty ? nil : HeartRateColumns(collected.hr),
            rr: collected.band == nil || collected.rr.isEmpty ? nil : RRColumns(collected.rr),
            minuteMetrics: collected.minutes.map(MinuteDTO.init),
            events: collected.events.map(EventDTO.init),
            alarmDeliveries: collected.alarms.map(AlarmDeliveryDTO.init),
            cursors: [
                "hr_sample": collected.to[.hrSample] ?? 0,
                "rr_interval": collected.to[.rrInterval] ?? 0,
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(body)
    }
}

/// An `alarm_delivery` row as the batch sends it.
struct AlarmDeliveryItem {
    let seq: Int64
    let id: String
    let alarmID: String?
    let dispatchID: String?
    let tsMs: Int64
    let channel: String
    let status: String
    let detail: String?
}

// MARK: Contract body (api-contract.md, Sync)

struct BatchBody: Encodable {
    let batchID: String
    let deviceID: String
    let createdAt: String
    let bands: [BandDTO]
    let hr: HeartRateColumns?
    let rr: RRColumns?
    let minuteMetrics: [MinuteDTO]
    let events: [EventDTO]
    let alarmDeliveries: [AlarmDeliveryDTO]
    let cursors: [String: Int64]

    enum CodingKeys: String, CodingKey {
        case schema
        case batchID = "batch_id"
        case deviceID = "device_id"
        case createdAt = "created_at"
        case bands, hr, rr
        case minuteMetrics = "minute_metrics"
        case events
        case alarmDeliveries = "alarm_deliveries"
        case cursors
    }

    /// Optional fields are written as null, not left out, because the contract names every key.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .schema)
        try container.encode(batchID, forKey: .batchID)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(bands, forKey: .bands)
        try container.encode(hr, forKey: .hr)
        try container.encode(rr, forKey: .rr)
        try container.encode(minuteMetrics, forKey: .minuteMetrics)
        try container.encode(events, forKey: .events)
        try container.encode(alarmDeliveries, forKey: .alarmDeliveries)
        try container.encode(cursors, forKey: .cursors)
    }
}

struct BandDTO: Encodable {
    let id: String
    let name: String?
    let firmware: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(firmware, forKey: .firmware)
    }

    private enum Keys: String, CodingKey { case id, name, firmware }
}

struct HeartRateColumns: Encodable {
    let bandID: String
    let tsMs: [Int64]
    let bpm: [Int]
    let source: [Int]
    let contact: [Bool?]

    init(_ rows: [HeartRateRow]) {
        bandID = rows[0].bandID
        tsMs = rows.map(\.tsMs)
        bpm = rows.map(\.bpm)
        source = rows.map(\.source)
        contact = rows.map(\.contact)
    }

    enum CodingKeys: String, CodingKey {
        case bandID = "band_id"
        case tsMs = "ts_ms"
        case bpm, source, contact
    }
}

struct RRColumns: Encodable {
    let bandID: String
    let tsMs: [Int64]
    let seq: [Int]
    let rrMs: [Double]
    let accepted: [Bool]

    init(_ rows: [RRIntervalRow]) {
        bandID = rows[0].bandID
        tsMs = rows.map(\.tsMs)
        seq = rows.map(\.seq)
        rrMs = rows.map(\.rrMs)
        accepted = rows.map(\.accepted)
    }

    enum CodingKeys: String, CodingKey {
        case bandID = "band_id"
        case tsMs = "ts_ms"
        case seq
        case rrMs = "rr_ms"
        case accepted
    }
}

struct MinuteDTO: Encodable {
    let row: MinuteMetricRow

    init(_ row: MinuteMetricRow) {
        self.row = row
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(row.minuteMs, forKey: .minuteMs)
        try container.encode(row.hrAvg, forKey: .hrAvg)
        try container.encode(row.hrMin, forKey: .hrMin)
        try container.encode(row.hrMax, forKey: .hrMax)
        try container.encode(row.hrN, forKey: .hrN)
        try container.encode(row.rmssdMs, forKey: .rmssdMs)
        try container.encode(row.sdnnMs, forKey: .sdnnMs)
        try container.encode(row.baevskySqrt, forKey: .baevskySqrt)
        try container.encode(row.stress, forKey: .stress)
        try container.encode(row.stressState, forKey: .stressState)
        try container.encode(row.kcal, forKey: .kcal)
        try container.encode(row.activeKcal, forKey: .activeKcal)
        try container.encode(row.kcalEstimated, forKey: .kcalEstimated)
        try container.encode(row.algoVersion, forKey: .algoVersion)
        try container.encode(row.syncRev, forKey: .syncRev)
    }

    private enum Keys: String, CodingKey {
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
        case syncRev = "sync_rev"
    }
}

struct EventDTO: Encodable {
    let bandID: String
    let tsMs: Int64
    let kind: String
    let payload: JSONValue

    init(_ row: BandEventRow) {
        bandID = row.bandID
        tsMs = row.tsMs
        kind = row.kind
        // Payloads are stored as JSON text. An unreadable one goes as an empty object, not as a failed batch.
        payload = row.payload
            .flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) } ?? .object([:])
    }

    enum CodingKeys: String, CodingKey {
        case bandID = "band_id"
        case tsMs = "ts_ms"
        case kind, payload
    }
}

struct AlarmDeliveryDTO: Encodable {
    let item: AlarmDeliveryItem

    init(_ item: AlarmDeliveryItem) {
        self.item = item
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(item.id, forKey: .id)
        try container.encode(item.alarmID, forKey: .alarmID)
        try container.encode(item.dispatchID, forKey: .dispatchID)
        try container.encode(item.tsMs, forKey: .tsMs)
        try container.encode(item.channel, forKey: .channel)
        try container.encode(item.status, forKey: .status)
        try container.encode(item.detail, forKey: .detail)
    }

    private enum Keys: String, CodingKey {
        case id
        case alarmID = "alarm_id"
        case dispatchID = "dispatch_id"
        case tsMs = "ts_ms"
        case channel, status, detail
    }
}

extension Date {
    /// Date from epoch milliseconds (the store's unit). Internal, so it does not clash with the app's own helper.
    init(epochMs: Int64) {
        self.init(timeIntervalSince1970: Double(epochMs) / 1000)
    }
}
