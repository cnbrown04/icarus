import BandKit
import BandProtocol
import Foundation
import Testing

// Controller-level pins for the NOOP-ported sync behaviour: the clock policy in the handshake,
// the corrupt-future-RTC handling in the drain, the trim=0xFFFFFFFF sentinel meanings, the run
// cap, the BackfillPolicy-driven cadence and the app-facing syncNow triggers.
// .serialized: these tests assert on the SHARED BandLog ring; concurrent suites
// handshaking in parallel would flush our lines out of the asserted window.
@Suite("Tier B sync policy", .serialized)
struct SyncPolicyControllerTests {
    private var wallUnix: UInt32 { UInt32(ManualClock.origin.timeIntervalSince1970) }

    /// GET_CLOCK replies with a strap RTC `drift` seconds away from the manual clock's wall time.
    private func clockResponder(drift: Int) -> FakeBand.Responder {
        { request, _ in
            if request.cmd == 11 {
                return reply(to: request, payload: [0x00, 0x01] + littleEndian(UInt32(ManualClock.origin.timeIntervalSince1970) - UInt32(drift)))
            }
            return reply(to: request, payload: request.cmd == 26 ? [0x00, 0x01, 0x69, 0x03] : [])
        }
    }

    /// A HISTORY_END metadata frame in NOOP's '<LHLL' layout: unix u32 @ payload 0, trim cursor
    /// u32 @ payload 10 (the first word of the echoed token).
    private func endFrame(unix: UInt32, trim: UInt32) -> Frame {
        var payload = [UInt8](repeating: 0, count: 18)
        for (index, byte) in littleEndian(unix).enumerated() { payload[index] = byte }
        for (index, byte) in littleEndian(trim).enumerated() { payload[10 + index] = byte }
        return Frame(type: PacketType.metadata.rawValue, seq: 24, cmd: 2, payload: payload)
    }

    private func historicalEvents(_ events: [BandEvent]) -> [[HistoricalRecord]] {
        events.compactMap { event -> [HistoricalRecord]? in
            if case let .historical(records) = event { return records }
            return nil
        }
    }

    // MARK: Clock policy in the handshake

    @Test func aHealthyClockIsNotGratuitouslyReset() async {
        let h = Harness(responder: clockResponder(drift: 0))
        await h.controller.connectionOpened()
        #expect(h.band.opcodes == [35, 11, 11, 34, 26, 3, 22], "no SET_CLOCK on a healthy clock")
        #expect(BandLog.capturedLines(2000).contains { $0.contains("clock within threshold; not set") })
    }

    @Test func aDriftedClockIsSetWithTheBeforeAndAfterReadingsLogged() async {
        let h = Harness(responder: clockResponder(drift: 3600))
        await h.controller.connectionOpened()
        let lines = BandLog.capturedLines(2000)
        #expect(lines.contains { $0.contains("strap RTC before SET_CLOCK") && $0.contains("drift 3600s") })
        #expect(lines.contains { $0.contains("clock drifted 3600s — SET_CLOCK sent (both forms") })
        #expect(lines.contains { $0.contains("strap RTC after SET_CLOCK") && $0.contains("(before:") })
    }

    @Test func aMissingClockReadingSkipsTheSet() async {
        // The default harness' GET_CLOCK replies are empty: no decoded reading → no set.
        let h = Harness()
        await h.controller.connectionOpened()
        #expect(h.band.commands.filter { $0.cmd == 10 }.isEmpty)
        #expect(BandLog.capturedLines(2000).contains { $0.contains("GET_CLOCK reply carried no clock value") })
    }

    // MARK: GET_DATA_RANGE decoders (NOOP's hardware-verified vectors, wired into the handshake)

    /// Real WHOOP 4.0 GET_DATA_RANGE captures (NOOP #791): the pagesBehind decode must land.
    @Test func theDataRangeReplyIsDecodedWithTheHardwareVectors() async {
        let pagesFrame = "aa4c00a7247e220a01010000000050070100a307010050070100000000000000020035030000" +
            "c2fc13008046394b00000000bbe1636aa02d0000bbe1636aa02d0000c6e4636ac07c000000000447ea04"
        let bytes: [UInt8] = stride(from: 0, to: pagesFrame.count, by: 2).map { off in
            let start = pagesFrame.index(pagesFrame.startIndex, offsetBy: off)
            let end = pagesFrame.index(start, offsetBy: 2)
            return UInt8(pagesFrame[start..<end], radix: 16)!
        }
        let h = Harness(responder: nil)
        h.band.setResponder { request, _ in
            reply(to: request, payload: Array(bytes.dropFirst(7))) // the envelope's [type, seq, cmd] lead the payload
        }
        await h.controller.connectionOpened()
        let lines = BandLog.capturedLines(2000)
        #expect(lines.contains { $0.contains("data range: banked") }, "the oldest/newest decode is logged")
        #expect(lines.contains { $0.contains("83 pages behind") }, "the #791 capture's ring backlog")
        // The same reply surfaces the full decoded ring state for the app-deleted restore:
        let ring = await h.controller.ringState
        #expect(ring == RingState(write: 67_491, read: 67_408, capacity: 131_072))
        #expect(ring?.pagesBehind == 83)
    }

