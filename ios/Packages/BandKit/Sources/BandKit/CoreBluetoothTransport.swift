#if canImport(CoreBluetooth)
import BandProtocol
import CoreBluetooth
import Foundation

/// The real band link. Tier A only: scan, connect, subscribe to 0x2A37 (PLAN.md §5.3.6, §7.2).
///
/// Concurrency: every piece of mutable state is confined to `queue`. CoreBluetooth delivers its
/// delegate callbacks on `queue`, and each public method hops onto `queue` before it reads or
/// writes state. `queue` is the only synchronisation, which is why this is `@unchecked Sendable`
/// rather than an actor. Events leave through `continuation`, which is Sendable.
///
/// Connection rules live in `ConnectionStateMachine`. This class only turns its effects into
/// CoreBluetooth calls and turns CoreBluetooth callbacks into machine inputs.
public final class CoreBluetoothTransport: NSObject, BandTransport, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    public let events: AsyncStream<BandEvent>

    static let restoreIdentifier = "icarus.central"

    private let continuation: AsyncStream<BandEvent>.Continuation
    private let queue = DispatchQueue(label: "icarus.bandkit.central")
    private let store: any BandIdentityStore

    // MARK: Queue-confined state

    private var machine: ConnectionStateMachine
    private var central: CBCentralManager?
    private var wantsRunning = false
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var names: [UUID: String] = [:]
    private var publishedState: ConnectionState = .idle
    private var retryGeneration = 0

    public init(store: any BandIdentityStore) {
        let (stream, continuation) = AsyncStream<BandEvent>.makeStream()
        let remembered = store.load()
        self.events = stream
        self.continuation = continuation
        self.store = store
        self.machine = ConnectionStateMachine(rememberedID: remembered?.id)
        if let remembered, let name = remembered.name {
            self.names = [remembered.id: name]
        }
        super.init()
    }

    // MARK: BandTransport

    public func start() async {
        queue.async {
            self.wantsRunning = true
            self.continuation.yield(.remembered(self.machine.rememberedID))
            if self.central == nil {
                // The restore identifier lets iOS relaunch the app for band events (PLAN.md §7.2).
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
            activePeripheral?.discoverServices([Self.heartRateService, Self.batteryService])
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
        // Subscribing with notify on: the band pushes 0x2A37 about once a second (PLAN.md §5.3.1).
        peripheral.setNotifyValue(true, for: characteristic)
    }

    private static var heartRateService: CBUUID { CBUUID(string: "180D") }
    private static var batteryService: CBUUID { CBUUID(string: "180F") }
    private static var heartRateMeasurement: CBUUID { CBUUID(string: "2A37") }
    /// Scan filter only. Tier B is not implemented (PLAN.md §5.3.6), so nothing is read or written here.
    private static var customService: CBUUID { CBUUID(string: "61080001-8d6d-82b8-614a-1c8cb0f8dcc6") }

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
        let hasHeartRate = peripheral.services?.contains(where: { $0.uuid == Self.heartRateService }) ?? false
        apply(error == nil && hasHeartRate ? .servicesDiscovered : .heartRateUnavailable)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard isTarget(peripheral), service.uuid == Self.heartRateService else { return }
        guard error == nil, let characteristic = service.characteristics?.first(where: { $0.uuid == Self.heartRateMeasurement }) else {
            apply(.heartRateUnavailable)
            return
        }
        peripheral.setNotifyValue(true, for: characteristic)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard isTarget(peripheral), characteristic.uuid == Self.heartRateMeasurement else { return }
        apply(error == nil && characteristic.isNotifying ? .subscribed : .heartRateUnavailable)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, isTarget(peripheral), characteristic.uuid == Self.heartRateMeasurement,
              let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        let receivedAt = Date()
        continuation.yield(.raw(char: GATTShortID.make(characteristic.uuid.uuidString), bytes: bytes, at: receivedAt))
        if let measurement = try? HeartRateMeasurementParser.parse(bytes) {
            continuation.yield(.hr(measurement, receivedAt: receivedAt))
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
