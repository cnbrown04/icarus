import Foundation

/// Launch arguments for deterministic UI tests and screenshots (PLAN.md §16.3).
/// Honoured only in DEBUG builds; release builds always get the defaults.
struct LaunchConfig: Equatable, Sendable {
    enum StartScreen: String, Sendable {
        case welcome
    }

    var isUITest = false
    var fixtureName: String?
    var fixedNow: Date?
    var startScreen: StartScreen?

    static let current = LaunchConfig(arguments: ProcessInfo.processInfo.arguments)

    init(arguments: [String]) {
        #if DEBUG
        var values: [String: String] = [:]
        for (index, argument) in arguments.enumerated() where argument.hasPrefix("-Icarus") && index + 1 < arguments.count {
            values[argument] = arguments[index + 1]
        }
        isUITest = values["-IcarusUITest"] == "1"
        fixtureName = values["-IcarusFixture"]
        fixedNow = values["-IcarusNow"].flatMap(Self.parseDate)
        startScreen = values["-IcarusScreen"].flatMap(StartScreen.init(rawValue:))
        // -IcarusSeedDB is accepted and ignored until Phase 2 (Store).
        #endif
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
