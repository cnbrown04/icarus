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

/// Outcome of the GET_ALARM_TIME read-back that follows each band alarm arming (whoop-parity §3.11).
public enum AlarmReadBack: Sendable, Equatable {
    /// The strap's reply carries the armed unix time.
    case matched
    /// The reply came back but does not carry the armed time. The raw payload is logged.
    case mismatched
    /// No reply, or the read-back was refused (disabled, not connected).
    case noReply
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
/// Durably stores one batch of drained records; true when they are safely written.
public typealias HistoricalSink = @Sendable ([HistoricalRecord]) async -> Bool

public actor TierBController {
    /// PLAN.md 7.2: 5 s timeout per attempt, at most 3 retries.
    public static let responseTimeout: Double = 5
    public static let maxRetries = 3
    /// PLAN.md 6.5: battery at most every 10 min.
    public static let batteryInterval: TimeInterval = 600
    /// The live HR stream is re-armed this often while the link is ready (NOOP's keep-alive).
    public static let realtimeRearmInterval: TimeInterval = 30
    /// LINK_VALID (cmd 1) keep-alive cadence while the link is ready (whoop-parity §3.8). [Unverified]:
    /// 30 s is the starting point, the same as the realtime re-arm; measure on hardware.
    public static let linkValidInterval: TimeInterval = 30
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
    /// Sends LINK_VALID (cmd 1) every `linkValidInterval` while `.ready`. Cancelled wherever the realtime
    /// task is, so the keep-alive never runs with the channel off or the link down.
    private var linkTask: Task<Void, Never>?
    /// Consecutive LINK_VALID writes that failed. Counted and logged only: no reconnect is forced yet.
    public private(set) var linkValidFailures = 0
    /// When the last LINK_VALID write was confirmed by the link on this connection, for the Device screen.
    public private(set) var lastLinkValidAt: Date?
    /// The last GET_ALARM_TIME read-back after arming: whether the strap's reply matched the armed time.
    /// Nil until the first arming on this connection reads back. [Unverified] reply offset (see `rearmNext`).
    public private(set) var lastAlarmReadBack: AlarmReadBack?
    /// Drives the strap's history offload: decodes type-47 records and produces the write and stop
    /// effects (PLAN.md 5.3.4).
    private var offload: HistoricalOffloadHandler
    /// Records decoded since the current drain began; emitted with `.historical` when the drain stops.
    private var historicalRecords: [HistoricalRecord] = []
    /// Durable store for drained records, awaited BEFORE each batch's ack (`setHistoricalSink`).
    private var historicalSink: HistoricalSink?
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
    /// Records kept across every completed drain since the link opened, for the live UI total.
    private var sessionKeptRecords = 0
    /// Future-dated records dropped this drain (the record-timestamp gate tally).
    private var drainDroppedFutureRecords = 0
    /// When the last `.drainProgress` event went out. Acks are throttled to about 2/s; drain
    /// start and end always emit, so the last count is never lost.
    private var lastDrainProgressAt: Date?
    /// Minimum spacing between the throttled `.drainProgress` emissions.
    private static let drainProgressMinInterval: TimeInterval = 0.5
    /// The decoded ring-buffer state of the strap's GET_DATA_RANGE reply (NOOP's DataRange words):
    /// write pointer, persistent read pointer, ring capacity, and the page backlog. Set from every
    /// decoded GET_DATA_RANGE reply (the handshake's and `drainFullHistory`'s); nil until the first
    /// readable reply. The app reads it for diagnostics and the full-history restore reads it to
    /// compute the rewind target.
    public private(set) var ringState: RingState?
    /// One-line state of the last (or running) full-history restore, for the app's UI.
    public private(set) var fullHistorySummary: String?
    /// Oldest and newest record times kept by the running restore, and by its current pass. Fed by
    /// `handleOffloadFrame`; reset at the restore's start and at each pass's start.
    private var restoreSpan = RecordSpan()
    private var phaseSpan = RecordSpan()
    /// Waiters resumed when the running drain ends (`drainFullHistory` parks here between the
    /// back-to-back kicks).
    private var drainEndWaiters: [CheckedContinuation<Void, Never>] = []
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
            stopLinkKeepAlive()
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
        sessionKeptRecords = 0
        lastDrainProgressAt = nil
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
        startLinkKeepAlive()
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
        stopLinkKeepAlive()
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
        stopLinkKeepAlive()
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

    // MARK: Full-history restore (OpenStrap §4.3: drain the entire stored history)

    /// Runaway guard for `drainFullHistory`: the most back-to-back drains one restore may kick,
    /// shared by both passes. Each drain is already bounded by the ~60 s run cap, so the cap only
    /// stops a pathological loop. A full ring is 131072 pages × ~9 records ≈ 1.2 M records (13.6 days,
    /// 2026-10-30 finding); drains keep ~5–7k records each, so a whole ring needs ~200–240 drains
    /// (~3–4 h connected).
    public static let maxFullHistoryDrains = 320
    /// How far past the write pointer the restore starts (pages). The strap fills a page about every
    /// 9 s, overwriting the oldest one, so starting at W itself would race the overwrite; the margin skips
    /// the oldest ~18 minutes, and the restore reads ~10 pages/s, far outrunning the writer.
    public static let restoreMarginSlots = 120

    /// Positions the strap's persistent read cursor (SET_READ_POINTER, cmd 33). OpenStrap §4.3:
    /// the cursor survives connections and acks, and repositioning it makes the strap re-stream
    /// history it already drained — the mechanism behind the app-deleted restore.
    ///
    /// The write goes out as a confirmed (with-response) GATT write without awaiting a command
    /// response: OpenStrap's reference client sends every command that way
    /// (`research_playground.py:send` — a `write_gatt_char(response=True)` and move on), and no
    /// capture shows a cmd-33 COMMAND_RESPONSE. Whether some firmware echoes one is
    /// [Unverified]; a reply, if it ever comes, is ignored like any other unsolicited response.
    public func rewindReadPointer(to offset: UInt32) async throws {
        try await writeConfirmedWithoutReply(.setReadPointer(offset: offset))
        BandLog.tierB(.info, "read pointer set to \(offset) (cmd 33, no reply awaited)")
    }

    /// Pages the read-pointer probe rewinds by: ~9 records a page, so about 10 minutes of history,
    /// which the probe's drain re-reads and the store dedupes.
    public static let probeRewindPages = 64

    /// The strap's cursor words from one GET_DATA_RANGE: the ring (W, U, T) and the read cursor.
    private func readCursorState() async throws -> (ring: RingState, cursor: Int)? {
        let raw = FrameCodec.reencode(try await send(BandCommand.getDataRange()))
        guard let ring = DataRange.ringState(from: raw, cmdOff: 6),
              let cursor = DataRange.readCursor(from: raw, cmdOff: 6) else { return nil }
        ringState = ring
        return (ring, cursor)
    }

    /// Hardware check of SET_READ_POINTER now that commands are padded (`FrameCodec.encodeCommand`): ends the
    /// transmit session (ABORT_HISTORICAL_TRANSMITS), aims the read cursor `probeRewindPages` behind U, reads
    /// the cursor words back, then runs ONE drain and
    /// reports where it really started (its oldest record). Every step is logged as `read-pointer probe`.
    /// The returned line is for the Debug screen. Never runs during a drain.
    public func probeReadPointer() async -> String {
        guard enabled, state == .ready, linkOpen else { return "probe skipped: the channel is not ready" }
        if case .draining = offload.phase { return "probe skipped: a drain is running, try again in a minute" }
        do {
            guard let before = try await readCursorState() else { return "probe aborted: ring state unreadable" }
            guard before.ring.read >= Self.probeRewindPages else { return "probe skipped: U too close to 0" }
            let target = before.ring.read - Self.probeRewindPages
            BandLog.tierB(.info, "read-pointer probe: before cursor=\(before.cursor) W=\(before.ring.write) U=\(before.ring.read), target \(target)")
            // 2026-10-30, second probe: the padded rewind moved the cursor word, but the next drain still
            // streamed from the old place. End the strap's transmit session first, so a cached session
            // position cannot outlive the rewind (OpenStrap's client aborts whenever a sync goes idle).
            try await writeConfirmedWithoutReply(.abortHistoricalTransmits())
            if let aborted = try await readCursorState() {
                BandLog.tierB(.info, "read-pointer probe: after abort cursor=\(aborted.cursor) W=\(aborted.ring.write) U=\(aborted.ring.read)")
            }
            // No settle delay: the strap handles commands in order, so the GET_DATA_RANGE below is answered
            // after the cmd-33 write (2026-10-30 log: the cmd-33 response precedes the next range reply).
            try await rewindReadPointer(to: UInt32(target))
            guard let after = try await readCursorState() else { return "probe aborted: ring state unreadable after the write" }
            BandLog.tierB(.info, "read-pointer probe: after cursor=\(after.cursor) W=\(after.ring.write) U=\(after.ring.read)")
            restoreSpan = RecordSpan()
            guard await runDrain(.manual) else { return "probe: cursor \(before.cursor)→\(after.cursor); the drain could not start" }
            await waitForDrainEnd()
            let kept = drainKeptRecords
            let span = restoreSpan.rangeText ?? "no records"
            let line = "probe: cursor \(before.cursor)→\(after.cursor) (target \(target)), U \(before.ring.read)→\(after.ring.read); drain kept \(kept): \(span)"
            BandLog.tierB(.info, "read-pointer probe result: \(line)")
            return line
        } catch {
            return "probe aborted: \(String(describing: error))"
        }
    }

    /// Re-reads the strap's ENTIRE stored history: the app-deleted restore. After the app's
    /// database is wiped, the strap's persistent read cursor still sits at the last-acked batch,
    /// so a plain connect would only re-read what came after it. The flash is a ring
    /// (`DataRange.ringState`): once the write pointer W has wrapped, the OLDEST surviving data
    /// sits at W, not at slot 0, so a rewind to 0 skips it. The restore therefore runs two passes:
    ///
    /// 1. Rewind to `W + restoreMarginSlots` (mod T) and drain back to back until the live edge.
    ///    That reads the ring oldest-first, around the wrap, up to W. The margin skips the oldest
    ///    slots, which the strap overwrites about once a second while the restore runs.
    /// 2. Only when pass 1 stopped on an empty drain or HISTORY_COMPLETE short of the live edge
    ///    (a strap that never wrapped, or never wraps its cursor at T − 1), rewind to 0 and drain
    ///    from the ring start.
    ///
    /// Both passes share `maxFullHistoryDrains`. Each drain's ~60 s run cap slices the work, so even
    /// a full ~13.6-day ring (131072 pages) drains in bounded slices. Never throws: every failure is
    /// logged and leaves the normal drain machinery intact.
    public func drainFullHistory() async {
        guard enabled, state == .ready, linkOpen else {
            fullHistorySummary = "restore skipped: the channel is off or the link is not ready"
            BandLog.tierB(.info, "full-history restore skipped: the channel is off or the link is not ready")
            return
        }
        fullHistorySummary = "draining…"
        BandLog.tierB(.info, "full-history restore begins")
        do {
            // The connect trigger kicks its own drain as soon as Tier B goes ready, so an
            // auto-restore (or a manual tap) can land while that drain is still running. Waiting
            // it out keeps the restore's first kick from being denied and reported as "0 drains".
            while case .draining = offload.phase {
                await waitForDrainEnd()
            }
            guard enabled, state == .ready, linkOpen else {
                fullHistorySummary = "restore aborted: the link closed before the restore started"
                BandLog.tierB(.error, "full-history restore aborted: the link closed before the restore started")
                return
            }
            // The reply's ring state is ALSO decoded into `ringState` by `handleDataRangeReply`
            // when the notification lands; decoding the resolved frame here keeps the rewind
            // decision independent of that event's ordering.
            let rangeFrame = try await send(BandCommand.getDataRange())
            guard let ring = DataRange.ringState(from: FrameCodec.reencode(rangeFrame), cmdOff: 6) else {
                fullHistorySummary = "restore aborted: the band's ring state is unreadable"
                BandLog.tierB(.error, "full-history restore aborted: the GET_DATA_RANGE reply's ring state is unreadable")
                return
            }
            ringState = ring
            restoreSpan = RecordSpan()

            let phase1Start = (ring.write + Self.restoreMarginSlots) % ring.capacity
            guard await seekForRestore(phase1Start, from: ring.read) else { return }
            phaseSpan = RecordSpan()
            let first = await runFullHistoryPass(budget: Self.maxFullHistoryDrains)
            logRestorePhase(1, start: phase1Start, pass: first)

            var last = first
            var drains = first.drains
            var kept = first.kept
            if first.stop == .emptyDrain || first.stop == .historyComplete {
                guard await seekForRestore(0, from: nil) else { return }
                phaseSpan = RecordSpan()
                BandLog.tierB(.info, "full-history restore phase 2: pass 1 ended short of the live edge, draining from the ring start")
                let second = await runFullHistoryPass(budget: Self.maxFullHistoryDrains - first.drains)
                logRestorePhase(2, start: 0, pass: second)
                last = second
                drains += second.drains
                kept += second.kept
            }

            if last.stop == .denied {
                fullHistorySummary = "restore stopped: the next drain could not start"
            } else if drains == 0 {
                fullHistorySummary = "restore stopped: the link closed before the first drain"
            } else if last.stop == .cap {
                fullHistorySummary = "restore hit the \(Self.maxFullHistoryDrains)-drain cap"
                BandLog.tierB(.error, "full-history restore hit the \(Self.maxFullHistoryDrains)-drain cap")
            } else {
                let span = restoreSpan.summaryText.map { ", \($0)" } ?? ""
                fullHistorySummary = "finished: \(drains) drain(s), \(kept.formatted()) record(s)\(span)"
                BandLog.tierB(.info, "full-history restore finished: \(drains) drain(s), \(kept) record(s)\(span)")
            }
        } catch {
            // `send` failures land here (disabled / notConnected / timedOut after retries).
            fullHistorySummary = "restore aborted: \(String(describing: error))"
            BandLog.tierB(.error, "full-history restore aborted: \(String(describing: error))")
        }
    }

    /// Positions the read cursor for one restore pass, then READS IT BACK: until 2026-10-30 every restore's
    /// rewind was silently discarded (unpadded frame) and the restore reported success anyway. Returns false
    /// — and the restore ends with a summary saying so — when the write failed or the strap's read cursor
    /// did not land on `target`. Skips the write when the cursor is known to be at `target` already.
    private func seekForRestore(_ target: Int, from current: Int?) async -> Bool {
        if let current, current == target { return true }
        let message = current.map { "rewinding read cursor \($0)→\(target)" } ?? "rewinding read cursor to \(target)"
        BandLog.tierB(.info, "\(message)")
        do {
            // No settle delay: the strap handles commands in order, so the GET_DATA_RANGE below is answered
            // after the cmd-33 write (2026-10-30 log: the cmd-33 response precedes the next range reply).
            try await rewindReadPointer(to: UInt32(target))
            guard let after = try await readCursorState() else {
                fullHistorySummary = "restore aborted: could not read the cursor back"
                BandLog.tierB(.error, "full-history restore aborted: GET_DATA_RANGE unreadable after the rewind")
                return false
            }
            guard after.cursor == target || after.ring.read == target else {
                fullHistorySummary = "restore aborted: the band ignored the rewind (cursor \(after.cursor), wanted \(target))"
                BandLog.tierB(.error, "full-history restore aborted: read cursor \(after.cursor) / U \(after.ring.read) after rewinding to \(target)")
                return false
            }
            BandLog.tierB(.info, "read cursor confirmed at \(after.cursor) (U \(after.ring.read))")
            return true
        } catch {
            fullHistorySummary = "restore aborted: the read-cursor rewind failed"
            BandLog.tierB(.error, "full-history restore aborted: the SET_READ_POINTER write failed (\(String(describing: error)))")
            return false
        }
    }

    /// One pass of NOOP's `.autoContinue` flow: back-to-back drains, un-floored. The pass's own stop
    /// conditions and `budget` are the runaway protection. `runDrain`'s quiet and run-cap watchdogs
    /// bound each slice, and the acked batches flush as they always do.
    private func runFullHistoryPass(budget: Int) async -> RestorePass {
        var pass = RestorePass()
        while pass.drains < budget {
            // A periodic or strap-triggered drain can win the actor race between slices; wait
            // for it and retry rather than treating the restore as denied.
            while case .draining = offload.phase {
                await waitForDrainEnd()
            }
            guard enabled, state == .ready, linkOpen else {
                pass.stop = .linkLost
                break
            }
            guard await runDrain(.autoContinue) else {
                if case .draining = offload.phase { continue }
                pass.stop = .denied
                BandLog.tierB(.info, "full-history restore: the next drain was denied — stopping")
                break
            }
            pass.drains += 1
            await waitForDrainEnd()
            // Read the tally and the stop reason in one actor turn (no await between them, so
            // another drain cannot start and reset the counters in between).
            let kept = drainKeptRecords
            let phase = offload.phase
            pass.kept += kept
            if kept == 0 {
                pass.stop = .emptyDrain
                BandLog.tierB(.info, "full-history restore: the last drain completed empty — stopping")
                break
            }
            if case .stopped(.drainCompleted) = phase {
                pass.stop = .historyComplete
                BandLog.tierB(.info, "full-history restore: HISTORY_COMPLETE after \(pass.kept) record(s) — stopping")
                break
            }
            if case .stopped(.reachedLiveEdge) = phase {
                pass.stop = .liveEdge
                BandLog.tierB(.info, "full-history restore: caught up to the live edge after \(pass.kept) record(s) — stopping")
                break
            }
        }
        pass.stop = pass.stop ?? .cap
        return pass
    }

    /// One line per restore pass: where it started, what it kept, and the span of those records.
    private func logRestorePhase(_ number: Int, start: Int, pass: RestorePass) {
        let range = phaseSpan.rangeText.map { ", \($0)" } ?? ""
        BandLog.tierB(.info, "full-history restore phase \(number) from slot \(start): \(pass.drains) drain(s), \(phaseSpan.count) record(s) kept\(range), stopped on \(pass.stop.map { "\($0)" } ?? "none")")
    }

    /// Resumes when the running drain ends (its `.stop` effect ran `finishDrain`). A drain that
    /// already ended resumes immediately, so a drain finishing between the kick and this call
    /// cannot hang the restore loop.
    private func waitForDrainEnd() async {
        if case .draining = offload.phase {} else { return }
        await withCheckedContinuation { continuation in
            drainEndWaiters.append(continuation)
        }
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
        let ring = DataRange.ringState(from: raw, cmdOff: 6) // WHOOP 4: the cmd byte sits at raw offset 6
        ringState = ring
        let pages = ring?.pagesBehind
        if let oldest, let newest {
            BandLog.tierB(.info, "data range: banked \(oldest)…\(newest) (\((newest - oldest) / 86_400) day(s)), \(pages.map { "\($0) pages behind" } ?? "backlog unreadable")")
        } else if let newest {
            BandLog.tierB(.info, "data range: newest \(newest), oldest unreadable, \(pages.map { "\($0) pages behind" } ?? "backlog unreadable")")
        } else {
            BandLog.tierB(.info, "data range: no plausible timestamps decoded, \(pages.map { "\($0) pages behind" } ?? "backlog unreadable")")
        }
        // The corruption check uses NOOP's `newestUnix` semantics exactly: it prefers the newest
        // word that is NOT implausibly future, so a healthy strap's real (past) newest dominates
        // any garbage/straddle words near the window ceiling. A genuinely future-dated strap
        // (whose whole bank is future-dated) has no not-future word, so the any-scan fallback
        // inside `newestUnix` surfaces the future word and the guard fires (NOOP #928/#1012).
        // Checking the any-scan directly instead would latch `clockUntrusted` on HEALTHY straps
        // whenever a reply carries a garbage word under the ceiling (observed live 2026-10-19:
        // 26001h "ahead", pausing every automatic drain for the whole connection).
        if BackfillPolicy.isFutureDatedNewest(newest, wallNowUnix: wallNow), let newest {
            if !clockUntrusted {
                BandLog.tierB(.info, "data range: \(BackfillDiagnostics.futureDatedNewestLine(newest: newest, wallNowUnix: wallNow))")
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

    /// Re-arms the live HR stream with a write that does not wait for a reply, as NOOP's keep-alive does.
    /// Routing it through `send` was the stall: the strap does not reliably answer TOGGLE_REALTIME_HR while a
    /// history drain streams (device log 2026-10-23: 15 `toggleRealtimeHR attempt N failed: timedOut`, every
    /// one during a drain). Each missed reply became a 5 s wait, retried up to 3 times, and held the
    /// one-at-a-time command queue, so other commands queued behind a re-arm nobody was waiting for. An
    /// unmatched reply is only logged, and the realtime HR frames keep arriving on their own.
    private func rearmRealtime() async {
        guard enabled, state == .ready, linkOpen else { return }
        try? await writeConfirmedWithoutReply(.toggleRealtimeHR(on: true))
    }

    // MARK: Link keep-alive (LINK_VALID, cmd 1; whoop-parity §3.8)

    /// Starts the LINK_VALID loop for this connection. [Unverified] layout and cadence: NOOP sends
    /// cmd 1 while connected; nothing on hardware confirms the reply behaviour, so failures are only
    /// counted and logged. The loop runs in its own task, like the realtime re-arm, and never takes
    /// a slot in the one-at-a-time command queue.
    private func startLinkKeepAlive() {
        linkTask?.cancel()
        linkValidFailures = 0
        lastLinkValidAt = nil
        let clock = clock
        linkTask = Task {
            while !Task.isCancelled {
                try? await clock.sleep(seconds: Self.linkValidInterval)
                guard !Task.isCancelled else { break }
                await self.sendLinkValid()
            }
        }
    }

    private func stopLinkKeepAlive() {
        linkTask?.cancel()
        linkTask = nil
    }

    /// One LINK_VALID write. Fire-and-forget like `rearmRealtime`: a confirmed GATT write, no reply
    /// awaited. Does nothing unless the channel is ready, so it is silent in every other state.
    private func sendLinkValid() async {
        guard enabled, state == .ready, linkOpen else { return }
        do {
            try await writeConfirmedWithoutReply(.linkValid())
            linkValidFailures = 0
            lastLinkValidAt = clock.now()
        } catch {
            linkValidFailures += 1
            BandLog.tierB(.error, "LINK_VALID (cmd 1) write failed; \(linkValidFailures) in a row: \(String(describing: error))")
        }
        emit(.linkKeepAlive(sentAt: lastLinkValidAt, consecutiveFailures: linkValidFailures))
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
        let effects = offload.start()
        // Drain start is a UI milestone, so it bypasses the ack throttle.
        emitDrainProgress(force: true)
        await runOffloadEffects(effects)
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
                phaseSpan.add(unix: Int(record.unixSeconds))
                restoreSpan.add(unix: Int(record.unixSeconds))
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
                // Persist-then-ack (CONTEXT.md lesson 4): the ack advances the strap's read cursor
                // past this batch, so with a sink installed the batch is written to the store FIRST.
                // Handing records over and acking straight away left them in an in-memory queue,
                // and every queued batch was lost when iOS suspended or killed the app.
                if let sink = historicalSink, !historicalRecords.isEmpty {
                    let records = historicalRecords
                    historicalRecords = []
                    guard await sink(records) else {
                        // Not acked: the cursor stays put, so the next drain re-sends this batch.
                        BandLog.tierB(.error, "store failed for \(records.count) record(s); batch not acked")
                        continue
                    }
                    emit(.historical(records))
                }
                do {
                    try await writeConfirmedWithoutReply(.historicalDataResult(token: token))
                    BandLog.tierB(.info, "acked batch, trim cursor \(Self.tokenValue(token)) (\(offload.recordCount) record(s) so far)")
                    // Without a sink the decoded records are handed to the app now: holding the whole
                    // drain in memory until it stops would lose every acked record if the app died
                    // mid-drain. Repeated stores dedupe on (band_id, ts_ms).
                    flushRecords()
                    // One emission per acked batch (never per record), throttled to ~2/s. The
                    // end-of-drain emission always carries the final count.
                    emitDrainProgress(force: false)
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
        guard case .draining = offload.phase, let deadline = offload.runCapDeadline else { return }
        let clock = clock
        offloadRunCapTask = Task {
            // Sleep to the drain's ABSOLUTE run-cap deadline: the Task body starts after its
            // creation (lazy scheduling), and a relative `runCap` sleep would drift the cap later
            // by that scheduling delay. `runCapElapsed`'s deadline guard still drops stale fires.
            try? await clock.sleep(seconds: max(0, deadline.timeIntervalSince(clock.now())))
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
        sessionKeptRecords += drainKeptRecords
        let dropped = drainDroppedFutureRecords
        BandLog.tierB(.info, "historical offload ended (\(offload.phase)): \(offload.recordCount) record(s) total, \(historicalRecords.count) unflushed"
            + (dropped > 0 ? ", \(dropped) future-dated record(s) dropped" : ""))
        flushRecords()
        // The end-of-drain emission always goes out, so the UI sees the final count and why the
        // drain stopped even when the last ack was throttled.
        emitDrainProgress(force: true)
        // The full-history restore parks one waiter per drain here; resume them all (the restore
        // loop re-checks the phase itself, so a stale resume is harmless).
        let waiters = drainEndWaiters
        drainEndWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Surfaces the offload's current state to the app. Called on drain start, after each acked
    /// batch (throttled) and at drain end (forced): it only reads counters, so the drain's
    /// per-record path stays untouched.
    private func emitDrainProgress(force: Bool) {
        let now = clock.now()
        if !force,
           let last = lastDrainProgressAt,
           now.timeIntervalSince(last) < Self.drainProgressMinInterval {
            return
        }
        lastDrainProgressAt = now
        let phase: DrainProgress.Phase
        let stopReason: OffloadStateMachine.StopReason?
        switch offload.phase {
        case .draining:
            phase = .draining
            stopReason = nil
        case .idle:
            phase = .idle
            stopReason = nil
        case let .stopped(reason):
            phase = .idle
            stopReason = reason
        }
        let total = sessionKeptRecords + (phase == .draining ? drainKeptRecords : 0)
        emit(.drainProgress(DrainProgress(
            phase: phase,
            recordsThisDrain: drainKeptRecords,
            totalThisSession: total,
            pagesBehind: ringState?.pagesBehind,
            stopReason: stopReason,
            at: now
        )))
    }

    /// Hands the accumulated records to the app and clears the buffer. Called after each acked
    /// batch (the strap's trim point) and at drain end; a no-op when nothing is pending.
    private func flushRecords() {
        let records = historicalRecords
        guard !records.isEmpty else { return }
        historicalRecords = []
        guard let sink = historicalSink else {
            emit(.historical(records))
            return
        }
        // Only an unacked tail reaches here with a sink installed (a drain that stopped between
        // batches): the strap re-sends it next drain, so storing it now is a best-effort preview.
        let emit = emit
        Task {
            if await sink(records) {
                emit(.historical(records))
            }
        }
    }

    /// Installs the durable store for drained records. While set, each batch is passed to `sink`
    /// and its ack is written only after `sink` returns true; `.historical` is still emitted, after
    /// the store, for the UI. `sink` should do the minimum (insert the rows) and return quickly:
    /// the drain waits on it. Nil restores the emit-only behaviour.
    public func setHistoricalSink(_ sink: HistoricalSink?) {
        historicalSink = sink
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
            if kind == .batteryLevel || kind == .chargingOn || kind == .chargingOff {
                // Payload layouts for these events are not pinned (whoop-parity §3.7), so the raw
                // bytes go to the log for hardware capture rather than being guessed at.
                BandLog.tierB(.info, "battery/charging event \(frame.cmd) payload=\(hex(frame.payload))")
            }
            if kind == .batteryLevel, let percent = BatteryEvent.percent(frame.payload) {
                // The battery EVENT carries a percent as well [Unverified]; the GET_BATTERY_LEVEL
                // reply already emitted it, but the event is the strap's own push.
                emit(.battery(percent))
            }
            if kind == .chargingOn || kind == .chargingOff {
                // The event id itself is the state (events 7 and 8 per PLAN.md 5.3.4): no payload decode needed.
                let charging = kind == .chargingOn
                emit(.charging(charging))
                // A charging change is the moment the percent moves, so read it now rather than at the next
                // 10-minute poll. Detached: a reply arrives through this same receive path.
                Task { await self.refreshBattery(force: true) }
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
        } else if frame.packetType == .consoleLogs {
            // The firmware console (type 50, whoop-parity §3.5). Decoded to printable lines here; the
            // app keeps a bounded ring of them for the Debug screen.
            let lines = ConsoleLog.lines(payload: frame.payload)
            if !lines.isEmpty {
                emit(.consoleLines(lines, at: clock.now()))
            }
        }
    }

    // MARK: Battery

    /// Reads the battery at most once per `batteryInterval` (PLAN.md 6.5). Does nothing before the handshake is done.
    /// Each read is GET_BATTERY_LEVEL (26) followed by GET_EXTENDED_BATTERY_INFO (98), which is logged raw
    /// because its layout is [Unverified] (whoop-parity §3.7). `force` skips the limiter for a charging change.
    public func refreshBattery(force: Bool = false) async {
        guard enabled, state == .ready else { return }
        let now = clock.now()
        if !force, let last = lastBatteryRequest, now.timeIntervalSince(last) < Self.batteryInterval {
            return
        }
        lastBatteryRequest = now
        if let frame = try? await send(.getBatteryLevel()),
           let percent = BatteryLevel.percent(payload: frame.payload) {
            emit(.battery(Int(percent.rounded())))
        }
        if let extended = try? await send(.getExtendedBatteryInfo()) {
            BandLog.tierB(.info, "extended battery (cmd 98) reply: \(hex(extended.payload))")
        } else {
            BandLog.tierB(.info, "extended battery (cmd 98) got no reply")
        }
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
            await readBackAlarm(unix: UInt32(unix))
        } else {
            BandLog.tierB(.error, "arming band alarm for \(next) failed")
        }
    }

    /// GET_ALARM_TIME (cmd 67) once after each arming: logs whether the strap holds the armed time.
    /// [Unverified] reply layout: the armed time is read as a u32 LE at payload offset 2, the same spot
    /// GET_CLOCK's reply carries its clock. A mismatch logs the raw payload so the layout can be pinned on hardware.
    private func readBackAlarm(unix: UInt32) async {
        guard let reply = try? await send(.getAlarmTime()) else {
            lastAlarmReadBack = .noReply
            BandLog.tierB(.info, "alarm read-back (cmd 67): no reply")
            return
        }
        let p = reply.payload
        let stored: UInt32? = p.count >= 6
            ? UInt32(p[2]) | UInt32(p[3]) << 8 | UInt32(p[4]) << 16 | UInt32(p[5]) << 24
            : nil
        if stored == unix {
            lastAlarmReadBack = .matched
            BandLog.tierB(.info, "alarm read-back (cmd 67): matches the armed time \(unix)")
        } else {
            lastAlarmReadBack = .mismatched
            BandLog.tierB(.error, "alarm read-back (cmd 67): armed \(unix), strap replied \(hex(p))")
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

/// One pass of the full-history restore's back-to-back drain loop: the drains it kicked, the records
/// they kept, and why the pass stopped (`cap` when it ran out of drains).
private struct RestorePass {
    enum Stop: Equatable {
        /// A drain kept nothing: the strap has no more records from the cursor.
        case emptyDrain
        case historyComplete
        /// A drain reached the live edge: nothing newer is left to read.
        case liveEdge
        case cap
        /// The next drain could not start (the rate gate or the drain state refused it).
        case denied
        case linkLost
    }

    var drains = 0
    var kept = 0
    var stop: Stop?
}

/// The oldest and newest record times a restore kept, for its log lines and summary.
private struct RecordSpan {
    private(set) var count = 0
    private(set) var oldest: Int?
    private(set) var newest: Int?

    mutating func add(unix: Int) {
        count += 1
        oldest = min(oldest ?? unix, unix)
        newest = max(newest ?? unix, unix)
    }

    /// "oldest Oct 29 07:12 (36.1 h)" in local time, or nil when nothing was kept.
    var summaryText: String? {
        guard let oldest, let newest else { return nil }
        return "oldest \(Self.clock(oldest)) (\(Self.hours(newest - oldest)) h)"
    }

    /// "Oct 29 07:12…Oct 30 19:20 (36.1 h)" in local time, or nil when nothing was kept.
    var rangeText: String? {
        guard let oldest, let newest else { return nil }
        return "\(Self.clock(oldest))…\(Self.clock(newest)) (\(Self.hours(newest - oldest)) h)"
    }

    private static func clock(_ unix: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    private static func hours(_ seconds: Int) -> String {
        String(format: "%.1f", Double(seconds) / 3600)
    }
}
