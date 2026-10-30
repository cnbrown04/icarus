import Foundation
import Testing
@testable import Metrics

@Suite("Medication: schedules, overrides, active-effect windows")
struct MedicationTests {
    private let chicago = TimeZone(identifier: "America/Chicago")!
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let oct8 = LocalDay(year: 2026, month: 10, day: 8)
    private let oct9 = LocalDay(year: 2026, month: 10, day: 9)
    private let oct12 = LocalDay(year: 2026, month: 10, day: 12)

    /// Epoch ms for an ISO-8601 UTC instant such as "2026-10-08T13:00:00Z".
    private func ms(_ text: String) -> Int64 {
        Int64(ISO8601DateFormatter().date(from: text)!.timeIntervalSince1970 * 1000)
    }

    private func adderall(schedule: [Int] = [480], weekdays: Set<Int> = [], active: Bool = true) -> MedicationProfile {
        MedicationProfile.Preset.amphetamineIR.profile(
            id: "adderall", scheduleMinutesOfDay: schedule, weekdays: weekdays, active: active
        )
    }

    // MARK: Schedule expansion

    @Test func scheduleExpandsEveryTimeOnEveryDayInLocalTime() {
        // Chicago is CDT (UTC-5) on Oct 8 and 9: 08:00 is 13:00Z and 20:00 is 01:00Z the next day.
        let doses = MedicationEffect.doses(
            profiles: [adderall(schedule: [480, 1200])],
            overrides: [],
            from: oct8, to: oct9, in: chicago
        )
        #expect(doses.map(\.takenAtMs) == [
            ms("2026-10-08T13:00:00Z"), ms("2026-10-09T01:00:00Z"),
            ms("2026-10-09T13:00:00Z"), ms("2026-10-10T01:00:00Z"),
        ])
        #expect(doses.allSatisfy { $0.medicationID == "adderall" })
    }

    @Test func weekdayFilterKeepsOnlyScheduledDays() {
        // Oct 8 2026 is a Thursday and Oct 12 a Monday. Weekday 2 is Monday.
        let doses = MedicationEffect.doses(
            profiles: [adderall(weekdays: [2])],
            overrides: [],
            from: oct8, to: oct12, in: chicago
        )
        #expect(doses.map(\.takenAtMs) == [ms("2026-10-12T13:00:00Z")])
    }

    @Test func inactiveProfileProducesNoDoses() {
        let doses = MedicationEffect.doses(
            profiles: [adderall(active: false)],
            overrides: [],
            from: oct8, to: oct9, in: chicago
        )
        #expect(doses.isEmpty)
    }

    @Test func rangeIsInclusiveOfBothEndDays() {
        let single = MedicationEffect.doses(profiles: [adderall()], overrides: [], from: oct9, to: oct9, in: chicago)
        #expect(single.count == 1)
        let empty = MedicationEffect.doses(profiles: [adderall()], overrides: [], from: oct9, to: oct8, in: chicago)
        #expect(empty.isEmpty)
    }

    // MARK: Overrides

    @Test func takenOverrideReplacesTheScheduleForThatDay() {
        let logged = ms("2026-10-08T15:10:00Z")
        let doses = MedicationEffect.doses(
            profiles: [adderall()],
            overrides: [DoseOverride(medicationID: "adderall", day: oct8, kind: .taken(atMs: logged))],
            from: oct8, to: oct9, in: chicago
        )
        // Oct 8 uses only the logged time; Oct 9 keeps the schedule.
        #expect(doses.map(\.takenAtMs) == [logged, ms("2026-10-09T13:00:00Z")])
    }

    @Test func skippedDayHasNoDoses() {
        let doses = MedicationEffect.doses(
            profiles: [adderall()],
            overrides: [DoseOverride(medicationID: "adderall", day: oct8, kind: .skipped)],
            from: oct8, to: oct9, in: chicago
        )
        #expect(doses.map(\.takenAtMs) == [ms("2026-10-09T13:00:00Z")])
    }

    @Test func takenOverrideCountsOnAnUnscheduledWeekday() {
        // Weekday 2 (Monday) only, but the user logged a dose on Thursday Oct 8.
        let logged = ms("2026-10-08T17:00:00Z")
        let doses = MedicationEffect.doses(
            profiles: [adderall(weekdays: [2])],
            overrides: [DoseOverride(medicationID: "adderall", day: oct8, kind: .taken(atMs: logged))],
            from: oct8, to: oct8, in: chicago
        )
        #expect(doses.map(\.takenAtMs) == [logged])
    }

    @Test func overridesOnlyApplyToTheirOwnMedication() {
        let other = MedicationProfile.Preset.methylphenidateIR.profile(id: "mph", scheduleMinutesOfDay: [540])
        let doses = MedicationEffect.doses(
            profiles: [adderall(), other],
            overrides: [DoseOverride(medicationID: "adderall", day: oct8, kind: .skipped)],
            from: oct8, to: oct8, in: chicago
        )
        #expect(doses.map(\.medicationID) == ["mph"])
    }

    // MARK: DST

    @Test func scheduledTimeStaysOnTheWallClockAcrossFallBack() {
        // New York falls back on Sunday 2026-11-01. 08:00 is EDT (12:00Z) on Oct 31 and EST (13:00Z) on Nov 1.
        let oct31 = LocalDay(year: 2026, month: 10, day: 31)
        let nov1 = LocalDay(year: 2026, month: 11, day: 1)
        let doses = MedicationEffect.doses(
            profiles: [adderall()],
            overrides: [],
            from: oct31, to: nov1, in: newYork
        )
        #expect(doses.map(\.takenAtMs) == [ms("2026-10-31T12:00:00Z"), ms("2026-11-01T13:00:00Z")])
    }

    // MARK: Windows

    @Test func windowStartsAtOnsetAndEndsAfterDuration() {
        // Adderall IR: onset 30 min, duration 300 min. Dose 13:00Z gives 13:30Z to 18:30Z.
        let doses = [MedicationDose(medicationID: "adderall", takenAtMs: ms("2026-10-08T13:00:00Z"))]
        let windows = MedicationEffect.activeWindows(doses: doses, profiles: [adderall()])
        #expect(windows == [MedicationWindow(
            medicationID: "adderall", medClass: .stimulant,
            startMs: ms("2026-10-08T13:30:00Z"), endMs: ms("2026-10-08T18:30:00Z")
        )])
    }

    @Test func dosesForUnknownMedicationsAreIgnored() {
        let doses = [MedicationDose(medicationID: "ghost", takenAtMs: 0)]
        #expect(MedicationEffect.activeWindows(doses: doses, profiles: [adderall()]).isEmpty)
    }

    @Test func mergeUnionsOverlappingWindowsOfTheSameClassOnly() {
        let stimulant = MedicationClass.stimulant
        let windows = [
            MedicationWindow(medicationID: "a", medClass: stimulant, startMs: 1_000, endMs: 2_000),
            MedicationWindow(medicationID: "b", medClass: stimulant, startMs: 1_500, endMs: 3_000),
            MedicationWindow(medicationID: "c", medClass: stimulant, startMs: 3_000, endMs: 3_500),
            MedicationWindow(medicationID: "d", medClass: stimulant, startMs: 5_000, endMs: 6_000),
            MedicationWindow(medicationID: "e", medClass: .other, startMs: 1_200, endMs: 1_800),
        ]
        let merged = MedicationEffect.merged(windows)
        #expect(merged == [
            MedicationWindow(medicationID: "a", medClass: stimulant, startMs: 1_000, endMs: 3_500),
            MedicationWindow(medicationID: "e", medClass: .other, startMs: 1_200, endMs: 1_800),
            MedicationWindow(medicationID: "d", medClass: stimulant, startMs: 5_000, endMs: 6_000),
        ])
    }

    @Test func mergeDropsEmptyWindows() {
        let empty = MedicationWindow(medicationID: "a", medClass: .stimulant, startMs: 100, endMs: 100)
        #expect(MedicationEffect.merged([empty]).isEmpty)
    }

    @Test func stimulantActiveIsStartInclusiveEndExclusive() {
        let windows = [MedicationWindow(medicationID: "a", medClass: .stimulant, startMs: 1_000, endMs: 2_000)]
        #expect(!MedicationEffect.isStimulantActive(at: 999, windows: windows))
        #expect(MedicationEffect.isStimulantActive(at: 1_000, windows: windows))
        #expect(MedicationEffect.isStimulantActive(at: 1_999, windows: windows))
        #expect(!MedicationEffect.isStimulantActive(at: 2_000, windows: windows))
    }

    @Test func otherClassWindowsDoNotCountAsStimulant() {
        let windows = [MedicationWindow(medicationID: "a", medClass: .other, startMs: 1_000, endMs: 2_000)]
        #expect(!MedicationEffect.isStimulantActive(at: 1_500, windows: windows))
    }

    // MARK: Presets

    @Test func presetsCarryTheApproximateTypicalRanges() {
        let expected: [(MedicationProfile.Preset, String, MedicationFormulation, Int, Int)] = [
            (.amphetamineIR, "Adderall (IR)", .immediateRelease, 30, 300),
            (.amphetamineXR, "Adderall XR", .extendedRelease, 60, 660),
            (.methylphenidateIR, "Methylphenidate (IR)", .immediateRelease, 20, 240),
            (.methylphenidateER, "Methylphenidate (ER)", .extendedRelease, 60, 600),
        ]
        for (preset, name, formulation, onset, duration) in expected {
            let profile = preset.profile(id: "x", scheduleMinutesOfDay: [480])
            #expect(profile.name == name)
            #expect(profile.medClass == .stimulant)
            #expect(profile.formulation == formulation)
            #expect(profile.onsetMinutes == onset)
            #expect(profile.durationMinutes == duration)
            #expect(profile.scheduleMinutesOfDay == [480])
            #expect(profile.weekdays.isEmpty)
            #expect(profile.active)
        }
    }
}
