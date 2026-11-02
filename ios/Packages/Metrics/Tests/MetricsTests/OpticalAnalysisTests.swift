import Foundation
import Testing
@testable import Metrics

@Suite("Optical analysis")
struct OpticalAnalysisTests {
    /// 30 s at 25 Hz of a level carrying a 72-a-minute pulse.
    private func channel(level: Double, pulse: Double) -> [Double] {
        (0..<750).map { i in level + pulse * sin(2 * .pi * 1.2 * Double(i) / 25) }
    }

    @Test func findsThePulseAndItsSizeAgainstTheLevel() throws {
        let summary = try #require(OpticalAnalysis.summarize(channel(level: 10_000, pulse: 100), sampleRate: 25))
        #expect(abs((summary.pulsePerMinute ?? 0) - 72) < 1)
        #expect(abs(summary.dc - 10_000) < 1)
        #expect(abs(summary.acOverDC - 100 / 2.0.squareRoot() / 10_000) < 0.0005)
    }

    @Test func theRatioOfRatiosComparesThePulsesAgainstTheirLevels() throws {
        let red = try #require(OpticalAnalysis.summarize(channel(level: 20_000, pulse: 100), sampleRate: 25))
        let infrared = try #require(OpticalAnalysis.summarize(channel(level: 10_000, pulse: 100), sampleRate: 25))
        let ratio = try #require(OpticalAnalysis.ratioOfRatios(red: red, infrared: infrared))
        #expect(abs(ratio - 0.5) < 0.01)
    }

    @Test func tooShortOrFlatHasNoSummary() {
        #expect(OpticalAnalysis.summarize(Array(repeating: 5, count: 750), sampleRate: 25) == nil)
        #expect(OpticalAnalysis.summarize(channel(level: 1, pulse: 1).prefix(50).map { $0 }, sampleRate: 25) == nil)
    }
}
