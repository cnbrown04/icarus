import BandKit
import BandProtocol
import Foundation
import Metrics
import Observation

/// The Device screen's view of the strap's history offload, fed by `.drainProgress` events.
/// Observable through `LiveState`, so a drain start, every acked batch and its end update the UI
/// without polling.
struct DrainProgressState: Equatable {
    var isDraining = false
    /// Records kept by the current (or, when idle, the last) drain.
    var recordsThisDrain = 0
    /// Records kept across every drain since the link opened.
    var totalThisSession = 0
    /// The strap's reported ring backlog, when a GET_DATA_RANGE reply has been decoded.
    var pagesBehind: Int?
    /// A full sync's share done (0...1), for the determinate progress bar. Nil for routine drains.
    var fraction: Double?
    /// Why the last drain stopped abnormally, in words. Nil after a clean catch-up/completion.
    var lastStopReasonText: String?
    /// When the last drain ended.
    var lastEndedAt: Date?
}

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
    /// The last Tier B failure reason from the transport. The Device screen shows it while the
    /// state is `.unavailable` (PLAN.md 7.2 debugging).
    private(set) var tierBFailure: String?
    /// The last EVENT from the band, such as wrist on or a double tap, and when it arrived here (PLAN.md 5.3.4).
    private(set) var lastBandEvent: BandEventKind?
    private(set) var lastBandEventAt: Date?
    /// Best-effort identity strings decoded from the last GET_HELLO reply (PLAN.md 5.3.4).
    private(set) var bandInfo: BandInfo?
    /// Charging state from the strap's charging events (7 on, 8 off). Nil until one arrives this launch.
    private(set) var isCharging: Bool?
    /// When the LINK_VALID keep-alive was last confirmed on the current link, and how many have failed in a row
    /// (whoop-parity §3.8). The time is nil before the first success on a connection.
    private(set) var linkKeepAliveAt: Date?
    private(set) var linkKeepAliveFailures = 0
    /// The strap's console (type 50) lines, bounded to `BandConsoleLog.capacity` (whoop-parity §3.5).
    private(set) var consoleLog = BandConsoleLog()
    /// EVENT ids the parser does not name, counted since launch (whoop-parity §3.11).
    private(set) var unknownEvents = UnknownEventTally()
    /// Live history-offload progress, for the Device screen's History section and any other view
    /// that wants to show a band sync without polling.
    private(set) var drainProgress = DrainProgressState()
    /// Handlers set by `AlarmCoordinator` (re-arm band alarms) and `AppEnvironment`
    /// (auto-restore). Assignment APPENDS instead of replacing, so both observers fire: the
    /// second assignment used to silently disable the first.
    var onTierBChange: (@MainActor (TierBState) -> Void)? {
        get { nil }
        set {
            guard let newValue else {
                tierBChangeHandlers.removeAll()
                return
            }
            tierBChangeHandlers.append(newValue)
        }
    }
    @ObservationIgnored private var tierBChangeHandlers: [@MainActor (TierBState) -> Void] = []
    @ObservationIgnored var onBandEvent: (@MainActor (BandEventKind) -> Void)?
    /// Called on the main actor with every EVENT frame, payload included, so it can be stored
    /// (`AppEnvironment.connectBandEvents`).
    @ObservationIgnored var onBandEventRecord: (@MainActor (BandEventRecord) -> Void)?
    /// Called on the main actor for each drained batch. The records are NOT stored here: with a
    /// sink installed (`installHistoricalSink`) they were already written before the strap was
    /// acked; otherwise the consumer owns their persistence (PLAN.md 5.3.4).
    @ObservationIgnored var onHistoricalRecords: (@MainActor ([HistoricalRecord]) -> Void)?
    /// Set by `AlarmCoordinator` for the opportunistic alarm pull (PLAN.md 9.3). Called on the main
    /// actor at every band wake-up: the link entering streaming, and every realtime heart-rate
    /// notification. The consumer throttles itself.
    @ObservationIgnored var onLinkAlive: (@MainActor () -> Void)?
    /// The last record of the most recent history drain, for the raw-data viewer. Not persisted.
    private(set) var lastHistoricalRecord: HistoricalRecord?
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
                tierBEnabled: BandChannel.isEnabled,
                handshakeDisablesRealtimeRawFlood: BandChannel.floodDisabled
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

    /// One line for the History section, counting the current (or last) drain's records so the running line and
    /// the finished line agree: "1,204 records so far" while a drain runs, then "Synced 1,204 records" (plus an
    /// abnormal stop reason). The backlog itself shows as the row's progress bar, not as text. Empty before the
    /// first drain of the launch.
    var drainProgressText: String {
        let count = drainProgress.recordsThisDrain
        let records = "\(count.formatted()) record\(count == 1 ? "" : "s")"
        if drainProgress.isDraining {
            return "\(records) so far"
        }
        guard drainProgress.lastEndedAt != nil else { return "" }
        var text = "Synced \(records)"
        if let reason = drainProgress.lastStopReasonText {
            text += " · \(reason)"
        }
        return text
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

    /// Turns the REALTIME_RAW_DATA (0x2B) flood on or off, for the raw-data viewer. The viewer
    /// enables it while open and disables it on disappear, so the flood never runs unseen. A
    /// transport without flood control (fixture, synthetic, or a BandKit without the Tier B call
    /// yet) logs and does nothing.
    func setRealtimeRawFlood(_ enabled: Bool) async {
        guard let flood = transport as? any RealtimeRawFloodTransport else {
            BandLog.tierB(.info, "app: raw flood \(enabled ? "on" : "off") skipped: transport has no flood control")
            return
        }
        do {
            try await flood.setRealtimeRawFlood(enabled: enabled)
            BandLog.tierB(.info, "app: raw flood \(enabled ? "on" : "off")")
        } catch {
            BandLog.tierB(.error, "app: raw flood \(enabled ? "on" : "off") failed: \(String(describing: error))")
        }
    }

    /// Turns the optical stream on or off (Band Tests SpO2 steps). True when the band accepted the commands.
    @discardableResult
    func setOpticalStream(_ enabled: Bool) async -> Bool {
        guard let flood = transport as? any RealtimeRawFloodTransport else {
            BandLog.tierB(.info, "app: optical stream skipped: transport has no stream control")
            return false
        }
        do {
            try await flood.setOpticalStream(enabled: enabled)
            return true
        } catch {
            BandLog.tierB(.error, "app: optical stream \(enabled ? "on" : "off") failed: \(String(describing: error))")
            return false
        }
    }

    /// Hands every decoded frame the controller only surfaces (the realtime-raw stream, R21 optical records
    /// included) to Band Tests while one of its optical steps runs. Nil otherwise, so the stream costs nothing.
    @ObservationIgnored var rawFrameSink: ((Frame, Date) -> Void)?

    /// Sets whether future handshakes disable the raw flood, applying the change to the current
    /// link immediately (lifting the policy re-enables the stream now; imposing it disables now).
    func setHandshakeRealtimeRawFloodDisabled(_ disabled: Bool) async {
        guard let flood = transport as? any RealtimeRawFloodTransport else {
            BandLog.tierB(.info, "app: flood policy skipped: transport has no flood control")
            return
        }
        do {
            try await flood.setHandshakeRealtimeRawFloodDisabled(disabled)
            BandLog.tierB(.info, "app: flood policy \(disabled ? "off (handshake will disable)" : "on (flood left running)")")
        } catch {
            BandLog.tierB(.error, "app: flood policy \(disabled) failed: \(String(describing: error))")
        }
    }

    /// Installs the store each drained batch is written to before the strap is acked. Returns
    /// false when the transport has no history sink (fixture, synthetic): its batches still arrive
    /// through `onHistoricalRecords` only.
    func installHistoricalSink(_ sink: @escaping HistoricalSink) -> Bool {
        guard let sinkTransport = transport as? any HistoricalSinkTransport else { return false }
        Task { await sinkTransport.setHistoricalSink(sink) }
        return true
    }

    /// Syncs everything the strap has recorded but not yet sent to the app. A transport without the
    /// capability (fixture, synthetic) logs and does nothing.
    /// Catches up with the band when the app opens: asks how far behind it is and drains until caught up
    /// (`drainFullHistory`), at most once a minute. With nothing pending this is one quick command.
    func catchUpOnOpen() async {
        guard tierBState == .ready else { return }
        let now = clock.now
        if let last = lastOpenCatchUp, now.timeIntervalSince(last) < 60 { return }
        lastOpenCatchUp = now
        await drainFullHistory()
    }

    @ObservationIgnored private var lastOpenCatchUp: Date?

    func drainFullHistory() async {
        guard let drain = transport as? any FullHistoryDrainTransport else {
            BandLog.tierB(.info, "app: full-history sync skipped: transport has no drain control")
            return
        }
        await drain.drainFullHistory()
    }

    /// The one-line state of the last (or running) full-history restore, for the Band screen.
    func fullHistorySummary() async -> String? {
        guard let drain = transport as? any FullHistoryDrainTransport else { return nil }
        return await drain.fullHistorySummary()
    }

    private func apply(_ event: BandEvent) {
        switch event {
        case let .state(newState):
            let wasStreaming = state == .streaming
            if newState != state {
                // Leaving streaming (disconnect, backoff) is a flush point (PLAN.md 7.2).
                ingest?.yield(.flush)
            }
            state = newState
            if newState == .streaming, !wasStreaming {
                onLinkAlive?()
            }
        case let .discovered(band):
            upsert(band)
        case let .remembered(id):
            rememberedID = id
        case let .raw(char, bytes, at):
            frameLog.append(characteristic: char, bytes: bytes, at: at)
        case let .rawFrame(frame, at):
            // Decoded frames the controller only surfaces, the 0x2B flood included. The ring is
            // tiny and nothing formats hex here, so the flood stays cheap (PLAN.md 7.2 debugging).
            frameLog.append(frame: frame, at: at)
            rawFrameSink?(frame, at)
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
            onLinkAlive?()
        case let .battery(percent):
            batteryPercent = percent
        case let .tierB(newState):
            tierBState = newState
            if newState != .unavailable {
                tierBFailure = nil
            }
            for handler in tierBChangeHandlers {
                handler(newState)
            }
        case let .tierBFailure(reason):
            tierBFailure = reason
        case let .bandEvent(event):
            let kind = event.kind
            lastBandEvent = kind
            lastBandEventAt = clock.now
            if case let .unknown(id) = kind {
                unknownEvents.record(id)
            }
            onBandEvent?(kind)
            onBandEventRecord?(event)
        case let .charging(charging):
            isCharging = charging
        case let .linkKeepAlive(sentAt, failures):
            linkKeepAliveAt = sentAt
            linkKeepAliveFailures = failures
        case let .consoleLines(lines, at):
            for line in lines {
                consoleLog.append(line, at: at)
            }
        case let .bandInfo(info):
            bandInfo = info
        case let .historical(records):
            BandLog.tierB(.info, "app: historical records arrived (\(records.count))")
            lastHistoricalRecord = records.last
            onHistoricalRecords?(records)
        case let .drainProgress(progress):
            applyDrainProgress(progress)
        }
    }

    private func applyDrainProgress(_ progress: DrainProgress) {
        drainProgress.isDraining = progress.isDraining
        drainProgress.recordsThisDrain = progress.recordsThisDrain
        drainProgress.totalThisSession = progress.totalThisSession
        drainProgress.pagesBehind = progress.pagesBehind
        drainProgress.fraction = progress.fraction
        if progress.isDraining {
            // A new drain starts: the previous end's reason no longer describes the state.
            drainProgress.lastStopReasonText = nil
        } else if let reason = progress.stopReason {
            drainProgress.lastEndedAt = progress.at
            drainProgress.lastStopReasonText = reason.isAbnormal ? reason.displayText : nil
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
