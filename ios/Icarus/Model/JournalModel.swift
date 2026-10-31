import Foundation
import GRDB
import Metrics
import Observation
import Store

/// Reads and writes for the journal check-in (v10), its insights, and the medication profiles and dose log (v8).
/// Each load is one read, so what a screen shows comes from one snapshot. Local only.
@MainActor
@Observable
final class JournalModel {
    /// What was logged for a scheduled medication on the day. `none` means the schedule is assumed.
    enum Logged: Sendable, Equatable {
        case none
        case taken([Int64])
        case skipped
    }

    /// One active medication on the day. A scheduled profile has `scheduledMs`; an as-needed profile (empty schedule)
    /// has none and shows only what was logged. `entries` lists every logged dose row for the day, for removal.
    struct MedicationRow: Identifiable, Sendable, Equatable {
        let profile: MedicationProfile
        let scheduledMs: [Int64]
        let logged: Logged
        let entries: [DoseOverrideEntry]

        var id: String { profile.id }
        var isAsNeeded: Bool { profile.scheduleMinutesOfDay.isEmpty }
        /// Logged taken doses only, oldest first.
        var takenEntries: [DoseOverrideEntry] {
            entries
                .filter { if case .taken = $0.override.kind { true } else { false } }
                .sorted { ($0.override.takenMs ?? 0) < ($1.override.takenMs ?? 0) }
        }
    }

    struct Snapshot: Sendable, Equatable {
        let timeZone: TimeZone
        let questions: [JournalQuestion]
        let answers: [String: Int]
        let medications: [MedicationRow]
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

    /// Logs the scheduled dose as taken at `atMs`, replacing whatever was logged for the day.
    func logTaken(_ medicationID: String, atMs: Int64) async {
        await replaceDay(medicationID, kind: .taken(atMs: atMs))
    }

    func logSkipped(_ medicationID: String) async {
        await replaceDay(medicationID, kind: .skipped)
    }

    /// Clears the day's log, so the schedule applies again.
    func resetDose(_ medicationID: String) async {
        await replaceDay(medicationID, kind: nil)
    }

    /// Adds one more taken dose to an as-needed medication. Other doses that day are kept.
    func addAsNeededDose(_ medicationID: String, atMs: Int64) async {
        let day = day
        let nowMs = clock.nowMs
        do {
            _ = try await database.writer.write { db in
                try db.addDoseOverride(
                    DoseOverride(medicationID: medicationID, day: day, kind: .taken(atMs: atMs)),
                    nowMs: nowMs
                )
            }
            await load()
        } catch {
            errorMessage = "Could not save that dose. Try again."
        }
    }

    /// Removes one logged dose row, for either kind of medication.
    func removeEntry(_ entryID: String) async {
        do {
            try await database.writer.write { db in
                try db.deleteDoseOverride(id: entryID)
            }
            await load()
        } catch {
            errorMessage = "Could not remove that dose. Try again."
        }
    }

    /// The default time for a new as-needed dose: now on today, else midday on the displayed day.
    func defaultAsNeededMs() -> Int64 {
        if day == today {
            return clock.nowMs
        }
        return LocalTime.localTime(day, hour: 12, in: snapshot?.timeZone ?? .current)
    }

    /// Epoch ms for a wall-clock time on the displayed day in the snapshot's zone. Only the hour and minute of
    /// `date` are used.
    func takenMs(for date: Date) -> Int64 {
        let zone = snapshot?.timeZone ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return LocalTime.localTime(day, minuteOfDay: minute, in: zone)
    }

    private func replaceDay(_ medicationID: String, kind: DoseOverride.Kind?) async {
        let day = day
        let nowMs = clock.nowMs
        do {
            try await database.writer.write { db in
                try db.removeDoseOverrides(medicationID: medicationID, day: day)
                if let kind {
                    try db.addDoseOverride(DoseOverride(medicationID: medicationID, day: day, kind: kind), nowMs: nowMs)
                }
            }
            await load()
        } catch {
            errorMessage = "Could not save that dose. Try again."
        }
    }

    nonisolated private static func snapshot(_ db: Database, day: LocalDay) throws -> Snapshot {
        let zone = try db.profile()?.timeZone ?? .current
        let profiles = try db.medications().filter(\.active)
        let allEntries = try db.doseOverrideEntries(day: day)
        let medications = profiles.map { profile -> MedicationRow in
            let scheduled = MedicationEffect.doses(
                profiles: [profile], overrides: [], from: day, to: day, in: zone
            ).map(\.takenAtMs)
            let entries = allEntries.filter { $0.override.medicationID == profile.id }
            let taken = entries.compactMap { $0.override.takenMs }
            let logged: Logged
            if !taken.isEmpty {
                logged = .taken(taken.sorted())
            } else if entries.contains(where: { $0.override.kind == .skipped }) {
                logged = .skipped
            } else {
                logged = .none
            }
            return MedicationRow(profile: profile, scheduledMs: scheduled.sorted(), logged: logged, entries: entries)
        }
        return Snapshot(
            timeZone: zone,
            questions: try db.journalQuestions(),
            answers: try db.answers(day: day),
            medications: medications
        )
    }
}

extension DoseOverride {
    /// The taken instant, or nil for a skipped day.
    var takenMs: Int64? {
        if case .taken(let atMs) = kind { atMs } else { nil }
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

/// Medication profiles for Settings: list, save and delete.
@MainActor
@Observable
final class MedicationsModel {
    private(set) var profiles: [MedicationProfile] = []
    private(set) var timeZone: TimeZone = .current
    private(set) var errorMessage: String?

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let clock: AppClock

    init(database: AppDatabase, clock: AppClock) {
        self.database = database
        self.clock = clock
    }

    func load() async {
        do {
            let loaded = try await database.writer.read { db -> ([MedicationProfile], TimeZone) in
                (try db.medications(), try db.profile()?.timeZone ?? .current)
            }
            profiles = loaded.0
            timeZone = loaded.1
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
            await load()
        } catch {
            errorMessage = "Could not delete the medication. Try again."
        }
    }

    /// A new profile id (UUIDv7 from the clock), matching the store's id convention.
    func newID() -> String {
        UUIDv7.make(unixMs: clock.nowMs).uuidString
    }
}
