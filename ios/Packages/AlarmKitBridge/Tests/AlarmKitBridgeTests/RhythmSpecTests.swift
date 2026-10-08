import BandKit
import Foundation
import Testing
@testable import AlarmKitBridge

struct RhythmSpecTests {
    @Test func builtInNamesDecode() throws {
        #expect(try RhythmSpec(jsonText: #""double""#) == .builtIn(.double))
        #expect(try RhythmSpec(jsonText: #""sos""#) == .builtIn(.sos))
    }

    @Test func unknownNamesAreRejected() {
        #expect(throws: RhythmSpec.WireError.unknownName("buzzy")) {
            try RhythmSpec(jsonText: #""buzzy""#)
        }
    }

    @Test func customStepsDecodeInWireOrder() throws {
        let spec = try RhythmSpec(jsonText: #"[{"type":"buzz","preset":2,"loops":1},{"type":"pause","ms":300}]"#)
        #expect(spec == .custom(try Rhythm(steps: [.buzz(preset: 2, loops: 1), .pause(ms: 300)])))
    }

    @Test func badStepsReportTheirIndex() {
        #expect(throws: RhythmSpec.WireError.badStep(index: 1)) {
            try RhythmSpec(jsonText: #"[{"type":"buzz","preset":2,"loops":1},{"type":"vibrate"}]"#)
        }
        #expect(throws: RhythmSpec.WireError.badStep(index: 0)) {
            try RhythmSpec(jsonText: #"[{"type":"buzz","preset":300,"loops":1}]"#)
        }
        #expect(throws: RhythmSpec.WireError.badStep(index: 0)) {
            try RhythmSpec(jsonText: #"[{"type":"buzz","preset":2,"loops":0}]"#)
        }
    }

    @Test func rhythmsOverThirtySecondsAreRejectedByBandKit() {
        // 31 loops at one second each is over the 30 s limit (PLAN.md 9.2).
        #expect(throws: (any Error).self) {
            try RhythmSpec(jsonText: #"[{"type":"buzz","preset":2,"loops":31}]"#)
        }
    }

    @Test func customRhythmRoundTrips() throws {
        let original = RhythmSpec.custom(try Rhythm(steps: [.buzz(preset: 2, loops: 2), .pause(ms: 500)]))
        let text = try original.jsonText()
        #expect(try RhythmSpec(jsonText: text) == original)
    }

    @Test func builtInRoundTripsAsItsName() throws {
        let text = try RhythmSpec.builtIn(.ramp).jsonText()
        #expect(text == #""ramp""#)
        #expect(try RhythmSpec(jsonText: text) == .builtIn(.ramp))
    }

    @Test func everyBuiltInIsValidAndWithinTheLimits() throws {
        for name in BuiltInRhythm.allCases {
            let rhythm = try RhythmSpec.builtIn(name).rhythm()
            #expect(rhythm.steps.count <= Rhythm.maxSteps, "\(name) has too many steps")
            #expect(rhythm.durationSeconds <= Rhythm.maxDurationSeconds, "\(name) is too long")
        }
    }

    @Test func editorLimitsAreEnforcedByBandKit() {
        let buzz = Rhythm.Step.buzz(preset: 2, loops: 1)
        #expect(RhythmSpec.isValid([buzz]))
        #expect(!RhythmSpec.isValid([]))
        #expect(RhythmSpec.isValid(Array(repeating: buzz, count: 10)))
        #expect(!RhythmSpec.isValid(Array(repeating: buzz, count: 11)))
        // Thirty one-second loops fit exactly; one more loop is over 30 s.
        #expect(RhythmSpec.isValid([.buzz(preset: 2, loops: 30)]))
        #expect(!RhythmSpec.isValid([.buzz(preset: 2, loops: 31)]))
    }

    @Test func stepsExpandBuiltInsAndKeepCustomSteps() throws {
        #expect(RhythmSpec.builtIn(.double).steps == BuiltInRhythm.double.steps)
        let custom = try Rhythm(steps: [.pause(ms: 200)])
        #expect(RhythmSpec.custom(custom).steps == [.pause(ms: 200)])
    }
}
