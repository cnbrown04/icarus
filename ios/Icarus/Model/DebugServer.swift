#if DEBUG
import Darwin
import Foundation
import GRDB
import BandKit
import Store

/// Debug-only HTTP server: serves the store's rows as JSON to a computer on the same Wi-Fi, so a
/// developer can inspect exactly what the app recorded — raw offload records, the sleep sessions
/// derived from them, live samples, frames and sync state.
///
/// GET only, one request per connection (`Connection: close`), fixed port so a computer can find the
/// phone without discovery. Started at launch in debug builds (IcarusApp) and from DebugView, which
/// shows the URL and a start/stop switch. Read-only: every query runs inside a `DatabasePool.read`,
/// so serving never blocks ingestion. A plain POSIX socket is used instead of Network.framework to
/// keep the concurrency surface trivial.
final class DebugServer: @unchecked Sendable {
    /// Fixed so a computer can reach the phone without mDNS discovery.
    static let port: UInt16 = 8087
    static let shared = DebugServer()

    // MARK: Responses

    /// Count, oldest and newest time for one table.
    struct TableStat: Codable, Sendable {
        let name: String
        let timeColumn: String
        let count: Int64
        let min: Int64?
        let max: Int64?
    }

    struct Summary: Codable, Sendable {
        let bands: [BandRow]
        let profileTZ: String?
        let tables: [TableStat]
        /// Acknowledged position per sync stream.
        let cursors: [String: Int64]
        let recentEvents: [BandEventRow]
        let recentBatches: [SyncBatchRow]
    }

    /// `raw_frame` has no row type in Store; this is only ever read here.
    struct RawFrame: Codable, Sendable, FetchableRecord {
        let rowid: Int64
        let tsMs: Int64
        let char: String
        let hex: String

        enum CodingKeys: String, CodingKey {
            case rowid, char, hex
            case tsMs = "ts_ms"
        }
    }

    private struct RowsResponse<Row: Codable & Sendable>: Codable, Sendable {
        let rows: [Row]
        let count: Int
    }

    private enum RouteError: Error {
        case badQuery(String)
    }

    // MARK: State

    private let lock = NSLock()
    private var database: AppDatabase?
    private var listenFD: Int32 = -1
    private var stopping = false
    private var thread: Thread?
    /// Last start failure, for DebugView. Cleared by a successful start.
    private(set) var lastError: String?

    private init() {}

