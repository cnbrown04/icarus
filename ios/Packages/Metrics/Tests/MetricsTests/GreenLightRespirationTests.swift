import Foundation
import Testing
@testable import Metrics

@Suite("Green-light respiration")
struct GreenLightRespirationTests {
    private let times = (0..<300).map(Double.init)

    @Test func recoversTheBreathingRateFromAModulatedLevel() throws {
        // 15 breaths/min (0.25 Hz) riding on a drifting level.
        let green = times.map { 20_000 + 2 * $0 + 300 * sin(2 * .pi * 0.25 * $0) }
        let rate = try GreenLightRespiration.estimate(green: green, timesSec: times, meanHeartRate: 66).get()
        #expect(abs(rate - 15) < 0.3)
    }

    @Test func aPeakOnThePulseAliasIsWithheld() {
        // A 72 bpm pulse (1.2 Hz) sampled once a second shows up at 0.2 Hz.
        let green = times.map { 20_000 + 300 * sin(2 * .pi * 1.2 * $0) }
        let result = GreenLightRespiration.estimate(green: green, timesSec: times, meanHeartRate: 72)
        #expect(result == .failure(.init(.pulseAlias)))
    }

    @Test func aMovingWindowIsWithheld() {
        let green = times.map { 20_000 + 300 * sin(2 * .pi * 0.25 * $0) }
        let gravity = times.map { t in (x: t < 150 ? 0.0 : 0.3, y: 0.0, z: 1.0) }
        let result = GreenLightRespiration.estimate(green: green, timesSec: times, meanHeartRate: 66, gravity: gravity)
        #expect(result == .failure(.init(.moving)))
    }

    @Test func tooFewOrTooSparseSamplesAreWithheld() {
        #expect(GreenLightRespiration.estimate(green: [1, 2, 3], timesSec: [0, 1, 2], meanHeartRate: nil)
            == .failure(.init(.tooFewSamples)))
        let sparse = (0..<60).map { Double($0) * 5 }
        #expect(GreenLightRespiration.estimate(green: sparse.map(sin), timesSec: sparse, meanHeartRate: nil)
            == .failure(.init(.cadenceTooSlow)))
    }
}
