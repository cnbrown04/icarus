import Foundation
import GRDB
import Metrics
import Observation
import Store

/// Reads and writes for the journal check-in (v10) and its insights. Each load is one read, so what a screen shows
/// comes from one snapshot. Local only. Medication doses are logged in `MedicationsModel`, not here.
@MainActor
@Observable
final class JournalModel {
    struct Snapshot: Sendable, Equatable {
        let timeZone: TimeZone
        let questions: [JournalQuestion]
        let answers: [String: Int]
    }

    /// The day being checked in. Starts on yesterday unless the caller passed one.
    private(set) var day: LocalDay
    /// Nil until the first load finishes.
    private(set) var snapshot: Snapshot?
    private(set) var errorMessage: String?

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let clock: AppClock

    init(database: AppDatabase, clock: AppClock, day: LocalDay?) {
        self.database = database
        self.clock = clock
        self.day = day ?? LocalTime.adding(days: -1, to: LocalTime.localDay(containing: clock.nowMs, in: .current))
    }

    /// Today on the profile's zone (device zone until a profile exists). Days after it cannot be checked in.
    var today: LocalDay {
        LocalTime.localDay(containing: clock.nowMs, in: snapshot?.timeZone ?? .current)
    }

    func move(by days: Int) async {
        let next = LocalTime.adding(days: days, to: day)
        guard !JournalFormat.isAfter(next, today) else { return }
        day = next
        await load()
    }

    func load() async {
        let day = day
        do {
            snapshot = try await database.writer.read { db in
                try JournalModel.snapshot(db, day: day)
            }
            errorMessage = nil
        } catch {
            errorMessage = "Could not read the journal for this day."
        }
    }

    func setAnswer(_ questionID: String, value: Int?) async {
        let day = day
        let nowMs = clock.nowMs
        do {
            try await database.writer.write { db in
                try db.setAnswer(day: day, question: questionID, value: value, nowMs: nowMs)
            }
            await load()
        } catch {
            errorMessage = "Could not save that answer. Try again."
        }
    }

    nonisolated private static func snapshot(_ db: Database, day: LocalDay) throws -> Snapshot {
        Snapshot(
            timeZone: try db.profile()?.timeZone ?? .current,
            questions: try db.journalQuestions(),
            answers: try db.answers(day: day)
        )
    }
}

/// The "with vs without" comparisons for the Journal insights screen.
@MainActor
@Observable
final class JournalInsightsModel {
    private(set) var insights: [JournalInsight] = []
    private(set) var loaded = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let clock: AppClock

    init(database: AppDatabase, clock: AppClock) {
        self.database = database
        self.clock = clock
    }

    func load() async {
        let nowMs = clock.nowMs
        do {
            insights = try await database.writer.read { db in
                let zone = try db.profile()?.timeZone ?? .current
                return try db.journalInsights(through: LocalTime.localDay(containing: nowMs, in: zone), in: zone)
            }
            errorMessage = nil
        } catch {
            errorMessage = "Could not compute insights."
        }
        loaded = true
    }
}

extension DoseOverride {
    /// The taken instant, or nil for a skipped day.
    var takenMs: Int64? {
        if case .taken(let atMs) = kind { atMs } else { nil }
    }
}

/// Medication profiles and their dose log, for Settings-style set-once use. Medications are a calculation setting:
/// this is the only place doses are logged. A scheduled profile is assumed taken on its days unless skipped; an
/// as-needed profile has a dose only where one was logged. Local only.
@MainActor
@Observable
final class MedicationsModel {
    /// How many days of the dose log each profile shows, ending today.
    static let logWindowDays = 7

    private(set) var profiles: [MedicationProfile] = []
    private(set) var timeZone: TimeZone = .current
    /// Each profile's logged doses and skips over the last `logWindowDays` days, newest first.
    private(set) var recentDoses: [String: [DoseOverrideEntry]] = [:]
    private(set) var errorMessage: String?

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let clock: AppClock

    /// Called after every successful write: medication edits change past stress (`Database.markStressStale`), so the
    /// stale minutes are rebuilt now rather than at the next launch.
    @ObservationIgnored private let recomputeStale: () -> Void

