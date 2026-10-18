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

/// Tier B command queue, handshake, rate limits, rhythms, band alarm and the history-offload driver
/// (PLAN.md 5.3.4, 6.5, 7.2, 9.2, 9.5).
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
    /// The live HR stream is re-armed this often while the link is ready (NOOP's keep-alive).
    public static let realtimeRearmInterval: TimeInterval = 30
    /// The history offload is restarted this often while the link is ready (NOOP's backfill cadence).
    public static let historicalRedrainInterval: TimeInterval = 900

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
    /// Re-arms the strap's live HR stream while the link is ready (PLAN.md 7.2).
    private var realtimeTask: Task<Void, Never>?
    /// Drives the strap's history offload: decodes type-47 records and produces the write and stop
    /// effects (PLAN.md 5.3.4).
    private var offload: HistoricalOffloadHandler
    /// Records decoded since the current drain began; emitted with `.historical` when the drain stops.
    private var historicalRecords: [HistoricalRecord] = []
    /// Restarts the offload every `historicalRedrainInterval` while the link is ready.
    private var offloadCadenceTask: Task<Void, Never>?
    /// Sleeps until the active drain's quiet deadline, then fires `.quietElapsed` (PLAN.md 5.3.4).
    private var offloadWatchdog: Task<Void, Never>?
    /// The quiet deadline the watchdog is parked on, so a stale wake-up is ignored.
    private var offloadWatchdogDeadline: Date?

    public init(writer: any CommandWriter, clock: any TierBClock, enabled: Bool, emit: @escaping @Sendable (BandEvent) -> Void) {
        self.writer = writer
        self.clock = clock
        self.emit = emit
        self.enabled = enabled
        self.state = enabled ? .awaitingLink : .disabled
        self.offload = HistoricalOffloadHandler(clock: clock)
    }

    // MARK: Link and toggle

    /// The Tier B toggle. Turning it off drops queued and in-flight commands and stops any rhythm.
    /// It sends nothing; the transport unsubscribes the custom characteristics (PLAN.md 19 Phase 6).
    /// Enabling while `.unavailable` retries: setup reruns on the next connection (or on the live
    /// link when the transport rediscovers).
    public func setEnabled(_ on: Bool) {
        guard on != enabled || (on && state == .unavailable) else { return }
        BandLog.tierB(.info, "channel \(on ? "on" : "off") (was: \(state) enabled=\(enabled))")
        enabled = on
        handshakeStarted = false
        if on {
            setState(.awaitingLink)
        } else {
            // The transport tears down the custom link when the toggle goes off, so no link remains.
            linkOpen = false
            armedAlarm = nil
            realtimeTask?.cancel()
            realtimeTask = nil
            stopOffloadForLinkLoss()
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
        BandLog.tierB(.info, "link open; handshake begins")
        guard enabled, !handshakeStarted else { return }
        handshakeStarted = true
        setState(.handshaking)
        // SET_CLOCK (cmd 10) first, as a confirmed write with no reply awaited (PLAN.md 5.3.4): a
        // wrong-length SET_CLOCK is ACKed but not latched per community findings, and some firmware
        // never replies, so the write's GATT ack is the only confirmation. WHOOP 4 fw 41.17.x latches
        // ONLY the legacy 9-byte form (the 8-byte body is ignored outright and the RTC stays lost,
        // which stops the strap from banking history); newer firmware wants the 8-byte form — so both
        // go out with the same seconds (NOOP, hardware-verified; double-latching is harmless).
        // GET_HELLO mirrors the official app's per-link hello (NOOP, verified); GET_CLOCK reads the
        // RTC back (its reply confirms the link); GET_DATA_RANGE confirms the record range.
        var step = "SET_CLOCK"
        var helloReply: Frame?
        do {
            let unix = clock.now().timeIntervalSince1970.rounded(.down)
            if let unix = UInt32(exactly: unix) {
                try await writeConfirmedWithoutReply(.setClock(unix: unix))
                try await writeConfirmedWithoutReply(.setClockLegacy(unix: unix))
            } else {
                BandLog.tierB(.info, "SET_CLOCK skipped: the wall clock is outside the u32 range")
            }
            for command in [BandCommand.getHello(), BandCommand.getClock(), BandCommand.getDataRange()] {
                step = "\(command.command)"
                let reply = try await send(command)
                if command.command == .getHello {
                    helloReply = reply
                }
                if command.command == .getClock, reply.payload.count >= 6 {
                    // Reply: [resp_seq][result][u32 clock …]. Logged so the capture shows whether a
                    // SET_CLOCK form actually latched (a latched RTC reads back ≈ the seconds sent).
                    let p = reply.payload
                    let rtc = UInt32(p[2]) | (UInt32(p[3]) << 8) | (UInt32(p[4]) << 16) | (UInt32(p[5]) << 24)
                    BandLog.tierB(.info, "strap RTC reads back \(rtc) (SET_CLOCK sent \(unix))")
                }
            }
        } catch {
            guard enabled else { return }
            if linkOpen {
                let reason = "Handshake step \(step) failed: \(String(describing: error))"
                BandLog.tierB(.error, reason)
                emit(.tierBFailure(reason))
                setState(.unavailable)
            } else {
                handshakeStarted = false
                setState(.awaitingLink)
            }
            return
        }
        BandLog.tierB(.info, "handshake complete")
        guard enabled, linkOpen else { return }
        setState(.ready)
        if let helloReply {
            // Best-effort identity strings from the hello reply (PLAN.md 5.3.4). [Unverified]
            emit(.bandInfo(BandInfo.helloReply(helloReply.payload)))
        }
        await rearmNext()
        await refreshBattery()
        await rearmRealtime()
        startRealtime()
        await startDrain()
        startOffloadCadence()
    }

    /// The link dropped. Pending commands fail with `.notConnected`.
    public func connectionClosed() {
        linkOpen = false
        handshakeStarted = false
        armedAlarm = nil
        realtimeTask?.cancel()
        realtimeTask = nil
        stopOffloadForLinkLoss()
        failPending(.notConnected)
        BandLog.tierB(.info, "link closed (enabled=\(enabled), state=\(state))")
        // A failed setup stays `.unavailable` until the next connection opens.
        if enabled, state != .unavailable {
            setState(.awaitingLink)
        }
    }

    /// Setup failed on this link (for example, a missing characteristic). Nothing more is sent until the next connection.
    public func linkFailed() {
        linkOpen = false
        handshakeStarted = false
        realtimeTask?.cancel()
        realtimeTask = nil
        stopOffloadForLinkLoss()
        failPending(.notConnected)
        BandLog.tierB(.error, "link failed (enabled=\(enabled))")
        if enabled {
            setState(.unavailable)
        }
    }

    // MARK: Realtime heart rate

    /// Keeps re-arming the strap's live HR stream every `realtimeRearmInterval` while the link is
    /// ready, mirroring the official client's keep-alive (NOOP). The first arm happened in
    /// `connectionOpened` before this task started, so the loop sleeps first.
    private func startRealtime() {
        realtimeTask?.cancel()
        let clock = clock
        realtimeTask = Task {
            while !Task.isCancelled {
                try? await clock.sleep(seconds: Self.realtimeRearmInterval)
                await self.rearmRealtime()
            }
        }
    }

    private func rearmRealtime() async {
        guard enabled, state == .ready, linkOpen else { return }
        _ = try? await send(.toggleRealtimeHR(on: true))
    }

    // MARK: Historical offload (PLAN.md 5.3.4)

    /// Starts one history drain: writes SEND_HISTORICAL_DATA (cmd 22) as a fire-and-forget
    /// confirmed write and lets the strap stream its on-device history. A drain already running is
    /// left alone — restarting it would drop the records collected so far without emitting them.
    private func startDrain() async {
        guard enabled, state == .ready, linkOpen else { return }
        if case .draining = offload.phase { return }
        BandLog.tierB(.info, "starting historical offload")
        historicalRecords.removeAll()
        await runOffloadEffects(offload.start())
        scheduleQuietWatchdog()
    }

    /// Restarts the offload every `historicalRedrainInterval` while the link is ready, mirroring
    /// the realtime keep-alive's backfill cadence. Cancelled on toggle-off and link loss.
    private func startOffloadCadence() {
        offloadCadenceTask?.cancel()
        let clock = clock
        offloadCadenceTask = Task {
            while !Task.isCancelled {
                try? await clock.sleep(seconds: Self.historicalRedrainInterval)
                await self.startDrain()
            }
        }
    }

    /// Feeds one reassembled frame into the offload handler and performs its effects. The handler
    /// ignores frames that are neither HISTORICAL_DATA (type 47) nor METADATA (type 49), and
    /// ignores them while no drain is running.
    private func handleOffloadFrame(_ frame: Frame) async {
        guard case .draining = offload.phase else { return }
        // The handler only surfaces a record's time through its effects, so the record itself is
        // decoded here for the `.historical` event. A record is collected even when it stops the
        // drain (the live-edge rule), because it belongs to the finished batch.
        let record = try? HistoricalRecord.parse(frame)
        let effects = offload.handle(frame)
        if let record {
            historicalRecords.append(record)
        }
        await runOffloadEffects(effects)
        scheduleQuietWatchdog()
    }

    /// Performs the effects a state-machine event produced: the cmd 22/23 writes are fire-and-
    /// forget confirmed writes, and `.stop` ends the drain and emits what was decoded.
    private func runOffloadEffects(_ effects: [OffloadStateMachine.Effect]) async {
        for effect in effects {
            switch effect {
            case .sendHistoricalData:
                do {
                    try await writeConfirmedWithoutReply(.sendHistoricalData())
                } catch {
                    BandLog.tierB(.error, "SEND_HISTORICAL_DATA write failed: \(String(describing: error))")
                    // Without the write the strap streams nothing, so the drain is abandoned. A
                    // failing link also lands here via connectionClosed/linkFailed.
                    stopOffloadForLinkLoss()
                }
            case let .sendResult(token):
                do {
                    try await writeConfirmedWithoutReply(.historicalDataResult(token: token))
                    BandLog.tierB(.info, "acked batch, trim cursor \(Self.tokenValue(token)) (\(offload.recordCount) record(s) so far)")
                    // The strap permanently trims everything this ack covers, so the decoded records
                    // must be handed to the app NOW: holding the whole drain in memory until it stops
                    // would lose every acked record if the app died mid-drain. Repeated stores dedupe
                    // on (band_id, ts_ms).
                    flushRecords()
                } catch {
                    BandLog.tierB(.error, "HISTORICAL_DATA_RESULT write failed: \(String(describing: error))")
                }
            case .stop:
                finishDrain()
            }
        }
    }

    /// Parks the quiet watchdog on the drain's current quiet deadline (PLAN.md 5.3.4). Every record
    /// or metadata pushes the deadline out, so the watchdog is rescheduled on each deadline change.
    private func scheduleQuietWatchdog() {
        guard case .draining = offload.phase, let deadline = offload.quietDeadline else { return }
        guard deadline != offloadWatchdogDeadline else { return }
        offloadWatchdog?.cancel()
        offloadWatchdogDeadline = deadline
        let clock = clock
        let seconds = max(0, deadline.timeIntervalSince(clock.now()))
        offloadWatchdog = Task {
            try? await clock.sleep(seconds: seconds)
            await self.quietWatchdogElapsed(deadline)
        }
    }

    /// A watchdog wake-up. Only the fire parked on the current deadline acts; a stale one,
    /// superseded by a pushed deadline or already finished, is dropped.
    private func quietWatchdogElapsed(_ deadline: Date) async {
        guard offloadWatchdogDeadline == deadline else { return }
        offloadWatchdogDeadline = nil
        offloadWatchdog = nil
        await runOffloadEffects(offload.quietElapsed())
    }

    /// Ends the current drain and emits any records not yet flushed (PLAN.md 5.3.4). Records are
    /// flushed per acked batch (`runOffloadEffects`), so a finished drain normally has nothing left;
    /// a drain that stops between batches still emits its partial batch exactly once.
    private func finishDrain() {
        offloadWatchdog?.cancel()
        offloadWatchdog = nil
        offloadWatchdogDeadline = nil
        BandLog.tierB(.info, "historical offload ended (\(offload.phase)): \(offload.recordCount) record(s) total, \(historicalRecords.count) unflushed")
        flushRecords()
    }

    /// Hands the accumulated records to the app and clears the buffer. Called after each acked
    /// batch (the strap's trim point) and at drain end; a no-op when nothing is pending.
    private func flushRecords() {
        let records = historicalRecords
        guard !records.isEmpty else { return }
        historicalRecords = []
        emit(.historical(records))
    }

    /// Tears the offload down for a lost link: cancels the cadence and quiet watchdog and, if a
    /// drain was running, ends it and emits the records decoded so far (PLAN.md 5.3.4).
    private func stopOffloadForLinkLoss() {
        offloadCadenceTask?.cancel()
        offloadCadenceTask = nil
        offloadWatchdog?.cancel()
        offloadWatchdog = nil
        offloadWatchdogDeadline = nil
        for effect in offload.linkDropped() {
            if case .stop = effect {
                finishDrain()
            }
        }
    }

    /// Writes one command frame as a confirmed (with-response) GATT write and returns when the
    /// link ACKs it. Unlike `send`, no command response notification is awaited: SET_CLOCK,
    /// SEND_HISTORICAL_DATA and HISTORICAL_DATA_RESULT are ACKed by the link but do not reliably
    /// produce replies (PLAN.md 5.3.4).
    private func writeConfirmedWithoutReply(_ command: BandCommand) async throws {
        guard enabled else { throw TierBError.disabled }
        guard linkOpen else { throw TierBError.notConnected }
        let seq = nextSeq
        nextSeq &+= 1
        let frame = command.frame(seq: seq)
        BandLog.tierB(.debug, "send \(command.command) seq=\(seq) (no reply awaited) frame=\(hex(frame))")
        try await writer.writeCommand(frame)
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

    /// Feeds one reassembled frame from the band. Replies complete the in-flight command. Events
    /// are emitted. HISTORICAL_DATA (type 47) and METADATA (type 49) frames drive the history
    /// offload (PLAN.md 5.3.4).
    public func receive(_ frame: Frame) async {
        guard enabled, linkOpen else {
            BandLog.tierB(.debug, "frame dropped (enabled=\(enabled) linkOpen=\(linkOpen))")
            return
        }
        await handleOffloadFrame(frame)
        if frame.packetType == .commandResponse {
            guard let current = waiter else {
                BandLog.tierB(.debug, "reply for cmd \(frame.cmd) ignored: nothing in flight")
                return
            }
            guard frame.cmd == current.command.rawValue else {
                BandLog.tierB(.debug, "reply ignored: expected \(current.command) (op \(current.command.rawValue)), got cmd \(frame.cmd) seq=\(frame.seq)")
                return
            }
            guard frame.seq == current.seq || !seqEchoObserved else {
                BandLog.tierB(.debug, "stale reply seq=\(frame.seq) (waiting for seq=\(current.seq))")
                return
            }
            if frame.seq == current.seq {
                seqEchoObserved = true
            }
            BandLog.tierB(.info, "reply: cmd=\(frame.cmd) seq=\(frame.seq) payload=\(hex(frame.payload))")
            resolve(current.token, with: .success(frame))
        } else if frame.packetType == .realtimeData {
            // The strap's live HR stream (type 40, ~1 Hz), turned on by TOGGLE_REALTIME_HR.
            if let measurement = RealtimeHeartRate.parse(frame.payload) {
                BandLog.tierB(.debug, "realtime HR: \(measurement.bpm) bpm")
                emit(.hr(measurement, receivedAt: clock.now()))
            }
        } else if let kind = BandEventParser.parse(frame) {
            BandLog.tierB(.debug, "event: \(kind)")
            emit(.bandEvent(kind))
            if kind == .batteryLevel, let percent = BatteryEvent.percent(frame.payload) {
                // The battery EVENT carries a percent as well [Unverified]; the GET_BATTERY_LEVEL
                // reply already emitted it, but the event is the strap's own push.
                emit(.battery(percent))
            }
            if kind == .strapDrivenAlarmExecuted {
                // The band has fired the alarm it was given. Drop it and arm the next due one.
                if let fired = armedAlarm {
                    upcomingAlarms.removeAll { $0 <= fired }
                }
                armedAlarm = nil
                await rearmNext()
            }
        } else if frame.packetType == .realtimeRawData {
            // The accel/PPG raw flood (PLAN.md 5.3.4, 1.9 KB/s): never parsed, only surfaced so
            // the raw-data viewer can show it. The emit is cheap — no hex formatting here.
            BandLog.tierB(.debug, "realtime raw: \(frame.payload.count) payload bytes")
            emit(.rawFrame(frame, at: clock.now()))
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
        BandLog.tierB(.info, "arming band alarm for \(next)")
        if (try? await send(.setAlarmTime(unix: UInt32(unix)))) != nil {
            armedAlarm = next
        } else {
            BandLog.tierB(.error, "arming band alarm for \(next) failed")
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
        BandLog.tierB(.info, "rhythm start: \(rhythm.steps.count) step(s)")
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
            BandLog.tierB(.debug, "send \(command.command) seq=\(seq) attempt=\(retries + 1) frame=\(hex(frame))")

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
            case .success(let reply):
                return .success(reply)
            case .failure(.disabled), .failure(.notConnected):
                return outcome
            case .failure(let error):
                BandLog.tierB(.error, "\(command.command) attempt \(retries + 1) failed: \(error)")
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

    /// The 8-byte HISTORY_END token read as a u64 little-endian, for the log line. A short token
    /// (should not happen) still produces a value from the bytes it has.
    private static func tokenValue(_ bytes: [UInt8]) -> UInt64 {
        var value: UInt64 = 0
        for (index, byte) in bytes.enumerated() where index < 8 {
            value |= UInt64(byte) << (8 * UInt64(index))
        }
        return value
    }

    private func setState(_ new: TierBState) {
        guard new != state else { return }
        BandLog.tierB(.info, "state: \(state) → \(new)")
        state = new
        emit(.tierB(new))
    }
}

/// Best-effort battery percent from the payload of an EVENT (0x30) frame with event id 3
/// (PLAN.md 5.3.4). No capture pins the event payload's layout, so every shape tried here is
/// [Unverified]: the GET_BATTERY_LEVEL reply's `[counter][status][u16 LE / 10]`, a bare
/// `[u16 LE / 10]`, and a single percent byte. Nil when nothing plausible fits.
enum BatteryEvent {
    static func percent(_ payload: [UInt8]) -> Int? {
        if payload.count >= 4, let percent = clamp(raw: Double(u16(payload, 2)) / 10) { return percent }
        if payload.count >= 2, let percent = clamp(raw: Double(u16(payload, 0)) / 10) { return percent }
        if payload.count == 1, payload[0] <= 100 { return Int(payload[0]) }
        return nil
    }

    private static func u16(_ payload: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(payload[offset]) | (UInt16(payload[offset + 1]) << 8)
    }

    private static func clamp(raw: Double) -> Int? {
        guard raw >= 0, raw <= 100 else { return nil }
        return Int(raw.rounded())
    }
}
