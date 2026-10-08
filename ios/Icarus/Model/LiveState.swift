import BandKit
import BandProtocol
import Foundation
import Metrics
import Observation

/// Live band data for Today, Device, Pair band and Debug (PLAN.md 7.3). Consumes a BandTransport on the
/// main actor. Charts read history from the store, not from here.
@MainActor
@Observable
final class LiveState {
    /// The band that UI tests see. It exists only under -IcarusUITest.
    static let fixtureBand = DiscoveredBand(
        id: UUID(uuidString: "6C1F3A10-2B7D-4E0A-9C11-0000000000B1")!,
        name: "Fixture band",
        rssi: -48
    )

    private(set) var state: ConnectionState = .idle
    private(set) var latestBPM: Int?
    private(set) var batteryPercent: Int?
    private(set) var tierBState: TierBState = .disabled
    private(set) var lastDataAt: Date?
    /// Bands seen while scanning, plus the connected band, in the order first seen.
    private(set) var bands: [DiscoveredBand] = []
    private(set) var rememberedID: UUID?
    private(set) var frameLog = FrameLog()
    let sourceName: String
    let clock: AppClock

    private let transport: any BandTransport
    private let ingest: AsyncStream<Ingestor.Input>.Continuation?
    private var consumeTask: Task<Void, Never>?

    init(
        transport: any BandTransport,
        sourceName: String,
        clock: AppClock,
        ingest: AsyncStream<Ingestor.Input>.Continuation?
    ) {
        self.transport = transport
        self.sourceName = sourceName
        self.clock = clock
        self.ingest = ingest
    }

    /// Transport selection (PLAN.md §7.2, §16.3):
    /// - UI tests replay the bundled fixture with no pauses. Pair band uses a fixture scan.
    /// - `-IcarusSynthetic 1` (DEBUG) forces the synthetic generator.
    /// - Everything else uses the real radio.
    static func makeForLaunch(_ config: LaunchConfig, ingest: AsyncStream<Ingestor.Input>.Continuation?) -> LiveState {
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
                return LiveState(transport: transport, sourceName: "Fixture \(name)", clock: clock, ingest: ingest)
            }
        }
        if config.isUITest || config.isSynthetic {
            return LiveState(transport: SyntheticTransport(seed: 1), sourceName: "Synthetic", clock: clock, ingest: ingest)
        }
        return LiveState(
            transport: CoreBluetoothTransport(store: UserDefaultsBandIdentityStore()),
            sourceName: "Bluetooth",
            clock: clock,
            ingest: ingest
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

    /// The band readings are attributed to: the remembered one, else the first band seen.
    private var activeBandID: UUID? {
        rememberedID ?? bands.first?.id
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
            if newState != state {
                // Leaving streaming (disconnect, backoff) is a flush point (PLAN.md 7.2).
                ingest?.yield(.flush)
            }
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
            if let bandID = activeBandID {
                ingest?.yield(.reading(Ingestor.Reading(
                    bandID: bandID,
                    tsMs: Int64((receivedAt.timeIntervalSince1970 * 1000).rounded(.down)),
                    bpm: measurement.bpm,
                    contact: Self.contact(measurement.sensorContact),
                    rrMs: measurement.rrIntervalsMs
                )))
            }
        case let .battery(percent):
            batteryPercent = percent
        case let .tierB(newState):
            tierBState = newState
        case .bandEvent:
            // Wrist and double-tap events are shown by the Phase 6 band screens.
            break
        }
    }

    private static func contact(_ contact: BandProtocol.SensorContact) -> Metrics.SensorContact? {
        switch contact {
        case .detected: .detected
        case .notDetected: .notDetected
        case .notSupported: nil
        }
    }

    private func upsert(_ band: DiscoveredBand) {
        if let index = bands.firstIndex(where: { $0.id == band.id }) {
            bands[index] = band
        } else {
            bands.append(band)
        }
    }
}
