import Foundation
import GRDB
import Metrics

/// One `medication` row (v8). `schedule` and `weekdays` hold JSON arrays; the enums hold their raw values.
struct MedicationRow: Codable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "medication"

    var id: String
    var name: String
    var medClass: String
    var formulation: String
    var onsetMin: Int
    var durationMin: Int
    var schedule: String
    var weekdays: String
    var active: Bool
    var updatedAt: Int64
    var deletedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case id, name, formulation, schedule, weekdays, active
        case medClass = "med_class"
        case onsetMin = "onset_min"
        case durationMin = "duration_min"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    init(profile: MedicationProfile, updatedAt: Int64) throws {
        id = profile.id
        name = profile.name
        medClass = profile.medClass.rawValue
        formulation = profile.formulation.rawValue
        onsetMin = profile.onsetMinutes
        durationMin = profile.durationMinutes
        schedule = try MedicationRow.json(profile.scheduleMinutesOfDay)
        weekdays = try MedicationRow.json(profile.weekdays.sorted())
        active = profile.active
        self.updatedAt = updatedAt
        deletedAt = nil
    }

    func profile() throws -> MedicationProfile {
        MedicationProfile(
            id: id,
            name: name,
            medClass: MedicationClass(rawValue: medClass) ?? .other,
            formulation: MedicationFormulation(rawValue: formulation) ?? .immediateRelease,
            onsetMinutes: onsetMin,
            durationMinutes: durationMin,
            scheduleMinutesOfDay: try MedicationRow.decode([Int].self, from: schedule),
            weekdays: Set(try MedicationRow.decode([Int].self, from: weekdays)),
            active: active
        )
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }
}

/// One `medication_dose_override` row (v8).
struct MedicationOverrideRow: Codable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "medication_dose_override"

    var id: String
    var medicationID: String
    var localDay: String
    var kind: String
    var takenAtMs: Int64?
    var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, kind
        case medicationID = "medication_id"
        case localDay = "local_day"
        case takenAtMs = "taken_at_ms"
        case createdAt = "created_at"
    }

    init(id: String, override: DoseOverride, createdAt: Int64) {
        self.id = id
        medicationID = override.medicationID
        localDay = MedicationOverrideRow.text(override.day)
        switch override.kind {
        case .taken(let atMs):
            kind = "taken"
            takenAtMs = atMs
        case .skipped:
            kind = "skipped"
            takenAtMs = nil
        }
        self.createdAt = createdAt
    }

    func doseOverride() -> DoseOverride? {
        guard let day = MedicationOverrideRow.day(localDay) else { return nil }
        let overrideKind: DoseOverride.Kind
        switch (kind, takenAtMs) {
        case ("taken", let atMs?): overrideKind = .taken(atMs: atMs)
        case ("skipped", nil): overrideKind = .skipped
        default: return nil
        }
        return DoseOverride(medicationID: medicationID, day: day, kind: overrideKind)
    }

    /// 'YYYY-MM-DD'. Lexical order matches calendar order, so BETWEEN works for ranges.
    static func text(_ day: LocalDay) -> String {
        func pad(_ value: Int, _ width: Int) -> String {
            let digits = String(value)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return "\(pad(day.year, 4))-\(pad(day.month, 2))-\(pad(day.day, 2))"
    }

    static func day(_ text: String) -> LocalDay? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return LocalDay(year: parts[0], month: parts[1], day: parts[2])
    }
}

/// One logged dose override with its row id, so a single dose can be listed and removed (v8).
public struct DoseOverrideEntry: Sendable, Equatable, Identifiable {
    public var id: String
    public var override: DoseOverride

    public init(id: String, override: DoseOverride) {
        self.id = id
        self.override = override
    }
}

/// Medication profiles, dose overrides and the active-effect windows they produce (v8). Local only: nothing
/// here syncs to the server. Call inside `DatabaseWriter.write` or `read`.
extension Database {
    /// Inserts or replaces a profile and clears any delete mark. `nowMs` becomes `updated_at`.
    public func saveMedication(_ profile: MedicationProfile, nowMs: Int64) throws {
        try MedicationRow(profile: profile, updatedAt: nowMs).save(self)
    }

