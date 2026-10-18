import Foundation
import GRDB

// Writes server configuration into the store (PLAN.md 11.4). The server copy wins, so these statements replace
// local values. `alarm.version` only moves forward, so an older response cannot overwrite a newer alarm.

extension Database {
    func applyAlarm(_ alarm: AlarmDTO, nowMs: Int64) throws {
        let updatedMs = RFC3339.date(alarm.updatedAt).map { Int64($0.timeIntervalSince1970 * 1000) } ?? nowMs
        let deletedMs = alarm.deletedAt.flatMap(RFC3339.date).map { Int64($0.timeIntervalSince1970 * 1000) }
        try execute(sql: """
        INSERT INTO alarm (id, kind, label, schedule, rhythm, channels, enabled, version, updated_at, deleted_at, dirty)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
        ON CONFLICT(id) DO UPDATE SET
          kind = excluded.kind, label = excluded.label, schedule = excluded.schedule, rhythm = excluded.rhythm,
          channels = excluded.channels, enabled = excluded.enabled, version = excluded.version,
          updated_at = excluded.updated_at, deleted_at = excluded.deleted_at, dirty = 0
        WHERE excluded.version >= alarm.version
        """, arguments: [
            alarm.id,
            alarm.kind,
            alarm.label,
            alarm.schedule?.text,
            alarm.rhythm.text ?? "[]",
            JSONValue.array(alarm.channels.map(JSONValue.string)).text ?? "[]",
            alarm.enabled,
            alarm.version,
            updatedMs,
            deletedMs,
        ])
    }

    /// Replaces the local profile with the server's. Unknown sex or timezone values fall back to nil or the default.
    func applyProfile(_ profile: ProfileDTO, nowMs: Int64) throws {
        let sex = ["male", "female"].contains(profile.formulaSex ?? "") ? profile.formulaSex : nil
        let zone = profile.tz.flatMap { TimeZone(identifier: $0) != nil ? $0 : nil } ?? "America/Chicago"
        try execute(sql: """
        INSERT INTO profile (id, formula_sex, birth_year, height_cm, weight_kg, hr_max, tz, version, updated_at)
        VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          formula_sex = excluded.formula_sex, birth_year = excluded.birth_year, height_cm = excluded.height_cm,
          weight_kg = excluded.weight_kg, hr_max = excluded.hr_max, tz = excluded.tz,
          version = excluded.version, updated_at = excluded.updated_at
        """, arguments: [
            sex,
            profile.birthYear,
            profile.heightCm,
            profile.weightKg,
            profile.hrMax,
            zone,
            profile.version,
            nowMs,
        ])
    }
}
