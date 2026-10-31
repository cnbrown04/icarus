import BandKit
import BandProtocol
import Foundation
import Testing

// Virtual time for TierBController. `sleep` suspends until `advance(by:)` moves time past its deadline,
// so timeouts and rhythm steps run without waiting.
final class ManualClock: TierBClock, @unchecked Sendable {
    private struct Sleeper {
        let id: Int
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, any Error>
    }

    static let origin = Date(timeIntervalSince1970: 1_791_382_500)

    private let lock = NSLock()
    private var elapsed: TimeInterval = 0
    private var sleepers: [Sleeper] = []
    private var cancelledBeforeSleep: Set<Int> = []
    private var lastID = 0

    func now() -> Date {
        lock.withLock { Self.origin.addingTimeInterval(elapsed) }
    }

    var sleeperCount: Int {
        lock.withLock { sleepers.count }
    }

    func sleep(seconds: Double) async throws {
        let id = lock.withLock { () -> Int in
            lastID += 1
            return lastID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let immediate = lock.withLock { () -> Result<Void, any Error>? in
                    if cancelledBeforeSleep.remove(id) != nil { return .failure(CancellationError()) }
                    if seconds <= 0 { return .success(()) }
                    sleepers.append(Sleeper(id: id, deadline: elapsed + seconds, continuation: continuation))
                    return nil
                }
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        } onCancel: {
            let removed = lock.withLock { () -> Sleeper? in
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else {
                    cancelledBeforeSleep.insert(id)
                    return nil
                }
                return sleepers.remove(at: index)
            }
            removed?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by seconds: Double) {
        let due = lock.withLock { () -> [Sleeper] in
            elapsed += seconds
            let ready = sleepers.filter { $0.deadline <= elapsed }
            sleepers.removeAll { $0.deadline <= elapsed }
            return ready.sorted { $0.deadline < $1.deadline }
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }
}

/// Stands in for the band's CMD characteristic. Records every frame, then, if the responder gives a reply,
/// delivers it to the controller the way the notify path would.
final class FakeBand: CommandWriter, @unchecked Sendable {
    typealias Responder = @Sendable (_ request: Frame, _ index: Int) -> Frame?
    typealias MultiResponder = @Sendable (_ request: Frame, _ index: Int) -> [Frame]

    private let lock = NSLock()
    private var written: [[UInt8]] = []
    private var responder: Responder?
    /// Delivers ZERO OR MORE reply frames per write, in order (a scripted band's batch: records
    /// then metadata). When set, it replaces `responder` entirely.
    private var multiResponder: MultiResponder?
    private var controller: TierBController?

    init(responder: Responder?) {
        self.responder = responder
    }

    func bind(_ controller: TierBController) {
        lock.withLock { self.controller = controller }
    }

    func setResponder(_ responder: Responder?) {
        lock.withLock { self.responder = responder }
    }

    func setMultiResponder(_ responder: MultiResponder?) {
        lock.withLock { self.multiResponder = responder }
    }

    var count: Int {
        lock.withLock { written.count }
    }

    var frames: [[UInt8]] {
        lock.withLock { written }
    }

    var commands: [Frame] {
        frames.map { try! FrameCodec.decode($0) }
    }

    var opcodes: [UInt8] {
        commands.map(\.cmd)
    }

    var last: Frame? {
        commands.last
    }

    func writeCommand(_ frame: [UInt8]) async throws {
        let index = lock.withLock { () -> Int in
            written.append(frame)
            return written.count - 1
        }
        let request = try FrameCodec.decode(frame)
        let multiResponder = lock.withLock { self.multiResponder }
        let responder = lock.withLock { self.responder }
        let controller = lock.withLock { self.controller }
        if let multiResponder, let controller {
            for reply in multiResponder(request, index) {
                await controller.receive(reply)
            }
        } else if let reply = responder?(request, index), let controller {
            await controller.receive(reply)
        }
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [BandEvent] = []

    func append(_ event: BandEvent) {
        lock.withLock { stored.append(event) }
    }

    var all: [BandEvent] {
        lock.withLock { stored }
    }
}

/// Replies with the request's command id and seq. The battery reply is 873, which is 87.3 %.
let answerAll: FakeBand.Responder = { request, _ in
    let batteryOpcode = BandCommand.getBatteryLevel().command.rawValue
    return reply(to: request, payload: request.cmd == batteryOpcode ? [0x00, 0x01, 0x69, 0x03] : [])
}

func reply(to request: Frame, payload: [UInt8] = []) -> Frame {
    Frame(type: PacketType.commandResponse.rawValue, seq: request.seq, cmd: request.cmd, payload: payload)
}

func eventFrame(_ id: UInt8) -> Frame {
    Frame(type: PacketType.event.rawValue, seq: 0, cmd: id, payload: [])
}

/// A minimal version-24 HISTORICAL_DATA (type 47) record frame. Offsets are `Frame.payload` offsets
/// (= NOOP's frame-absolute offsets minus the 7-byte envelope): unix seconds at 4, heart rate at 14,
/// on-wrist at 48.
func historicalRecordFrame(unix: UInt32, heartRate: UInt8 = 60) -> Frame {
    var payload = [UInt8](repeating: 0, count: 77)
    for (index, byte) in littleEndian(unix).enumerated() {
        payload[4 + index] = byte
    }
    payload[14] = heartRate
    payload[48] = 1
    return Frame(type: PacketType.historicalData.rawValue, seq: HistoricalRecord.supportedVersion, cmd: 7, payload: payload)
}

/// A METADATA (type 49) frame carrying the 8-byte batch token at payload[10..<18] (HistoricalMetadata).
func metadataFrame(token: [UInt8]) -> Frame {
    var payload = [UInt8](repeating: 0, count: 21)
    for (index, byte) in token.enumerated() {
        payload[10 + index] = byte
    }
    return Frame(type: PacketType.metadata.rawValue, seq: 24, cmd: 2, payload: payload)
}

/// A controller wired to a fake band, a manual clock and an event log.
struct Harness {
    let clock: ManualClock
    let band: FakeBand
    let events: EventLog
    let controller: TierBController

    init(enabled: Bool = true, responder: FakeBand.Responder? = answerAll) {
        let clock = ManualClock()
        let band = FakeBand(responder: responder)
        let events = EventLog()
        let controller = TierBController(
            writer: band,
            clock: clock,
            enabled: enabled,
            emit: { events.append($0) }
        )
        band.bind(controller)
        self.clock = clock
        self.band = band
        self.events = events
        self.controller = controller
    }
}

/// A thread-safe incrementing counter, for scripted-band responder closures that must vary by
/// how many times a given command was written (a `@Sendable` closure cannot capture a mutable local).
final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.withLock { value += 1; return value }
    }
}

/// Ends the drain that is running (if any) by advancing the clock until `drainPhase` leaves
/// `.draining`, one run-cap step at a time. Watchdog Tasks park their `clock.sleep` lazily (a
/// `Task` body runs after its creation, and the sleep's deadline is relative to that moment), so a
/// single `clock.advance` can race past before the sleeper is registered — an empty drain then
/// never ends. A record-ful drain ends on the FIRST of its quiet deadline / the run cap that the
/// steps reach, which is exactly the shape the restore loop continues on.
func endRunningDrain(_ h: Harness) async {
    for _ in 0 ..< 8 {
        guard await h.controller.drainPhase == .draining else { return }
        h.clock.advance(by: OffloadStateMachine.runCap)
        await flush()
    }
    Issue.record("the drain did not end")
}

/// Lets queued tasks run until `condition` holds. Bounded, so a broken condition fails instead of hanging.
func settle(_ condition: () async -> Bool) async {
    for _ in 0 ..< 10_000 {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("condition was not reached")
}

/// Gives every runnable task a chance to run, for asserting that something did not happen.
func flush() async {
    for _ in 0 ..< 200 {
        await Task.yield()
    }
}

/// Little-endian bytes of a unix time, as the alarm payload carries it (PLAN.md 5.3.4).
func littleEndian(_ value: UInt32) -> [UInt8] {
    [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
}

/// The #791 capture's GET_DATA_RANGE reply payload (the envelope minus its [AA][size][crc8]
/// head), with the ring words patched: W sits at payload offset 11, U at 15, T at 23. Word offsets
/// per NOOP's ring layout.
func ringPayload(write: UInt32, read: UInt32, capacity: UInt32 = 131_072) -> [UInt8] {
    let capture = "aa4c00a7247e220a01010000000050070100a307010050070100000000000000020035030000" +
        "c2fc13008046394b00000000bbe1636aa02d0000bbe1636aa02d0000c6e4636ac07c000000000447ea04"
    var payload: [UInt8] = stride(from: 0, to: capture.count, by: 2).map { off in
        let start = capture.index(capture.startIndex, offsetBy: off)
        return UInt8(capture[start ..< capture.index(start, offsetBy: 2)], radix: 16)!
    }
    payload.removeFirst(7)
    payload.replaceSubrange(11 ..< 15, with: littleEndian(write))
    payload.replaceSubrange(15 ..< 19, with: littleEndian(read))
    payload.replaceSubrange(23 ..< 27, with: littleEndian(capacity))
    return payload
}

/// A scripted strap whose flash is a ring of `capacity` record slots, for the full-history restore.
/// Slot `s` holds the record `age × secondsPerSlot` seconds before the clock origin, where age
/// counts back from the newest slot (W − 1). A wrapped ring is full, so its oldest survivors sit at
/// W and the ring reads oldest-first from W around to W − 1. An unwrapped ring holds only slots
/// below W. `respond` answers the commands the restore writes: GET_DATA_RANGE (34) reports the
/// pointers, SET_READ_POINTER (33) moves the persistent cursor, and SEND_HISTORICAL_DATA (22)
/// streams every record from the cursor up to W in one batch, then closes it with METADATA. A kick
/// with nothing left answers HISTORY_COMPLETE.
final class RingStrap: @unchecked Sendable {
    /// Spacing of the stored records. Only the newest slot (age 0) lands inside the live-edge window.
    static let secondsPerSlot = 36

    let capacity: Int
    let write: Int
    private let lock = NSLock()
    private var cursor: Int
    private var slots: [UInt32?]
    private var rewindOffsets: [UInt32] = []

    /// `newest` is the clock's now when the restore starts: the newest slot is stamped with it, so
    /// reading that slot lands inside the live-edge window.
    init(capacity: Int, write: Int, cursor: Int, wrapped: Bool, newest: Date) {
        self.capacity = capacity
        self.write = write
        self.cursor = cursor
        let origin = UInt32(newest.timeIntervalSince1970)
        slots = (0 ..< capacity).map { slot in
            guard wrapped || slot < write else { return nil }
            let age = (write - 1 - slot + capacity) % capacity
            return origin - UInt32(age * Self.secondsPerSlot)
        }
    }

    /// Every SET_READ_POINTER offset the strap has been asked to seek to, in order.
    var rewinds: [UInt32] {
        lock.withLock { rewindOffsets }
    }

    func respond(to request: Frame) -> [Frame] {
        switch request.cmd {
        case 34:
            let read = lock.withLock { cursor }
            return [reply(to: request, payload: ringPayload(write: UInt32(write), read: UInt32(read), capacity: UInt32(capacity)))]
        case 33:
            let p = request.payload
            let offset = UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24
            lock.withLock {
                rewindOffsets.append(offset)
                cursor = Int(offset)
            }
            return []
        case 22:
            return streamBatch()
        default:
            return []
        }
    }

    private func streamBatch() -> [Frame] {
        lock.withLock {
            var frames: [Frame] = []
            while cursor != write, let unix = slots[cursor] {
                frames.append(historicalRecordFrame(unix: unix))
                cursor = (cursor + 1) % capacity
            }
            guard !frames.isEmpty else {
                return [Frame(type: PacketType.metadata.rawValue, seq: 24, cmd: 3, payload: [])]
            }
            frames.append(metadataFrame(token: [0x2E, 0x47, 0x01, 0x00, 0x04, 0x00, 0x00, 0x00]))
            return frames
        }
    }
}
