import Foundation
import Testing
@testable import Icarus

struct DataAgeTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func formatsAgesWithNumbersBeforeUnits() {
        #expect(DataAge.text(seconds: 42) == "42 s ago")
        #expect(DataAge.text(seconds: 240) == "4 min ago")
        #expect(DataAge.text(seconds: 7_200) == "2 h ago")
    }

    @Test func freshDataHasNoStaleText() {
        let recent = now.addingTimeInterval(-60)
        #expect(DataAge.staleText(since: recent, now: now) == nil)
        #expect(DataAge.staleText(since: nil, now: now) == nil)
    }

    @Test func staleDataShowsItsAge() {
        let old = now.addingTimeInterval(-61)
        #expect(DataAge.staleText(since: old, now: now) == "1 min ago")
    }

    @Test func gapOverTenMinutesPausesCollection() {
        #expect(!DataAge.isPaused(since: nil, now: now))
        #expect(!DataAge.isPaused(since: now.addingTimeInterval(-600), now: now))
        #expect(DataAge.isPaused(since: now.addingTimeInterval(-601), now: now))
    }
}
