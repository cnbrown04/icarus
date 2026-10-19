import Foundation
#if canImport(os)
import os
#endif

/// Two-digit hex for log lines (frames and payloads), e.g. `AA 0F 23`.
func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

/// os.Logger outlets for the band link (PLAN.md 7.2 debugging). Two categories keep Console can
/// `log stream` filterable:
///
///     log stream --process Icarus --level debug --predicate 'subsystem == "com.cnbrown04.icarus"'
///
/// Messages are plain strings built at the call site — link diagnostics, not user data — so they
/// are marked public and are never redacted. On Linux (the pure-logic test target) `os` does not
/// exist and the calls compile to no-ops.
public enum BandLog {
    /// The Tier A link: central state, scan, connect, service and characteristic discovery,
    /// subscriptions and disconnects (CoreBluetooth routes).
    public static func link(_ level: Level, _ message: @autoclosure () -> String) {
        let text = message()
        #if canImport(os)
        linkLogger.log(level: level.os, "\(text, privacy: .public)")
        #endif
        #if DEBUG
        BandLogCapture.shared.record("link", level.name, text)
        #endif
    }

    /// Tier B (the Whoop custom service): setup, bonding, handshake and the command/reply path.
    public static func tierB(_ level: Level, _ message: @autoclosure () -> String) {
        let text = message()
        #if canImport(os)
        tierBLogger.log(level: level.os, "\(text, privacy: .public)")
        #endif
        #if DEBUG
        BandLogCapture.shared.record("tierb", level.name, text)
        #endif
    }

    #if DEBUG
    /// Starts DEBUG-only capture of link and Tier B lines to a file, so a computer can pull the
    /// full handshake/drain trail that os_log does not persist.
    public static func startCapture(at url: URL) {
        BandLogCapture.shared.start(at: url)
    }

    /// The newest captured lines, oldest first.
    public static func capturedLines(_ count: Int) -> [String] {
        BandLogCapture.shared.latest(count)
    }
    #endif

    public enum Level: Sendable {
        case debug
        case info
        case error

        var name: String {
            switch self {
            case .debug: "D"
            case .info: "I"
            case .error: "E"
            }
        }

        #if canImport(os)
        var os: OSLogType {
            switch self {
            case .debug: .debug
            case .info: .info
            case .error: .error
            }
        }
        #endif
    }

    #if canImport(os)
    private static let linkLogger = Logger(subsystem: "com.cnbrown04.icarus", category: "band.link")
    private static let tierBLogger = Logger(subsystem: "com.cnbrown04.icarus", category: "band.tierb")
    #endif
}

#if DEBUG
/// DEBUG-only on-device capture of `BandLog` lines: a bounded in-memory ring plus an append-only
/// text file. os_log drops info/debug lines shortly after they are logged, so the file is the only
/// durable record of a handshake or offload drain — a computer pulls it with `devicectl copy`.
public final class BandLogCapture: @unchecked Sendable {
    public static let shared = BandLogCapture()

    private let lock = NSLock()
    private var lines: [String] = []
    private var handle: FileHandle?

    private init() {}

    /// Starts capturing to `url`. The previous capture is rotated to a timestamped sibling (keeping
    /// the newest few), so an app restart overnight or the next morning still leaves every session's
    /// log on disk for a computer to pull. No-op without a call.
    func start(at url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard handle == nil else { return }
        Self.rotate(url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = FileHandle(forWritingAtPath: url.path)
        if handle == nil {
            record("capture", "E", "could not open \(url.path)")
        }
    }

    /// Renames an existing non-empty capture to `band_log_<stamp>.txt` and prunes old rotations.
    private static func rotate(_ url: URL) {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size > 0
        else { return }
        let stamp = DateFormatter.logStamp.string(from: Date()).replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: " ", with: "_")
        let rotated = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)_\(stamp).txt")
        try? manager.moveItem(atPath: url.path, toPath: rotated.path)
        // Keep the newest few rotations; this is a debug aid, not a data store. The stamp is
        // sortable, so name order is age order.
        let prefix = "\(url.deletingPathExtension().lastPathComponent)_"
        let siblings = (try? manager.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
        let rotations = siblings
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".txt") }
            .sorted(by: >)
        for stale in rotations.dropFirst(5) {
            try? manager.removeItem(atPath: url.deletingLastPathComponent().appendingPathComponent(stale).path)
        }
    }

    func record(_ category: String, _ level: String, _ text: String) {
        let stamp = DateFormatter.logStamp.string(from: Date())
        let line = "\(stamp) [\(category)] \(level) \(text)\n"
        lock.lock()
        lines.append(line)
        if lines.count > 2_000 {
            lines.removeFirst(lines.count - 2_000)
        }
        let handle = self.handle
        lock.unlock()
        if let handle, let data = line.data(using: .utf8) {
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                handle.closeFile()
                lock.lock()
                self.handle = nil
                lock.unlock()
            }
        }
    }

    /// The newest `count` captured lines, oldest first.
    public func latest(_ count: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(lines.suffix(count))
    }
}

private extension DateFormatter {
    static let logStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
#endif
