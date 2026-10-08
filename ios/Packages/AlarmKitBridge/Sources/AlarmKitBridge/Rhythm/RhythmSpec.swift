import BandKit
import Foundation

/// The six built-in rhythms (PLAN.md 9.2). Their steps are defined here, not by the band. Only preset 2 is documented
/// (PLAN.md 9.2 [Unverified] for other ids), so every built-in uses preset 2 with different loops and pauses.
public enum BuiltInRhythm: String, CaseIterable, Sendable {
    case single, double, triple, long, ramp, sos

    public var steps: [Rhythm.Step] {
        let buzz = Rhythm.Step.buzz(preset: 2, loops: 1)
        switch self {
        case .single: return [buzz]
        case .double: return [buzz, .pause(ms: 300), buzz]
        case .triple: return [buzz, .pause(ms: 300), buzz, .pause(ms: 300), buzz]
        case .long: return [.buzz(preset: 2, loops: 3)]
        case .ramp: return [buzz, .pause(ms: 500), .buzz(preset: 2, loops: 2), .pause(ms: 500), .buzz(preset: 2, loops: 3)]
        case .sos:
            return [
                buzz, .pause(ms: 200), buzz, .pause(ms: 200), buzz, .pause(ms: 500),
                .buzz(preset: 2, loops: 2), .pause(ms: 200), .buzz(preset: 2, loops: 2),
            ]
        }
    }
}

/// What an alarm plays: a built-in name or custom steps. Wire form (api-contract.md, Alarms): `"double"`, or
/// `[{"type":"buzz","preset":2,"loops":1},{"type":"pause","ms":300}]`.
public enum RhythmSpec: Equatable, Sendable {
    case builtIn(BuiltInRhythm)
    case custom(Rhythm)

    /// The steps either case plays. A built-in name expands to its steps.
    public var steps: [Rhythm.Step] {
        switch self {
        case let .builtIn(name): name.steps
        case let .custom(rhythm): rhythm.steps
        }
    }

    /// Whether `steps` make a rhythm BandKit accepts: 1 to 10 steps, 30 s at most (PLAN.md 9.2). The editor checks
    /// every change with this, so it never builds an invalid rhythm.
    public static func isValid(_ steps: [Rhythm.Step]) -> Bool {
        (try? Rhythm(steps: steps)) != nil
    }

    /// The validated rhythm, for BandKit and the phone player. Throws only for a custom rhythm BandKit rejects.
    public func rhythm() throws -> Rhythm {
        switch self {
        case let .builtIn(name): try Rhythm(steps: name.steps)
        case let .custom(rhythm): rhythm
        }
    }

    public enum WireError: Error, Equatable, Sendable {
        case unknownName(String)
        /// The step at this index has an unknown type or an out-of-range value.
        case badStep(index: Int)
    }

    public init(jsonText: String) throws {
        let wire = try JSONDecoder().decode(Wire.self, from: Data(jsonText.utf8))
        switch wire {
        case let .name(name):
            guard let builtIn = BuiltInRhythm(rawValue: name) else { throw WireError.unknownName(name) }
            self = .builtIn(builtIn)
        case let .steps(steps):
            var decoded: [Rhythm.Step] = []
            for (index, step) in steps.enumerated() {
                decoded.append(try Self.step(step, index: index))
            }
            self = .custom(try Rhythm(steps: decoded))
        }
    }

    public func jsonText() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        switch self {
        case let .builtIn(name):
            data = try encoder.encode(name.rawValue)
        case let .custom(rhythm):
            data = try encoder.encode(rhythm.steps.map(WireStep.init))
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func step(_ wire: WireStep, index: Int) throws -> Rhythm.Step {
        switch wire.type {
        case "buzz":
            guard let preset = wire.preset, (0...255).contains(preset),
                  let loops = wire.loops, (1...255).contains(loops)
            else { throw WireError.badStep(index: index) }
            return .buzz(preset: UInt8(preset), loops: UInt8(loops))
        case "pause":
            guard let ms = wire.ms, ms >= 0 else { throw WireError.badStep(index: index) }
            return .pause(ms: ms)
        default:
            throw WireError.badStep(index: index)
        }
    }

    /// Either shape of the wire value. Decoded first as a name, then as steps.
    private enum Wire: Decodable {
        case name(String)
        case steps([WireStep])

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let name = try? container.decode(String.self) {
                self = .name(name)
            } else {
                self = .steps(try container.decode([WireStep].self))
            }
        }
    }

    private struct WireStep: Codable {
        var type: String
        var preset: Int?
        var loops: Int?
        var ms: Int?

        init(_ step: Rhythm.Step) {
            switch step {
            case let .buzz(preset, loops):
                type = "buzz"
                self.preset = Int(preset)
                self.loops = Int(loops)
                ms = nil
            case let .pause(ms):
                type = "pause"
                preset = nil
                loops = nil
                self.ms = ms
            }
        }
    }
}
