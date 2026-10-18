import BandKit
import Foundation
import Testing

@Suite("Rhythm model (PLAN.md 9.2)")
struct RhythmTests {
    @Test func acceptsTenStepsAndThirtySeconds() throws {
        let steps = Array(repeating: Rhythm.Step.pause(ms: 3000), count: 10)
        let rhythm = try Rhythm(steps: steps)
        #expect(rhythm.durationSeconds == 30)
    }

    @Test func rejectsEmptyRhythms() {
        #expect(throws: Rhythm.ValidationError.empty) {
            try Rhythm(steps: [])
        }
    }

    @Test func rejectsMoreThanTenSteps() {
        #expect(throws: Rhythm.ValidationError.tooManySteps(11)) {
            try Rhythm(steps: Array(repeating: .pause(ms: 1), count: 11))
        }
    }

    @Test func rejectsZeroLoopsAndNegativePauses() {
        #expect(throws: Rhythm.ValidationError.invalidLoops) {
            try Rhythm(steps: [.buzz(preset: 2, loops: 0)])
        }
        #expect(throws: Rhythm.ValidationError.negativePause) {
            try Rhythm(steps: [.pause(ms: -1)])
        }
    }

    @Test func rejectsRhythmsLongerThanThirtySeconds() {
        #expect(throws: Rhythm.ValidationError.tooLong(seconds: 31)) {
            try Rhythm(steps: [.buzz(preset: 2, loops: 31)])
        }
    }

    @Test func roundTripsThroughJSONAndRevalidates() throws {
        let rhythm = try Rhythm(steps: [.buzz(preset: 2, loops: 3), .pause(ms: 250)])
        let data = try JSONEncoder().encode(rhythm)
        #expect(try JSONDecoder().decode(Rhythm.self, from: data) == rhythm)

        let tooLong = Data(#"[{"buzz":{"preset":2,"loops":40}}]"#.utf8)
        #expect(throws: Rhythm.ValidationError.tooLong(seconds: 40)) {
            try JSONDecoder().decode(Rhythm.self, from: tooLong)
        }
    }
}