    @Test func aFutureDatedRangeMarksTheClockUntrusted() async {
        let future = wallUnix + 48 * 3600 + 1
        let h = Harness(responder: nil)
        h.band.setResponder { request, _ in
            reply(to: request, payload: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00] + littleEndian(future))
        }
        await h.controller.connectionOpened()
        #expect(await h.controller.clockUntrusted)
        #expect(BandLog.capturedLines(2000).contains { $0.contains("AHEAD of the wall clock") })
    }

    // MARK: Corrupt future-RTC handling in the drain

    @Test func aFutureDatedHistoryEndStopsAutomaticDrainsButManualStillRuns() async {
        let h = Harness()
        await h.controller.connectionOpened()   // the connect pass kicks once
        await h.controller.receive(endFrame(unix: wallUnix + 3 * 86_400, trim: 500))
        #expect(await h.controller.clockUntrusted)
        #expect(BandLog.capturedLines(2000).contains { $0.contains("3 day(s) in the FUTURE") })

        // The 15-min periodic floor is denied while untrusted.
        h.clock.advance(by: 900)
        await flush()
        #expect(h.band.opcodes.filter { $0 == 22 }.count == 1, "the automatic re-drain skipped")

        // A manual sync still runs on the same connection.
        await h.controller.syncNow(trigger: .manual)
        #expect(h.band.opcodes.filter { $0 == 22 }.count == 2)
    }

    @Test func aFutureDatedRecordIsDroppedBeforeItCanPolluteTheStore() async throws {
        let h = Harness()
        await h.controller.connectionOpened()
        await h.controller.receive(historicalRecordFrame(unix: wallUnix + 2 * 86_400))
        await h.controller.connectionClosed()   // ends the drain, flushes the buffer
        #expect(historicalEvents(h.events.all).isEmpty, "the future-dated record was never emitted")
        #expect(await h.controller.clockUntrusted, "a future record marks the clock untrusted")
        #expect(await h.controller.emptyStreak == 1, "the dropped record never counted as banked")
        #expect(BandLog.capturedLines(2000).contains { $0.contains("dropped a historical record dated about 2 day(s) in the FUTURE") })
    }

    @Test func aFutureDatedRecordDoesNotTouchItsPlausibleNeighbours() async throws {
        let h = Harness()
        await h.controller.connectionOpened()
        await h.controller.receive(historicalRecordFrame(unix: wallUnix + 2 * 86_400))
        let good = historicalRecordFrame(unix: wallUnix - 3600)
        await h.controller.receive(good)
        await h.controller.connectionClosed()
        let record = try HistoricalRecord.parse(good)
        #expect(historicalEvents(h.events.all) == [[record]])
    }

    @Test func theNoCursorSentinelReadsAsCaughtUpAfterRowsPersisted() async {
        let h = Harness()
        await h.controller.connectionOpened()
        await h.controller.receive(historicalRecordFrame(unix: wallUnix - 3600))
        await h.controller.receive(endFrame(unix: wallUnix - 60, trim: 0xFFFFFFFF))
        #expect(BandLog.capturedLines(2000).contains { $0.contains("caught up after persisting 1 row(s) this run") })
        #expect(!BandLog.capturedLines(2000).contains { $0.contains("no flash cursor") }, "the rows pick wins; no false alarm")
    }

    @Test func theNoCursorSentinelReadsAsNoBankedHistoryWhenNothingCame() async {
        let h = Harness()
        await h.controller.connectionOpened()
        await h.controller.receive(endFrame(unix: wallUnix - 60, trim: 0xFFFFFFFF))
        #expect(BandLog.capturedLines(2000).contains { $0.contains("strap reported no flash cursor (trim=0xFFFFFFFF)") })
    }

    // MARK: Run cap (NOOP's ~60 s offload cap)

    /// Feed one record every 4 s so the quiet deadline (last record + 8 s) always stays ahead of
    /// the clock; then one advance past the cap deadline is the ONLY due sleeper, so the run cap
    /// (not the quiet timeout) deterministically stops the drain. Watchdogs register their sleeps
    /// lazily (their deadline is computed at the task's first yield), so settle until all three
    /// (realtime re-arm + run cap + cadence — the quiet watchdog parks on the FIRST record) are
    /// parked before any advance.
    @Test func aDrainIsCappedAtSixtySecondsSoLiveHRNeverStarves() async {
        let h = Harness()
        await h.controller.connectionOpened()
        await settle { h.clock.sleeperCount == 3 }   // realtime re-arm + runCap + cadence
        // The quiet watchdog re-parks after each record, but its repark is lazy (no yield here),
        // so it never registers: the run-cap sleeper is the only registered deadline past t=60.
        for index in 0..<15 {
            await h.controller.receive(historicalRecordFrame(unix: wallUnix - 7200 + UInt32(index)))
            h.clock.advance(by: 4)
        }
        // t=60; one advance to t=60 passes ONLY the cap deadline (60 ≤ 60; quiet unregistered).
        h.clock.advance(by: 4)
        await settle { await h.controller.drainPhase != .draining }
        await flush()
        #expect(BandLog.capturedLines(2000).contains { $0.contains("StopReason.runCap") }, "the drain ended on the run cap")
        // The un-acked records flush exactly once when the cap stops the drain.
        let flushed = historicalEvents(h.events.all)
        #expect(flushed.count == 1)
        #expect(flushed.first?.count == 15, "records fed before the cap fired are flushed")
    }

    // MARK: Cadence (BackfillPolicy in the redrain loop)

    @Test func thePeriodicRedrainKeepsTheFifteenMinuteFloor() async {
        let h = Harness()
        await h.controller.connectionOpened()
        await endRunningDrain(h)   // the connect drain ends (run cap; no records → no quiet deadline), empty → streak 1
        #expect(h.band.opcodes.filter { $0 == 22 }.count == 1)
        h.clock.advance(by: 841)   // past t=900: the cadence sleeper fires; the floor elapses
        await settle { h.band.opcodes.filter { $0 == 22 }.count == 2 }
    }

    @Test func emptyDrainsStretchThePeriodicFloor() async {
        let h = Harness()
        await h.controller.connectionOpened()
        await endRunningDrain(h)                // drain 1 ends on its run cap, empty → streak 1
        h.clock.advance(by: 841)                // past t=900: cadence fires → drain 2
        await settle { h.band.opcodes.filter { $0 == 22 }.count == 2 }
        await endRunningDrain(h)                // drain 2 ends empty → streak 2
        h.clock.advance(by: 841)                // past t=1800: cadence fires → drain 3
        await settle { h.band.opcodes.filter { $0 == 22 }.count == 3 }
        await endRunningDrain(h)                // drain 3 ends empty → streak 3
        #expect(await h.controller.emptyStreak == 3)

        // The streak of 3 stretches the floor to 2×: the cadence wake parked since drain 3 began
        // (the old 900-s mark, ~t=2700) is denied, and the next automatic drain is due 1800 s
        // after the last kick (t=3600). The denied attempt re-parks the cadence exactly on the
        // stretched floor (`periodicCadenceDelay`), so drain 4 lands at t=3600.
        h.clock.advance(by: 999)                // t=2859: past the old cadence mark → policy denies
        await flush()
        #expect(h.band.opcodes.filter { $0 == 22 }.count == 3)
        h.clock.advance(by: 700)                // t=3559: still inside the stretched floor
        await flush()
        #expect(h.band.opcodes.filter { $0 == 22 }.count == 3)
        h.clock.advance(by: 41)                 // t=3600: the stretched floor elapses → drain 4
        await settle { h.band.opcodes.filter { $0 == 22 }.count == 4 }
    }

    @Test func theForegroundTriggerKeepsTheNinetySecondFloorAndManualIsUnfloored() async {
        let h = Harness()
        await h.controller.connectionOpened()
        await settle { h.clock.sleeperCount == 3 }
        await h.controller.syncNow(trigger: .foreground)
        #expect(h.band.opcodes.filter { $0 == 22 }.count == 1, "inside the event floor → skipped")
        // The advance wakes the connect drain's watchdogs; let the drain settle before kicking.
        h.clock.advance(by: 90)
        await settle { await h.controller.drainPhase != .draining }
        await h.controller.syncNow(trigger: .foreground)
        #expect(h.band.opcodes.filter { $0 == 22 }.count == 2)
        // Wait until the new drain's run-cap sleeper is parked (registration is lazy)…
        await settle { h.clock.sleeperCount == 3 }
        // …then end it (run cap) before the manual kick.
        h.clock.advance(by: OffloadStateMachine.runCap)
        await settle { await h.controller.drainPhase != .draining }
        await h.controller.syncNow(trigger: .manual)
        #expect(h.band.opcodes.filter { $0 == 22 }.count == 3, "manual is never floored")
    }

    @Test func theStrapPromptEventKicksAStrapTriggeredDrain() async {
        let h = Harness()
        await h.controller.connectionOpened()
        await settle { h.clock.sleeperCount == 3 }
        // Immediately after the connect drain the .strap event floor (90 s) denies it…
        await h.controller.receive(eventFrame(96))
        #expect(h.band.opcodes.filter { $0 == 22 }.count == 1)
        // The advance wakes the connect drain's watchdogs; let it settle, then re-prompt.
        h.clock.advance(by: 90)
        await settle { await h.controller.drainPhase != .draining }
        await h.controller.receive(eventFrame(96))
        #expect(h.band.opcodes.filter { $0 == 22 }.count == 2, "past the floor the strap's own prompt syncs")
    }
}
