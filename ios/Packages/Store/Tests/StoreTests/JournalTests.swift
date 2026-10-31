import Foundation
import GRDB
import Metrics
import Testing
@testable import Store

@Suite("Journal store: questions, answers, insights (v10)")
struct JournalStoreTests {
    private let oct1 = LocalDay(year: 2026, month: 10, day: 1)
    private let oct2 = LocalDay(year: 2026, month: 10, day: 2)
    private let oct4 = LocalDay(year: 2026, month: 10, day: 4)
    private let oct12 = LocalDay(year: 2026, month: 10, day: 12)
    private let oct20 = LocalDay(year: 2026, month: 10, day: 20)

    private func day(_ value: Int) -> LocalDay {
        LocalDay(year: 2026, month: 10, day: value)
    }

    // MARK: Migration

    @Test func freshDatabaseSeedsTheBuiltInQuestions() throws {
        let database = try AppDatabase.inMemory()
        let questions = try database.writer.read { try $0.journalQuestions() }
        #expect(questions.count == 10)
        #expect(questions.allSatisfy { $0.builtIn && $0.enabled && $0.kind == .yesno })
        #expect(questions.map(\.id) == [
            "caffeine_after_2pm", "alcohol", "late_meal", "screens_in_bed", "hydrated",
            "read_before_bed", "sexual_activity", "felt_sick", "high_stress_day", "nap",
        ])
        #expect(questions.map(\.sort) == Array(0..<10))
    }

    @Test func upgradingFromV8KeepsMedicationDataAndAddsTheJournal() throws {
        let queue = try DatabaseQueue(configuration: {
            var configuration = Configuration()
            configuration.foreignKeysEnabled = true
            return configuration
        }())
        var migrator = DatabaseMigrator()
        Schema.registerMigrations(in: &migrator)
        try migrator.migrate(queue, upTo: "v8")
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO medication (id, name, med_class, formulation, onset_min, duration_min, schedule, weekdays,
              active, updated_at)
            VALUES ('adderall', 'Adderall (IR)', 'stimulant', 'immediateRelease', 30, 300, '[480]', '[]', 1, 1)
            """)
        }
        try migrator.migrate(queue)

        try queue.read { db in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM journal_question") == 10)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM journal_entry") == 0)
            #expect(try String.fetchOne(db, sql: "SELECT name FROM medication WHERE id = 'adderall'") == "Adderall (IR)")
            let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
            #expect(applied.contains("v10"))
        }
    }

    // MARK: Questions

    @Test func disableEnableAndReorderQuestions() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try db.setJournalQuestionEnabled(id: "alcohol", enabled: false, nowMs: 10)
            try db.reorderJournalQuestions(ids: ["nap", "alcohol"], nowMs: 11)
        }
        let questions = try database.writer.read { try $0.journalQuestions() }
        #expect(questions.first { $0.id == "alcohol" }?.enabled == false)
        // Listed ids first in the given order, then the rest in their previous order.
        #expect(questions.prefix(3).map(\.id) == ["nap", "alcohol", "caffeine_after_2pm"])
        #expect(questions.map(\.sort) == Array(0..<10))
    }

    @Test func customQuestionIsAddedAtTheEndAndCanBeDeleted() throws {
        let database = try AppDatabase.inMemory()
        let id = try database.writer.write { db in
            try db.addJournalQuestion(label: "  Cold shower ", kind: .yesno, nowMs: 5_000)
        }
        try database.writer.write { db in
            try db.setAnswer(day: oct1, question: id, value: 1, nowMs: 5_001)
        }
        var questions = try database.writer.read { try $0.journalQuestions() }
        let custom = try #require(questions.last)
        #expect(custom.id == id)
        #expect(custom.label == "Cold shower")
        #expect(custom.builtIn == false)
        #expect(custom.sort == 10)

        try database.writer.write { db in try db.deleteJournalQuestion(id: id) }
        questions = try database.writer.read { try $0.journalQuestions() }
        #expect(questions.count == 10)
        #expect(try database.writer.read { try $0.answers(day: oct1) }.isEmpty)
    }

    @Test func builtInQuestionsCannotBeDeletedAndEmptyLabelsAreRejected() throws {
        let database = try AppDatabase.inMemory()
        #expect(throws: JournalError.builtInQuestion) {
            try database.writer.write { db in try db.deleteJournalQuestion(id: "alcohol") }
        }
        #expect(throws: JournalError.emptyLabel) {
            try database.writer.write { db in
                try db.addJournalQuestion(label: "   ", kind: .yesno, nowMs: 1)
            }
        }
    }

    // MARK: Answers

    @Test func answersRoundTripAndClear() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try db.setAnswer(day: oct1, question: "alcohol", value: 1, nowMs: 1)
            try db.setAnswer(day: oct1, question: "hydrated", value: 0, nowMs: 2)
            try db.setAnswer(day: oct2, question: "alcohol", value: 0, nowMs: 3)
            try db.setAnswer(day: oct1, question: "alcohol", value: 0, nowMs: 4) // overwrite
        }
        let stored = try database.writer.read { db -> ([String: Int], [JournalAnswer]) in
            (try db.answers(day: oct1), try db.answers(from: oct1, to: oct2))
        }
        #expect(stored.0 == ["alcohol": 0, "hydrated": 0])
        #expect(stored.1 == [
            JournalAnswer(day: oct1, questionID: "alcohol", value: 0),
            JournalAnswer(day: oct1, questionID: "hydrated", value: 0),
            JournalAnswer(day: oct2, questionID: "alcohol", value: 0),
        ])

        try database.writer.write { db in
            try db.setAnswer(day: oct1, question: "alcohol", value: nil, nowMs: 5)
        }
        #expect(try database.writer.read { try $0.answers(day: oct1) } == ["hydrated": 0])
    }

    @Test func answerRangeIsInclusiveOfBothDays() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try db.setAnswer(day: day(30), question: "alcohol", value: 1, nowMs: 1)
            try db.setAnswer(day: oct1, question: "alcohol", value: 1, nowMs: 1)
            try db.setAnswer(day: oct2, question: "alcohol", value: 1, nowMs: 1)
            try db.setAnswer(day: oct4, question: "alcohol", value: 1, nowMs: 1)
        }
        let inRange = try database.writer.read { try $0.answers(from: oct1, to: oct2) }
        #expect(inRange.map(\.day) == [oct1, oct2])
    }

    @Test func invalidAnswersAreRejected() throws {
        let database = try AppDatabase.inMemory()
        #expect(throws: JournalError.invalidValue) {
            try database.writer.write { db in try db.setAnswer(day: oct1, question: "alcohol", value: 2, nowMs: 1) }
        }
        #expect(throws: JournalError.unknownQuestion) {
            try database.writer.write { db in try db.setAnswer(day: oct1, question: "nope", value: 1, nowMs: 1) }
        }
        // A count question takes any non-negative value.
        let count = try database.writer.write { db in
            try db.addJournalQuestion(label: "Coffees", kind: .count, nowMs: 1)
        }
        try database.writer.write { db in try db.setAnswer(day: oct1, question: count, value: 3, nowMs: 2) }
        #expect(try database.writer.read { try $0.answers(day: oct1)[count] } == 3)
    }

    // MARK: Insights

    /// Ten nights of journal answers for alcohol on Oct 1-12 (yes on odd days), with the morning after each day
    /// carrying HRV 30 ms after a yes and 50 ms after a no. A stray sleep on Oct 1's morning (HRV 999) belongs to
    /// Sep 30, which has no alcohol answer, so it must not reach the alcohol comparison.
    private func seedAlcoholAndSleep(_ database: AppDatabase) throws {
        try database.writer.write { db in
            for index in 1...12 {
                let answer = index % 2 == 1
                try db.setAnswer(day: day(index), question: "alcohol", value: answer ? 1 : 0, nowMs: 1)
            }
            // Morning of day M (M = 1...13) has HRV from the answer on M - 1; Oct 1's morning is the stray one.
            try insertNight(db, morning: oct1, rmssd: 999)
            for index in 2...13 {
                let previousAnswer = (index - 1) % 2 == 1
                try insertNight(db, morning: day(index), rmssd: previousAnswer ? 30 : 50)
            }
        }
    }

    private func insertNight(_ db: Database, morning: LocalDay, rmssd: Double) throws {
        let end = LocalTime.localTime(morning, hour: 7, in: chicago)
        try db.execute(sql: """
        INSERT INTO sleep_session (band_id, start_ms, end_ms, duration_s, rmssd_ms, contact_fraction, quality,
          record_count, algo_version, computed_at, is_nap)
        SELECT id, ?, ?, 25200, ?, 1.0, 'good', 1, 1, 0, 0 FROM band
        """, arguments: [end - 7 * 3_600_000, end, rmssd])
    }

    @Test func insightsPairDayDWithTheMorningAfterAndCountOnlyAnsweredDays() throws {
        let database = try seededDatabase()
        try seedAlcoholAndSleep(database)
        let insights = try database.writer.read {
            try $0.journalInsights(through: oct20, in: chicago)
        }
        let alcohol = try #require(insights.first { $0.behaviourID == "alcohol" && $0.effect.metric == .hrv })
        #expect(alcohol.label == "Alcohol")
        // Odd days (yes) 1, 3, ..., 11 map to mornings 2, 4, ..., 12 with HRV 30. Even days map to 50.
        #expect(alcohol.effect.with.days == 6)
        #expect(alcohol.effect.without.days == 6)
        #expect(alcohol.effect.with.mean == 30)
        #expect(alcohol.effect.without.mean == 50)
        #expect(alcohol.effect.difference == -20)
        #expect(alcohol.effect.isConfident)
    }

    @Test func insightsNeverIncludeMedications() throws {
        let database = try seededDatabase()
        try seedAlcoholAndSleep(database)
        try database.writer.write { db in
            try db.saveMedication(
                MedicationProfile.Preset.amphetamineIR.profile(id: "adderall", scheduleMinutesOfDay: [480]),
                nowMs: 1
            )
            try db.addDoseOverride(DoseOverride(medicationID: "adderall", day: oct4, kind: .skipped), nowMs: 2)
        }
        let insights = try database.writer.read {
            try $0.journalInsights(through: oct20, in: chicago)
        }
        let questionIDs = try database.writer.read { Set(try $0.journalQuestions().map(\.id)) }
        #expect(insights.allSatisfy { questionIDs.contains($0.behaviourID) })
    }

    @Test func questionsWithoutAnswersProduceNoEffectsWithData() throws {
        let database = try seededDatabase()
        let insights = try database.writer.read {
            try $0.journalInsights(through: oct20, in: chicago)
        }
        // No sleep or answers at all: every effect is empty and nothing is confident.
        #expect(insights.allSatisfy { !$0.effect.isConfident })
        #expect(insights.allSatisfy { $0.effect.with.days == 0 && $0.effect.without.days == 0 })
    }
}
