import Foundation
import Store
import Testing
@testable import Icarus

struct ProfileDraftTests {
    private func complete() -> ProfileDraft {
        var draft = ProfileDraft()
        draft.sex = .female
        draft.birthYear = "1990"
        draft.heightCm = "165"
        draft.weightKg = "62,5"
        return draft
    }

    @Test func emptyDraftNeedsSexFirst() {
        #expect(ProfileDraft().firstIssue == .sex)
        #expect(!ProfileDraft().isComplete)
    }

    @Test func completeDraftBuildsARowWithOptionalHRmaxBlank() throws {
        let row = try #require(complete().row())
        #expect(row.formulaSex == "female")
        #expect(row.birthYear == 1990)
        #expect(row.heightCm == 165)
        #expect(row.weightKg == 62.5)
        #expect(row.hrMax == nil)
    }

    @Test func rejectsOutOfRangeValues() {
        var draft = complete()
        draft.heightCm = "99"
        #expect(draft.firstIssue == .height)
        draft.heightCm = "165"
        draft.weightKg = "301"
        #expect(draft.firstIssue == .weight)
        draft.weightKg = "62"
        draft.hrMax = "240"
        #expect(draft.firstIssue == .hrMax)
        draft.hrMax = ""
        #expect(draft.firstIssue == nil)
    }

    @Test func roundTripsThroughARow() throws {
        let row = ProfileRow(formulaSex: "male", birthYear: 1985, heightCm: 180, weightKg: 75, hrMax: 190)
        let draft = ProfileDraft(row: row)
        #expect(draft.sex == .male)
        #expect(draft.hrMax == "190")
        #expect(draft.row()?.heightCm == 180)
    }

    @Test func messagesNameTheUnitsInUse() {
        // Metric names cm and kg; imperial names the converted display range (40...98 in and
        // 66.2...661.3 lb, widened outward so accepted display values map back into metric range).
        #expect(ProfileDraft.Issue.height.message(isImperial: false) == "Height must be from 100 to 250 cm.")
        #expect(ProfileDraft.Issue.height.message(isImperial: true) == "Height must be from 3'4\" to 8'2\".")
        #expect(ProfileDraft.Issue.weight.message(isImperial: false) == "Weight must be from 30 to 300 kg.")
        #expect(ProfileDraft.Issue.weight.message(isImperial: true) == "Weight must be from 66.2 to 661.3 lb.")
        #expect(ProfileDraft.Issue.hrMax.message(isImperial: true) == "Max heart rate must be from 100 to 230 bpm, or empty.")
    }

    @Test func parsedValuesIgnoreRangeForDisplaySeeding() {
        var draft = complete()
        #expect(draft.parsedHeightCm == 165)
        #expect(draft.parsedWeightKg == 62.5)
        draft.heightCm = "99" // out of range but still displayable
        #expect(draft.parsedHeightCm == 99)
        #expect(draft.firstIssue == .height)
        draft.heightCm = "abc"
        #expect(draft.parsedHeightCm == nil)
    }
}
