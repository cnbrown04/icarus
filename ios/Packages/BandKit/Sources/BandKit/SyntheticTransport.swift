import BandProtocol
import Foundation

/// SplitMix64: small and seedable, with no Foundation randomness, so output is reproducible.
struct SplitMix64: Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }
}

/// Produces plausible resting heart rate (55 to 70 bpm) as real 0x2A37 payloads, then parses them,
/// so the parser is exercised on every sample.
public struct SyntheticHeartRateSource: Sendable {
    private var random: SplitMix64
    private var bpm = 62

    public init(seed: UInt64) {
        random = SplitMix64(seed: seed)
    }

    /// Flags 0x16: UINT8 heart rate, sensor contact detected, R-R interval present.
    public mutating func nextPayload() -> [UInt8] {
        bpm = min(70, max(55, bpm + random.nextInt(in: -1 ... 1)))
        let rrMs = 60_000.0 / Double(bpm) + Double(random.nextInt(in: -20 ... 20))
        let rrRaw = min(Int((rrMs * 1024 / 1000).rounded()), Int(UInt16.max))
        return [0x16, UInt8(bpm), UInt8(rrRaw & 0xFF), UInt8(rrRaw >> 8)]
    }

    public mutating func nextMeasurement() throws -> HeartRateMeasurement {
        try HeartRateMeasurementParser.parse(nextPayload())
    }
}

/// Emits `.state(.streaming)`, then one raw notification and one heart-rate event every `interval`
/// seconds, until `maxSamples` or `stop()`. Used for demos, previews and `-IcarusSynthetic 1`.
public actor SyntheticTransport: BandTransport {
    public nonisolated let events: AsyncStream<BandEvent>

    private let continuation: AsyncStream<BandEvent>.Continuation
    private var source: SyntheticHeartRateSource
    private let interval: Double
    private let maxSamples: Int?
    private let clock: any ReplayClock
    private var task: Task<Void, Never>?

    public init(
        seed: UInt64,
        interval: Double = 1,
        maxSamples: Int? = nil,
        clock: any ReplayClock = RealtimeClock()
    ) {
        let (stream, continuation) = AsyncStream<BandEvent>.makeStream()
        self.events = stream
        self.continuation = continuation
        self.source = SyntheticHeartRateSource(seed: seed)
        self.interval = interval
        self.maxSamples = maxSamples
        self.clock = clock
    }

    public func start() {
        guard task == nil else { return }
        task = Task { await self.run() }
    }

    /// The synthetic band has no scan list, so there is nothing to pair with.
    public func pair(_ id: UUID) async {}

    public func forget() async {}

    public func stop() {
        task?.cancel()
        task = nil
        continuation.finish()
    }

    private func run() async {
        continuation.yield(.state(.streaming))
        for index in 0 ..< (maxSamples ?? Int.max) {
            if index > 0 {
                do {
                    try await clock.sleep(seconds: interval)
                } catch {
                    break
                }
            }
            guard !Task.isCancelled else { break }
            let payload = source.nextPayload()
            guard let measurement = try? HeartRateMeasurementParser.parse(payload) else { break }
            let receivedAt = Date()
            continuation.yield(.raw(char: NDJSONFixture.heartRateCharacteristic, bytes: payload, at: receivedAt))
            continuation.yield(.hr(measurement, receivedAt: receivedAt))
        }
        continuation.finish()
    }
}
