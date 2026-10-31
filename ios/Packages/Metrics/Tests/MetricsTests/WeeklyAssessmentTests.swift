import Testing
@testable import Metrics

@Suite("WeeklyAssessment: week-over-week averages, deltas and observations")
struct WeeklyAssessmentTests {
    private func week(hrv: Double? = nil, restingHR: Double? = nil, recovery: Double? = nil,
                      strain: Double? = nil, sleep: Double? = nil, hours: Double? = nil) -> [WeeklyAssessment.Day] {
        (0..<7).map { _ in
            WeeklyAssessment.Day(
                recovery: recovery,
                sleepPerformance: sleep,
                hoursSlept: hours,
                strain: strain,
                hrv: hrv,
                restingHR: restingHR
            )
        }
    }

    private func row(_ report: WeeklyAssessment.Report, _ metric: WeeklyAssessment.Metric) -> WeeklyAssessment.Row? {
        report.rows.first { $0.metric == metric }
    }

    @Test func averagesAndDeltasComeFromTheTwoWeeks() throws {
        let report = WeeklyAssessment.report(
            thisWeek: week(hrv: 50),
            previousWeek: week(hrv: 40)
        )
        let hrv = try #require(row(report, .hrv))
        #expect(hrv.thisWeek == 50)
        #expect(hrv.previousWeek == 40)
        #expect(hrv.delta == 10)
    }

    @Test func aWeekWithFewerThanThreeValuesHasNoAverage() {
        let sparse = [
            WeeklyAssessment.Day(hrv: 50),
            WeeklyAssessment.Day(hrv: 52),
            WeeklyAssessment.Day(),
            WeeklyAssessment.Day(),
        ]
        let report = WeeklyAssessment.report(thisWeek: sparse, previousWeek: week(hrv: 40))
        let hrv = row(report, .hrv)
        #expect(hrv?.thisWeek == nil)
        #expect(hrv?.delta == nil)
        #expect(hrv?.previousWeek == 40)
        #expect(report.thisWeekDays == 2)
        #expect(report.previousWeekDays == 7)
    }

    @Test func aMissingWeekGivesNoDeltaAndNoObservation() {
        let report = WeeklyAssessment.report(thisWeek: week(hrv: 50), previousWeek: [])
        #expect(report.rows.allSatisfy { $0.delta == nil })
        #expect(report.observations.isEmpty)
    }

    @Test func observationIsNumbersFirstAndNamesTheDirection() {
        let report = WeeklyAssessment.report(
            thisWeek: week(hrv: 48, restingHR: 58),
            previousWeek: week(hrv: 55, restingHR: 58)
        )
        #expect(report.observations == ["HRV averaged 48 ms, down 7 ms from the week before."])
    }

    @Test func smallMovesBelowThresholdAreNotMentioned() {
        // HRV moves 3 ms, under its 5 ms threshold. Resting HR moves 2 bpm, under its 3 bpm threshold.
        let report = WeeklyAssessment.report(
            thisWeek: week(hrv: 53, restingHR: 58),
            previousWeek: week(hrv: 50, restingHR: 56)
        )
        #expect(report.observations.isEmpty)
    }

    @Test func atMostThreeObservationsRankedBySize() {
        // Threshold multiples: recovery 4x (20 points), sleep 3x (15 points), HRV 2x (10 ms), RHR 1.7x (5 bpm).
        // RHR is the fourth-largest move, so it is dropped.
        let report = WeeklyAssessment.report(
            thisWeek: week(hrv: 40, restingHR: 61, recovery: 50, sleep: 70),
            previousWeek: week(hrv: 50, restingHR: 56, recovery: 70, sleep: 85)
        )
        #expect(report.observations.count == 3)
        #expect(report.observations[0].hasPrefix("Recovery averaged 50%"))
        #expect(report.observations[1].hasPrefix("Sleep performance averaged 70%"))
        #expect(report.observations[2].hasPrefix("HRV averaged 40 ms"))
    }

    @Test func restingHRRisingIsReportedAsUp() {
        let report = WeeklyAssessment.report(
            thisWeek: week(restingHR: 60),
            previousWeek: week(restingHR: 52)
        )
        #expect(report.observations == ["Resting HR averaged 60 bpm, up 8 bpm from the week before."])
        #expect(WeeklyAssessment.Metric.restingHR.higherIsBetter == false)
    }

    @Test func strainAndHoursUseTheirOwnUnits() {
        let report = WeeklyAssessment.report(
            thisWeek: week(strain: 14.5, hours: 6.0),
            previousWeek: week(strain: 11.0, hours: 7.0)
        )
        #expect(report.observations.contains("Strain averaged 14.5, up 3.5 from the week before."))
        #expect(report.observations.contains("Hours slept averaged 6.0 h, down 1.0 h from the week before."))
    }

    @Test func rowsCoverEveryMetricInOrder() {
        let report = WeeklyAssessment.report(thisWeek: [], previousWeek: [])
        #expect(report.rows.map(\.metric) == WeeklyAssessment.Metric.allCases)
        #expect(report.observations.isEmpty)
    }
}
