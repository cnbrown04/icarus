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
}
