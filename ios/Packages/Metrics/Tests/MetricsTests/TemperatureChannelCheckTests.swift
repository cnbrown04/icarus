import Foundation
import Testing
@testable import Metrics

@Suite("Temperature channel check")
struct TemperatureChannelCheckTests {
    /// A thermistor-like channel: flat at 300 for 3 minutes, rising toward 340 off the wrist, falling back on it.
    private func run(_ value: (Double) -> Double) -> (b: [(t: Double, v: Double)], off: [(t: Double, v: Double)], on: [(t: Double, v: Double)]) {
        let b = (0..<180).map { (t: Double($0), v: value(Double($0))) }
        let off = (180..<1380).map { (t: Double($0), v: value(Double($0))) }
        let on = (1380..<2580).map { (t: Double($0), v: value(Double($0))) }
        return (b, off, on)
    }

    @Test func aSlowChannelThatMovesOffAndBackPasses() {
        let r = run { t in
            if t < 180 { return 300 }
            if t < 1380 { return 300 + 40 * (1 - exp(-(t - 180) / 400)) }
            let peak = 300 + 40 * (1 - exp(-1200.0 / 400))
            return 300 + (peak - 300) * exp(-(t - 1380) / 300)
        }
        let verdict = TemperatureChannelCheck.judge(baseline: r.b, off: r.off, on: r.on)
        #expect(verdict.passes)
        #expect((verdict.offChange ?? 0) > 0)
        #expect((verdict.onChange ?? 0) < 0)
    }

    @Test func aFastMovingChannelFails() {
        // Jumps ~11 counts every second, like frame 72 on the real band.
        let r = run { t in 600 + 11 * Double(Int(t) % 2) + (t > 180 && t < 1380 ? (t - 180) / 30 : 0) }
        let verdict = TemperatureChannelCheck.judge(baseline: r.b, off: r.off, on: r.on)
        #expect(!verdict.passes)
        #expect((verdict.medianStep ?? 0) >= 1)
    }

    @Test func aChannelThatKeepsGoingTheSameWayFails() {
        let r = run { t in 300 + t / 60 }
        let verdict = TemperatureChannelCheck.judge(baseline: r.b, off: r.off, on: r.on)
        #expect(!verdict.passes)
    }

    /// The real band records nothing off the wrist: the cooling shows as the step across the gap. Shaped on frame 76
    /// from the first run (327 before, 266 back on, climbing to 316 over 20 minutes).
    @Test func withNoRecordsOffTheWristTheGapCarriesTheOffMove() {
        let baseline = (0..<180).map { (t: Double($0), v: 327.0) }
        let on = (1380..<2580).map { t in (t: Double(t), v: 316 - 50 * exp(-(Double(t) - 1380) / 300)) }
        let verdict = TemperatureChannelCheck.judge(baseline: baseline, off: [], on: on)
        #expect(verdict.passes)
        #expect((verdict.offChange ?? 0) < -50)
        #expect(verdict.offSteadiness == nil)

        // Frame 92's shape: no drop while off, then a rise. Same direction both times: not skin temperature.
        let flat: [(t: Double, v: Double)] = (0..<180).map { (t: Double($0), v: 16_521) }
        let rising: [(t: Double, v: Double)] = (1380..<2580).map { second in
            let t = Double(second)
            return (t: t, v: 16_533 + 79 * (t - 1380) / 1200)
        }
        let frame92 = TemperatureChannelCheck.judge(baseline: flat, off: [], on: rising)
        #expect(!frame92.passes)
    }
}
