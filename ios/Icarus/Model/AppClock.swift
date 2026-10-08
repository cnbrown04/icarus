import Foundation

/// Wall clock, or the fixed instant from -IcarusNow in DEBUG UI-test runs.
struct AppClock: Sendable {
    let fixedNow: Date?

    var now: Date {
        fixedNow ?? Date()
    }
}
