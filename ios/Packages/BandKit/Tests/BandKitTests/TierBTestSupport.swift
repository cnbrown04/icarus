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

    private let lock = NSLock()
    private var written: [[UInt8]] = []
    private var responder: Responder?
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
        let responder = lock.withLock { self.responder }
        let controller = lock.withLock { self.controller }
        if let reply = responder?(request, index), let controller {
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
    return reply(to: request, payload: request.cmd == batteryOpcode ? [0x69, 0x03] : [])
}

func reply(to request: Frame, payload: [UInt8] = []) -> Frame {
    Frame(type: PacketType.commandResponse.rawValue, seq: request.seq, cmd: request.cmd, payload: payload)
}

func eventFrame(_ id: UInt8) -> Frame {
    Frame(type: PacketType.event.rawValue, seq: 0, cmd: id, payload: [])
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
