#if canImport(CoreBluetooth)
import BandProtocol
import CoreBluetooth
import Foundation

/// The real band link. Tier A: scan, connect, subscribe to 0x2A37 (PLAN.md 5.3.6, 7.2).
/// Tier B (opt-in, off by default): also discovers the WHOOP custom service, bonds with a
/// GET_BATTERY_LEVEL write, subscribes to 61080003/4/5, and hands frames to `TierBController`.
///
/// Concurrency: every piece of mutable state is confined to `queue`. CoreBluetooth delivers its
/// delegate callbacks on `queue`, and each public method hops onto `queue` before it reads or
/// writes state. `queue` is the only synchronisation, which is why this is `@unchecked Sendable`
/// rather than an actor. Events leave through `continuation`, which is Sendable.
///
/// Connection rules live in `ConnectionStateMachine`. Tier B command rules live in `TierBController`.
/// This class turns their effects into CoreBluetooth calls and turns CoreBluetooth callbacks into inputs.
public final class CoreBluetoothTransport: NSObject, BandTransport, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    public let events: AsyncStream<BandEvent>

    static let restoreIdentifier = "icarus.central"

    private let continuation: AsyncStream<BandEvent>.Continuation
    private let queue: DispatchQueue
    private let store: any BandIdentityStore
    private let tierB: TierBController
    private let commandWriter: TierBCommandWriter
    private let inboundContinuation: AsyncStream<Frame>.Continuation

    // MARK: Queue-confined state

    private var machine: ConnectionStateMachine
    private var central: CBCentralManager?
    private var wantsRunning = false
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var names: [UUID: String] = [:]
    private var publishedState: ConnectionState = .idle
    private var retryGeneration = 0
    private var tierBEnabled: Bool
    /// Custom-service setup has started on the current link (discovery through unsubscription).
    private var tierBActive = false
    private var tierBSubscriptionsPending = 0
    /// True once the bond write (GET_BATTERY_LEVEL with response) has been ACKed on this link.
    /// The custom channels only answer on a bonded link, so the handshake waits for this.
    private var tierBBonded = false
    /// One reassembler per notify characteristic, because frames may span notifications (PLAN.md 5.3.3).
    private var reassemblers: [String: FrameReassembler] = [:]

    public init(store: any BandIdentityStore, tierBEnabled: Bool = false) {
        let (stream, continuation) = AsyncStream<BandEvent>.makeStream()
        let (frames, frameContinuation) = AsyncStream<Frame>.makeStream()
        let queue = DispatchQueue(label: "icarus.bandkit.central")
        let writer = TierBCommandWriter(queue: queue)
        let controller = TierBController(
            writer: writer,
            clock: SystemTierBClock(),
            enabled: tierBEnabled,
            emit: { continuation.yield($0) }
        )
        let remembered = store.load()
        self.events = stream
        self.continuation = continuation
        self.queue = queue
        self.store = store
        self.tierB = controller
        self.commandWriter = writer
        self.inboundContinuation = frameContinuation
        self.tierBEnabled = tierBEnabled
        self.machine = ConnectionStateMachine(rememberedID: remembered?.id)
        if let remembered, let name = remembered.name {
            self.names = [remembered.id: name]
        }
        super.init()
        // Tell the app the channel state at launch: the controller starts at .awaitingLink when
        // enabled, and nothing emits until the state changes. Without this, after a relaunch with
        // the channel persisted on, the Device toggle says on while the status pill still says Off.
        if tierBEnabled {
            continuation.yield(.tierB(.awaitingLink))
            BandLog.tierB(.info, "tier B enabled at launch; waiting for link")
        }
        Task {
            for await frame in frames {
                await controller.receive(frame)
            }
        }
    }

    // MARK: BandTransport

    public func start() async {
        queue.async {
            BandLog.link(.info, "start: remembered=\(self.machine.rememberedID?.uuidString ?? "nil")")
            self.wantsRunning = true
            self.continuation.yield(.remembered(self.machine.rememberedID))
            if self.central == nil {
                // The restore identifier lets iOS relaunch the app for band events (PLAN.md 7.2).
                self.central = CBCentralManager(
                    delegate: self,
                    queue: self.queue,
                    options: [CBCentralManagerOptionRestoreIdentifierKey: CoreBluetoothTransport.restoreIdentifier]
                )
            }
            self.startIfPowered()
        }
    }

    public func stop() async {
        queue.async {
            self.wantsRunning = false
            self.apply(.stop)
        }
    }

    public func pair(_ id: UUID) async {
        queue.async {
            self.apply(.pairRequested(id))
        }
    }

    public func forget() async {
        queue.async {
            self.apply(.forget)
            if self.wantsRunning {
                self.startIfPowered()
            }
        }
    }

    public func setTierBEnabled(_ enabled: Bool) async {
        queue.async {
            // Off→off is a no-op. On is always processed: re-tapping the switch with the channel
            // already on retries setup after a failed one (the controller only re-arms when it is
            // .unavailable), instead of the switch appearing to do nothing.
            guard enabled != self.tierBEnabled || enabled else { return }
            let changing = enabled != self.tierBEnabled
            self.tierBEnabled = enabled
            BandLog.tierB(.info, "channel \(enabled ? "on" : "off") (link: \(Self.describe(self.machine.state)))")
            let controller = self.tierB
            if enabled {
                Task { await controller.setEnabled(true) }
                // Streaming and no active setup (fresh enable, or retry after a failed one):
                // find the custom service on the live link. Otherwise the next connection does it.
                if self.machine.state == .streaming, !self.tierBActive, let peripheral = self.activePeripheral {
                    self.tierBActive = true
                    BandLog.tierB(.info, "discovering custom service on the live link")
                    peripheral.discoverServices([Self.customService])
                }
            } else {
                guard changing else { return }
                // Unsubscribe first, then stop the controller, so no custom notification is recorded after the toggle is off.
                self.tearDownTierB(unsubscribe: true, linkFailed: false)
                Task { await controller.setEnabled(false) }
            }
        }
    }

    public func runRhythm(_ rhythm: Rhythm) async {
        await tierB.startRhythm(rhythm)
    }

    public func stopHaptics() async {
        await tierB.stopHaptics()
    }

    public func armBandAlarm(at date: Date?) async {
        await tierB.armAlarms(date.map { [$0] } ?? [])
    }

    // MARK: Machine plumbing (queue only)

    private func startIfPowered() {
        guard wantsRunning, let central, central.state == .poweredOn else { return }
        apply(.start)
    }

    private func apply(_ input: ConnectionInput) {
        let before = machine.state
        let effects = machine.handle(input)
        if machine.state != before {
            BandLog.link(.info, "state: \(Self.describe(before)) → \(Self.describe(machine.state)) (\(Self.describe(input)))")
        } else {
            BandLog.link(.debug, "input ignored: \(Self.describe(input)) in \(Self.describe(machine.state))")
        }
        publishStateIfChanged()
        for effect in effects {
            perform(effect)
        }
        // Tier B setup only lives while the link is up. Any other state means the link is gone.
        if tierBActive, ![.discovering, .subscribing, .streaming].contains(machine.state) {
            tearDownTierB(unsubscribe: false, linkFailed: false)
        }
    }

    private func publishStateIfChanged() {
        guard machine.state != publishedState else { return }
        publishedState = machine.state
        continuation.yield(.state(publishedState))
    }

    private func perform(_ effect: ConnectionEffect) {
        switch effect {
        case .startScan:
            guard let central, central.state == .poweredOn else { return }
            BandLog.link(.info, "scanning for bands")
            central.scanForPeripherals(
                withServices: [Self.heartRateService, Self.customService],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        case .stopScan:
            BandLog.link(.debug, "scan stopped")
            central?.stopScan()
        case let .connect(id):
            connect(id)
        case let .cancelConnection(id):
            BandLog.link(.debug, "cancel connection \(id.uuidString)")
            if let peripheral = peripherals[id] {
                central?.cancelPeripheralConnection(peripheral)
            }
        case .discoverServices:
            var services = [Self.heartRateService, Self.batteryService]
            if tierBEnabled {
                services.append(Self.customService)
            }
            BandLog.link(.info, "discovering services \(Self.shortIDs(services)) (tierB=\(tierBEnabled))")
            activePeripheral?.discoverServices(services)
        case .subscribe:
            BandLog.link(.info, "subscribing to heart rate")
            subscribeToHeartRate()
        case let .scheduleRetry(after: delay):
            retryGeneration += 1
            let generation = retryGeneration
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, generation == self.retryGeneration else { return }
                self.apply(.retryTimerFired)
            }
        case .cancelRetry:
            retryGeneration += 1
        case let .rememberPeripheral(id):
            store.save(RememberedBand(id: id, name: names[id]))
            continuation.yield(.remembered(id))
        case .forgetPeripheral:
            store.save(nil)
            continuation.yield(.remembered(nil))
        }
    }

    private var activePeripheral: CBPeripheral? {
        machine.targetID.flatMap { peripherals[$0] }
    }

    private func isTarget(_ peripheral: CBPeripheral) -> Bool {
        peripheral.identifier == machine.targetID
    }

    private func connect(_ id: UUID) {
        guard let central, central.state == .poweredOn else {
            BandLog.link(.error, "connect \(id.uuidString): central not powered on")
            return
        }
        guard let peripheral = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            BandLog.link(.error, "connect \(id.uuidString): peripheral not known to CoreBluetooth")
            apply(.rememberedPeripheralUnavailable)
            return
        }
        peripherals[id] = peripheral
        peripheral.delegate = self
        BandLog.link(.info, "connect \(id.uuidString)")
        if peripheral.state == .connected {
            // A restored, already-connected peripheral: CoreBluetooth will not call didConnect again.
            apply(.connected)
        } else {
            central.connect(peripheral, options: nil)
        }
    }

    private func subscribeToHeartRate() {
        guard let peripheral = activePeripheral else {
            BandLog.link(.error, "subscribe: no active peripheral")
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.heartRateService }) else {
            BandLog.link(.error, "subscribe: heart rate service missing from \(Self.shortIDs(peripheral.services?.compactMap(\.uuid) ?? []))")
            apply(.heartRateUnavailable)
            return
        }
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == Self.heartRateMeasurement }) else {
            BandLog.link(.info, "subscribe: HR measurement characteristic not listed yet, discovering")
            peripheral.discoverCharacteristics([Self.heartRateMeasurement], for: service)
            return
        }
        // Subscribing with notify on: the band pushes 0x2A37 about once a second (PLAN.md 5.3.1).
        BandLog.link(.info, "subscribing to heart rate measurement")
        peripheral.setNotifyValue(true, for: characteristic)
    }

    // MARK: Tier B link (queue only)

    /// Starts custom-service setup once the custom service is found on the link.
    private func tierBServiceDiscovered(_ peripheral: CBPeripheral, _ service: CBService) {
        guard tierBEnabled else { return }
        BandLog.tierB(.info, "custom service found; discovering characteristics")
        tierBActive = true
        peripheral.discoverCharacteristics(
            [Self.customCommand] + Self.customNotifyUUIDs,
            for: service
        )
    }

    private func tierBCharacteristicsDiscovered(_ peripheral: CBPeripheral, _ service: CBService, _ error: Error?) {
        guard tierBEnabled, tierBActive else { return }
        let found = service.characteristics ?? []
        let foundIDs = Self.shortIDs(found.compactMap(\.uuid))
        if let error {
            tierBSetupFailed("Characteristic discovery failed after the custom service was found (found: [\(foundIDs)]): \(error.localizedDescription)")
            return
        }
        let expected = [Self.customCommand] + Self.customNotifyUUIDs
        let missing = Self.shortIDs(expected.filter { uuid in !found.contains { $0.uuid == uuid } })
        guard missing.isEmpty else {
            tierBSetupFailed("Custom service is missing characteristics \(missing) (found: [\(foundIDs)]). The band may not have the custom-service firmware, or the link is not bonded.")
            return
        }
        guard let command = found.first(where: { $0.uuid == Self.customCommand }) else { return }
        BandLog.tierB(.info, "characteristics found; subscribing notify channels, then bonding")
        commandWriter.attach(peripheral, command)
        tierBBonded = false
        // Order mirrors the verified NOOP client: the CCCDs go on BEFORE the bond write so the
        // strap's reply cannot beat the subscription. The handshake starts only when the write
        // is ACKed (bonded) AND all three notify subscriptions are on.
        subscribeTierB()
        // Bonding (PLAN.md 5.3.2): one GET_BATTERY_LEVEL write with response — the confirmed write
        // is what makes CoreBluetooth complete just-works bonding for this link.
        let bonding = BandCommand.getBatteryLevel().frame(seq: 0)
        let writer = commandWriter
        let queue = self.queue
        Task {
            do {
                try await writer.writeCommand(bonding)
            } catch {
                queue.async { self.tierBSetupFailed("Bond write (GET_BATTERY_LEVEL) failed: \(error.localizedDescription)") }
                return
            }
            queue.async {
                self.tierBBonded = true
                BandLog.tierB(.info, "bond write ACKed; link bonded")
                self.maybeOpenTierB()
            }
        }
    }

    /// Opens the Tier B session once the link is bonded and every custom channel is subscribed.
    private func maybeOpenTierB() {
        guard tierBActive, tierBBonded, tierBSubscriptionsPending == 0 else { return }
        let controller = tierB
        Task { await controller.connectionOpened() }
    }

    private func subscribeTierB() {
        guard tierBActive, let peripheral = activePeripheral else {
            BandLog.tierB(.error, "subscribe: tier B torn down before subscribing")
            return
        }
        var characteristics: [CBCharacteristic] = []
        for uuid in Self.customNotifyUUIDs {
            guard let characteristic = customCharacteristic(uuid) else {
                tierBSetupFailed("Custom characteristic \(uuid.uuidString) vanished before subscribing")
                return
            }
            characteristics.append(characteristic)
        }
        tierBSubscriptionsPending = characteristics.count
        BandLog.tierB(.info, "subscribing to \(characteristics.count) notify characteristics")
        for characteristic in characteristics {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    private func tierBSubscribed(_ characteristic: CBCharacteristic, _ error: Error?) {
        guard tierBActive, tierBSubscriptionsPending > 0 else { return }
        guard error == nil, characteristic.isNotifying else {
            tierBSetupFailed("CCCD subscribe failed for \(characteristic.uuid.uuidString): \(error.map { $0.localizedDescription } ?? "notify did not turn on"). The band usually rejects this when the link is not bonded.")
            return
        }
        tierBSubscriptionsPending -= 1
        BandLog.tierB(.info, "subscribed \(characteristic.uuid.uuidString) (\(tierBSubscriptionsPending) left)")
        if tierBSubscriptionsPending == 0 {
            maybeOpenTierB()
        }
    }

    private func tierBSetupFailed(_ reason: String) {
        BandLog.tierB(.error, "setup failed: \(reason)")
        continuation.yield(.tierBFailure(reason))
        tearDownTierB(unsubscribe: true, linkFailed: true)
    }

    /// Ends custom-service setup on this link. `unsubscribe` writes CCCD off for each subscribed characteristic.
    /// That write is the only custom-service packet sent when Tier B is switched off.
    private func tearDownTierB(unsubscribe: Bool, linkFailed: Bool) {
        BandLog.tierB(.info, "teardown: unsubscribe=\(unsubscribe) linkFailed=\(linkFailed)")
        if unsubscribe, let peripheral = activePeripheral {
            for uuid in Self.customNotifyUUIDs {
                if let characteristic = customCharacteristic(uuid), characteristic.isNotifying {
                    peripheral.setNotifyValue(false, for: characteristic)
                }
            }
        }
        commandWriter.detach()
        reassemblers.removeAll()
        tierBActive = false
        tierBBonded = false
        tierBSubscriptionsPending = 0
        let controller = tierB
        Task {
            if linkFailed {
                await controller.linkFailed()
            } else {
                await controller.connectionClosed()
            }
        }
    }

    private func customCharacteristic(_ uuid: CBUUID) -> CBCharacteristic? {
        activePeripheral?.services?
            .first(where: { $0.uuid == Self.customService })?
            .characteristics?
            .first(where: { $0.uuid == uuid })
    }

    private static var heartRateService: CBUUID { CBUUID(string: "180D") }
    private static var batteryService: CBUUID { CBUUID(string: "180F") }
    private static var heartRateMeasurement: CBUUID { CBUUID(string: "2A37") }
    /// WHOOP 4.0 custom service (PLAN.md 5.3.2). Used as a scan filter and, with Tier B on, for discovery.
    private static var customService: CBUUID { CBUUID(string: "61080001-8d6d-82b8-614a-1c8cb0f8dcc6") }
    /// CMD -> strap, write with response (PLAN.md 5.3.2).
    private static var customCommand: CBUUID { CBUUID(string: "61080002-8d6d-82b8-614a-1c8cb0f8dcc6") }
    /// CMD <- strap, EVENTS <- strap, DATA <- strap: notify (PLAN.md 5.3.2).
    private static var customNotifyUUIDs: [CBUUID] {
        ["61080003", "61080004", "61080005"].map { CBUUID(string: "\($0)-8d6d-82b8-614a-1c8cb0f8dcc6") }
    }

    // MARK: Logging helpers (queue only)

    /// Short characteristic/service UUIDs for logs, e.g. `180D`, `61080002` (fixture/log ids).
    static func shortIDs(_ uuids: [CBUUID]) -> String {
        uuids.map { GATTShortID.make($0.uuidString) }.joined(separator: ", ")
    }

    static func describe(_ state: CBManagerState) -> String {
        switch state {
        case .unknown: "unknown"
        case .resetting: "resetting"
        case .unsupported: "unsupported"
        case .unauthorized: "unauthorized"
        case .poweredOff: "poweredOff"
        case .poweredOn: "poweredOn"
        @unknown default: "unknown (\(state.rawValue))"
        }
    }

    static func describe(_ state: ConnectionState) -> String {
        switch state {
        case .idle: "idle"
        case .scanning: "scanning"
        case .connecting: "connecting"
        case .discovering: "discovering"
        case .subscribing: "subscribing"
        case .streaming: "streaming"
        case .backoff(let attempt): "backoff(try \(attempt))"
        }
    }

    static func describe(_ input: ConnectionInput) -> String {
        switch input {
        case .start: "start"
        case .stop: "stop"
        case .forget: "forget"
        case let .peripheralDiscovered(id): "peripheralDiscovered \(id.uuidString)"
        case let .pairRequested(id): "pairRequested \(id.uuidString)"
        case .rememberedPeripheralUnavailable: "rememberedPeripheralUnavailable"
        case .connected: "connected"
        case .connectFailed: "connectFailed"
        case .servicesDiscovered: "servicesDiscovered"
        case .heartRateUnavailable: "heartRateUnavailable"
        case .subscribed: "subscribed"
        case .disconnected: "disconnected"
        case .retryTimerFired: "retryTimerFired"
        }
    }

    // MARK: CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            BandLog.link(.info, "central powered on")
            startIfPowered()
        } else {
            BandLog.link(.error, "central state: \(Self.describe(central.state))")
            apply(.stop)
        }
    }

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // Runs before the first poweredOn callback on a background relaunch. Keep the peripherals
        // so that connect(_:) can reuse them. The machine starts after poweredOn.
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        BandLog.link(.info, "restoring \(restored.count) peripheral(s) from a background relaunch")
        for peripheral in restored {
            peripherals[peripheral.identifier] = peripheral
            peripheral.delegate = self
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let id = peripheral.identifier
        if let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) {
            names[id] = name
        }
        peripherals[id] = peripheral
        let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        BandLog.link(.info, "discovered \(names[id] ?? "unnamed") id=\(id.uuidString) rssi=\(RSSI.intValue) advServices=[\(Self.shortIDs(advertised))]")
        continuation.yield(.discovered(DiscoveredBand(id: id, name: names[id], rssi: RSSI.intValue)))
        apply(.peripheralDiscovered(id))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard isTarget(peripheral) else { return }
        BandLog.link(.info, "didConnect \(peripheral.identifier.uuidString)")
        apply(.connected)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard isTarget(peripheral) else { return }
        BandLog.link(.error, "didFailToConnect \(peripheral.identifier.uuidString): \(error.map { $0.localizedDescription } ?? "no error given")")
        apply(.connectFailed)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard isTarget(peripheral) else { return }
        BandLog.link(.info, "didDisconnect \(peripheral.identifier.uuidString): \(error.map { $0.localizedDescription } ?? "clean")")
        apply(.disconnected)
    }

    // MARK: CBPeripheralDelegate

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard isTarget(peripheral) else { return }
        let found = peripheral.services?.compactMap(\.uuid) ?? []
        if let error {
            BandLog.link(.error, "didDiscoverServices error: \(error.localizedDescription)")
        } else {
            BandLog.link(.info, "services found: [\(Self.shortIDs(found))]")
        }
        if tierBEnabled {
            // A band without the custom service, or a failed discovery, leaves Tier B unavailable on this link.
            if error == nil, let custom = peripheral.services?.first(where: { $0.uuid == Self.customService }) {
                tierBServiceDiscovered(peripheral, custom)
            } else {
                let reason = error.map { error in
                    "Custom-service discovery failed: \(error.localizedDescription)"
                } ?? "Custom service \(Self.customService.uuidString) is not in the band's GATT (found: [\(Self.shortIDs(found))]). Check HR Broadcast is on in the WHOOP app."
                tierBSetupFailed(reason)
            }
        }
        // The machine ignores this input unless it is discovering, so a custom-only discovery while streaming is harmless.
        let hasHeartRate = peripheral.services?.contains(where: { $0.uuid == Self.heartRateService }) ?? false
        if error == nil && !hasHeartRate {
            BandLog.link(.error, "heart rate service missing after discovery (found: [\(Self.shortIDs(found))])")
        }
        apply(error == nil && hasHeartRate ? .servicesDiscovered : .heartRateUnavailable)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard isTarget(peripheral) else { return }
        BandLog.link(.info, "characteristics for \(service.uuid.uuidString): [\(Self.shortIDs(service.characteristics?.compactMap(\.uuid) ?? []))] \(error.map { "error: \($0.localizedDescription)" } ?? "")")
        if service.uuid == Self.customService {
            tierBCharacteristicsDiscovered(peripheral, service, error)
            return
        }
        guard service.uuid == Self.heartRateService else { return }
        guard error == nil, let characteristic = service.characteristics?.first(where: { $0.uuid == Self.heartRateMeasurement }) else {
            BandLog.link(.error, "heart rate measurement characteristic missing: \(error.map { $0.localizedDescription } ?? "not listed")")
            apply(.heartRateUnavailable)
            return
        }
        BandLog.link(.info, "enabling heart rate notify")
        peripheral.setNotifyValue(true, for: characteristic)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard isTarget(peripheral), characteristic.uuid == Self.customCommand else { return }
        if let error {
            BandLog.tierB(.error, "write to CMD rejected by the band: \(error.localizedDescription)")
        } else {
            BandLog.tierB(.debug, "write to CMD confirmed")
        }
        commandWriter.didWrite(error: error)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard isTarget(peripheral) else { return }
        if characteristic.uuid == Self.heartRateMeasurement {
            if let error = error {
                BandLog.link(.error, "heart rate notify failed: \(error.localizedDescription)")
            } else {
                BandLog.link(.info, "heart rate notify: \(characteristic.isNotifying ? "on" : "off")")
            }
            apply(error == nil && characteristic.isNotifying ? .subscribed : .heartRateUnavailable)
        } else if Self.customNotifyUUIDs.contains(characteristic.uuid) {
            tierBSubscribed(characteristic, error)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard isTarget(peripheral) else { return }
        // Notification and read errors were previously swallowed; the WHOOP link cannot be
        // debugged without them.
        if let error {
            BandLog.link(.error, "value update error on \(characteristic.uuid.uuidString): \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        let receivedAt = Date()
        let short = GATTShortID.make(characteristic.uuid.uuidString)
        if characteristic.uuid == Self.heartRateMeasurement {
            continuation.yield(.raw(char: short, bytes: bytes, at: receivedAt))
            if let measurement = try? HeartRateMeasurementParser.parse(bytes) {
                continuation.yield(.hr(measurement, receivedAt: receivedAt))
            }
        } else if tierBActive, Self.customNotifyUUIDs.contains(characteristic.uuid) {
            // Recorded for the frame log (PLAN.md 7.2), then reassembled by length, never by scanning for 0xAA.
            BandLog.tierB(.debug, "notify \(short): \(hex(bytes))")
            continuation.yield(.raw(char: short, bytes: bytes, at: receivedAt))
            var reassembler = reassemblers[short] ?? FrameReassembler()
            let results = reassembler.append(bytes)
            reassemblers[short] = reassembler
            for case let .success(frame) in results {
                BandLog.tierB(.debug, "frame on \(short): \(Data(frame.payload).count) payload bytes")
                inboundContinuation.yield(frame)
            }
        }
    }
}

/// Errors from the Tier B write path.
enum TierBWriteError: Error {
    case notConnected
}

/// Confirmed writes to 61080002 (PLAN.md 5.3.2, 7.2). Queue-confined. Completions are matched in arrival order.
final class TierBCommandWriter: CommandWriter, @unchecked Sendable {
    private let queue: DispatchQueue
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var pending: [CheckedContinuation<Void, any Error>] = []

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Queue only.
    func attach(_ peripheral: CBPeripheral, _ characteristic: CBCharacteristic) {
        self.peripheral = peripheral
        self.characteristic = characteristic
    }

    /// Queue only. Fails writes still waiting for the link.
    func detach() {
        peripheral = nil
        characteristic = nil
        let waiting = pending
        pending = []
        for continuation in waiting {
            continuation.resume(throwing: TierBWriteError.notConnected)
        }
    }

    /// Queue only. Called from `didWriteValueFor`.
    func didWrite(error: (any Error)?) {
        guard !pending.isEmpty else { return }
        let continuation = pending.removeFirst()
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    func writeCommand(_ frame: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                guard let peripheral = self.peripheral, let characteristic = self.characteristic,
                      peripheral.state == .connected
                else {
                    continuation.resume(throwing: TierBWriteError.notConnected)
                    return
                }
                self.pending.append(continuation)
                peripheral.writeValue(Data(frame), for: characteristic, type: .withResponse)
            }
        }
    }
}

// TODO(PLAN.md §19 Phase 1, §20 Q1): read-only Tier B probe (version, clock, battery), opt-in only.
// The probe is not wired up yet and must not send any custom command in Phase 1.
#if ICARUS_TIER_B_PROBE
extension CoreBluetoothTransport {
    func runTierBProbe() {}
}
#endif
#endif
