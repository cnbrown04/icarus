import Foundation
import GRDB
import Metrics

public enum JournalQuestionKind: String, Sendable, Codable, Equatable, CaseIterable {
    /// Value 1 is yes, 0 is no.
    case yesno
    /// Value is a non-negative count. Counts as yes when above zero in insights.
    case count
}

/// One question on the morning check-in (v10). Built-ins are disabled, never deleted.
public struct JournalQuestion: Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var kind: JournalQuestionKind
    public var builtIn: Bool
    public var enabled: Bool
    public var sort: Int
}

/// One stored answer for a local day.
public struct JournalAnswer: Sendable, Equatable {
    public var day: LocalDay
    public var questionID: String
    public var value: Int
}

/// One behaviour's comparison for one metric, labelled for the UI. Medication behaviours carry the profile name
/// and `isMedication`, and their ids start with `JournalBehaviour.medicationPrefix`.
public struct JournalInsight: Sendable, Equatable, Identifiable {
    public var id: String { "\(behaviourID)|\(effect.metric.rawValue)" }
    public var behaviourID: String
    public var label: String
    public var isMedication: Bool
    public var effect: JournalInsights.Effect
}

public enum JournalError: Error, Equatable {
    /// The question's label is empty after trimming.
    case emptyLabel
    /// A yes/no question was given a value other than 0 or 1.
    case invalidValue
    /// Only custom questions can be deleted.
    case builtInQuestion
    /// The question id does not exist.
    case unknownQuestion
}

/// Behaviour ids used by `journalInsights`.
public enum JournalBehaviour {
    public static let medicationPrefix = "medication:"
}

/// `journal_question` (v10) as a GRDB record. `kind` holds the raw value.
struct JournalQuestionRow: Codable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "journal_question"

    var id: String
    var label: String
    var kind: String
    var builtIn: Bool
    var enabled: Bool
    var sort: Int
    var updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, label, kind, enabled, sort
        case builtIn = "built_in"
        case updatedAt = "updated_at"
    }

    func question() -> JournalQuestion {
        JournalQuestion(
            id: id,
            label: label,
            kind: JournalQuestionKind(rawValue: kind) ?? .yesno,
            builtIn: builtIn,
            enabled: enabled,
            sort: sort
        )
    }
}

/// The morning check-in: questions, answers and the join that feeds `JournalInsights` (v10). Local only.
/// Call inside `DatabaseWriter.write` or `read`.
extension Database {
    /// Days of answers `journalInsights` looks back over, ending on its `through` day.
    public static let journalWindowDays = 90

    // MARK: Questions

    /// Every question, enabled or not, in the order the check-in shows them.
    public func journalQuestions() throws -> [JournalQuestion] {
        try JournalQuestionRow.fetchAll(self, sql: "SELECT * FROM journal_question ORDER BY sort, rowid")
            .map { $0.question() }
    }

    public func setJournalQuestionEnabled(id: String, enabled: Bool, nowMs: Int64) throws {
        try requireQuestion(id)
        try execute(sql: "UPDATE journal_question SET enabled = ?, updated_at = ? WHERE id = ?",
                    arguments: [enabled, nowMs, id])
    }

    /// Sets `sort` to each id's position in `ids`. Questions missing from `ids` keep their relative order after them.
    public func reorderJournalQuestions(ids: [String], nowMs: Int64) throws {
        let all = try journalQuestions().map(\.id)
        let listed = ids.filter { all.contains($0) }
        let order = listed + all.filter { !listed.contains($0) }
        for (position, id) in order.enumerated() {
            try execute(sql: "UPDATE journal_question SET sort = ?, updated_at = ? WHERE id = ?",
                        arguments: [position, nowMs, id])
        }
    }

