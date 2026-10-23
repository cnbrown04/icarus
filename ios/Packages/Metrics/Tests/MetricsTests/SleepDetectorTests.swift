import Foundation
import Testing
@testable import Metrics

/// Synthetic worn days in America/New_York. The strap records around the clock, so every scenario
/// is a continuous worn stream; only motion and heart rate say where the sleep was.
@Suite("Sleep detector")
struct SleepDetectorTests {
    static let zone = TimeZone(identifier: "America/New_York")!

    /// Local wall-clock time on 2026-10-`day` as unix seconds.
    static func local(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        return Int64(date.timeIntervalSince1970)
    }

    /// Builds a stream one stretch at a time. Moving stretches change the wrist vector by far more
    /// than the 0.01 g stillness threshold every record; still stretches jitter by 0.001 g.
    struct Stream {
        enum Motion {
            case moving
            case still
        }

        var records: [SleepRecord] = []
        private var seed: UInt64 = 0x9E37_79B9_7F4A_7C15

        private mutating func random() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53) * 2 - 1
        }

        mutating func add(
            from start: Int64,
            to end: Int64,
            _ motion: Motion,
            bpm: Double?,
            contact: Bool = true,
            cadence: Int64 = 5
        ) {
            var t = start
            while t < end {
                let jitter = motion == .moving ? 0.2 : 0.001
                let gravity = SleepRecord.Gravity(
                    x: 0.1 + jitter * random(),
                    y: 0.2 + jitter * random(),
                    z: 0.97 + jitter * random()
                )
                records.append(SleepRecord(
                    unixSeconds: t,
                    bpm: bpm.map { $0 + 2 * random() },
                    rrMs: [],
                    skinContact: contact,
                    gravity: gravity
                ))
                t += cadence
            }
        }
    }

    // MARK: The reported bug

    @Test func aWornDayWithAnEveningOnTheSofaYieldsOnlyTheNight() throws {
        // 2026-10-20 18:00 → 10-21 18:00: a still evening (HR near sleeping HR), an hour up and about,
        // the night, then the day. The old contiguity rule called this whole span one 24 h "night".
        var stream = Stream()
        stream.add(from: Self.local(20, 18), to: Self.local(20, 21), .moving, bpm: 88)
        stream.add(from: Self.local(20, 21), to: Self.local(20, 23, 50), .still, bpm: 72)
        stream.add(from: Self.local(20, 23, 50), to: Self.local(21, 1, 15), .moving, bpm: 80)
        stream.add(from: Self.local(21, 1, 15), to: Self.local(21, 9, 40), .still, bpm: 62)
        stream.add(from: Self.local(21, 9, 40), to: Self.local(21, 18), .moving, bpm: 92)

        let windows = SleepDetector.detect(stream.records, in: Self.zone)
        let night = try #require(windows.only)
        #expect(!night.isNap)
        #expect(abs(night.startUnix - Self.local(21, 1, 15)) <= 10 * 60)
        #expect(abs(night.endUnix - Self.local(21, 9, 40)) <= 10 * 60)
    }

    @Test func aBriefMidnightAwakeningStaysOneNight() throws {
        var stream = Stream()
        stream.add(from: Self.local(20, 18), to: Self.local(20, 23), .moving, bpm: 88)
        stream.add(from: Self.local(20, 23), to: Self.local(21, 3), .still, bpm: 60)
        // Up for 25 minutes (bathroom, water) with HR barely above sleeping.
        stream.add(from: Self.local(21, 3), to: Self.local(21, 3, 25), .moving, bpm: 64)
        stream.add(from: Self.local(21, 3, 25), to: Self.local(21, 7), .still, bpm: 60)
        stream.add(from: Self.local(21, 7), to: Self.local(21, 12), .moving, bpm: 90)

        let night = try #require(SleepDetector.detect(stream.records, in: Self.zone).only)
        #expect(abs(night.startUnix - Self.local(20, 23)) <= 10 * 60)
        #expect(abs(night.endUnix - Self.local(21, 7)) <= 10 * 60)
    }

    @Test func drainGapsDoNotBreakTheNight() throws {
        // What the store held before persist-then-ack: ~3 minutes of every 16.
        var full = Stream()
        full.add(from: Self.local(20, 18), to: Self.local(20, 23), .moving, bpm: 88)
        full.add(from: Self.local(20, 23), to: Self.local(21, 7), .still, bpm: 60)
        full.add(from: Self.local(21, 7), to: Self.local(21, 12), .moving, bpm: 90)
        let chunked = full.records.filter { ($0.unixSeconds - Self.local(20, 18)) % (16 * 60) < 3 * 60 }

        let night = try #require(SleepDetector.detect(chunked, in: Self.zone).only)
        // A bound can only land on a chunk the store kept, so it is resolved to ~one chunk (16 min)
        // plus the stillness window's smear.
        #expect(abs(night.startUnix - Self.local(20, 23)) <= 32 * 60)
        #expect(abs(night.endUnix - Self.local(21, 7)) <= 32 * 60)
    }

    // MARK: Rejections

    @Test func aStrapLeftOnATableIsNotSleep() {
        var stream = Stream()
        stream.add(from: Self.local(20, 8), to: Self.local(20, 12), .moving, bpm: 88)
        stream.add(from: Self.local(20, 12), to: Self.local(21, 2), .still, bpm: nil, contact: false)
        stream.add(from: Self.local(21, 2), to: Self.local(21, 8), .moving, bpm: 88)
        #expect(SleepDetector.detect(stream.records, in: Self.zone).isEmpty)
    }

    @Test func sedentaryDaytimeStillnessIsNotANap() {
        var stream = Stream()
        stream.add(from: Self.local(20, 8), to: Self.local(20, 13), .moving, bpm: 85)
        // Two hours at a desk: still wrist, HR at the waking level.
        stream.add(from: Self.local(20, 13), to: Self.local(20, 15), .still, bpm: 84)
        stream.add(from: Self.local(20, 15), to: Self.local(20, 20), .moving, bpm: 86)
        #expect(SleepDetector.detect(stream.records, in: Self.zone).isEmpty)
    }

    @Test func aDaytimeNapWithAHeartRateDipIsKeptAsANap() throws {
        var stream = Stream()
        stream.add(from: Self.local(20, 8), to: Self.local(20, 13), .moving, bpm: 88)
        stream.add(from: Self.local(20, 13), to: Self.local(20, 15), .still, bpm: 66)
        stream.add(from: Self.local(20, 15), to: Self.local(20, 20), .moving, bpm: 88)
        let nap = try #require(SleepDetector.detect(stream.records, in: Self.zone).only)
        #expect(nap.isNap)
    }

    @Test func aShortStillEveningWithoutAHeartRateDipIsNotANight() {
        // The real 2026-10-22 shape: an hour on the sofa at the waking HR, and no night after it yet.
        var stream = Stream()
        stream.add(from: Self.local(22, 10), to: Self.local(22, 20, 40), .moving, bpm: 92)
        stream.add(from: Self.local(22, 20, 40), to: Self.local(22, 22, 10), .still, bpm: 88)
        stream.add(from: Self.local(22, 22, 10), to: Self.local(23, 0, 30), .moving, bpm: 92)
        #expect(SleepDetector.detect(stream.records, in: Self.zone).isEmpty)
    }

    @Test func aShortNightWithARealDipIsKept() throws {
        var stream = Stream()
        stream.add(from: Self.local(22, 16), to: Self.local(23, 3), .moving, bpm: 90)
        stream.add(from: Self.local(23, 3), to: Self.local(23, 5, 30), .still, bpm: 60)
        stream.add(from: Self.local(23, 5, 30), to: Self.local(23, 12), .moving, bpm: 90)
        let night = try #require(SleepDetector.detect(stream.records, in: Self.zone).only)
        #expect(!night.isNap)
    }

    @Test func theContactByteIsNotAWearFlag() throws {
        // OpenStrap PROTOCOL.md §5: the byte is contact quality. A worn night whose byte reads 0
        // while the heart rate is present is still a night.
        var stream = Stream()
        stream.add(from: Self.local(20, 18), to: Self.local(20, 23), .moving, bpm: 88, contact: false)
        stream.add(from: Self.local(20, 23), to: Self.local(21, 7), .still, bpm: 60, contact: false)
        stream.add(from: Self.local(21, 7), to: Self.local(21, 12), .moving, bpm: 90, contact: false)
        #expect(SleepDetector.detect(stream.records, in: Self.zone).count == 1)
    }

    @Test func aStillBlockShorterThanAnHourIsNotSleep() {
        var stream = Stream()
        stream.add(from: Self.local(20, 18), to: Self.local(20, 23), .moving, bpm: 88)
        stream.add(from: Self.local(20, 23), to: Self.local(20, 23, 50), .still, bpm: 60)
        stream.add(from: Self.local(20, 23, 50), to: Self.local(21, 8), .moving, bpm: 88)
        #expect(SleepDetector.detect(stream.records, in: Self.zone).isEmpty)
    }

    @Test func aStillBlockLongerThanSixteenHoursIsAClockArtefact() {
        var stream = Stream()
        stream.add(from: Self.local(20, 6), to: Self.local(20, 8), .moving, bpm: 88)
        stream.add(from: Self.local(20, 8), to: Self.local(21, 2), .still, bpm: 60)
        stream.add(from: Self.local(21, 2), to: Self.local(21, 4), .moving, bpm: 88)
        #expect(SleepDetector.detect(stream.records, in: Self.zone).isEmpty)
    }

    @Test func recordsWithoutGravityYieldNothing() {
        let records = (0..<2_000).map {
            SleepRecord(unixSeconds: Self.local(21, 0) + Int64($0) * 30, bpm: 60, rrMs: [], skinContact: true)
        }
        #expect(SleepDetector.detect(records, in: Self.zone).isEmpty)
        #expect(SleepDetector.detect([], in: Self.zone).isEmpty)
    }

    @Test func inputOrderAndDuplicatesDoNotMatter() {
        var stream = Stream()
        stream.add(from: Self.local(20, 18), to: Self.local(20, 23), .moving, bpm: 88)
        stream.add(from: Self.local(20, 23), to: Self.local(21, 7), .still, bpm: 60)
        stream.add(from: Self.local(21, 7), to: Self.local(21, 12), .moving, bpm: 90)
        let expected = SleepDetector.detect(stream.records, in: Self.zone)
        let shuffled = Array(stream.records.reversed()) + Array(stream.records.prefix(500))
        #expect(SleepDetector.detect(shuffled, in: Self.zone) == expected)
        #expect(expected.count == 1)
    }
}

extension Array {
    /// The single element, or nil when there are zero or several.
    var only: Element? { count == 1 ? first : nil }
}
