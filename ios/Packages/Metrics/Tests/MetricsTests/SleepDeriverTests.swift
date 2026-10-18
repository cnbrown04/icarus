import Foundation
import Testing
@testable import Metrics

// Synthetic nights. All timestamps are UTC, so the 21:00-06:00 local window is [21:00, 06:00) UTC.
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

    // MARK: A whole night

    @Test func derivesOneSessionForAContiguousNight() throws {
        // 23:00 to 06:30 at 1 Hz-minute cadence: 450 records, 20-minute gaps nowhere.
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

        let sessions = SleepDeriver.derive(records, in: Self.utc)
        #expect(sessions.count == 1)

        let session = try #require(sessions.first)
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
        let end = start + 90 * 60
        let rrPattern: [Double] = [980, 1_020, 1_000, 1_040, 960]
        let records = run(from: start, until: end) { offset in
            let minute = Int(offset - start) / 60
            return record(offset, rr: [rrPattern[minute % rrPattern.count]])
        }

        let session = try #require(SleepDeriver.derive(records, in: Self.utc).first)
        let allRR = records.flatMap(\.rrMs)
        let flags = RRCleaner.acceptedFlags(allRR)
        let accepted = zip(allRR, flags).compactMap { $1 ? $0 : nil }
        #expect(session.rmssdMs == HRV.rmssd(accepted))
        #expect(session.rmssdMs != nil)
    }

    // MARK: Gaps

    @Test func aTwentyMinuteGapDoesNotSplitTheNight() throws {
        let start = unix(2026, 10, 15, 23, 0)
        let gapStart = start + 60 * 60
        var records: [SleepRecord] = run(from: start, until: gapStart) { record($0) }
        records += run(from: gapStart + 20 * 60, until: gapStart + 80 * 60) { record($0) }

        let sessions = SleepDeriver.derive(records, in: Self.utc)
        #expect(sessions.count == 1)
        #expect(sessions[0].startUnix == start)
        #expect(sessions[0].endUnix == gapStart + 80 * 60 - 60)
    }

    @Test func aThirtyMinuteGapSplitsTheNight() throws {
        let start = unix(2026, 10, 15, 23, 0)
        let gapStart = start + 60 * 60
        var records: [SleepRecord] = run(from: start, until: gapStart) { record($0) }
        records += run(from: gapStart + 30 * 60, until: gapStart + 90 * 60) { record($0) }

        let sessions = SleepDeriver.derive(records, in: Self.utc)
        #expect(sessions.count == 2)
        #expect(sessions[0].startUnix == start)
        #expect(sessions[1].startUnix == gapStart + 30 * 60)
    }

    // MARK: Night window

    @Test func aDaytimeStretchIsNotASession() {
        let start = unix(2026, 10, 15, 14, 0)
        let records = run(from: start, until: start + 90 * 60) { record($0) }
        #expect(SleepDeriver.derive(records, in: Self.utc).isEmpty)
    }

    @Test func anEveningSessionOverlappingTheNightWindowCounts() throws {
        // 21:30-22:30 sits inside the 21:00-06:00 window.
        let start = unix(2026, 10, 15, 21, 30)
        let records = run(from: start, until: start + 60 * 60) { record($0) }
        #expect(SleepDeriver.derive(records, in: Self.utc).count == 1)
    }

    @Test func aMorningTailAfterMidnightCounts() throws {
        // 00:30-07:30 overlaps the previous evening's window (21:00 -> 06:00).
        let start = unix(2026, 10, 16, 0, 30)
        let records = run(from: start, until: start + 90 * 60) { record($0) }
        #expect(SleepDeriver.derive(records, in: Self.utc).count == 1)
    }

    // MARK: Skin contact

    @Test func aMostlyOffWristRunIsRejected() {
        let start = unix(2026, 10, 15, 23, 0)
        let records = run(from: start, until: start + 3 * 60 * 60) { offset in
            let minute = Int(offset - start) / 60
            return record(offset, contact: minute % 10 < 4) // 40% on-wrist
        }
        #expect(SleepDeriver.derive(records, in: Self.utc).isEmpty)
    }

    @Test func offWristRecordsKeepTheSessionButAreExcludedFromAggregates() throws {
        let start = unix(2026, 10, 15, 23, 0)
        let offStart = start + 60 * 60
        let records = run(from: start, until: start + 6 * 60 * 60) { offset in
            let onWrist = !(offset >= offStart && offset < offStart + 60 * 60)
            let minute = Int(offset - start) / 60
            // Off-wrist minutes carry garbage readings (200 bpm): they must not reach the median.
            return record(offset, bpm: onWrist ? 55 : 200, rr: onWrist ? [980 + Double(minute % 5) * 10] : [], contact: onWrist)
        }

        let session = try #require(SleepDeriver.derive(records, in: Self.utc).first)
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
        let session = try #require(SleepDeriver.derive(records, in: Self.utc).first)
        #expect(abs(session.contactFraction - 0.6) < 0.0001)
        #expect(session.quality == .poor)
    }

    // MARK: Input hygiene

    @Test func duplicatesByUnixTimeAreCollapsed() throws {
        let start = unix(2026, 10, 15, 23, 0)
        var records = run(from: start, until: start + 2 * 60 * 60) { record($0) }
        records += run(from: start, until: start + 2 * 60 * 60) { record($0, bpm: 200) } // replayed batch

        let session = try #require(SleepDeriver.derive(records, in: Self.utc).first)
        #expect(session.recordCount == 2 * 60)
        #expect(session.restingHeartRate == 55) // the 200 bpm replays did not win
    }

    @Test func outOfOrderInputIsSorted() throws {
        let start = unix(2026, 10, 15, 23, 0)
        var records = run(from: start, until: start + 2 * 60 * 60) { record($0) }
        records.shuffle()

        let session = try #require(SleepDeriver.derive(records, in: Self.utc).first)
        #expect(session.startUnix == start)
        #expect(session.endUnix == start + 2 * 60 * 60 - 60)
    }

    @Test func implausibleHeartRatesAreExcludedFromTheMedian() throws {
        let start = unix(2026, 10, 15, 23, 0)
        let records = run(from: start, until: start + 90 * 60) { offset in
            let minute = Int(offset - start) / 60
            return record(offset, bpm: minute == 30 ? 400 : 55)
        }
        let session = try #require(SleepDeriver.derive(records, in: Self.utc).first)
        #expect(session.restingHeartRate == 55)
    }

    @Test func recordsWithNoReadingContributeNothing() throws {
        let start = unix(2026, 10, 15, 23, 0)
        let records = run(from: start, until: start + 90 * 60) { offset in
            let minute = Int(offset - start) / 60
            return record(offset, bpm: minute == 30 ? nil : 55)
        }
        let session = try #require(SleepDeriver.derive(records, in: Self.utc).first)
        #expect(session.restingHeartRate == 55)
    }

    @Test func anEmptyStreamYieldsNothing() {
        #expect(SleepDeriver.derive([], in: Self.utc).isEmpty)
    }
}