    init(database: AppDatabase, clock: AppClock, recomputeStale: @escaping () -> Void = {}) {
        self.database = database
        self.clock = clock
        self.recomputeStale = recomputeStale
    }

    /// Today on the profile's zone.
    var today: LocalDay {
        LocalTime.localDay(containing: clock.nowMs, in: timeZone)
    }

    func load() async {
        let nowMs = clock.nowMs
        let windowDays = Self.logWindowDays
        do {
            let loaded = try await database.writer.read { db -> ([MedicationProfile], TimeZone, [DoseOverrideEntry]) in
                let zone = try db.profile()?.timeZone ?? .current
                let today = LocalTime.localDay(containing: nowMs, in: zone)
                var entries: [DoseOverrideEntry] = []
                for offset in 0..<windowDays {
                    entries += try db.doseOverrideEntries(day: LocalTime.adding(days: -offset, to: today))
                }
                return (try db.medications(), zone, entries)
            }
            profiles = loaded.0
            timeZone = loaded.1
            recentDoses = Dictionary(grouping: loaded.2, by: \.override.medicationID).mapValues { entries in
                entries.sorted { Self.sortKey($0) > Self.sortKey($1) }
            }
            errorMessage = nil
        } catch {
            errorMessage = "Could not read medications."
        }
    }

    func save(_ profile: MedicationProfile) async {
        let nowMs = clock.nowMs
        do {
            try await database.writer.write { db in
                try db.saveMedication(profile, nowMs: nowMs)
            }
            recomputeStale()
            await load()
        } catch {
            errorMessage = "Could not save \(profile.name). Try again."
        }
    }

    func delete(_ id: String) async {
        let nowMs = clock.nowMs
        do {
            try await database.writer.write { db in
                try db.deleteMedication(id: id, nowMs: nowMs)
            }
            recomputeStale()
            await load()
        } catch {
            errorMessage = "Could not delete the medication. Try again."
        }
    }

    /// Skips the scheduled dose on `day`, replacing anything logged for that day.
    func skipDay(_ medicationID: String, on day: LocalDay) async {
        let nowMs = clock.nowMs
        do {
            try await database.writer.write { db in
                try db.removeDoseOverrides(medicationID: medicationID, day: day)
                try db.addDoseOverride(DoseOverride(medicationID: medicationID, day: day, kind: .skipped), nowMs: nowMs)
            }
            recomputeStale()
            await load()
        } catch {
            errorMessage = "Could not save that skip. Try again."
        }
    }

    /// Logs one dose of an as-needed medication at `time` on `day`. Other doses that day are kept. Only the hour and
    /// minute of `time` are used, read on the device calendar (the one the time picker shows) and placed on `day` in
    /// the profile's zone.
    func logDose(_ medicationID: String, on day: LocalDay, at time: Date) async {
        let atMs = LocalTime.localTime(day, minuteOfDay: Self.minuteOfDay(time), in: timeZone)
        let nowMs = clock.nowMs
        do {
            _ = try await database.writer.write { db in
                try db.addDoseOverride(DoseOverride(medicationID: medicationID, day: day, kind: .taken(atMs: atMs)),
                                       nowMs: nowMs)
            }
            recomputeStale()
            await load()
        } catch {
            errorMessage = "Could not save that dose. Try again."
        }
    }

    /// Removes one logged dose or skip, by its row id.
    func removeDose(_ entryID: String) async {
        do {
            try await database.writer.write { db in
                try db.deleteDoseOverride(id: entryID)
            }
            recomputeStale()
            await load()
        } catch {
            errorMessage = "Could not remove that dose. Try again."
        }
    }

    /// A new profile id (UUIDv7 from the clock), matching the store's id convention.
    func newID() -> String {
        UUIDv7.make(unixMs: clock.nowMs).uuidString
    }

    /// The calendar day of `date` on the device calendar, the one the date pickers show.
    static func deviceDay(_ date: Date) -> LocalDay {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return LocalDay(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// Minutes after midnight of `date` on the device calendar.
    static func minuteOfDay(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// Newest day first, then latest dose first. Skips have no time and sort after a day's doses.
    private static func sortKey(_ entry: DoseOverrideEntry) -> (Int, Int, Int, Int64) {
        (entry.override.day.year, entry.override.day.month, entry.override.day.day, entry.override.takenMs ?? -1)
    }
}
