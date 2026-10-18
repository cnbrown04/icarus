#if canImport(CoreHaptics)
import BandKit
import CoreHaptics

/// Plays a rhythm on the phone with Core Haptics (PLAN.md 9.2). Foreground only: Core Haptics stops when the app
/// leaves the foreground, so the background path buzzes the band instead.
@MainActor
public final class RhythmHapticPlayer {
    private var engine: CHHapticEngine?

    public init() {}

    public static var supportsHaptics: Bool {
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    public func play(_ rhythm: Rhythm) throws {
        let segments = HapticTimeline.segments(for: rhythm)
        guard Self.supportsHaptics, !segments.isEmpty else { return }
        let engine = try self.engine ?? CHHapticEngine()
        self.engine = engine
        // Starting again is cheap, and needed after the engine stopped when the app went to the background.
        try engine.start()
        let player = try engine.makePlayer(with: Self.pattern(for: segments))
        try player.start(atTime: 0)
    }

    public func stop() {
        engine?.stop(completionHandler: nil)
    }

    /// One continuous event per segment, at fixed intensity and sharpness.
    static func pattern(for segments: [HapticSegment]) throws -> CHHapticPattern {
        let events = segments.map { segment in
            CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
                ],
                relativeTime: segment.start,
                duration: segment.duration
            )
        }
        return try CHHapticPattern(events: events, parameters: [])
    }
}
#endif
