import Foundation
import GRDB

/// The local store (PLAN.md 7.4). A `DatabasePool` in WAL mode for the app file; a `DatabaseQueue`
/// in memory for tests and UI-test seeds. Both run the same migrations.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        Schema.registerMigrations(in: &migrator)
        try migrator.migrate(writer)
        self.writer = writer
    }

    /// Opens or creates the store file. The directory and files get
    /// `completeUntilFirstUserAuthentication`, so background writes work while the phone is locked (PLAN.md 7.4).
    public static func file(at url: URL) throws -> AppDatabase {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: url.path, configuration: configuration())
        #if canImport(Darwin)
        try protect(url: url, directory: directory)
        #endif
        return try AppDatabase(writer: pool)
    }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(writer: DatabaseQueue(configuration: configuration()))
    }

    /// Runs `observe` now and again after each write that changes its result. The stream ends when
    /// the consumer cancels or a read fails.
    public func observe<Value: Sendable>(
        _ tracking: @escaping @Sendable (Database) throws -> Value
    ) -> AsyncThrowingStream<Value, Error> {
        let observation = ValueObservation.tracking(tracking)
        let writer = writer
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in observation.values(in: writer) {
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        return configuration
    }

    #if canImport(Darwin)
    private static func protect(url: URL, directory: URL) throws {
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try FileManager.default.setAttributes(attributes, ofItemAtPath: directory.path)
        for path in [url.path, url.path + "-wal", url.path + "-shm"] where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.setAttributes(attributes, ofItemAtPath: path)
        }
    }
    #endif
}
