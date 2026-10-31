import Foundation
import GRDB
import Metrics
import Store

/// What the Sleep tab reads in one pass: the recent nights with their hypnogram (`Dashboard.sleep`), every session in
/// the chosen range with its stage totals and wake day, the `daily_score` rows for that range, and tonight's planner
/// inputs. Read-only.
enum SleepModel {
    /// The chart's range. D shows one night's hypnogram; W, M and 6M show one stacked bar per night.
    enum Range: String, CaseIterable, Identifiable, Sendable {
        case day
        case week
        case month
        case sixMonths

        var id: String { rawValue }

        var title: String {
            switch self {
            case .day: "D"
            case .week: "W"
            case .month: "M"
            case .sixMonths: "6M"
            }
        }

        /// Local days read, ending today. D and W share the seven-night window `Dashboard.sleep` already reads.
        var days: Int {
            switch self {
            case .day, .week: 7
            case .month: 30
            case .sixMonths: 180
            }
        }
    }

    /// One session in the range, naps included, with its stage totals. Totals are empty for an unstaged night.
    struct Day: Identifiable, Sendable {
        /// Session start in epoch ms, also its identity.
        let id: Int64
        let startMs: Int64
        let durationS: Int64
        let isNap: Bool
        /// Seconds per stage. Empty when the night is unstaged.
        let totals: [SleepStage: Int]
        /// 'YYYY-MM-DD' of the wake day, the `daily_score` key.
        let wakeDayKey: String

        var isStaged: Bool { !totals.isEmpty }

        /// When the night ended: the day a night is dated by.
        var wakeMs: Int64 { startMs + durationS * 1_000 }

        /// Time asleep: light + deep + REM when staged, else the in-bed span.
        var asleepS: Int64 {
            guard isStaged else { return durationS }
            return Int64((totals[.light] ?? 0) + (totals[.deep] ?? 0) + (totals[.rem] ?? 0))
        }

        /// Asleep divided by the staged seconds, nil when unstaged. Matches `Dashboard.sleep`.
        var efficiency: Double? {
            let staged = totals.values.reduce(0, +)
            guard staged > 0 else { return nil }
            return min(1, max(0, Double(asleepS) / Double(staged)))
        }
    }

    struct Snapshot: Sendable {
        /// The recent nights, newest first. Their hypnogram segments feed the D chart, and their ids feed Edit.
        let recent: Dashboard.SleepSnapshot
        /// Every session in the range, oldest first.
        let days: [Day]
        /// `daily_score` rows for the range, keyed by wake day.
        let scores: [String: DailyScoreRow]
        /// Tonight's bedtime inputs (`CoachingModel`).
        let coaching: CoachingModel.Snapshot

        var timeZone: TimeZone { recent.context.timeZone }

        /// The most recent main sleep, never a nap.
        var latest: Day? {
            guard let id = recent.latest?.id else { return nil }
            return days.first { $0.id == id }
        }
    }

    static func load(_ db: Database, nowMs: Int64, range: Range) throws -> Snapshot {
        let recent = try Dashboard.sleep(db, nowMs: nowMs)
        let zone = recent.context.timeZone
        let today = LocalTime.localDay(containing: nowMs, in: zone)
        let first = LocalTime.adding(days: -(range.days - 1), to: today)
        let from = LocalTime.localTime(first, hour: 0, in: zone)

        var days: [Day] = []
        for band in try BandRow.fetchAll(db) {
            for row in try db.sleepSessionRows(bandID: band.id, from: from, to: nowMs) {
                let segments = try db.sleepStageSegments(bandID: band.id, sessionStartMs: row.startMs)
                var totals: [SleepStage: Int] = [:]
                if !segments.isEmpty {
                    totals = try db.sleepStageTotals(bandID: band.id, sessionStartMs: row.startMs)
                }
                days.append(Day(
                    id: row.startMs,
                    startMs: row.startMs,
                    durationS: row.durationS,
                    isNap: row.isNap,
                    totals: totals,
                    wakeDayKey: wakeDayKey(startMs: row.startMs, durationS: row.durationS, in: zone)
                ))
            }
        }
        days.sort { $0.startMs < $1.startMs }

        var scores: [String: DailyScoreRow] = [:]
        let rows = try DailyScoreRow.fetchAll(
            db,
            sql: "SELECT * FROM daily_score WHERE local_day BETWEEN ? AND ?",
            arguments: [dayKey(first), dayKey(today)]
        )
        for row in rows {
            scores[row.localDay] = row
        }

        return Snapshot(
            recent: recent,
            days: days,
            scores: scores,
            coaching: try CoachingModel.load(db, nowMs: nowMs)
        )
    }

    /// The wake day of a session, as the `daily_score` key. Matches `Dashboard.sleep`'s choice for the latest night.
    static func wakeDayKey(startMs: Int64, durationS: Int64, in zone: TimeZone) -> String {
        dayKey(LocalTime.localDay(containing: startMs + durationS * 1_000, in: zone))
    }

    /// 'YYYY-MM-DD', the `daily_score` key.
    static func dayKey(_ day: LocalDay) -> String {
        func pad(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
        return "\(day.year)-\(pad(day.month))-\(pad(day.day))"
    }
}
