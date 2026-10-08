import BandProtocol
import Foundation

/// Time source for `TierBController`. Tests inject a manual clock so nothing waits in real time.
public protocol TierBClock: Sendable {
    func now() -> Date
    func sleep(seconds: Double) async throws
}

public struct SystemTierBClock: TierBClock {
    public init() {}

    public func now() -> Date {
        Date()
    }

    public func sleep(seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

/// Writes one encoded COMMAND frame to the band's CMD characteristic as a confirmed write.
/// Returns when the link confirms the write. The band's reply arrives separately, as a notification.
public protocol CommandWriter: Sendable {
    func writeCommand(_ frame: [UInt8]) async throws
}

/// Tier B link state (PLAN.md 5.3.6, 7.2).
public enum TierBState: Sendable, Equatable {
    /// The toggle is off. No custom-service traffic is sent.
    case disabled
    /// Enabled, waiting for the custom service to be bonded and subscribed.
    case awaitingLink
    /// Bonded. The once-per-connection handshake is running.
    case handshaking
    case ready
    /// Setup or the handshake failed. Nothing more is sent until the next connection.
    case unavailable
}

public enum TierBError: Error, Sendable, Equatable {
    /// The toggle is off. Every call is rejected and nothing is written.
    case disabled
    case notConnected
    /// The handshake has not finished, or the state is not `.ready`.
    case notReady
    /// No matching response after the last retry (PLAN.md 7.2).
    case timedOut
    case writeFailed
}

/// Tier B command queue, handshake, rate limits, rhythms and band alarm (PLAN.md 5.3.4, 6.5, 7.2, 9.2, 9.5).
///
/// Only `BandCommand` can be sent, and `BandCommand` only holds whitelisted opcodes, so the denylist
/// (PLAN.md 5.3.5) holds at the type level. Pure logic: there is no CoreBluetooth in this file.
/// Every write goes through the injected `CommandWriter`, and every timeout comes from the injected clock.
public actor TierBController {
    /// PLAN.md 7.2: 5 s timeout per attempt, at most 3 retries.
    public static let responseTimeout: Double = 5
    public static let maxRetries = 3
    /// PLAN.md 6.5: battery at most every 10 min.
    public static let batteryInterval: TimeInterval = 600

    private struct Job {
        let command: BandCommand
        let continuation: CheckedContinuation<Frame, any Error>
    }

    /// The one command awaiting a reply. `token` tells a late timer or write failure apart from the current attempt.
    private struct Waiter {
        let command: SafeCommand
        let seq: UInt8
        let token: Int
        let timer: Task<Void, Never>
        let continuation: CheckedContinuation<Result<Frame, TierBError>, Never>
    }

    private let writer: any CommandWriter
    private let clock: any TierBClock
    private let emit: @Sendable (BandEvent) -> Void

    public private(set) var state: TierBState
    private var enabled: Bool
    private var linkOpen = false
    private var handshakeStarted = false
    private var nextSeq: UInt8 = 0
    private var nextToken = 0
    /// Once a reply has echoed the seq byte, a reply with another seq is treated as stale (PLAN.md 7.2).
    private var seqEchoObserved = false
    private var queue: [Job] = []
    private var draining = false
    private var waiter: Waiter?
    private var rhythmTask: Task<Void, Never>?
    private var rhythmGeneration = 0
    private var upcomingAlarms: [Date] = []
    private var armedAlarm: Date?
    private var lastBatteryRequest: Date?

    public init(writer: any CommandWriter, clock: any TierBClock, enabled: Bool, emit: @escaping @Sendable (BandEvent) -> Void) {
        self.writer = writer
        self.clock = clock
        self.emit = emit
        self.enabled = enabled
        self.state = enabled ? .awaitingLink : .disabled
    }

    // MARK: Link and toggle

    /// The Tier B toggle. Turning it off drops queued and in-flight commands and stops any rhythm.
    /// It sends nothing; the transport unsubscribes the custom characteristics (PLAN.md 19 Phase 6).
    public func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        handshakeStarted = false
        if on {
            setState(.awaitingLink)
        } else {
            // The transport tears down the custom link when the toggle goes off, so no link remains.
            linkOpen = false
            armedAlarm = nil
            failPending(.disabled)
            rhythmTask?.cancel()
            rhythmTask = nil
            setState(.disabled)
        }
    }

    /// The custom service is bonded and subscribed. Runs the handshake once per connection (PLAN.md 7.2).
    public func connectionOpened() async {
        linkOpen = true
        armedAlarm = nil
        guard enabled, !handshakeStarted else { return }
        handshakeStarted = true
        setState(.handshaking)
        // SET_CLOCK is skipped: its payload is undocumented (PLAN.md 5.3.4). GET_HELLO and the raw
        // realtime disable are not in SafeCommand or PLAN.md 5.3.4, so they are skipped too.
        for command in [BandCommand.getClock(), BandCommand.getDataRange()] {
            do {
                _ = try await send(command)
            } catch {
                guard enabled else { return }
                if linkOpen {
                    setState(.unavailable)
                } else {
                    handshakeStarted = false
                    setState(.awaitingLink)
                }
                return
            }
        }
        guard enabled, linkOpen else { return }
        setState(.ready)
        await rearmNext()
        await refreshBattery()
    }

    /// The link dropped. Pending commands fail with `.notConnected`.
    public func connectionClosed() {
        linkOpen = false
        handshakeStarted = false
        armedAlarm = nil
        failPending(.notConnected)
        // A failed setup stays `.unavailable` until the next connection opens.
        if enabled, state != .unavailable {
            setState(.awaitingLink)
        }
    }

    /// Setup failed on this link (for example, a missing characteristic). Nothing more is sent until the next connection.
    public func linkFailed() {
        linkOpen = false
        handshakeStarted = false
        failPending(.notConnected)
        if enabled {
            setState(.unavailable)
        }
    }

    // MARK: Commands

    /// Sends one command and waits for its reply. Commands run one at a time, in order (PLAN.md 7.2).
    public func send(_ command: BandCommand) async throws -> Frame {
        guard enabled else { throw TierBError.disabled }
        guard linkOpen else { throw TierBError.notConnected }
        return try await withCheckedThrowingContinuation { continuation in
            queue.append(Job(command: command, continuation: continuation))
            startDrainingIfNeeded()
        }
    }

    /// Feeds one reassembled frame from the band. Replies complete the in-flight command. Events are emitted.
    public func receive(_ frame: Frame) async {
        guard enabled, linkOpen else { return }
        if frame.packetType == .commandResponse {
            guard let current = waiter, frame.cmd == current.command.rawValue else { return }
            guard frame.seq == current.seq || !seqEchoObserved else { return }
            if frame.seq == current.seq {
                seqEchoObserved = true
            }
            resolve(current.token, with: .success(frame))
        } else if let kind = BandEventParser.parse(frame) {
            emit(.bandEvent(kind))
            if kind == .strapDrivenAlarmExecuted {
                // The band has fired the alarm it was given. Drop it and arm the next due one.
                if let fired = armedAlarm {
                    upcomingAlarms.removeAll { $0 <= fired }
                }
                armedAlarm = nil
                await rearmNext()
            }
        }
    }

    // MARK: Battery

    /// Reads the battery at most once per `batteryInterval` (PLAN.md 6.5). Does nothing before the handshake is done.
    public func refreshBattery() async {
        guard enabled, state == .ready else { return }
        let now = clock.now()
        if let last = lastBatteryRequest, now.timeIntervalSince(last) < Self.batteryInterval {
            return
        }
        lastBatteryRequest = now
        guard let frame = try? await send(.getBatteryLevel()),
              let percent = BatteryLevel.percent(payload: frame.payload)
        else { return }
        emit(.battery(Int(percent.rounded())))
    }

    // MARK: Band alarm (PLAN.md 9.5)

    /// Sets the upcoming scheduled alarms (UTC instants). The earliest future one is armed on the band.
    /// Call again after DST or time zone changes. Passing an empty list stops re-arming but leaves the
    /// band's current alarm in place, because no disarm command is documented (PLAN.md 5.3.4).
    public func armAlarms(_ occurrences: [Date]) async {
        upcomingAlarms = occurrences.sorted()
        await rearmNext()
    }

    private func rearmNext() async {
        guard enabled, state == .ready else { return }
        let now = clock.now()
        guard let next = upcomingAlarms.first(where: { $0 > now }), next != armedAlarm else { return }
        let unix = next.timeIntervalSince1970.rounded(.down)
        guard unix >= 0, unix <= Double(UInt32.max) else { return }
        if (try? await send(.setAlarmTime(unix: UInt32(unix)))) != nil {
            armedAlarm = next
        }
    }

    // MARK: Haptics (PLAN.md 9.2)

    /// Plays a rhythm and returns when it has finished. A throw from cancellation or a failed step sends STOP_HAPTICS.
    public func runRhythm(_ rhythm: Rhythm) async throws {
        try requireReady()
        do {
            for step in rhythm.steps {
                switch step {
                case let .buzz(preset, loops):
                    _ = try await send(.runHapticsPattern(patternId: preset, loops: loops))
                    try await clock.sleep(seconds: step.seconds)
                case let .pause(ms):
                    try await clock.sleep(seconds: Double(ms) / 1000)
                }
                try requireReady()
            }
        } catch {
            await stopAfterInterruption()
            throw error
        }
    }

    /// Plays a rhythm in the background. A rhythm already running is stopped first, so two never overlap.
    public func startRhythm(_ rhythm: Rhythm) {
        let previous = rhythmTask
        previous?.cancel()
        rhythmGeneration += 1
        let generation = rhythmGeneration
        rhythmTask = Task {
            await previous?.value
            try? await self.runRhythm(rhythm)
            self.rhythmEnded(generation)
        }
    }

    /// Cancels the running rhythm, which sends STOP_HAPTICS as it ends. With no rhythm running, sends STOP_HAPTICS directly.
    public func stopHaptics() async {
        if let running = rhythmTask {
            rhythmTask = nil
            running.cancel()
            await running.value
        } else {
            _ = try? await send(.stopHaptics())
        }
    }

    private func rhythmEnded(_ generation: Int) {
        if generation == rhythmGeneration {
            rhythmTask = nil
        }
    }

    private func stopAfterInterruption() async {
        guard enabled, linkOpen else { return }
        _ = try? await send(.stopHaptics())
    }

    private func requireReady() throws {
        guard enabled else { throw TierBError.disabled }
        guard state == .ready else { throw TierBError.notReady }
    }

    // MARK: Queue internals

    private func startDrainingIfNeeded() {
        guard !draining else { return }
        draining = true
        Task { await self.drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let job = queue.removeFirst()
            switch await execute(job.command) {
            case let .success(frame):
                job.continuation.resume(returning: frame)
            case let .failure(error):
                job.continuation.resume(throwing: error)
            }
        }
        draining = false
    }

    /// One command: up to `maxRetries` retries, each with a new seq byte and a fresh timeout.
    private func execute(_ command: BandCommand) async -> Result<Frame, TierBError> {
        var retries = 0
        while true {
            guard enabled else { return .failure(.disabled) }
            guard linkOpen else { return .failure(.notConnected) }
            let seq = nextSeq
            nextSeq &+= 1
            nextToken &+= 1
            let token = nextToken
            let frame = command.frame(seq: seq)

            let outcome: Result<Frame, TierBError> = await withCheckedContinuation { continuation in
                let timer = Task {
                    do {
                        try await self.clock.sleep(seconds: Self.responseTimeout)
                    } catch {
                        return
                    }
                    self.resolve(token, with: .failure(.timedOut))
                }
                waiter = Waiter(command: command.command, seq: seq, token: token, timer: timer, continuation: continuation)
                let writer = self.writer
                Task {
                    do {
                        try await writer.writeCommand(frame)
                    } catch {
                        self.resolve(token, with: .failure(.writeFailed))
                    }
                }
            }

            switch outcome {
            case .success:
                return outcome
            case .failure(.disabled), .failure(.notConnected):
                return outcome
            case .failure:
                retries += 1
                if retries > Self.maxRetries {
                    return outcome
                }
            }
        }
    }

    private func resolve(_ token: Int, with result: Result<Frame, TierBError>) {
        guard let current = waiter, current.token == token else { return }
        waiter = nil
        current.timer.cancel()
        current.continuation.resume(returning: result)
    }

    private func failPending(_ error: TierBError) {
        let jobs = queue
        queue.removeAll()
        for job in jobs {
            job.continuation.resume(throwing: error)
        }
        if let current = waiter {
            resolve(current.token, with: .failure(error))
        }
    }

    private func setState(_ new: TierBState) {
        guard new != state else { return }
        state = new
        emit(.tierB(new))
    }
}
