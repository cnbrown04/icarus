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
    /// The BACKFILL POLICY floors (see `BackfillPolicy`) are the real gate; this constant survives as
    /// the base periodic interval for callers that reference it.
    public static let historicalRedrainInterval: TimeInterval = BackfillPolicy.periodicFloorSeconds

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
    /// Sleeps until the active drain's run-cap deadline (~60 s, NOOP's offload cap: slices a deep
    /// backlog so the link stays responsive to live HR), then fires `.runCapElapsed`.
    private var offloadRunCapTask: Task<Void, Never>?
    /// Wall time of the last kicked drain — the `BackfillPolicy` rate-limiter's `lastBackfillAt`.
    private var lastBackfillAt: Date?
    /// Consecutive completed drains that banked no records (the policy's empty-drain backoff
    /// input). A drain that kept at least one record resets it. Exposed read-only for diagnostics.
    public private(set) var emptyStreak = 0
    /// The strap's clock is untrusted (future-dated history or range) — automatic drains skip
    /// while true. Re-derived on every connection. Exposed read-only for diagnostics.
    public private(set) var clockUntrusted = false
    /// Records that passed the future gate this drain — the sentinel/summary tally.
    private var drainKeptRecords = 0
    /// Future-dated records dropped this drain (the record-timestamp gate tally).
    private var drainDroppedFutureRecords = 0
    /// Logged-once-per-drain flags for the two HISTORY_END diagnostics (NOOP logs each once per
    /// session, never per chunk).
    private var loggedNoCursorSentinel = false
    private var loggedFutureEndRTC = false
    /// Whether the handshake also sends SEND_R10_R11_REALTIME (0x3F) `[0x00]` to stop the raw
    /// accel/PPG flood. Default **false**: OpenStrap's hardware-verified reference never disables
    /// the stream (OpenStrap PROTOCOL.md §2–3; their 0x3F is documented as the *enable* verb, with
    /// the off form unverified), NOOP's R22Disable is a WHOOP 5/MG feature-flag system (opcode 120),
    /// not this command, and on this strap sending cmd 63 in the handshake (2026-10-18 17:33)
    /// coincided with a multi-hour window that left no banked history. Opt-in only until that is
    /// explained on hardware.
    public private(set) var handshakeDisablesRealtimeRawFlood = false

    public init(writer: any CommandWriter, clock: any TierBClock, enabled: Bool, emit: @escaping @Sendable (BandEvent) -> Void, handshakeDisablesRealtimeRawFlood: Bool = false) {
        self.writer = writer
        self.clock = clock
        self.emit = emit
        self.enabled = enabled
        self.state = enabled ? .awaitingLink : .disabled
        self.offload = HistoricalOffloadHandler(clock: clock)
        self.handshakeDisablesRealtimeRawFlood = handshakeDisablesRealtimeRawFlood
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
        // A fresh connection re-derives clock trust (the range/END checks below) and restarts the
        // empty-drain backoff — a reconnect is a genuine new chance, and a policy streak must
        // never starve a link that just came back.
        clockUntrusted = false
        emptyStreak = 0
        BandLog.tierB(.info, "link open; handshake begins")
        guard enabled, !handshakeStarted else { return }
        handshakeStarted = true
        setState(.handshaking)
        // Handshake order: hello first (OpenStrap's verified session init), then the clock
        // sequence — instrumented to answer THE banking question: NOOP found unclocked straps bank
        // no sensor history, and this strap banked only while connected overnight (2026-10-18/19).
        // GET_CLOCK runs BEFORE any SET_CLOCK and logs the RTC as the strap itself reports it:
        // ≈ wall clock = the RTC persisted across the disconnected period; an uptime-like counter
        // or a far-past value = the clock resets when idle, which would explain the missing
        // overnight records. NOOP's ClockPolicy decides the SET_CLOCK.
        var step = "GET_HELLO"
        var helloReply: Frame?
        do {
            let hello = try await send(BandCommand.getHello())
            helloReply = hello
            // NOOP's RTC-persistence probe: read the strap's clock BEFORE any SET_CLOCK. The reply
            // payload is [resp_seq, result, clock u32 LE] (bytes 2..6, little-endian).
            step = "GET_CLOCK"
            let preClock = try await send(BandCommand.getClock())
            let deviceClock = ClockPolicy.deviceClock(replyPayload: preClock.payload)
            let wallNow = Int(clock.now().timeIntervalSince1970.rounded(.down))
            if let deviceClock {
                let drift = wallNow - deviceClock
                BandLog.tierB(.info, "strap RTC before SET_CLOCK: \(deviceClock) (wall \(wallNow), drift \(drift)s)")
                if ClockPolicy.shouldSetClock(deviceClock: deviceClock, wallNow: wallNow) {
                    // SET_CLOCK (cmd 10), confirmed writes with no reply awaited (PLAN.md 5.3.4): a
                    // wrong-length SET_CLOCK is ACKed but not latched per community findings, and some
                    // firmware never replies, so the write's GATT ack is the only confirmation. WHOOP 4
                    // fw 41.17.x latches ONLY the legacy 9-byte form (the 8-byte body is ignored outright
                    // and the RTC stays lost, which stops the strap from banking history); newer firmware
                    // wants the 8-byte form — so both go out with the same seconds (NOOP,
                    // hardware-verified; double-latching is harmless).
                    step = "SET_CLOCK"
                    if let unix = UInt32(exactly: wallNow) {
                        try await writeConfirmedWithoutReply(.setClock(unix: unix))
                        try await writeConfirmedWithoutReply(.setClockLegacy(unix: unix))
                        BandLog.tierB(.info, "clock drifted \(drift)s — SET_CLOCK sent (both forms, \(unix))")
                    } else {
                        BandLog.tierB(.info, "SET_CLOCK skipped: the wall clock is outside the u32 range")
                    }
                } else {
                    BandLog.tierB(.info, "clock within threshold; not set")
                }
            } else {
                // NOOP never sets the clock without a decoded reading (its SET_CLOCK rides on the
                // clockRef correlation landing). The next connection retries GET_CLOCK.
                BandLog.tierB(.info, "GET_CLOCK reply carried no clock value — SET_CLOCK not sent this connection")
            }
            // Post read-back (always): logs both values, so the strap log shows the before/after pair —
            // the "before" reading is the RTC-persistence probe, the "after" one proves a set latched.
            let postClock = try await send(BandCommand.getClock())
            let postDeviceClock = ClockPolicy.deviceClock(replyPayload: postClock.payload)
            BandLog.tierB(.info, "strap RTC after SET_CLOCK: \(postDeviceClock.map(String.init) ?? "unreadable") (before: \(deviceClock.map(String.init) ?? "unreadable"))")
            // Disable the realtime-raw flood only when opted in (see the property's doc): OpenStrap
            // never sends it and the off form is unverified. Fire-and-forget confirmed write like
            // SET_CLOCK, so the handshake never hangs on a cmd-63 reply the firmware may not send.
            if handshakeDisablesRealtimeRawFlood {
                step = "SEND_R10_R11_REALTIME"
                try await writeConfirmedWithoutReply(.toggleRealtimeRaw(on: false))
                BandLog.tierB(.info, "realtime-raw flood disabled (cmd 63 [0x00])")
            }
            step = "GET_DATA_RANGE"
            _ = try await send(BandCommand.getDataRange())
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
        await runDrain(.connect)
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

    // MARK: Sync triggers (NOOP's requestSync / syncNow)

    /// The active drain's phase, for diagnostics and the app (a `.stopped` phase means the last
    /// drain ended; `.draining` means one is running).
    public var drainPhase: OffloadStateMachine.Phase { offload.phase }

    /// The app-facing sync entry point: the foreground (scenePhase .active) and manual ("Sync
    /// now") triggers are the app's to call. Both route through the same `BackfillPolicy` gate as
    /// every other trigger — `.manual` is un-floored, `.foreground` keeps NOOP's 90-s event floor.
    /// A no-op while the channel is off, the link is down, or a drain is already running.
    public func syncNow(trigger: BackfillTrigger) async {
        await runDrain(trigger)
    }

    // MARK: GET_DATA_RANGE (NOOP's #695 response processing)

    /// Decodes a GET_DATA_RANGE COMMAND_RESPONSE with NOOP's hardware-verified `DataRange`
    /// decoders and surfaces the range: the banked span (oldest…newest), the ring-buffer page
    /// backlog, and the future-dated-newest check that marks the strap clock untrusted (which
    /// pauses the automatic drains for this connection).
    private func handleDataRangeReply(_ frame: Frame) {
        // The timestamp decoders scan RAW frame bytes with the envelope's offsets: the oldest grid
        // is aligned from raw offset 7 — which is exactly where the payload starts — so the scan
        // domain is the payload itself, spliced out of the envelope. Feeding the FULL envelope
        // instead also scans the header and CRC-32: an empty/unreadable reply then has ONLY those
        // bytes to scan, and a header straddle word (0xAA + len `07 00` + crc8 `0x6B` →
        // 0x6B0007AA ≈ 1050 h ahead of the wall clock) latches as a future-dated "newest" and
        // wrongly marks a healthy strap's clock untrusted, pausing every automatic drain for the
        // connection. The payload slice carries exactly the strap-reported words.
        let raw = FrameCodec.reencode(frame)
        let payload = frame.payload
        let wallNow = Int(clock.now().timeIntervalSince1970)
        let newest = DataRange.newestUnix(from: payload, wallNowUnix: wallNow,
                                          futureSkewSeconds: BackfillPolicy.defaultFutureSkewSeconds)
        let oldest = DataRange.oldestUnix(from: payload)
        // pagesBehind's word offsets are anchored to the cmd byte's frame offset (6 on WHOOP 4.0),
        // so it keeps scanning the full envelope; a too-short reply is nil ("backlog unreadable").
        let pages = DataRange.pagesBehind(from: raw, cmdOff: 6) // WHOOP 4: the cmd byte sits at raw offset 6
        if let oldest, let newest {
            BandLog.tierB(.info, "data range: banked \(oldest)…\(newest) (\((newest - oldest) / 86_400) day(s)), \(pages.map { "\($0) pages behind" } ?? "backlog unreadable")")
        } else if let newest {
            BandLog.tierB(.info, "data range: newest \(newest), oldest unreadable, \(pages.map { "\($0) pages behind" } ?? "backlog unreadable")")
        } else {
            BandLog.tierB(.info, "data range: no plausible timestamps decoded, \(pages.map { "\($0) pages behind" } ?? "backlog unreadable")")
        }
        // The corruption check uses the any-scan: a corrupt future-dated newest is excluded from
        // `newestUnix`'s preferred result, which lets a plausible straddle word mask it.
        let newestAny = DataRange.newestAnyUnix(from: payload)
        if BackfillPolicy.isFutureDatedNewest(newestAny ?? newest, wallNowUnix: wallNow), let newestAny {
            if !clockUntrusted {
                BandLog.tierB(.info, "data range: \(BackfillDiagnostics.futureDatedNewestLine(newest: newestAny, wallNowUnix: wallNow))")
            }
            clockUntrusted = true
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

    // MARK: Realtime-raw flood (PLAN.md 7.2 step 4)

    /// Sets the handshake flood policy for this and future connections. No write goes out; the
    /// next handshake applies it. For an immediate effect on the current link use
    /// `setRealtimeRawFlood(enabled:)`.
    public func setHandshakeRealtimeRawFloodDisabled(_ disabled: Bool) {
        handshakeDisablesRealtimeRawFlood = disabled
    }

    /// Re-enables or disables the strap's realtime-raw flood at runtime: REALTIME_RAW_DATA (type
    /// 0x2B) raw accel/PPG samples, ~1.9 KB/s (whoop-parity §3.4). The handshake already disables
    /// the stream on every connection; this is the on-demand path, e.g. to record raw data for one
    /// session and turn it off again. Unlike `send`, the write goes out directly as a
    /// fire-and-forget confirmed write (like SET_CLOCK), so it is never blocked behind the
    /// one-command-at-a-time queue's in-flight command — a history drain or a timed-out command
    /// cannot hold it back. Throws `.disabled` when the channel is off and `.notConnected` when the
    /// link is down. Does not touch the plain realtime HR stream (type 0x28, cmd 3).
    public func setRealtimeRawFlood(enabled: Bool) async throws {
        try await writeConfirmedWithoutReply(.toggleRealtimeRaw(on: enabled))
        BandLog.tierB(.info, "realtime-raw flood \(enabled ? "on" : "off") (cmd 63 [\(enabled ? "01" : "00")])")
    }

    // MARK: Historical offload (PLAN.md 5.3.4)

    // MARK: Historical offload (PLAN.md 5.3.4, NOOP's backfill state machine)

    /// Starts one history drain after the `BackfillPolicy` rate-limiter passes: the single gated
    /// entry point for every kick (NOOP's `requestSync`). A drain already running is left alone —
    /// restarting it would drop the records collected so far without emitting them. Returns false
    /// when the gate or the policy denied the kick (logged, NOOP's "skipped (rate-limited)" line).
    @discardableResult
    private func runDrain(_ trigger: BackfillTrigger) async -> Bool {
        guard enabled, state == .ready, linkOpen else { return false }
        if case .draining = offload.phase { return false }
        let now = clock.now()
        guard BackfillPolicy.shouldRun(
            trigger: trigger,
            now: now.timeIntervalSince1970,
            lastBackfillAt: lastBackfillAt?.timeIntervalSince1970,
            emptyStreak: emptyStreak,
            clockUntrusted: clockUntrusted)
        else {
            let last = lastBackfillAt.map { Int(now.timeIntervalSince($0)) } ?? -1
            BandLog.tierB(.info, "drain \(trigger) skipped (rate-limited; last drain \(last)s ago, emptyStreak \(emptyStreak), clockUntrusted \(clockUntrusted))")
            return false
        }
        BandLog.tierB(.info, "starting historical offload (\(trigger))")
        lastBackfillAt = now
        drainKeptRecords = 0
        drainDroppedFutureRecords = 0
        loggedNoCursorSentinel = false
        loggedFutureEndRTC = false
        historicalRecords.removeAll()
        await runOffloadEffects(offload.start())
        scheduleQuietWatchdog()
        scheduleRunCapWatchdog()
        return true
    }

    /// Re-kicks the offload on NOOP's `BackfillPolicy` cadence while the link is ready: the loop
    /// sleeps until the earliest instant a `.periodic` trigger would pass the policy (15-min floor,
    /// stretched by the empty-drain backoff), then routes through the same gated `runDrain` as
    /// every other trigger. Cancelled on toggle-off and link loss.
    private func startOffloadCadence() {
        offloadCadenceTask?.cancel()
        let clock = clock
        offloadCadenceTask = Task {
            while !Task.isCancelled {
                try? await clock.sleep(seconds: periodicCadenceDelay())
                await self.runDrain(.periodic)
            }
        }
    }

    /// How long the periodic cadence should sleep before its next attempt: the time still owed on
    /// the policy's periodic floor (multiplied out by the empty-drain backoff), at least 1 s so a
    /// denied attempt can never busy-loop. While the strap clock is untrusted the policy denies
    /// `.periodic` entirely, so the loop settles into a cheap re-check every minute.
    private func periodicCadenceDelay() -> Double {
        guard !clockUntrusted else { return 60 }
        let now = clock.now().timeIntervalSince1970
        guard let last = lastBackfillAt else { return 1 }
        let floor = BackfillPolicy.periodicFloorSeconds * BackfillPolicy.backoffMultiplier(emptyStreak: emptyStreak)
        return max(1, floor - (now - last.timeIntervalSince1970))
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
            // Record-timestamp gate (NOOP's implausible-timestamp handling): a record whose own
            // unix is implausibly far in the FUTURE is a corrupt-RTC strap — drop it BEFORE it can
            // pollute the store, with a one-line log (the total is surfaced at drain end).
            let wallNow = Int(clock.now().timeIntervalSince1970)
            if BackfillDiagnostics.isCorruptFutureRtc(unix: Int(record.unixSeconds), wallNowUnix: wallNow) {
                drainDroppedFutureRecords += 1
                BandLog.tierB(.info, "history drain: \(BackfillDiagnostics.futureRecordDroppedLine(unix: Int(record.unixSeconds), wallNowUnix: wallNow))")
                if !clockUntrusted {
                    clockUntrusted = true
                    BandLog.tierB(.info, "history drain: the strap's clock is untrusted — automatic re-drains pause until the next connection")
                }
            } else {
                drainKeptRecords += 1
                historicalRecords.append(record)
            }
        }
        if frame.packetType == .metadata, frame.cmd == 2 {
            noteEndMarker(frame)
        }
        await runOffloadEffects(effects)
        scheduleQuietWatchdog()
    }

    /// HISTORY_END diagnostics (NOOP's Backfiller, ported): the corrupt future-RTC guard on the
    /// END's own timestamp, and the trim=0xFFFFFFFF "no valid flash cursor" sentinel — whose
    /// meaning depends on whether this drain already kept rows. Each logs once per drain.
    private func noteEndMarker(_ frame: Frame) {
        let payload = frame.payload
        let trim = HistoricalMetadata.trimCursor(fromPayload: payload)
        let wallNow = Int(clock.now().timeIntervalSince1970)
        // 0xFFFFFFFF is the sentinel, not a date — the future check skips it.
        if let trim, trim != 0xFFFFFFFF, let endUnix = HistoricalMetadata.endUnix(fromPayload: payload),
           BackfillDiagnostics.isCorruptFutureRtc(unix: Int(endUnix), wallNowUnix: wallNow),
           !loggedFutureEndRTC {
            loggedFutureEndRTC = true
            clockUntrusted = true
            BandLog.tierB(.info, "history drain: \(BackfillDiagnostics.futureRtcLine(unix: Int(endUnix), wallNowUnix: wallNow))")
        }
        if let trim, trim == 0xFFFFFFFF, !loggedNoCursorSentinel {
            loggedNoCursorSentinel = true
            BandLog.tierB(.info, "history drain: \(BackfillDiagnostics.noCursorLine(rowsKept: drainKeptRecords))")
        }
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

    /// Parks the run-cap watchdog on the drain's ~60 s bound (NOOP's offload cap: a deep backlog
    /// drains in bounded slices so the link stays responsive to live HR). One park per drain.
    private func scheduleRunCapWatchdog() {
        offloadRunCapTask?.cancel()
        guard case .draining = offload.phase, offload.runCapDeadline != nil else { return }
        let clock = clock
        offloadRunCapTask = Task {
            try? await clock.sleep(seconds: OffloadStateMachine.runCap)
            await self.runCapElapsed()
        }
    }

    /// A run-cap wake-up. Stale ones (the drain already ended, or no cap is parked) are dropped —
    /// the machine re-checks its own deadline too.
    private func runCapElapsed() async {
        guard case .draining = offload.phase else { return }
        await runOffloadEffects(offload.runCapElapsed())
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
        offloadRunCapTask?.cancel()
        offloadRunCapTask = nil
        // The BackfillPolicy empty-drain backoff input: a drain that banked nothing stretches the
        // automatic floors; the first kept record resets the streak (NOOP's EmptySyncTracker /
        // consecutiveEmptyOffloads idiom).
        if drainKeptRecords == 0 {
            emptyStreak += 1
        } else {
            emptyStreak = 0
        }
        let dropped = drainDroppedFutureRecords
        BandLog.tierB(.info, "historical offload ended (\(offload.phase)): \(offload.recordCount) record(s) total, \(historicalRecords.count) unflushed"
            + (dropped > 0 ? ", \(dropped) future-dated record(s) dropped" : ""))
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

    /// Tears the offload down for a lost link: cancels the cadence, quiet and run-cap watchdogs
    /// and, if a drain was running, ends it and emits the records decoded so far (PLAN.md 5.3.4).
    private func stopOffloadForLinkLoss() {
        offloadCadenceTask?.cancel()
        offloadCadenceTask = nil
        offloadWatchdog?.cancel()
        offloadWatchdog = nil
        offloadWatchdogDeadline = nil
        offloadRunCapTask?.cancel()
        offloadRunCapTask = nil
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
            if frame.cmd == SafeCommand.getDataRange.rawValue {
                handleDataRangeReply(frame)
            }
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
            if frame.cmd == 96 {
                // HIGH_FREQ_SYNC_PROMPT (NOOP event 96): the strap's flash is filling and it asks
                // for a sync — route through the same gated entry as every other trigger, so the
                // policy's `.strap` floor (and the clock-untrusted skip) still applies.
                await runDrain(.strap)
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
