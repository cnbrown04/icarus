import Foundation

/// Reads shared/golden/metrics_v1.json, which the Rust core also consumes.
enum GoldenFixture {
    static func data() throws -> Data {
        // Test file: <repo>/ios/Packages/Metrics/Tests/MetricsTests/GoldenFixture.swift
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MetricsTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Metrics
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repo root
        return try Data(contentsOf: repoRoot.appendingPathComponent("shared/golden/metrics_v1.json"))
    }
}
