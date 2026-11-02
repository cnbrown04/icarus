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
        // Lowest 5-minute bin: bins hold 54.8 bpm on average at best (the 54/55/56 cycle over five minutes).
        let resting = try #require(session.restingHeartRate)
        #expect(abs(resting - 54.8) < 1e-9)
        #expect(session.contactFraction == 1)
        #expect(session.quality == .good)
        #expect(session.recordCount == 450)
        #expect(session.respRateRawMedian == 600)
        // Frame 72 is stored but is not temperature; with no frame-76 samples there is no skin temperature.
        #expect(session.skinTemperature == nil)
        // Records a minute apart never carry a successive difference, so there is no RMSSD to report.
        #expect(session.rmssdMs == nil)
    }

    /// The readings are what the nightly values summarise: resting HR is their floor, RMSSD their mean.
    @Test func readingsAgreeWithTheNightlyValues() throws {
        let start = unix(2026, 10, 15, 23, 0)
        let end = unix(2026, 10, 16, 1, 0)
        let records = run(from: start, until: end, cadence: 1) { offset in
            let second = Int(offset - start)
            return record(offset, bpm: 50 + Double((second / 600) % 4), rr: [second.isMultiple(of: 2) ? 1_000 : 1_040 + Double((second / 900) % 3) * 10])
        }
        let session = try #require(SleepDeriver.summarize(records, startUnix: start, endUnix: end))
        let resting = SleepDeriver.readings(.restingHR, records, startUnix: start, endUnix: end)
        let hrv = SleepDeriver.readings(.hrv, records, startUnix: start, endUnix: end)

        #expect(resting.count == 24)
        #expect(resting.first?.unixSeconds == start)
        #expect(resting.map(\.value).min() == session.restingHeartRate)
        let rmssd = hrv.map(\.value)
        #expect(!rmssd.isEmpty)
        let mean = rmssd.reduce(0, +) / Double(rmssd.count)
        #expect(abs(mean - (session.rmssdMs ?? -1)) < 1e-9)
        #expect(hrv.map(\.unixSeconds) == hrv.map(\.unixSeconds).sorted())
        // The session keeps the same readings it summarised.
        #expect(session.readings.restingHR == resting)
        #expect(session.readings.hrv == hrv)
    }

    @Test func rmssdIsTheMeanOfPerWindowRMSSD() throws {
        // 1 Hz beats alternating 1000 / 1040 ms: every successive difference is 40 ms, so every full
        // 5-minute window has RMSSD 40 and the session mean is 40.
        let start = unix(2026, 10, 15, 23, 0)
        let records = run(from: start, until: start + 90 * 60, cadence: 1) { offset in
            record(offset, rr: [(offset - start) % 2 == 0 ? 1_000 : 1_040])
        }

        let session = try #require(summarize(records))
        #expect(session.rmssdMs == 40)
    }

    @Test func offWristRecordsCountTowardContactButNotAggregates() throws {
        let start = unix(2026, 10, 15, 23, 0)
        let offStart = start + 60 * 60
        let records = run(from: start, until: start + 6 * 60 * 60, cadence: 1) { offset in
            let onWrist = !(offset >= offStart && offset < offStart + 60 * 60)
            let minute = Int(offset - start) / 60
            // Off-wrist minutes carry no heart rate (the strap records 0); the contact byte is a
            // quality value and plays no part.
            return record(offset, bpm: onWrist ? 55 : nil, rr: onWrist ? [980 + Double(minute % 5) * 10] : [], contact: true)
        }

        let session = try #require(summarize(records))
        #expect(session.recordCount == 6 * 60 * 60)
        // 5 h of 6 h on-wrist → 0.8333, fair.
        #expect(abs(session.contactFraction - 5 / 6.0) < 0.0001)
        #expect(session.quality == .fair)
        #expect(session.restingHeartRate == 55)
        #expect(session.rmssdMs != nil) // computed from the on-wrist intervals only
    }

    @Test func aPoorContactFractionIsFlagged() throws {
        let start = unix(2026, 10, 15, 23, 0)
        let records = run(from: start, until: start + 3 * 60 * 60) { offset in
            let minute = Int(offset - start) / 60
            return record(offset, bpm: minute % 10 < 6 ? 55 : nil) // 60% on-wrist
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

    @Test func restingHRIsTheLowestWellPopulatedFiveMinuteBin() throws {
        // An hour at 70 bpm, plus three records at 45 bpm in the 00:00-00:05 bin. Three samples are below
        // the five a bin needs to win the floor, so the 70 bpm plateau is the resting HR.
        let start = unix(2026, 10, 15, 23, 0)
        let midnight = unix(2026, 10, 16, 0, 0)
        let plateau = run(from: start, until: midnight, cadence: 1) { offset in record(offset, bpm: 70) }
        let sparse = (0..<3).map { record(midnight + Int64($0), bpm: 45) }
        let session = try #require(SleepDeriver.summarize(plateau + sparse, startUnix: start, endUnix: midnight + 2))
        #expect(session.restingHeartRate == 70)
    }

    @Test func restingHRFallsBackToTheLowestBinOfAnySize() throws {
        // Records every two minutes: every 5-minute bin holds three, so none qualifies for the gated floor.
        // The lowest bin of any size is the 50 bpm one.
        let start = unix(2026, 10, 15, 23, 0)
        let records = run(from: start, until: start + 10 * 60, cadence: 120) { offset in
            record(offset, bpm: offset < start + 300 ? 60 : 50)
        }
        let session = try #require(summarize(records))
        #expect(session.restingHeartRate == 50)
    }

    @Test func isNapCarriesThroughSummarize() throws {
        let start = unix(2026, 10, 15, 13, 0)
        let records = run(from: start, until: start + 60 * 60) { offset in record(offset) }
        let nap = try #require(SleepDeriver.summarize(records, startUnix: start, endUnix: start + 3_540, isNap: true))
        #expect(nap.isNap)
        #expect(try #require(summarize(records)).isNap == false)
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

    // MARK: Respiratory rate

    /// One record per beat of a stream whose R-R is modulated at `brpm`, each stamped with its whole second as
    /// the strap writes it, so the estimator sees the real timestamp resolution.
    private func rsaRecords(brpm: Double, seconds: Double, start: Int64) -> [SleepRecord] {
        let f = brpm / 60
        var records: [SleepRecord] = []
        var t = 0.0
        while t < seconds {
            let rr = 1_000 + 40 * sin(2 * Double.pi * f * t)
            records.append(SleepRecord(unixSeconds: start + Int64(t), bpm: 60_000 / rr, rrMs: [rr], skinContact: true))
            t += rr / 1_000
        }
        return records
    }

    @Test func respiratoryRateIsEstimatedFromTheRRIntervals() throws {
        let start = unix(2026, 10, 15, 23, 0)
        let records = rsaRecords(brpm: 15, seconds: 2_400, start: start)
        let session = try #require(SleepDeriver.summarize(records, startUnix: start, endUnix: start + 2_400))
        let rate = try #require(session.respiratoryRateBrpm)
        #expect(abs(rate - 15) <= 1, "estimated \(rate)")
    }

    @Test func respiratoryRateIsNilWithoutRR() throws {
        let start = unix(2026, 10, 15, 23, 0)
        let records = run(from: start, until: start + 2_400, cadence: 1) { record($0, rr: []) }
        let session = try #require(SleepDeriver.summarize(records, startUnix: start, endUnix: start + 2_400))
        #expect(session.respiratoryRateBrpm == nil)
    }

    @Test func offWristRRDoesNotFeedTheRespiratoryRate() throws {
        let start = unix(2026, 10, 15, 23, 0)
        // Every record is off-wrist (no heart rate), so none of its R-R may reach the estimator.
        let records = rsaRecords(brpm: 15, seconds: 2_400, start: start).map {
            SleepRecord(unixSeconds: $0.unixSeconds, bpm: nil, rrMs: $0.rrMs, skinContact: false)
        }
        let session = try #require(SleepDeriver.summarize(records, startUnix: start, endUnix: start + 2_400))
        #expect(session.respiratoryRateBrpm == nil)
    }
}
