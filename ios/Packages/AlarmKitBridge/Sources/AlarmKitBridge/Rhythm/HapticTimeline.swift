import BandKit

/// One phone vibration on a rhythm's timeline, in seconds from the start (PLAN.md 9.2).
public struct HapticSegment: Equatable, Sendable {
    public let start: Double
    public let duration: Double
}

/// Turns a rhythm into timed vibrations. Pure, so the timing is tested on Linux. `RhythmHapticPlayer` builds the
/// Core Haptics pattern from these segments.
public enum HapticTimeline {
    /// Each buzz loop becomes one vibration of `Rhythm.secondsPerBuzzLoop`, the same length BandKit assumes. Pauses add
    /// silence and no segment.
    public static func segments(for rhythm: Rhythm) -> [HapticSegment] {
        var cursor = 0.0
        var segments: [HapticSegment] = []
        for step in rhythm.steps {
            switch step {
            case let .buzz(_, loops):
                for _ in 0..<Int(loops) {
                    segments.append(HapticSegment(start: cursor, duration: Rhythm.secondsPerBuzzLoop))
                    cursor += Rhythm.secondsPerBuzzLoop
                }
            case let .pause(ms):
                cursor += Double(ms) / 1000
            }
        }
        return segments
    }
}
