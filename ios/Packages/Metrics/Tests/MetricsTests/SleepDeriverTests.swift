import Foundation
import Testing
@testable import Metrics

// Session summaries. WHERE sleep was is `SleepDetector`'s job (SleepDetectorTests); these cover what
// a detected window's row says, plus the derive() glue between the two.
@Suite("Sleep deriver")
struct SleepDeriverTests {
    private static let utc = TimeZone(identifier: "UTC")!

    private func unix(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.utc
        let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
        return Int64(date.timeIntervalSince1970)
    }

    private func record(
        _ unixSeconds: Int64,
        bpm: Double? = 55,
        rr: [Double] = [1_000],
        contact: Bool = true,
        resp: Double? = 600,
        temp: Double? = 3_100
    ) -> SleepRecord {
        SleepRecord(
            unixSeconds: unixSeconds,
            bpm: bpm,
            rrMs: rr,
            skinContact: contact,
            respRateRaw: resp,
            skinTempRaw: temp
        )
    }

    /// Records every `cadence` seconds from `start` until just before `end`.
    private func run(from start: Int64, until end: Int64, cadence: Int64 = 60, make: (Int64) -> SleepRecord) -> [SleepRecord] {
        stride(from: start, to: end, by: Int(cadence)).map(make)
    }

    private func summarize(_ records: [SleepRecord]) -> SleepSession? {
        let times = records.map(\.unixSeconds)
        return SleepDeriver.summarize(records, startUnix: times.min() ?? 0, endUnix: times.max() ?? 0)
    }

    // MARK: Aggregates

    @Test func summarizesAWindow() throws {
        let start = unix(2026, 10, 15, 23, 0)
        let end = unix(2026, 10, 16, 6, 30)
        let records = run(from: start, until: end) { offset in
            let minute = Int(offset - start) / 60
            return record(
                offset,
                bpm: 54 + Double(minute % 3), // 54, 55, 56 → median 55
                rr: [980 + Double(minute % 5) * 10] // 980..1020, all inside the cleaner range
            )
        }
        #expect(records.count == 450)

        let session = try #require(summarize(records))
        #expect(session.startUnix == start)
        #expect(session.endUnix == end - 60)
        #expect(session.durationSeconds == 450 * 60 - 60)
        #expect(session.restingHeartRate == 55)
        #expect(session.contactFraction == 1)
        #expect(session.quality == .good)
        #expect(session.recordCount == 450)
        #expect(session.respRateRawMedian == 600)
        #expect(session.skinTempRawMedian == 3_100)
        #expect(session.rmssdMs != nil) // the varied intervals survive the cleaner
    }

    @Test func rmssdMatchesTheSharedHRVAlgorithm() throws {
        let start = unix(2026, 10, 15, 23, 0)
        let rrPattern: [Double] = [980, 1_020, 1_000, 1_040, 960]
        let records = run(from: start, until: start + 90 * 60) { offset in
            let minute = Int(offset - start) / 60
            return record(offset, rr: [rrPattern[minute % rrPattern.count]])
        }

        let session = try #require(summarize(records))
        let allRR = records.flatMap(\.rrMs)
        let flags = RRCleaner.acceptedFlags(allRR)
        let accepted = zip(allRR, flags).compactMap { $1 ? $0 : nil }
        #expect(session.rmssdMs == HRV.rmssd(accepted))
        #expect(session.rmssdMs != nil)
    }

    @Test func offWristRecordsCountTowardContactButNotAggregates() throws {
        let start = unix(2026, 10, 15, 23, 0)
        let offStart = start + 60 * 60
        let records = run(from: start, until: start + 6 * 60 * 60) { offset in
            let onWrist = !(offset >= offStart && offset < offStart + 60 * 60)
            let minute = Int(offset - start) / 60
            // Off-wrist minutes carry garbage readings (200 bpm): they must not reach the median.
            return record(offset, bpm: onWrist ? 55 : 200, rr: onWrist ? [980 + Double(minute % 5) * 10] : [], contact: onWrist)
        }

        let session = try #require(summarize(records))
        #expect(session.recordCount == 6 * 60)
        // 5 h of 6 h on-wrist → 0.8333, fair.
        #expect(abs(session.contactFraction - 5 / 6.0) < 0.0001)
        #expect(session.quality == .fair)
        #expect(session.restingHeartRate == 55) // the off-wrist 200 bpm readings did not win
        #expect(session.rmssdMs != nil) // computed from the on-wrist intervals only
    }

    @Test func aPoorContactFractionIsFlagged() throws {
        let start = unix(2026, 10, 15, 23, 0)
        let records = run(from: start, until: start + 3 * 60 * 60) { offset in
            let minute = Int(offset - start) / 60
            return record(offset, contact: minute % 10 < 6) // 60% on-wrist
        }
        let session = try #require(summarize(records))
        #expect(abs(session.contactFraction - 0.6) < 0.0001)
        #expect(session.quality == .poor)
    }

    @Test func implausibleHeartRatesAreExcludedFromTheMedian() throws {
        let start = unix(2026, 10, 15, 23, 0)
        let records = run(from: start, until: start + 90 * 60) { offset in
            let minute = Int(offset - start) / 60
            return record(offset, bpm: minute == 30 ? 400 : 55)
        }
        #expect(try #require(summarize(records)).restingHeartRate == 55)
    }

    @Test func recordsWithNoReadingContributeNothing() throws {
        let start = unix(2026, 10, 15, 23, 0)
        let records = run(from: start, until: start + 90 * 60) { offset in
            let minute = Int(offset - start) / 60
            return record(offset, bpm: minute == 30 ? nil : 55)
        }
        #expect(try #require(summarize(records)).restingHeartRate == 55)
    }

    @Test func anEmptyOrZeroLengthWindowYieldsNothing() {
        let start = unix(2026, 10, 15, 23, 0)
        #expect(SleepDeriver.summarize([], startUnix: start, endUnix: start + 60) == nil)
        #expect(SleepDeriver.summarize([record(start)], startUnix: start, endUnix: start) == nil)
    }

    // MARK: derive()

    @Test func deriveSummarizesOnlyTheDetectedNight() throws {
        // The old deriver's 20 h "night" took its resting HR from the whole worn day (83 bpm on the
        // real record); the detected window's median is the sleeping HR alone.
        let zone = SleepDetectorTests.zone
        var stream = SleepDetectorTests.Stream()
        stream.add(from: SleepDetectorTests.local(20, 18), to: SleepDetectorTests.local(20, 23), .moving, bpm: 90)
        stream.add(from: SleepDetectorTests.local(20, 23), to: SleepDetectorTests.local(21, 7), .still, bpm: 58)
        stream.add(from: SleepDetectorTests.local(21, 7), to: SleepDetectorTests.local(21, 12), .moving, bpm: 90)

        let session = try #require(SleepDeriver.derive(stream.records, in: zone).only)
        let resting = try #require(session.restingHeartRate)
        #expect(abs(resting - 58) < 1.5)
        #expect(session.durationSeconds > 7 * 60 * 60)
        #expect(session.durationSeconds < 9 * 60 * 60)
        // Replayed batches and arrival order change nothing.
        let replayed = stream.records.reversed() + stream.records.prefix(1_000).map {
            SleepRecord(unixSeconds: $0.unixSeconds, bpm: 200, rrMs: [], skinContact: true, gravity: $0.gravity)
        }
        #expect(SleepDeriver.derive(Array(replayed), in: zone) == [session])
    }

    @Test func anEmptyStreamYieldsNothing() {
        #expect(SleepDeriver.derive([], in: Self.utc).isEmpty)
    }
}
