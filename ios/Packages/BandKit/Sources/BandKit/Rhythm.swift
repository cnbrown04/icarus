import Foundation

/// A custom vibration: an ordered list of steps, stored as JSON on an alarm (PLAN.md 9.2).
///
/// Only built-in presets exist on the band. A step names a preset, and the preset ids beyond
/// `patternId = 2` (NOOP) are not documented, so callers must not assume a mapping. [Unverified]
public struct Rhythm: Sendable, Equatable, Codable {
    public enum Step: Sendable, Equatable, Codable {
        /// Plays built-in preset `preset`, repeated `loops` times.
        case buzz(preset: UInt8, loops: UInt8)
        case pause(ms: Int)

        /// Time the step occupies in the timeline. Buzz length is an assumption (see `Rhythm.secondsPerBuzzLoop`).
        var seconds: Double {
            switch self {
            case let .buzz(_, loops): Double(loops) * Rhythm.secondsPerBuzzLoop
            case let .pause(ms): Double(ms) / 1000
            }
        }
    }

    public enum ValidationError: Error, Sendable, Equatable {
        case empty
        case tooManySteps(Int)
        case invalidLoops
        case negativePause
        case tooLong(seconds: Double)
    }

    /// PLAN.md 9.2: at most 10 steps and 30 s in total.
    public static let maxSteps = 10
    public static let maxDurationSeconds: Double = 30
    /// PLAN.md 9.2 gives no buzz length. One second per loop is assumed for timing. [Unverified]
    /// Measure it on Caleb's band with HAPTICS_FIRED (60) before relying on it.
    public static let secondsPerBuzzLoop: Double = 1

    public let steps: [Step]

    public init(steps: [Step]) throws {
        guard !steps.isEmpty else { throw ValidationError.empty }
        guard steps.count <= Self.maxSteps else { throw ValidationError.tooManySteps(steps.count) }
        for step in steps {
            switch step {
            case let .buzz(_, loops) where loops == 0:
                throw ValidationError.invalidLoops
            case let .pause(ms) where ms < 0:
                throw ValidationError.negativePause
            default:
                break
            }
        }
        let total = steps.reduce(0) { $0 + $1.seconds }
        guard total <= Self.maxDurationSeconds else { throw ValidationError.tooLong(seconds: total) }
        self.steps = steps
    }

    public var durationSeconds: Double {
        steps.reduce(0) { $0 + $1.seconds }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(steps: container.decode([Step].self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(steps)
    }
}
