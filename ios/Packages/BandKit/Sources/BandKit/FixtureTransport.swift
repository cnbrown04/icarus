import Foundation

/// Replays a recorded NDJSON session through HeartRateMeasurementParser.
///
/// Without `band`, the session streams as soon as it starts. With `band`, the band is announced
/// as `.discovered` and then either remembered and streamed (default), or, with `pairingRequired`,
/// streamed only after `pair(_:)` for that band. Each frame yields `.raw` then `.hr`.
/// Gaps between frames are paced by `speed` (2 means twice as fast). Use `speed: .infinity`
/// to replay without pauses. Timestamps are the recorded ones, not wall time.
///
/// Used only by UI tests and screenshots (PLAN.md §16.3).
public actor FixtureTransport: BandTransport {
    public nonisolated let events: AsyncStream<BandEvent>
    public nonisolated let skippedLineCount: Int

    private let continuation: AsyncStream<BandEvent>.Continuation
    private let frames: [NDJSONFixture.Frame]
    private let speed: Double
    private let clock: any ReplayClock
    private let band: DiscoveredBand?
    private let pairingRequired: Bool
    private var started = false
    private var replayTask: Task<Void, Never>?

    public init(
        ndjson: String,
        speed: Double = 1,
        clock: any ReplayClock = RealtimeClock(),
        band: DiscoveredBand? = nil,
        pairingRequired: Bool = false
    ) {
        precondition(speed > 0, "FixtureTransport speed must be positive")
        let parsed = NDJSONFixture.parse(ndjson)
        let (stream, continuation) = AsyncStream<BandEvent>.makeStream()
        self.events = stream
        self.continuation = continuation
        self.frames = parsed.frames
        self.skippedLineCount = parsed.skippedLineCount
        self.speed = speed
        self.clock = clock
        self.band = band
        self.pairingRequired = pairingRequired
    }

    public func start() {
        guard !started else { return }
        started = true
        guard let band else {
            beginReplay()
            return
        }
        continuation.yield(.discovered(band))
        if pairingRequired {
            continuation.yield(.state(.scanning))
        } else {
            continuation.yield(.remembered(band.id))
            beginReplay()
        }
    }

    public func pair(_ id: UUID) async {
        guard started, pairingRequired, replayTask == nil, let band, band.id == id else { return }
        continuation.yield(.remembered(id))
        beginReplay()
    }

    /// Nothing to forget: the fixture band is never persisted.
    public func forget() async {}

    public func stop() {
        replayTask?.cancel()
        replayTask = nil
        continuation.finish()
    }

    private func beginReplay() {
        replayTask = Task { await self.replay() }
    }

    private func replay() async {
        continuation.yield(.state(.streaming))
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
            let receivedAt = Date(timeIntervalSince1970: frame.timestamp)
            continuation.yield(.raw(char: NDJSONFixture.heartRateCharacteristic, bytes: frame.bytes, at: receivedAt))
            continuation.yield(.hr(frame.measurement, receivedAt: receivedAt))
        }
        continuation.finish()
    }
}