    /// Live profiles (soft-deleted ones excluded), in the order they were created.
    public func medications() throws -> [MedicationProfile] {
        try MedicationRow.fetchAll(self, sql: "SELECT * FROM medication WHERE deleted_at IS NULL ORDER BY rowid")
            .map { try $0.profile() }
    }

    /// Hides a profile from `medications()` and from every window computed afterwards. Its overrides are kept.
    public func deleteMedication(id: String, nowMs: Int64) throws {
        try execute(sql: """
        UPDATE medication SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL
        """, arguments: [nowMs, nowMs, id])
    }

    /// Records a per-day override and returns its new id (UUIDv7 from `nowMs`).
    @discardableResult
    public func addDoseOverride(_ override: DoseOverride, nowMs: Int64) throws -> String {
        let id = UUIDv7.make(unixMs: nowMs).uuidString
        try MedicationOverrideRow(id: id, override: override, createdAt: nowMs).insert(self)
        return id
    }

    /// Removes every override for one medication on one day, so that day goes back to the schedule.
    public func removeDoseOverrides(medicationID: String, day: LocalDay) throws {
        try execute(sql: """
        DELETE FROM medication_dose_override WHERE medication_id = ? AND local_day = ?
        """, arguments: [medicationID, MedicationOverrideRow.text(day)])
    }

    /// Removes one override by its row id. Other doses on the same day are kept.
    public func deleteDoseOverride(id: String) throws {
        try execute(sql: "DELETE FROM medication_dose_override WHERE id = ?", arguments: [id])
    }

    /// Every override for `day` with its row id, in the order they were logged. Lists the doses of an as-needed
    /// medication so that one can be removed.
    public func doseOverrideEntries(day: LocalDay) throws -> [DoseOverrideEntry] {
        try MedicationOverrideRow.fetchAll(self, sql: """
        SELECT * FROM medication_dose_override WHERE local_day = ? ORDER BY created_at, rowid
        """, arguments: [MedicationOverrideRow.text(day)]).compactMap { row in
            row.doseOverride().map { DoseOverrideEntry(id: row.id, override: $0) }
        }
    }

    /// Overrides for days in `from...to` (both inclusive), oldest day first.
    public func doseOverrides(from: LocalDay, to: LocalDay) throws -> [DoseOverride] {
        try MedicationOverrideRow.fetchAll(self, sql: """
        SELECT * FROM medication_dose_override WHERE local_day BETWEEN ? AND ? ORDER BY local_day, rowid
        """, arguments: [MedicationOverrideRow.text(from), MedicationOverrideRow.text(to)])
            .compactMap { $0.doseOverride() }
    }

    /// Merged active-effect windows that overlap the local days `from...to` (both inclusive), in `timeZone`.
    ///
    /// Doses are expanded from a few days earlier, so a late dose whose effect runs into `from` is included.
    /// Windows are merged per class with `MedicationEffect.merged`, so `medicationID` on the result is the
    /// medication that started each merged run.
    public func medicationWindows(from: LocalDay, to: LocalDay, in timeZone: TimeZone) throws -> [MedicationWindow] {
        let profiles = try medications()
        let longestMinutes = profiles.filter(\.active).map { $0.onsetMinutes + $0.durationMinutes }.max() ?? 0
        let lookbackDays = longestMinutes / 1440 + 2
        let scanFrom = LocalTime.adding(days: -lookbackDays, to: from)

        let doses = MedicationEffect.doses(
            profiles: profiles,
            overrides: try doseOverrides(from: scanFrom, to: to),
            from: scanFrom,
            to: to,
            in: timeZone
        )
        let rangeStartMs = LocalTime.localTime(from, minuteOfDay: 0, in: timeZone)
        let rangeEndMs = LocalTime.localTime(LocalTime.adding(days: 1, to: to), minuteOfDay: 0, in: timeZone)
        let overlapping = MedicationEffect.activeWindows(doses: doses, profiles: profiles).filter {
            $0.endMs > rangeStartMs && $0.startMs < rangeEndMs
        }
        return MedicationEffect.merged(overlapping)
    }
}
