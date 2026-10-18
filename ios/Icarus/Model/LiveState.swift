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
    /// The last EVENT from the band, such as wrist on or a double tap, and when it arrived here (PLAN.md 5.3.4).
    private(set) var lastBandEvent: BandEventKind?
    private(set) var lastBandEventAt: Date?
    /// Set by `AlarmCoordinator`. Called on the main actor when Tier B changes, or when a band event arrives.
    @ObservationIgnored var onTierBChange: (@MainActor (TierBState) -> Void)?
    @ObservationIgnored var onBandEvent: (@MainActor (BandEventKind) -> Void)?
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
            transport: CoreBluetoothTransport(
                store: UserDefaultsBandIdentityStore(),
                tierBEnabled: BandChannel.isEnabled
            ),
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

    /// Signal strength of the remembered band, once it has been seen in a scan.
    var connectedRSSI: Int? {
        guard let rememberedID else { return nil }
        return bands.first { $0.id == rememberedID }?.rssi
    }

    /// SF Symbol for the link state.
    var connectionSymbol: String {
        switch state {
        case .streaming: "checkmark.circle.fill"
        case .idle: "circle"
        case .backoff: "arrow.clockwise"
        case .scanning, .connecting, .discovering, .subscribing: "arrow.triangle.2.circlepath"
        }
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

    // MARK: Band channel (PLAN.md 7.2, 9.2, 9.5). Each call does nothing unless Tier B is on and ready.

    /// Turns the Experimental band channel on or off. Off stops all custom-service traffic (BandKit guarantees it).
    func setTierBEnabled(_ enabled: Bool) async {
        await transport.setTierBEnabled(enabled)
    }

    func runRhythm(_ rhythm: Rhythm) async {
        await transport.runRhythm(rhythm)
    }

    func stopHaptics() async {
        await transport.stopHaptics()
    }

    /// Arms the band alarm for the next due occurrence, in UTC. Nil sends nothing (PLAN.md 5.3.4).
    func armBandAlarm(_ at: Date?) async {
        await transport.armBandAlarm(at: at)
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
            onTierBChange?(newState)
        case let .bandEvent(kind):
            lastBandEvent = kind
            lastBandEventAt = clock.now
            onBandEvent?(kind)
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
