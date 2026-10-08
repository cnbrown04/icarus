import Foundation
import GRDB
import Metrics
import Testing
@testable import Store

struct SeedTests {
    private let now = Date(timeIntervalSince1970: 1_791_383_400)

    @Test func buildsThirtyDaysOfMinutesAndFifteenMinutesOfRawHeartRate() throws {
        let database = try SeedData.make30Days(now: now)
        let counts = try database.writer.read { db -> (Int, Int) in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM minute_metric") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hr_sample") ?? 0)
        }
        #expect(counts.0 == 30 * 1440)
        #expect(counts.1 == 900)
    }

    @Test func buildsWithinTwoSeconds() throws {
        let elapsed = try ContinuousClock().measure {
            _ = try SeedData.make30Days(now: now)
        }
        #expect(elapsed < .seconds(2))
    }

    @Test func seedsACompleteProfileAndBand() throws {
        let database = try SeedData.make30Days(now: now)
        let profile = try database.writer.read { try $0.profile() }
        #expect(profile?.userProfile(year: 2026) != nil)
        #expect(profile?.hrMax == nil)
        let bands = try database.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM band") }
        #expect(bands == 1)
    }

    @Test func firstSixDaysAreCalibratingAndLaterDaysHaveStress() throws {
        let database = try SeedData.make30Days(now: now)
        let rows = try database.writer.read { try $0.minuteMetricRows(from: 0, to: Int64.max) }
        let first = try #require(rows.first)
        #expect(first.state == .calibrating)
        #expect(rows.allSatisfy { $0.state != .calibrating || $0.minuteMs < rows[0].minuteMs + Int64(SeedData.calibrationDays) * 1440 * LocalTime.msPerMinute })
        let late = rows.last(where: { $0.state == .value })
        #expect(late?.stress != nil)
    }

    @Test func isDeterministicForTheSameClock() throws {
        let first = try SeedData.make30Days(now: now)
        let second = try SeedData.make30Days(now: now)
        let lhs = try first.writer.read { try $0.minuteMetricRows(from: 0, to: Int64.max) }
        let rhs = try second.writer.read { try $0.minuteMetricRows(from: 0, to: Int64.max) }
        #expect(lhs == rhs)
    }

    @Test func rawSamplesEndAtTheClock() throws {
        let database = try SeedData.make30Days(now: now)
        let newest = try database.writer.read { try Int64.fetchOne($0, sql: "SELECT MAX(ts_ms) FROM hr_sample") }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        #expect(newest == nowMs - 1000)
    }
}
