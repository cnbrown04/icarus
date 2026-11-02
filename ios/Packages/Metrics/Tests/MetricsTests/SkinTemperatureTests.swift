import Foundation
import Testing
@testable import Metrics

@Suite("Skin temperature")
struct SkinTemperatureTests {
    @Test func aColdWarmUpIsLeftOutButAFeverIsKept() throws {
        // 10 % of the night still warming up 60 counts low, the rest at 340.
        let warmUp = Array(repeating: 280.0, count: 60) + Array(repeating: 340.0, count: 540)
        let night = try #require(SkinTemperature.nightly(warmUp))
        #expect(night == 340)

        // A warm stretch (a fever) is above the median and passes through, raising the night.
        let warm = Array(repeating: 340.0, count: 400) + Array(repeating: 360.0, count: 200)
        let feverish = try #require(SkinTemperature.nightly(warm))
        #expect(feverish > 345)
    }

    @Test func aNightMostlyBelowSkinTemperatureHasNoValue() {
        // Half the night off the wrist or warming: under 80 % settled.
        let unsettled = Array(repeating: 280.0, count: 300) + Array(repeating: 340.0, count: 300)
        #expect(SkinTemperature.nightly(unsettled) == nil)
        #expect(SkinTemperature.nightly(Array(repeating: 340, count: 30)) == nil)
    }

    @Test func theSessionCarriesTheSettledFrame76Mean() throws {
        let records = (0..<600).map { second in
            SleepRecord(unixSeconds: Int64(second), bpm: 55, rrMs: [], skinContact: true, skinTempRaw: 1_000,
                        skinTemp: second < 60 ? 280 : 340)
        }
        let session = try #require(SleepDeriver.summarize(records, startUnix: 0, endUnix: 599))
        #expect(session.skinTemperature == 340)
    }
}
