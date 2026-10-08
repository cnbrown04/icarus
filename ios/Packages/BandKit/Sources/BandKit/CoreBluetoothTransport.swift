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
        Task {
            for await frame in frames {
                await controller.receive(frame)
            }
        }
    }

    // MARK: BandTransport

    public func start() async {
        queue.async {
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
            guard enabled != self.tierBEnabled else { return }
            self.tierBEnabled = enabled
            let controller = self.tierB
            if enabled {
                Task { await controller.setEnabled(true) }
                // Already streaming: find the custom service on the live link. Otherwise the next connection does it.
                if self.machine.state == .streaming, let peripheral = self.activePeripheral {
                    self.tierBActive = true
                    peripheral.discoverServices([Self.customService])
                }
            } else {
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
        let effects = machine.handle(input)
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
            central.scanForPeripherals(
                withServices: [Self.heartRateService, Self.customService],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        case .stopScan:
            central?.stopScan()
        case let .connect(id):
            connect(id)
        case let .cancelConnection(id):
            if let peripheral = peripherals[id] {
                central?.cancelPeripheralConnection(peripheral)
            }
        case .discoverServices:
            var services = [Self.heartRateService, Self.batteryService]
            if tierBEnabled {
                services.append(Self.customService)
            }
            activePeripheral?.discoverServices(services)
        case .subscribe:
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
        guard let central, central.state == .poweredOn else { return }
        guard let peripheral = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            apply(.rememberedPeripheralUnavailable)
            return
        }
        peripherals[id] = peripheral
        peripheral.delegate = self
        if peripheral.state == .connected {
            // A restored, already-connected peripheral: CoreBluetooth will not call didConnect again.
            apply(.connected)
        } else {
            central.connect(peripheral, options: nil)
        }
    }

    private func subscribeToHeartRate() {
        guard let peripheral = activePeripheral else { return }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.heartRateService }) else {
            apply(.heartRateUnavailable)
            return
        }
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == Self.heartRateMeasurement }) else {
            peripheral.discoverCharacteristics([Self.heartRateMeasurement], for: service)
            return
        }
        // Subscribing with notify on: the band pushes 0x2A37 about once a second (PLAN.md 5.3.1).
        peripheral.setNotifyValue(true, for: characteristic)
    }

    // MARK: Tier B link (queue only)

    /// Starts custom-service setup once the custom service is found on the link.
    private func tierBServiceDiscovered(_ peripheral: CBPeripheral, _ service: CBService) {
        guard tierBEnabled else { return }
        tierBActive = true
        peripheral.discoverCharacteristics(
            [Self.customCommand] + Self.customNotifyUUIDs,
            for: service
        )
    }

    private func tierBCharacteristicsDiscovered(_ peripheral: CBPeripheral, _ service: CBService, _ error: Error?) {
        guard tierBEnabled, tierBActive else { return }
        let found = service.characteristics ?? []
        guard error == nil,
              let command = found.first(where: { $0.uuid == Self.customCommand }),
              Self.customNotifyUUIDs.allSatisfy({ uuid in found.contains { $0.uuid == uuid } })
        else {
            tearDownTierB(unsubscribe: true, linkFailed: true)
            return
        }
        commandWriter.attach(peripheral, command)
        // Bonding (PLAN.md 5.3.2): one GET_BATTERY_LEVEL write with response. The custom notify
        // characteristics stay silent until this completes, so they are subscribed afterwards.
        let bonding = BandCommand.getBatteryLevel().frame(seq: 0)
        let writer = commandWriter
        let queue = self.queue
        Task {
            do {
                try await writer.writeCommand(bonding)
            } catch {
                queue.async { self.tierBSetupFailed() }
                return
            }
            queue.async { self.subscribeTierB() }
        }
    }

    private func subscribeTierB() {
        guard tierBActive, let peripheral = activePeripheral else { return }
        var characteristics: [CBCharacteristic] = []
        for uuid in Self.customNotifyUUIDs {
            guard let characteristic = customCharacteristic(uuid) else {
                tierBSetupFailed()
                return
            }
            characteristics.append(characteristic)
        }
        tierBSubscriptionsPending = characteristics.count
        for characteristic in characteristics {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    private func tierBSubscribed(_ characteristic: CBCharacteristic, _ error: Error?) {
        guard tierBActive, tierBSubscriptionsPending > 0 else { return }
        guard error == nil, characteristic.isNotifying else {
            tierBSetupFailed()
            return
        }
        tierBSubscriptionsPending -= 1
        if tierBSubscriptionsPending == 0 {
            let controller = tierB
            Task { await controller.connectionOpened() }
        }
    }

    private func tierBSetupFailed() {
        tearDownTierB(unsubscribe: true, linkFailed: true)
    }

    /// Ends custom-service setup on this link. `unsubscribe` writes CCCD off for each subscribed characteristic.
    /// That write is the only custom-service packet sent when Tier B is switched off.
    private func tearDownTierB(unsubscribe: Bool, linkFailed: Bool) {
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

    // MARK: CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            startIfPowered()
        } else {
            apply(.stop)
        }
    }

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // Runs before the first poweredOn callback on a background relaunch. Keep the peripherals
        // so that connect(_:) can reuse them. The machine starts after poweredOn.
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
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
        continuation.yield(.discovered(DiscoveredBand(id: id, name: names[id], rssi: RSSI.intValue)))
        apply(.peripheralDiscovered(id))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard isTarget(peripheral) else { return }
        apply(.connected)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard isTarget(peripheral) else { return }
        apply(.connectFailed)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard isTarget(peripheral) else { return }
        apply(.disconnected)
    }

    // MARK: CBPeripheralDelegate

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard isTarget(peripheral) else { return }
        if tierBEnabled {
            // A band without the custom service, or a failed discovery, leaves Tier B unavailable on this link.
            if error == nil, let custom = peripheral.services?.first(where: { $0.uuid == Self.customService }) {
                tierBServiceDiscovered(peripheral, custom)
            } else {
                tierBSetupFailed()
            }
        }
        // The machine ignores this input unless it is discovering, so a custom-only discovery while streaming is harmless.
        let hasHeartRate = peripheral.services?.contains(where: { $0.uuid == Self.heartRateService }) ?? false
        apply(error == nil && hasHeartRate ? .servicesDiscovered : .heartRateUnavailable)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard isTarget(peripheral) else { return }
        if service.uuid == Self.customService {
            tierBCharacteristicsDiscovered(peripheral, service, error)
            return
        }
        guard service.uuid == Self.heartRateService else { return }
        guard error == nil, let characteristic = service.characteristics?.first(where: { $0.uuid == Self.heartRateMeasurement }) else {
            apply(.heartRateUnavailable)
            return
        }
        peripheral.setNotifyValue(true, for: characteristic)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard isTarget(peripheral), characteristic.uuid == Self.customCommand else { return }
        commandWriter.didWrite(error: error)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard isTarget(peripheral) else { return }
        if characteristic.uuid == Self.heartRateMeasurement {
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
        guard error == nil, isTarget(peripheral), let data = characteristic.value else { return }
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
            continuation.yield(.raw(char: short, bytes: bytes, at: receivedAt))
            var reassembler = reassemblers[short] ?? FrameReassembler()
            let results = reassembler.append(bytes)
            reassemblers[short] = reassembler
            for case let .success(frame) in results {
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
