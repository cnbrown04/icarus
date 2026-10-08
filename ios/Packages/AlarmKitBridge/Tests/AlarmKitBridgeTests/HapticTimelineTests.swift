import BandKit
import Testing
@testable import AlarmKitBridge

struct HapticTimelineTests {
    @Test func eachBuzzLoopIsOneSegmentAndPausesAddGaps() throws {
        // Two loops, a 300 ms pause, then one loop: starts at 0, 1 and 2.3 s.
        let rhythm = try Rhythm(steps: [.buzz(preset: 2, loops: 2), .pause(ms: 300), .buzz(preset: 2, loops: 1)])
        let segments = HapticTimeline.segments(for: rhythm)
        #expect(segments.count == 3)
        let starts = segments.map(\.start)
        let durations = segments.map(\.duration)
        #expect(zip(starts, [0, 1, 2.3]).allSatisfy { abs($0 - $1) < 1e-9 })
        #expect(durations.allSatisfy { $0 == Rhythm.secondsPerBuzzLoop })
    }

    @Test func timelineEndsWhereTheRhythmDurationEnds() throws {
        let rhythm = try Rhythm(steps: [.buzz(preset: 2, loops: 2), .pause(ms: 300), .buzz(preset: 2, loops: 1)])
        let last = try #require(HapticTimeline.segments(for: rhythm).last)
        #expect(abs(last.start + last.duration - rhythm.durationSeconds) < 1e-9)
    }

    @Test func pausesOnlyProduceNoVibration() throws {
        let rhythm = try Rhythm(steps: [.pause(ms: 500)])
        #expect(HapticTimeline.segments(for: rhythm).isEmpty)
    }
}
