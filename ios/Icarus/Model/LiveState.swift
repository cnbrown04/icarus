import BandKit
import Foundation
import Observation

/// Live band data for Today, Device, Pair band and Debug. Consumes a BandTransport on the main actor.
@MainActor
@Observable
final class LiveState {
    struct Sample: Identifiable, Equatable {
        let date: Date
        let bpm: Int

        var id: Date { date }
    }

    static let sparklineWindow: TimeInterval = 15 * 60

    /// The band that UI tests see. It exists only under -IcarusUITest.
    static let fixtureBand = DiscoveredBand(
        id: UUID(uuidString: "6C1F3A10-2B7D-4E0A-9C11-0000000000B1")!,
        name: "Fixture band",
        rssi: -48
    )

    private(set) var state: ConnectionState = .idle
    private(set) var latestBPM: Int?
    private(set) var lastDataAt: Date?
    private(set) var samples: [Sample] = []
    /// Bands seen while scanning, plus the connected band, in the order first seen.
    private(set) var bands: [DiscoveredBand] = []
    private(set) var rememberedID: UUID?
    private(set) var frameLog = FrameLog()
    let sourceName: String
    let clock: AppClock

    private let transport: any BandTransport
    private var consumeTask: Task<Void, Never>?

    init(transport: any BandTransport, sourceName: String, clock: AppClock) {
        self.transport = transport
        self.sourceName = sourceName
        self.clock = clock
    }

    /// Transport selection (PLAN.md §7.2, §16.3):
    /// - UI tests replay the bundled fixture with no pauses. Pair band uses a fixture scan.
    /// - `-IcarusSynthetic 1` (DEBUG) forces the synthetic generator.
    /// - Everything else uses the real radio.
    static func makeForLaunch(_ config: LaunchConfig) -> LiveState {
        let clock = AppClock(fixedNow: config.fixedNow)
        if config.isUITest {
            let name = config.fixtureName ?? "resting_day"
            if let url = Bundle.main.url(forResource: name, withExtension: "ndjson"),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                let transport = FixtureTransport(
                    ndjson: text,
                    speed: .infinity,
                    band: fixtureBand,
                    pairingRequired: config.startScreen == .pairBand
                )
                return LiveState(transport: transport, sourceName: "Fixture \(name)", clock: clock)
            }
        }
        if config.isUITest || config.isSynthetic {
            return LiveState(transport: SyntheticTransport(seed: 1), sourceName: "Synthetic", clock: clock)
        }
        return LiveState(
            transport: CoreBluetoothTransport(store: UserDefaultsBandIdentityStore()),
            sourceName: "Bluetooth",
            clock: clock
        )
    }

    var now: Date { clock.now }

    var isStreaming: Bool { state == .streaming }

    var connectionText: String {
        switch state {
        case .idle: "Not connected"
        case .scanning: "Scanning"
        case .connecting, .discovering, .subscribing: "Connecting"
        case .streaming: "Connected"
        case .backoff: "Reconnecting"
        }
    }

    /// The remembered band's name, when it has been seen in this session or a previous one.
    var bandName: String? {
        guard let rememberedID else { return nil }
        return bands.first { $0.id == rememberedID }?.name
    }

    var isCollectionPaused: Bool {
        DataAge.isPaused(since: lastDataAt, now: clock.now)
    }

    func start() {
        guard consumeTask == nil else { return }
        consumeTask = Task {
            await self.transport.start()
            for await event in self.transport.events {
                self.apply(event)
            }
        }
    }

    func pair(_ id: UUID) {
        let transport = transport
        Task { await transport.pair(id) }
    }

    func forgetBand() {
        let transport = transport
        Task { await transport.forget() }
    }

    private func apply(_ event: BandEvent) {
        switch event {
        case let .state(newState):
            state = newState
        case let .discovered(band):
            upsert(band)
        case let .remembered(id):
            rememberedID = id
        case let .raw(char, bytes, at):
            frameLog.append(characteristic: char, bytes: bytes, at: at)
        case let .hr(measurement, receivedAt):
            latestBPM = measurement.bpm
            lastDataAt = receivedAt
            samples.append(Sample(date: receivedAt, bpm: measurement.bpm))
            trimSamples()
        case .battery:
            break
        }
    }

    private func upsert(_ band: DiscoveredBand) {
        if let index = bands.firstIndex(where: { $0.id == band.id }) {
            bands[index] = band
        } else {
            bands.append(band)
        }
    }

    private func trimSamples() {
        let cutoff = clock.now.addingTimeInterval(-Self.sparklineWindow)
        let staleCount = samples.prefix(while: { $0.date < cutoff }).count
        if staleCount > 0 {
            samples.removeFirst(staleCount)
        }
    }
}