    // MARK: Control

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listenFD >= 0
    }

    /// `http://<phone's Wi-Fi address>:8087` while running, when the phone has a Wi-Fi address.
    var url: String? {
        guard isRunning, let ip = Self.lanIPv4 else { return nil }
        return "http://\(ip):\(Self.port)"
    }

    /// Binds and starts the accept thread. Safe to call more than once; a running server wins.
    func start(database: AppDatabase) {
        lock.lock()
        defer { lock.unlock() }
        guard listenFD < 0 else { return }
        self.database = database
        stopping = false
        do {
            let fd = try Self.bind(port: Self.port)
            listenFD = fd
            lastError = nil
            let thread = Thread { [weak self] in self?.run() }
            thread.name = "DebugServer"
            thread.qualityOfService = .utility
            self.thread = thread
            thread.start()
        } catch {
            listenFD = -1
            lastError = "Start failed: \(error)"
        }
    }

    func stop() {
        lock.lock()
        stopping = true
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 {
            close(fd)
        }
    }

    // MARK: Sockets

    private static func bind(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError() }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: 0)
        let bound = withUnsafePointer(to: addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw posixError(code)
        }
        guard listen(fd, 4) == 0 else {
            let code = errno
            close(fd)
            throw posixError(code)
        }
        return fd
    }

    private static func posixError(_ code: Int32 = errno) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EINVAL)
    }

    /// Accepts one connection at a time until the listener is closed.
    private func run() {
        while true {
            lock.lock()
            let fd = listenFD
            let db = database
            let shouldStop = stopping
            lock.unlock()
            guard fd >= 0, !shouldStop, let db else { return }
            var clientAddr = sockaddr()
            var length = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(fd, &clientAddr, &length)
            if client < 0 {
                lock.lock()
                let closed = stopping || listenFD < 0
                lock.unlock()
                if closed { return }
                usleep(50_000)
                continue
            }
            serve(client, db)
            close(client)
        }
    }

    /// One request, then close. A bad or oversized request just ends the connection.
    private func serve(_ fd: Int32, _ db: AppDatabase) {
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard let target = readTarget(fd) else { return }
        let (path, params) = Self.split(target)
        var status = 200
        var body = Data()
        do {
            switch path {
            case "/healthz":
                body = try Self.json(["status": "ok"])
            case "/db":
                body = try Self.json(try Self.summary(db))
            case "/historical":
                let rows = try Self.historicalRows(db, params)
                body = try Self.json(Self.RowsResponse(rows: rows, count: rows.count))
            case "/sleep":
                let rows = try Self.sleepRows(db, params)
                body = try Self.json(Self.RowsResponse(rows: rows, count: rows.count))
            case "/hr":
                let rows = try Self.hrRows(db, params)
                body = try Self.json(Self.RowsResponse(rows: rows, count: rows.count))
            case "/minutes":
                let rows = try Self.minuteRows(db, params)
                body = try Self.json(Self.RowsResponse(rows: rows, count: rows.count))
            case "/events":
                let rows = try Self.eventRows(db, params)
                body = try Self.json(Self.RowsResponse(rows: rows, count: rows.count))
            case "/frames":
                let rows = try Self.frameRows(db, params)
                body = try Self.json(Self.RowsResponse(rows: rows, count: rows.count))
            case "/bands":
                let rows = try db.writer.read { db in
                    try BandRow.fetchAll(db, sql: "SELECT * FROM band ORDER BY created_at")
                }
                body = try Self.json(Self.RowsResponse(rows: rows, count: rows.count))
            case "/log":
                body = try Self.json(BandLogCapture.shared.latest(1_000))
            default:
                status = 404
                body = try Self.json(["error": "Unknown path \(path)."])
            }
        } catch let error as RouteError {
            status = 400
            body = (try? Self.json(["error": "\(error)"])) ?? Data()
        } catch {
            status = 500
            body = (try? Self.json(["error": String(describing: error)])) ?? Data()
        }
        respond(fd, status: status, body: body)
    }

    /// Writes one response, then the caller closes.
    private func respond(_ fd: Int32, status: Int, body: Data) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        default: reason = "Internal Server Error"
        }
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        var offset = 0
        out.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            while offset < out.count {
                let sent = send(fd, raw.baseAddress!.advanced(by: offset), out.count - offset, 0)
                guard sent > 0 else { return }
                offset += sent
            }
        }
    }

    /// Reads the request head (the GET has no body), returns the request target `/path?query`.
    private func readTarget(_ fd: Int32) -> String? {
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { return nil }
            request.append(contentsOf: buffer[0..<n])
            if request.range(of: Data("\r\n\r\n".utf8)) != nil { break }
            if request.count > 16_384 { return nil }
        }
        guard let text = String(bytes: request.prefix(16_384), encoding: .utf8),
              let lineEnd = text.range(of: "\r\n")
        else { return nil }
        let parts = text[..<lineEnd.lowerBound].split(separator: " ")
        guard parts.count == 3, parts[0] == "GET" else { return nil }
        return String(parts[1])
    }

    /// Splits `/path?query` and percent-decodes the query values.
    private static func split(_ target: String) -> (String, [String: String]) {
        let pieces = target.split(separator: "?", maxSplits: 1)
        let path = String(pieces.first ?? Substring(target))
        var params: [String: String] = [:]
        if pieces.count > 1 {
            for pair in pieces[1].split(separator: "&") {
                let halves = pair.split(separator: "=", maxSplits: 1)
                let key = String(halves[0]).removingPercentEncoding ?? String(halves[0])
                let value = halves.count > 1
                    ? (String(halves[1]).removingPercentEncoding ?? String(halves[1]))
                    : ""
                params[key] = value
            }
        }
        return (path, params)
    }

    // MARK: Queries

    private static func summary(_ db: AppDatabase) throws -> Summary {
        try db.writer.read { db in
            let bands = try BandRow.fetchAll(db, sql: "SELECT * FROM band ORDER BY created_at")
            let tz: String? = try String.fetchOne(db, sql: "SELECT tz FROM profile WHERE id = 1")
            let sources: [(String, String)] = [
                ("hr_sample", "ts_ms"),
                ("rr_interval", "ts_ms"),
                ("minute_metric", "minute_ms"),
                ("band_event", "ts_ms"),
                ("alarm_delivery", "ts_ms"),
                ("historical_record", "ts_ms"),
                ("sleep_session", "start_ms"),
                ("raw_frame", "ts_ms"),
            ]
            let tables = try sources.map { (name, column) -> TableStat in
                let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS count, MIN(\(column)) AS min, MAX(\(column)) AS max FROM \(name)
                """)
                let count: Int64 = row?["count"] ?? 0
                let min: Int64? = row?["min"]
                let max: Int64? = row?["max"]
                return TableStat(name: name, timeColumn: column, count: count, min: min, max: max)
            }
            let cursors = try Dictionary(
                uniqueKeysWithValues: SyncStream.allCases.map { stream in
                    (stream.rawValue, try db.syncCursor(stream))
                }
            )
            let events = try BandEventRow.fetchAll(
                db, sql: "SELECT * FROM band_event ORDER BY rowid DESC LIMIT 20"
            )
            let batches = try SyncBatchRow.fetchAll(
                db, sql: "SELECT * FROM sync_batch_log ORDER BY created_at DESC LIMIT 10"
            )
            return Summary(
                bands: bands,
                profileTZ: tz,
                tables: tables,
                cursors: cursors,
                recentEvents: events,
                recentBatches: batches
            )
        }
    }

    private static func historicalRows(_ db: AppDatabase, _ params: [String: String]) throws -> [HistoricalRecordRow] {
        let from = try int64(params, "from_ms", default: 0)
        let to = try int64(params, "to_ms", default: Int64.max)
        let limit = try int64(params, "limit", default: 20_000)
        return try db.writer.read { db in
            try HistoricalRecordRow.fetchAll(db, sql: """
            SELECT * FROM historical_record WHERE ts_ms >= ? AND ts_ms <= ? ORDER BY ts_ms LIMIT ?
            """, arguments: [from, to, limit])
        }
    }

    private static func sleepRows(_ db: AppDatabase, _ params: [String: String]) throws -> [SleepSessionRow] {
        let limit = try int64(params, "limit", default: 500)
        return try db.writer.read { db in
            try SleepSessionRow.fetchAll(db, sql: """
            SELECT * FROM sleep_session ORDER BY start_ms DESC LIMIT ?
            """, arguments: [limit])
        }
    }

    private static func hrRows(_ db: AppDatabase, _ params: [String: String]) throws -> [HeartRateRow] {
        let from = try int64(params, "from_ms", default: 0)
        let to = try int64(params, "to_ms", default: Int64.max)
        let limit = try int64(params, "limit", default: 20_000)
        return try db.writer.read { db in
            try HeartRateRow.fetchAll(db, sql: """
            SELECT * FROM hr_sample WHERE ts_ms >= ? AND ts_ms <= ? ORDER BY ts_ms LIMIT ?
            """, arguments: [from, to, limit])
        }
    }

    private static func minuteRows(_ db: AppDatabase, _ params: [String: String]) throws -> [MinuteMetricRow] {
        let limit = try int64(params, "limit", default: 1_440)
        return try db.writer.read { db in
            try MinuteMetricRow.fetchAll(db, sql: """
            SELECT * FROM minute_metric ORDER BY minute_ms DESC LIMIT ?
            """, arguments: [limit])
        }
    }

    private static func eventRows(_ db: AppDatabase, _ params: [String: String]) throws -> [BandEventRow] {
        let limit = try int64(params, "limit", default: 200)
        return try db.writer.read { db in
            try BandEventRow.fetchAll(db, sql: """
            SELECT * FROM band_event ORDER BY rowid DESC LIMIT ?
            """, arguments: [limit])
        }
    }

    private static func frameRows(_ db: AppDatabase, _ params: [String: String]) throws -> [RawFrame] {
        let limit = try int64(params, "limit", default: 1_000)
        return try db.writer.read { db in
            try RawFrame.fetchAll(db, sql: """
            SELECT rowid AS rowid, ts_ms, char, hex FROM raw_frame ORDER BY rowid DESC LIMIT ?
            """, arguments: [limit])
        }
    }

    private static func int64(
        _ params: [String: String],
        _ key: String,
        default fallback: @autoclosure () -> Int64
    ) throws -> Int64 {
        guard let raw = params[key], !raw.isEmpty else { return fallback() }
        guard let value = Int64(raw), value >= 0 else {
            throw RouteError.badQuery("\(key) must be a non-negative integer.")
        }
        return value
    }

    // MARK: Encoding

    private static func json(_ value: some Encodable & Sendable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    // MARK: Address

    /// The phone's Wi-Fi IPv4 address, for the URL DebugView shows.
    static var lanIPv4: String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(first) }
        var wifi: String?
        var fallback: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let interface = current.pointee
            cursor = interface.ifa_next
            guard let sa = interface.ifa_addr,
                  sa.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            let addr = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_in.self).pointee
            var address = addr.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let ip = String(decoding: buffer.map(UInt8.init).prefix(while: { $0 != 0 }), as: UTF8.self)
            let name = String(cString: interface.ifa_name)
            if name == "en0" {
                wifi = ip
            } else if name.hasPrefix("en"), fallback == nil {
                fallback = ip
            }
        }
        return wifi ?? fallback
    }
}
#endif
