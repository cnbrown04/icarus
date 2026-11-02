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
}