    /// Adds a custom question at the end and returns its id (UUIDv7 from `nowMs`).
    @discardableResult
    public func addJournalQuestion(label: String, kind: JournalQuestionKind, nowMs: Int64) throws -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw JournalError.emptyLabel }
        let id = UUIDv7.make(unixMs: nowMs).uuidString
        let nextSort = try Int.fetchOne(self, sql: "SELECT COALESCE(MAX(sort), -1) + 1 FROM journal_question") ?? 0
        try JournalQuestionRow(
            id: id, label: trimmed, kind: kind.rawValue, builtIn: false, enabled: true,
            sort: nextSort, updatedAt: nowMs
        ).insert(self)
        return id
    }

    /// Deletes a custom question and its answers. Built-ins throw `JournalError.builtInQuestion`.
    public func deleteJournalQuestion(id: String) throws {
        let question = try requireQuestion(id)
        guard !question.builtIn else { throw JournalError.builtInQuestion }
        try execute(sql: "DELETE FROM journal_entry WHERE question_id = ?", arguments: [id])
        try execute(sql: "DELETE FROM journal_question WHERE id = ?", arguments: [id])
    }

    @discardableResult
    private func requireQuestion(_ id: String) throws -> JournalQuestion {
        guard let row = try JournalQuestionRow.fetchOne(self, sql: "SELECT * FROM journal_question WHERE id = ?",
                                                        arguments: [id]) else {
            throw JournalError.unknownQuestion
        }
        return row.question()
    }

    // MARK: Answers

    /// Records the answer for `question` on `day`. A nil value clears it. Yes/no values must be 0 or 1.
    public func setAnswer(day: LocalDay, question: String, value: Int?, nowMs: Int64) throws {
        let row = try requireQuestion(question)
        guard let value else {
            try execute(sql: "DELETE FROM journal_entry WHERE local_day = ? AND question_id = ?",
                        arguments: [JournalDayText.text(day), question])
            return
        }
        if row.kind == .yesno, !(value == 0 || value == 1) { throw JournalError.invalidValue }
        guard value >= 0 else { throw JournalError.invalidValue }
        try execute(sql: """
        INSERT INTO journal_entry (local_day, question_id, value, updated_at) VALUES (?, ?, ?, ?)
        ON CONFLICT (local_day, question_id) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
        """, arguments: [JournalDayText.text(day), question, value, nowMs])
    }

    /// Answers for one day, keyed by question id.
    public func answers(day: LocalDay) throws -> [String: Int] {
        let rows = try answers(from: day, to: day)
        return Dictionary(rows.map { ($0.questionID, $0.value) }, uniquingKeysWith: { kept, _ in kept })
    }

    /// Answers for days in `from...to` (both inclusive), oldest day first.
    public func answers(from: LocalDay, to: LocalDay) throws -> [JournalAnswer] {
        try Row.fetchAll(self, sql: """
        SELECT local_day, question_id, value FROM journal_entry WHERE local_day BETWEEN ? AND ?
        ORDER BY local_day, question_id
        """, arguments: [JournalDayText.text(from), JournalDayText.text(to)]).compactMap { row in
            guard let day = JournalDayText.day(row["local_day"]) else { return nil }
            return JournalAnswer(day: day, questionID: row["question_id"], value: row["value"])
        }
    }

    // MARK: Insights

    /// Comparisons over the `journalWindowDays` local days ending on `through`, for every question and for each
    /// stimulant medication.
    ///
    /// Day D's answers (and "took <medication>" for day D, from `MedicationEffect.doses` with the schedule or
    /// overrides) are paired with the outcomes of the morning of D + 1: recovery and sleep performance from
    /// `dailyScores(day: D + 1)`, and HRV from the main sleep that ended on D + 1. A day with no outcome, or
    /// with no answer, is left out of that behaviour. The result is correlation, not causation (see
    /// `JournalInsights`).
    public func journalInsights(through last: LocalDay, in timeZone: TimeZone) throws -> [JournalInsight] {
        let first = LocalTime.adding(days: -(Self.journalWindowDays - 1), to: last)
        let questions = try journalQuestions()
        let profiles = try medications().filter { $0.active && $0.medClass == .stimulant }
        let doses = MedicationEffect.doses(
            profiles: profiles,
            overrides: try doseOverrides(from: first, to: last),
            from: first,
            to: last,
            in: timeZone
        )

        var behaviours: [LocalDay: [String: Bool]] = [:]
        for answer in try answers(from: first, to: last) {
            behaviours[answer.day, default: [:]][answer.questionID] = answer.value > 0
        }
        // A medication is "taken" on a day that has a dose. Every other day in the window is a "no".
        let takenKeys = Set(doses.map { dose in
            "\(dose.medicationID)|\(JournalDayText.text(LocalTime.localDay(containing: dose.takenAtMs, in: timeZone)))"
        })
        var day = first
        while JournalDayText.text(day) <= JournalDayText.text(last) {
            for profile in profiles {
                behaviours[day, default: [:]][JournalBehaviour.medicationPrefix + profile.id] =
                    takenKeys.contains("\(profile.id)|\(JournalDayText.text(day))")
            }
            day = LocalTime.adding(days: 1, to: day)
        }

        var days: [JournalInsights.Day] = []
        day = first
        while JournalDayText.text(day) <= JournalDayText.text(last) {
            let outcome = try morningOutcome(of: LocalTime.adding(days: 1, to: day), in: timeZone)
            days.append(JournalInsights.Day(behaviours: behaviours[day] ?? [:], outcome: outcome))
            day = LocalTime.adding(days: 1, to: day)
        }

        let questionLabels = Dictionary(questions.map { ($0.id, $0.label) }, uniquingKeysWith: { kept, _ in kept })
        let profileNames = Dictionary(profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { kept, _ in kept })
        return JournalInsights.effects(for: days).compactMap { effect in
            if effect.behaviour.hasPrefix(JournalBehaviour.medicationPrefix) {
                let id = String(effect.behaviour.dropFirst(JournalBehaviour.medicationPrefix.count))
                guard let name = profileNames[id] else { return nil }
                return JournalInsight(behaviourID: effect.behaviour, label: name, isMedication: true, effect: effect)
            }
            guard let label = questionLabels[effect.behaviour] else { return nil }
            return JournalInsight(behaviourID: effect.behaviour, label: label, isMedication: false, effect: effect)
        }
    }

    /// Recovery, sleep performance and HRV for the morning of `day`.
    private func morningOutcome(of day: LocalDay, in timeZone: TimeZone) throws -> JournalInsights.Outcome {
        let scores = try dailyScores(day: day, in: timeZone)
        var recovery: Double?
        if case .scored(let score)? = scores.recovery {
            recovery = score.score
        }
        let dayStart = LocalTime.localTime(day, hour: 0, in: timeZone)
        let dayEnd = LocalTime.localTime(LocalTime.adding(days: 1, to: day), hour: 0, in: timeZone)
        let tonight = try SleepSessionRow.fetchAll(self, sql: """
        SELECT * FROM sleep_session WHERE is_nap = 0 AND end_ms >= ? AND end_ms < ? ORDER BY start_ms, rowid
        """, arguments: [dayStart, dayEnd])
            .max { $0.endMs - $0.startMs < $1.endMs - $1.startMs }
        return JournalInsights.Outcome(
            recoveryPct: recovery,
            sleepPerformancePct: scores.sleep?.performancePct,
            hrvMs: tonight?.rmssdMs
        )
    }
}

/// 'YYYY-MM-DD' for `journal_entry.local_day`. Lexical order matches calendar order.
enum JournalDayText {
    static func text(_ day: LocalDay) -> String {
        "\(pad(day.year, 4))-\(pad(day.month, 2))-\(pad(day.day, 2))"
    }

    static func day(_ text: String?) -> LocalDay? {
        guard let text else { return nil }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return LocalDay(year: parts[0], month: parts[1], day: parts[2])
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}
