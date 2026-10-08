import Foundation

/// Replays a recorded NDJSON session through HeartRateMeasurementParser.
///
/// Emits `.connected`, then one `.hr` per recorded frame in file order, then finishes the stream.
/// Gaps between frames are paced by `speed` (2 means twice as fast). Use `speed: .infinity`
/// to replay without pauses. The `receivedAt` value is the recorded timestamp, not wall time.
public actor FixtureTransport: BandTransport {
    public nonisolated let events: AsyncStream<BandEvent>
    public nonisolated let skippedLineCount: Int

    private let continuation: AsyncStream<BandEvent>.Continuation
    private let frames: [NDJSONFixture.Frame]
    private let speed: Double
    private let clock: any ReplayClock
    private var replayTask: Task<Void, Never>?

    public init(ndjson: String, speed: Double = 1, clock: any ReplayClock = RealtimeClock()) {
        precondition(speed > 0, "FixtureTransport speed must be positive")
        let parsed = NDJSONFixture.parse(ndjson)
        let (stream, continuation) = AsyncStream<BandEvent>.makeStream()
        self.events = stream
        self.continuation = continuation
        self.frames = parsed.frames
        self.skippedLineCount = parsed.skippedLineCount
        self.speed = speed
        self.clock = clock
    }

    public func start() {
        guard replayTask == nil else { return }
        replayTask = Task { await self.replay() }
    }

    public func stop() {
        replayTask?.cancel()
        replayTask = nil
        continuation.finish()
    }

    private func replay() async {
        continuation.yield(.connected)
        var previous: Double?
        for frame in frames {
            if let previous {
                let gap = (frame.timestamp - previous) / speed
                if gap > 0 {
                    do {
                        try await clock.sleep(seconds: gap)
                    } catch {
                        break
                    }
                }
            }
            guard !Task.isCancelled else { break }
            previous = frame.timestamp
            continuation.yield(.hr(frame.measurement, receivedAt: Date(timeIntervalSince1970: frame.timestamp)))
        }
        continuation.finish()
    }
}
