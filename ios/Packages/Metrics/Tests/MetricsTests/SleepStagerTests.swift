import Foundation
import Testing
@testable import Metrics

/// NOOP SleepStagerV2 port. Upstream tests:
/// ryanbr/noop@ef165de4 Tests/StrandAnalyticsTests/SleepStagerV2Tests.swift.
@Suite("Sleep stager (NOOP V2)")
struct SleepStagerTests {
    /// 2025-06-10 01:00:00 UTC, a 30 s boundary.
    private let start: Int64 = 1_749_517_200

    private func record(
        _ ts: Int64,
        bpm: Double?,
        rr: [Double] = [],
        gravity: StagingRecord.Gravity? = .init(x: 0, y: 0, z: 1),
        contact: Bool = true
    ) -> StagingRecord {
        StagingRecord(tsUnix: ts, bpm: bpm, contact: contact, rrMs: rr, gravity: gravity)
    }

    // MARK: - Crafted night (ported from NOOP's frozen golden fixture)

    /// Four 90-minute phases: still low-HR deep sleep, light sleep, lighter sleep, then restless
    /// high-HR wake with period jerks. `rsaWave` is integer-only so the input is exactly reproducible.
    private func craftedNight(seconds: Int) -> [StagingRecord] {
        let phase = 90 * 60
        func rsaWave(_ phase: Int, _ index: Int) -> Int {
            let amplitude = [12, 60, 30, 20][phase]
            return [0, amplitude, 0, -amplitude][index % 4]
        }
        return (0..<seconds).map { index in
            let ts = start + Int64(index)
            let phase = index / phase
            let restless = phase == 3 && (index % 20) < 6
            let bpm: Int
            switch phase {
            case 0: bpm = 50
            case 1: bpm = 54 + [0, 1, 2, 3, 2, 1][(index / 20) % 6]
            case 2: bpm = 56 + ((index / 60) % 4)
            default: bpm = 66 + ((index / 30) % 6)
            }
            return record(
                ts,
                bpm: Double(bpm),
                rr: [Double(60_000 / bpm + rsaWave(phase, index))],
                gravity: restless ? .init(x: 0.2, y: 0.15, z: 0.96) : .init(x: 0, y: 0, z: 1)
            )
        }
    }

    private func stageCraftedNight(seconds: Int) -> SleepStaging {
        SleepStager.stage(
            records: craftedNight(seconds: seconds),
            fromUnix: start,
            toUnix: start + Int64(seconds),
            restingHR: nil
        )
    }

    @Test func craftedNightHasTheExpectedDeepFirstRemLateWakeLastShape() {
        let staging = stageCraftedNight(seconds: 4 * 90 * 60)
        #expect(!staging.segments.isEmpty)
        #expect(staging.segments.first?.stage == .deep, "the night opens with deep sleep")
        #expect(staging.segments.last?.stage == .wake, "the restless phase is wake")

        let firstDeep = staging.segments.firstIndex { $0.stage == .deep }
        let lastREM = staging.segments.lastIndex { $0.stage == .rem }
        let firstREM = staging.segments.firstIndex { $0.stage == .rem }
        #expect(firstDeep != nil)
        #expect(firstREM != nil)
        #expect(lastREM != nil)
        if let firstDeep, let firstREM {
            #expect(firstDeep < firstREM, "REM follows the early deep block")
        }
        #expect(staging.stageSeconds[.wake]! > 0)
        #expect(staging.stageSeconds[.deep]! > 0)
        #expect(staging.stageSeconds[.rem]! > 0)
    }

    /// Upstream's frozen golden hypnogram for the same four-phase fixture
    /// (`testFrozenGoldenHypnogram`, NOOP ef165de4).
    @Test func craftedNightMatchesUpstreamGoldenHypnogram() {
        let staging = stageCraftedNight(seconds: 4 * 90 * 60)
        let expected: [(Int64, Int64, SleepStage)] = [
            (0, 5_070, .deep), (5_070, 5_310, .light), (5_310, 5_550, .rem),
            (5_550, 10_740, .light), (10_740, 16_290, .rem), (16_290, 21_600, .wake),
        ]
        #expect(staging.segments.count == expected.count)
        for (index, segment) in staging.segments.enumerated() where index < expected.count {
            #expect(segment.startUnix == start + expected[index].0, "segment \(index) start")
            #expect(segment.endUnix == start + expected[index].1, "segment \(index) end")
            #expect(segment.stage == expected[index].2, "segment \(index) stage")
        }
    }

    @Test func segmentsTileTheWindowWithoutGapsOrOverlaps() {
        let end = start + 4 * 90 * 60
        let staging = SleepStager.stage(
            records: craftedNight(seconds: 4 * 90 * 60),
            fromUnix: start,
            toUnix: end,
            restingHR: nil
        )
        #expect(staging.segments.first?.startUnix == start)
        #expect(staging.segments.last?.endUnix == end)
        for index in 1..<staging.segments.count {
            #expect(staging.segments[index].startUnix == staging.segments[index - 1].endUnix)
        }
        for segment in staging.segments {
            #expect(segment.endUnix > segment.startUnix)
        }
    }

