import BandProtocol
import Foundation
import Metrics
import Store
import Testing
@testable import Icarus

struct BandTestAnalysisTests {
    /// The run's steps back to back, each its minimum length, with the given readings.
    private func marks(readings: [BandTestStep: Double] = [:], skipping skipped: Set<BandTestStep> = []) -> [BandTestMark] {
        var start: Int64 = 0
        return BandTestStep.allCases.map { step in
            let length = Int64(step.minimumSeconds) * 1000
            defer { start += length }
            return BandTestMark(runID: "r", step: step.rawValue, label: step.title, startMs: start, endMs: start + length,
                                skipped: skipped.contains(step), reading: readings[step])
        }
    }

    private func span(_ step: BandTestStep, in marks: [BandTestMark]) -> BandTestMark {
        marks.first { $0.step == step.rawValue }!
    }

    @Test func twoThermometerReadingsCalibrateFrame76() throws {
        let run = marks(readings: [.roomTemperature: 22, .wristTemperature: 33])
        let on = span(.backOn, in: run), wrist = span(.wristTemperature, in: run)
        // 280 counts as the band goes back on (room temperature), 340 in the last worn minute.
        let samples = stride(from: on.startMs, to: wrist.startMs, by: 1_000).map { ts in
            BandTestSample(tsMs: ts, frame76: ts < on.startMs + 30_000 ? 280 : 340)
        }
        let results = BandTestAnalysis.results(marks: run, samples: samples, frames: [])
        #expect(results.room == .init(celsius: 22, counts: 280))
        #expect(results.skin == .init(celsius: 33, counts: 340))
        let calibration = try #require(results.calibration)
        #expect(abs(calibration.slope - 11.0 / 60) < 1e-9)
        #expect(abs(calibration.celsius(310) - 27.5) < 1e-9)
    }

    @Test func aSkippedThermometerStepLeavesNoCalibration() {
        let run = marks(readings: [.roomTemperature: 22, .wristTemperature: 33], skipping: [.wristTemperature])
        let on = span(.backOn, in: run)
        let samples = (0..<60).map { BandTestSample(tsMs: on.startMs + Int64($0) * 1000, frame76: 300) }
        let results = BandTestAnalysis.results(marks: run, samples: samples, frames: [])
        #expect(results.room != nil)
        #expect(results.calibration == nil)
    }

    /// One R21 frame: four seconds of 25-a-second samples, with infrared (c) and red (f) carrying a 72-a-minute
    /// pulse on different levels.
    private func opticalFrame(second: Int, arrivalMs: Int64) -> BandTestFrame {
        var payload = [UInt8](repeating: 0, count: 1_241)
        let unix = UInt32(1_000 + second)
        for byte in 0..<4 { payload[4 + byte] = UInt8((unix >> (8 * byte)) & 0xFF) }
        payload[13] = 100
        let offsets = [17, 217, 417, 629, 829, 1_029]
        for (channel, start) in offsets.enumerated() {
            for i in 0..<100 {
                let t = Double(second) + Double(i) / 25
                let level: Double = channel == 5 ? 20_000 : 10_000
                let pulse = channel == 2 || channel == 5 ? 100 * sin(2 * .pi * 1.2 * t) : 0
                let value = UInt16(level + pulse)
                payload[start + i * 2] = UInt8(value & 0xFF)
                payload[start + i * 2 + 1] = UInt8(value >> 8)
            }
        }
        return BandTestFrame(tsMs: arrivalMs, seq: 21, payload: payload)
    }

    @Test func theOpticalChannelsThatSeeThePulseAreFound() throws {
        let run = marks()
        let still = span(.opticalStill, in: run)
        let frames = stride(from: 0, to: 120, by: 4).map { second in
            opticalFrame(second: second, arrivalMs: still.startMs + Int64(second) * 1000)
        } + [BandTestFrame(tsMs: still.startMs, seq: 10, payload: [1, 2])]
        let samples = (0..<120).map { BandTestSample(tsMs: still.startMs + Int64($0) * 1000, bpm: 72) }
        let results = BandTestAnalysis.results(marks: run, samples: samples, frames: frames)
        #expect(results.opticalRecords == 30)
        #expect(results.framesByType == ["21": 30, "10": 1])
        #expect(abs((results.sampleRate ?? 0) - 25) < 0.01)
        let byName = Dictionary(uniqueKeysWithValues: results.channels.map { ($0.channel, $0) })
        #expect(byName["c (infrared)"]?.followsPulse == true)
        #expect(byName["f (red)"]?.followsPulse == true)
        #expect(byName["a (green)"]?.followsPulse == false)
        let ratio = try #require(results.ratios.first { $0.step == .opticalStill }?.ratio)
        #expect(abs(ratio - 0.5) < 0.02)
    }

    @Test func anInProgressRunRoundTripsAndOldStepsAreNotResumed() {
        let saved = BandTestRunner.InProgress(runID: "r", step: BandTestStep.settle.rawValue,
                                              startedAt: Date(timeIntervalSince1970: 100))
        saved.save()
        #expect(BandTestRunner.InProgress.saved == saved)
        BandTestRunner.InProgress(runID: "old", step: 3, startedAt: Date()).save()
        #expect(BandTestRunner.InProgress.saved == nil)
        BandTestRunner.InProgress.clear()
    }
}