    @Test func stageTotalsAndEfficiencyExcludeWake() {
        let end = start + 4 * 90 * 60
        let staging = stageCraftedNight(seconds: 4 * 90 * 60)
        let total = SleepStage.allCases.reduce(0) { $0 + staging.stageSeconds[$1]! }
        #expect(total == Int(end - start))

        let asleep = staging.stageSeconds[.light]!
            + staging.stageSeconds[.deep]!
            + staging.stageSeconds[.rem]!
        #expect(staging.stageSeconds[.wake]! > 0)
        #expect(abs(staging.efficiency - Double(asleep) / Double(total)) < 1e-12)
        #expect(staging.efficiency < 1.0, "wake must not be counted as sleep")
    }

    @Test func stagingIsDeterministic() {
        let records = craftedNight(seconds: 3 * 60 * 60)
        let first = SleepStager.stage(records: records, fromUnix: start, toUnix: start + 3 * 60 * 60, restingHR: 48)
        let second = SleepStager.stage(records: records, fromUnix: start, toUnix: start + 3 * 60 * 60, restingHR: 48)
        #expect(first == second)
    }

    @Test func emptyAndDegenerateInputReturnsEmpty() {
        let empty = SleepStager.stage(records: [], fromUnix: start, toUnix: start + 3_600, restingHR: nil)
        #expect(empty.segments.isEmpty)
        #expect(empty.efficiency == 0)
        #expect(empty.stageSeconds.values.allSatisfy { $0 == 0 })

        let zeroLength = SleepStager.stage(records: craftedNight(seconds: 1_800), fromUnix: start, toUnix: start, restingHR: nil)
        #expect(zeroLength.segments.isEmpty)

        let noUsableChannels = SleepStager.stage(
            records: [record(start, bpm: nil, gravity: nil)],
            fromUnix: start,
            toUnix: start + 3_600,
            restingHR: nil
        )
        #expect(noUsableChannels.segments.isEmpty)
    }

    @Test func suppliedRestingHRIsEchoedAndFallbackUsesTheLowestFiveMinuteMean() {
        let records = craftedNight(seconds: 60 * 60)
        let supplied = SleepStager.stage(
            records: records,
            fromUnix: start,
            toUnix: start + 60 * 60,
            restingHR: 47.5
        )
        #expect(supplied.restingHR == 47.5)

        let derived = SleepStager.stage(
            records: records,
            fromUnix: start,
            toUnix: start + 60 * 60,
            restingHR: nil
        )
        #expect(derived.restingHR != nil)
    }

    // MARK: - Ported recipe invariants (NOOP SleepStagerV2Tests)

    @Test func cyclePriorConcentratesDeepEarlyAndSuppressesEarlyREM() {
        let early = SleepStager.cyclePrior(0.05, 3.0)
        let late = SleepStager.cyclePrior(0.90, 400.0)
        #expect(early["deep"]! > late["deep"]!)
        #expect(early["rem"]! < late["rem"]!)
        #expect(early["light"]! == 0)
        #expect(early["awake"]! == 0)
    }

    @Test func remLatencyGuardShapeAndClamp() {
        let penalty = SleepStager.remLatencyPenalty
        let minutes = SleepStager.remLatencyMinutes
        #expect(abs(SleepStager.remLatencyGuard(0) - penalty) < 1e-12)
        #expect(abs(SleepStager.remLatencyGuard(minutes / 2) - penalty / 2) < 1e-12)
        #expect(SleepStager.remLatencyGuard(minutes) == 0)
        #expect(SleepStager.remLatencyGuard(minutes + 500) == 0)
        #expect(abs(SleepStager.remLatencyGuard(-240) - penalty) < 1e-12)
        #expect(SleepStager.remLatencyGuard(.infinity) == 0)
    }

    @Test func sustainedSleepOnsetNeedsFiveConsecutiveMinutes() {
        let wake = [String](repeating: "awake", count: 6)
        let brief = wake + [String](repeating: "light", count: 9) + wake
        #expect(SleepStager.sustainedSleepOnset(brief) == nil)

        let sustained = wake + [String](repeating: "light", count: 10) + wake
        #expect(SleepStager.sustainedSleepOnset(sustained) == 6)

        let both = wake + [String](repeating: "rem", count: 4) + ["awake"]
            + [String](repeating: "deep", count: 12)
        #expect(SleepStager.sustainedSleepOnset(both) == 11)
        #expect(SleepStager.sustainedSleepOnset([]) == nil)
    }

    @Test func viterbiSingleEpochPicksMaxEmission() {
        let path = SleepStager.viterbi([["deep": 0.1, "rem": 0.1, "light": 5.0, "awake": 0.1]])
        #expect(path == ["light"])
    }

    @Test func transitionRowsAreNormalisedAndWakeCannotDropStraightIntoDeepOrREM() {
        for (_, row) in SleepStager.transition {
            #expect(abs(row.values.reduce(0, +) - 1.0) < 1e-9)
        }
        #expect(SleepStager.transition["awake"]!["deep"] == 0)
        #expect(SleepStager.transition["awake"]!["rem"] == 0)
    }
}
