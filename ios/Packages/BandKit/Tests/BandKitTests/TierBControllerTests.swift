import BandKit
import BandProtocol
import Foundation
import Testing

@Suite("TierBController queue, handshake and safety")
struct TierBControllerTests {
    private let alarmOpcode: UInt8 = 66
    private let batteryOpcode: UInt8 = 26

    // MARK: Handshake

    /// The default harness' GET_CLOCK replies carry no clock value (empty payloads), so NOOP's
    /// ClockPolicy has no decoded reading and SET_CLOCK is NOT sent: a healthy-or-unknown clock is
    /// never gratuitously reset. Order: hello → clock-pre → clock-post → range → battery →
    /// realtime → drain. The SET_CLOCK branch is pinned in `SyncPolicyControllerTests`.
    @Test func handshakeReadsTheClockTwiceAndTheRangeOncePerConnection() async {
        let h = Harness()
        await h.controller.connectionOpened()
        await h.controller.connectionOpened()
        #expect(h.band.opcodes == [35, 11, 11, 34, 26, 3, 22])
        #expect(h.band.opcodes.filter { $0 == 10 }.count == 0, "no clock value decoded → no SET_CLOCK")
        #expect(await h.controller.state == .ready)
        #expect(h.events.all.contains(.battery(87)))
        #expect(h.events.all.contains(.tierB(.ready)))
    }

    @Test func reconnectRepeatsTheHandshakeButNotTheBatteryPoll() async {
        let h = Harness()
        await h.controller.connectionOpened()
        await h.controller.connectionClosed()
        #expect(await h.controller.state == .awaitingLink)
        await h.controller.connectionOpened()
        // The connect trigger keeps NOOP's 90-s event floor against `lastBackfillAt`, so an
        // immediate reconnect re-runs the handshake but NOT the drain (NOOP's
        // "no second backfill on a same-process reconnect" behaviour).
        #expect(h.band.opcodes == [35, 11, 11, 34, 26, 3, 22, 35, 11, 11, 34, 3])
    }

    @Test func aSilentBandFailsTheHandshakeAfterRetriesAndStaysUnavailable() async {
        let h = Harness(responder: nil)
        let opening = Task { await h.controller.connectionOpened() }
        for attempt in 1 ... 4 {
            await settle { h.band.count >= attempt }
            await settle { h.clock.sleeperCount == 1 }
            h.clock.advance(by: TierBController.responseTimeout)
        }
        await opening.value
        #expect(await h.controller.state == .unavailable)
        #expect(h.band.opcodes == [35, 35, 35, 35], "GET_HELLO now leads the handshake")
        #expect(!h.events.all.contains(.tierB(.ready)))

        // A dropped link does not clear unavailable. Only a new connection tries again.
        await h.controller.connectionClosed()
        #expect(await h.controller.state == .unavailable)
    }

    // MARK: Serial queue, timeout, retry and seq

    @Test func oneConfirmedWriteIsInFlightAtATime() async throws {
        let h = Harness()
        await h.controller.connectionOpened()
        h.band.setResponder(nil)

        let first = Task { try await h.controller.send(.getAlarmTime()) }
        let second = Task { try await h.controller.send(.getDataRange()) }
        await settle { h.band.count == 8 }
        await flush()
        #expect(h.band.count == 8, "the second command must wait for the first reply")
        #expect(h.band.last?.cmd == 67)

        await h.controller.receive(reply(to: h.band.last!))
        let firstReply = try await first.value
        #expect(firstReply.cmd == 67)

        await settle { h.band.count == 9 }
        #expect(h.band.last?.cmd == 34)
        await h.controller.receive(reply(to: h.band.last!))
        _ = try await second.value
    }

    @Test func aSilentCommandRetriesThreeTimesWithANewSeqThenTimesOut() async {
        let h = Harness()
        await h.controller.connectionOpened()
        h.band.setResponder(nil)
        let base = h.band.count

        let task = Task { try await h.controller.send(.getAlarmTime()) }
        for attempt in 1 ... 4 {
            await settle { h.band.count == base + attempt }
            // Attempt timer + realtime keep-alive + offload cadence + drain run cap.
            await settle { h.clock.sleeperCount == 4 }
            h.clock.advance(by: TierBController.responseTimeout)
        }
        guard case let .failure(error) = await task.result else {
            Issue.record("expected the command to fail")
            return
        }
        #expect((error as? TierBError) == .timedOut)
        #expect(h.band.count == base + 4, "one attempt plus three retries")
        let seqs = h.band.commands.suffix(4).map(\.seq)
        #expect(Set(seqs).count == 4, "each attempt carries a new seq byte")
    }

    @Test func aReplyOnTheSecondAttemptCompletesTheCommand() async throws {
        let h = Harness()
        await h.controller.connectionOpened()
        let base = h.band.count
        h.band.setResponder { request, index in
            index == base + 1 ? reply(to: request) : nil
        }

        let task = Task { try await h.controller.send(.getAlarmTime()) }
        await settle { h.band.count == base + 1 }
        await settle { h.clock.sleeperCount == 4 }
        h.clock.advance(by: TierBController.responseTimeout)
        let frame = try await task.value
        #expect(frame.cmd == 67)
        #expect(h.band.count == base + 2)
    }

    @Test func repliesForAnotherCommandDoNotCompleteTheInFlightOne() async {
        let h = Harness()
        await h.controller.connectionOpened()
        h.band.setResponder(nil)
        let base = h.band.count
        let task = Task { try await h.controller.send(.getAlarmTime()) }
        await settle { h.band.count == base + 1 }

        await h.controller.receive(Frame(type: PacketType.commandResponse.rawValue, seq: h.band.last!.seq, cmd: 34, payload: []))
        await settle { h.clock.sleeperCount == 4 }
        h.clock.advance(by: TierBController.responseTimeout)
        await settle { h.band.count == base + 2 }
        #expect(h.band.last?.cmd == 67, "the timeout retried the original command")
        await h.controller.connectionClosed()
        _ = await task.result
    }

    @Test func aReplyWithAnotherSeqIsStaleOnceTheBandEchoesSeq() async throws {
        let h = Harness()
        await h.controller.connectionOpened()
        h.band.setResponder(nil)
        let base = h.band.count
        let task = Task { try await h.controller.send(.getAlarmTime()) }
        await settle { h.band.count == base + 1 }
        let request = h.band.last!

        // The handshake replies echoed seq, so a mismatched seq is treated as stale and ignored.
        await h.controller.receive(Frame(type: PacketType.commandResponse.rawValue, seq: request.seq &+ 9, cmd: 67, payload: []))
        await settle { h.clock.sleeperCount == 4 }
        h.clock.advance(by: TierBController.responseTimeout)
        await settle { h.band.count == base + 2 }

        await h.controller.receive(reply(to: h.band.last!))
        #expect(try await task.value.cmd == 67)
    }

    // MARK: Denylist

    @Test func denylistedOpcodesNeverReachTheWire() async throws {
        let h = Harness()
        await h.controller.connectionOpened()
        let builders: [BandCommand] = [
            .runHapticsPattern(patternId: 2, loops: 1), .stopHaptics(), .getAllHapticsPatterns(),
            .setAlarmTime(unix: 1_800_000_000), .getAlarmTime(), .getClock(), .getBatteryLevel(),
            .getDataRange(), .toggleRealtimeHR(on: true), .hrBroadcast(on: false),
        ]
        for command in builders {
            _ = try await h.controller.send(command)
        }
        await h.controller.stopHaptics()
        #expect(h.band.opcodes.count >= builders.count)
        #expect(Set(h.band.opcodes).isDisjoint(with: SafeCommand.deniedOpcodes))
        #expect(Set(h.band.opcodes).isSubset(of: Set(SafeCommand.allCases.map(\.rawValue))))
    }

    // MARK: Toggle

    @Test func disabledSendsNothingAndRejectsEveryCall() async {
        let h = Harness(enabled: false)
        await h.controller.connectionOpened()
        await h.controller.armAlarms([h.clock.now().addingTimeInterval(3600)])
        await h.controller.refreshBattery()
        await h.controller.receive(eventFrame(9))
        await h.controller.stopHaptics()

        #expect(await h.controller.state == .disabled)
        #expect(h.band.count == 0)
        #expect(h.events.all.isEmpty)
        do {
            _ = try await h.controller.send(.getClock())
            Issue.record("send must throw while disabled")
        } catch {
            #expect((error as? TierBError) == .disabled)
        }
        do {
            try await h.controller.runRhythm(try Rhythm(steps: [.buzz(preset: 2, loops: 1)]))
            Issue.record("runRhythm must throw while disabled")
        } catch {
            #expect((error as? TierBError) == .disabled)
        }
        #expect(h.band.count == 0)
    }

    @Test func turningTheToggleOffFailsPendingCallsAndSendsNothingMore() async {
        let h = Harness()
        await h.controller.connectionOpened()
        h.band.setResponder(nil)
        let base = h.band.count
        let task = Task { try await h.controller.send(.getAlarmTime()) }
        await settle { h.band.count == base + 1 }

        await h.controller.setEnabled(false)
        guard case let .failure(error) = await task.result else {
            Issue.record("expected the pending command to fail")
            return
        }
        #expect((error as? TierBError) == .disabled)
        await settle { h.clock.sleeperCount == 0 }
        h.clock.advance(by: 60)
        await flush()
        #expect(h.band.count == base + 1)
    }

    @Test func enablingAgainWaitsForTheLinkBeforeSending() async {
        let h = Harness(enabled: false)
        await h.controller.setEnabled(true)
        #expect(await h.controller.state == .awaitingLink)
        #expect(h.band.count == 0)
        await h.controller.connectionOpened()
        #expect(h.band.opcodes == [35, 11, 11, 34, 26, 3, 22])
    }

    /// The Device checkbox becomes the way to retry from the red triangle: enabling while
    /// `.unavailable` re-arms the channel instead of being swallowed by the same-value guard.
    @Test func enablingWhileUnavailableRetriesSetup() async {
        let h = Harness()
        await h.controller.connectionOpened()
        #expect(await h.controller.state == .ready)

        await h.controller.linkFailed()
        #expect(await h.controller.state == .unavailable)

        // A repeat enable call (the toggle is already on) must recover the channel.
        await h.controller.setEnabled(true)
        #expect(await h.controller.state == .awaitingLink)
        #expect(h.events.all.contains(.tierB(.awaitingLink)))
        await h.controller.connectionOpened()
        #expect(await h.controller.state == .ready)
    }

    // MARK: Rate limit

    @Test func batteryIsReadAtMostEveryTenMinutes() async {
        let h = Harness()
        await h.controller.connectionOpened()
        await h.controller.refreshBattery()
        h.clock.advance(by: TierBController.batteryInterval - 1)
        await h.controller.refreshBattery()
        #expect(h.band.opcodes.filter { $0 == batteryOpcode }.count == 1)

        h.clock.advance(by: 1)
        await h.controller.refreshBattery()
        #expect(h.band.opcodes.filter { $0 == batteryOpcode }.count == 2)
    }

    // MARK: Events

    @Test func bandEventsAreEmittedAndUnknownIdsAreKept() async {
        let h = Harness()
        await h.controller.connectionOpened()
        for id: UInt8 in [9, 10, 14, 23, 21] {
            await h.controller.receive(eventFrame(id))
        }
        #expect(h.events.all.contains(.bandEvent(.wristOn)))
        #expect(h.events.all.contains(.bandEvent(.wristOff)))
        #expect(h.events.all.contains(.bandEvent(.doubleTap)))
        #expect(h.events.all.contains(.bandEvent(.bleBonded)))
        #expect(h.events.all.contains(.bandEvent(.unknown(21))))
    }

    /// The battery EVENT (id 3) carries a percent [Unverified]; the controller decodes it and
    /// emits the same `.battery` the GET_BATTERY_LEVEL reply produces.
    @Test func aBatteryEventAlsoEmitsItsDecodedPercent() async {
        let h = Harness()
        await h.controller.connectionOpened()
        await h.controller.receive(Frame(type: PacketType.event.rawValue, seq: 0, cmd: 3, payload: [0xD8, 0x03]))
        #expect(h.events.all.contains(.bandEvent(.batteryLevel)))
        #expect(h.events.all.contains(.battery(98)))
    }

    // MARK: Band alarm (PLAN.md 9.5)

    @Test func armsTheEarliestFutureOccurrenceAsAUTCUnixTime() async {
        let h = Harness()
        await h.controller.connectionOpened()
        let now = h.clock.now()
        let past = now.addingTimeInterval(-60)
        let soon = now.addingTimeInterval(300)
        let later = now.addingTimeInterval(900)
        let base = h.band.count

        await h.controller.armAlarms([later, past, soon])
        #expect(h.band.count == base + 1)
        let alarm = h.band.last!
        #expect(alarm.cmd == alarmOpcode)
        // 1_791_382_800 (2026-10-08 ... + 300 s from the test origin), little-endian, inside the golden layout.
        #expect(alarm.payload == [0x01, 0x10, 0x55, 0xC6, 0x6A, 0, 0, 0, 0])
        #expect(alarm.payload == BandCommand.setAlarmTime(unix: UInt32(soon.timeIntervalSince1970)).payload)

        await h.controller.armAlarms([later, past, soon])
        #expect(h.band.count == base + 1, "the same next occurrence is not sent twice")
    }

    @Test func rearmsTheNextAlarmAfterTheBandReportsOneExecuted() async {
        let h = Harness()
        await h.controller.connectionOpened()
        let now = h.clock.now()
        let soon = now.addingTimeInterval(300)
        let later = now.addingTimeInterval(900)
        await h.controller.armAlarms([soon, later])
        #expect(h.band.last?.payload == BandCommand.setAlarmTime(unix: UInt32(soon.timeIntervalSince1970)).payload)

        await h.controller.receive(eventFrame(57))
        #expect(h.events.all.contains(.bandEvent(.strapDrivenAlarmExecuted)))
        #expect(h.band.last?.cmd == alarmOpcode)
        #expect(h.band.last?.payload == BandCommand.setAlarmTime(unix: UInt32(later.timeIntervalSince1970)).payload)
    }

    @Test func alarmsSetBeforeTheLinkAreSentAfterTheHandshake() async {
        let h = Harness()
        await h.controller.armAlarms([h.clock.now().addingTimeInterval(300)])
        #expect(h.band.count == 0)
        await h.controller.connectionOpened()
        #expect(h.band.opcodes == [35, 11, 11, 34, alarmOpcode, batteryOpcode, 3, 22])
    }

    @Test func alarmTimesOutsideTheUInt32RangeAreNotSent() async {
        let h = Harness()
        await h.controller.connectionOpened()
        let base = h.band.count
        await h.controller.armAlarms([Date(timeIntervalSince1970: 5_000_000_000)])
        #expect(h.band.count == base)
    }

    // MARK: SET_CLOCK and hello (PLAN.md 5.3.4)

    /// The observed GET_HELLO reply header plus its ASCII strings (see `BandInfo.helloReply`).
    private static let helloPayload: [UInt8] = [
        0x00, 0x01, 0x04, 0xD8, 0x03, 0x00, 0x00, 0x00, 0xA2, 0x8F, 0xE2, 0x01, 0x28, 0x03, 0x00, 0x00,
    ] + Array("4C1551500".utf8) + [0x00] + Array("8e27cafe".utf8) + [0x00]

    /// SET_CLOCK goes out in both forms ONLY when the decoded GET_CLOCK reading has drifted past
    /// NOOP's 2 s threshold: this harness' strap RTC reads 100 s behind the wall clock. Order:
    /// hello → clock-pre → SET_CLOCK ×2 → clock-post → range → battery → realtime → drain.
    @Test func aDriftedClockIsSetInBothFormsPerConnection() async {
        let h = Harness(responder: nil)
        h.band.setResponder { request, _ in
            if request.cmd == 11 { return reply(to: request, payload: [0x00, 0x01] + littleEndian(UInt32(ManualClock.origin.timeIntervalSince1970 - 100))) }
            return reply(to: request, payload: request.cmd == 26 ? [0x00, 0x01, 0x69, 0x03] : [])
        }
        await h.controller.connectionOpened()
        await h.controller.connectionClosed()
        await h.controller.connectionOpened()
        let setClocks = h.band.commands.filter { $0.cmd == 10 }
        #expect(setClocks.count == 4, "both forms, once per connection")
        let secs = littleEndian(UInt32(ManualClock.origin.timeIntervalSince1970))
        #expect(setClocks[0].payload == secs + [0, 0, 0, 0], "the 8-byte form first")
        #expect(setClocks[1].payload == secs + [0, 0, 0, 0, 0], "then the legacy 9-byte form")
        #expect(setClocks[2].payload == secs + [0, 0, 0, 0])
        #expect(setClocks[3].payload == secs + [0, 0, 0, 0, 0])
        let opcodes = h.band.opcodes
        if let first = opcodes.firstIndex(of: 10) {
            #expect(Array(opcodes[first - 1 ..< first + 3]) == [11, 10, 10, 11], "clock-pre, both forms, clock-post")
            #expect(opcodes[first + 3] == 34, "the range follows the clock-post read")
        } else {
            Issue.record("a drifted clock must be set")
        }
    }

    @Test func helloReplyPopulatesBandInfo() async {
        let h = Harness(responder: nil)
        h.band.setResponder { request, _ in
            reply(to: request, payload: request.cmd == 35 ? Self.helloPayload : [])
        }
        await h.controller.connectionOpened()
        #expect(h.events.all.contains(.bandInfo(BandInfo(
            firmwareVersion: "8e27cafe",
            hardwareRevision: nil,
            serial: "4C1551500"
        ))))
    }

    @Test func aHelloReplyWithoutReadableStringsLeavesBandInfoFieldsNil() async {
        let h = Harness()
        await h.controller.connectionOpened()
        let infos = h.events.all.compactMap { event -> BandInfo? in
            if case let .bandInfo(info) = event { return info }
            return nil
        }
        #expect(infos == [BandInfo(firmwareVersion: nil, hardwareRevision: nil, serial: nil)])
    }

    // MARK: Realtime-raw flood (PLAN.md 7.2 step 4)

    /// Default handshake does NOT touch the raw flood: OpenStrap's verified reference never
    /// disables it and the off form is unverified (see `handshakeDisablesRealtimeRawFlood`).
    @Test func theDefaultHandshakeLeavesTheRealtimeRawFloodAlone() async {
        let h = Harness()
        await h.controller.connectionOpened()
        #expect(h.band.commands.filter { $0.cmd == 63 }.isEmpty, "no flood write unless opted in")
        #expect(h.band.opcodes.filter { $0 == 3 }.count == 1, "the realtime HR arm still happens per connection")
    }

    /// With the policy on, the handshake disables the strap's raw accel/PPG flood (cmd 63 `[0x00]`)
    /// right after GET_CLOCK and before GET_DATA_RANGE, as a fire-and-forget confirmed write.
    @Test func theOptInHandshakeDisablesTheRealtimeRawFloodBetweenClockAndRange() async {
        let h = Harness()
        await h.controller.setHandshakeRealtimeRawFloodDisabled(true)
        await h.controller.connectionOpened()
        await h.controller.connectionClosed()
        await h.controller.connectionOpened()
        let disables = h.band.commands.filter { $0.cmd == 63 }
        #expect(disables.count == 2, "one disable per connection")
        #expect(disables[0].payload == [0x00])
        #expect(disables[1].payload == [0x00])
        let opcodes = h.band.opcodes
        if let index = opcodes.firstIndex(of: 63) {
            #expect(index > 0, "the disable is not the first write")
            #expect(opcodes[index - 1] == 11, "the disable rides between GET_CLOCK and GET_DATA_RANGE")
            #expect(opcodes[index + 1] == 34)
        } else {
            Issue.record("the handshake never disabled the realtime-raw flood")
        }
        #expect(h.band.opcodes.filter { $0 == 3 }.count == 2, "the realtime HR arm still happens per connection")
    }

    /// The runtime toggle bypasses the one-command-at-a-time queue: with a command wedged on the
    /// queue waiting for a reply that never comes, the flood toggle still reaches the wire.
    @Test func theRuntimeFloodToggleIsNotBlockedByABusyQueue() async {
        let h = Harness()
        await h.controller.connectionOpened()
        h.band.setResponder(nil)
        let base = h.band.count
        let wedged = Task { try await h.controller.send(.getAlarmTime()) }
        await settle { h.band.count == base + 1 }

        try? await h.controller.setRealtimeRawFlood(enabled: true)
        #expect(h.band.count == base + 2, "the toggle must not wait behind the wedged command")
        #expect(h.band.last?.cmd == 63)
        #expect(h.band.last?.payload == [0x01])

        try? await h.controller.setRealtimeRawFlood(enabled: false)
        #expect(h.band.count == base + 3)
        #expect(h.band.last?.payload == [0x00])

        await h.controller.connectionClosed()
        _ = await wedged.result
    }

    @Test func theRuntimeFloodToggleThrowsWhenDisabledOrUnlinked() async {
        let h = Harness(enabled: false)
        await h.controller.connectionOpened()
        do {
            try await h.controller.setRealtimeRawFlood(enabled: false)
            Issue.record("must throw while the channel is disabled")
        } catch {
            #expect((error as? TierBError) == .disabled)
        }
        #expect(h.band.count == 0)

        await h.controller.setEnabled(true)
        // Drop the link flag the disabled connectionOpened set, so the channel is back to
        // .awaitingLink without a live link (the transport reopens it on the next connection).
        await h.controller.connectionClosed()
        do {
            try await h.controller.setRealtimeRawFlood(enabled: true)
            Issue.record("must throw before the link opens")
        } catch {
            #expect((error as? TierBError) == .notConnected)
        }
        #expect(h.band.count == 0)
    }

    // MARK: Historical offload (PLAN.md 5.3.4)

    @Test func aStoppedDrainEmitsItsDecodedRecordsOnce() async throws {
        let h = Harness()
        await h.controller.connectionOpened()
        #expect(h.band.opcodes.contains(22), "the drain starts with SEND_HISTORICAL_DATA")
        #expect(h.band.opcodes.filter { $0 == 22 }.count == 1)

        let frame = historicalRecordFrame(unix: UInt32(ManualClock.origin.timeIntervalSince1970) - 3600)
        await h.controller.receive(frame)
        let record = try HistoricalRecord.parse(frame)

        let token: [UInt8] = [0x2E, 0x47, 0x01, 0x00, 0x04, 0x00, 0x00, 0x00]
        await h.controller.receive(metadataFrame(token: token))
        #expect(h.band.last?.cmd == 23, "the batch token is echoed as HISTORICAL_DATA_RESULT")
        #expect(h.band.last?.payload == [0x01] + token, "the ack leads with 0x01 (NOOP, verified on 4.0)")

        // The acked batch flushes immediately: the strap trims acked records permanently, so
        // holding them until the drain stops would lose them if the app died mid-drain.
        func historicalEvents() -> [[HistoricalRecord]] {
            h.events.all.compactMap { event -> [HistoricalRecord]? in
                if case let .historical(records) = event { return records }
                return nil
            }
        }
        #expect(historicalEvents() == [[record]])

        // The drain then goes quiet and stops; the flushed records are NOT emitted a second time.
        h.clock.advance(by: OffloadStateMachine.quietTimeout)
        await flush()
        #expect(historicalEvents() == [[record]], "records flush exactly once")
    }

    @Test func aLinkDropEmitsThePartialDrain() async throws {
        let h = Harness()
        await h.controller.connectionOpened()
        let frame = historicalRecordFrame(unix: UInt32(ManualClock.origin.timeIntervalSince1970) - 3600)
        await h.controller.receive(frame)
        let record = try HistoricalRecord.parse(frame)

        await h.controller.connectionClosed()
        let historical = h.events.all.compactMap { event -> [HistoricalRecord]? in
            if case let .historical(records) = event { return records }
            return nil
        }
        #expect(historical == [[record]])
        #expect(await h.controller.state == .awaitingLink)
    }

    /// The live UI gets start, throttled ack updates and a forced end, so a drain is visible
    /// while it runs without per-record emissions.
    @Test func drainProgressReportsStartThrottledAcksAndEnd() async throws {
        let h = Harness()
        await h.controller.connectionOpened()

        func progress() -> [DrainProgress] {
            h.events.all.compactMap { event in
                if case let .drainProgress(value) = event { return value }
                return nil
            }
        }

        let started = progress()
        #expect(started.count == 1)
        #expect(started.first?.phase == .draining)
        #expect(started.first?.recordsThisDrain == 0)
        #expect(started.first?.totalThisSession == 0)

        let base = UInt32(ManualClock.origin.timeIntervalSince1970)
        // The first ack lands in the same instant as the start emission, so it is throttled.
        await h.controller.receive(historicalRecordFrame(unix: base - 3600))
        await h.controller.receive(metadataFrame(token: [1, 0, 0, 0, 1, 0, 0, 0]))
        await flush()
        #expect(progress().count == 1, "acks within 0.5 s stay throttled")

        // Half a second later the next ack emits with the accumulated count.
        h.clock.advance(by: 0.5)
        await flush()
        await h.controller.receive(historicalRecordFrame(unix: base - 3599))
        await h.controller.receive(metadataFrame(token: [2, 0, 0, 0, 1, 0, 0, 0]))
        await flush()
        let acked = progress()
        #expect(acked.count == 2)
        #expect(acked.last?.phase == .draining)
        #expect(acked.last?.recordsThisDrain == 2)
        #expect(acked.last?.totalThisSession == 2)

        // The end always emits, with the stop reason and the final kept total.
        for _ in 0 ..< 8 {
            guard await h.controller.drainPhase == .draining else { break }
            h.clock.advance(by: OffloadStateMachine.quietTimeout)
            await flush()
        }
        #expect(await h.controller.drainPhase != .draining)
        let ended = progress()
        #expect(ended.count == 3)
        #expect(ended.last?.phase == .idle)
        #expect(ended.last?.stopReason == .quietTimeout)
        #expect(ended.last?.recordsThisDrain == 2)
        #expect(ended.last?.totalThisSession == 2)
    }

    // MARK: Full-history restore (app-deleted repopulation)

    /// The #791 capture's GET_DATA_RANGE reply payload (the envelope minus its [AA][size][crc8]
    /// head), with the ring words patched: W sits at payload offset 11, U at 15, T at 23 (and stays
    /// at the capture's 131072). Word offsets per NOOP's ring layout.
    private func ringPayload(write: UInt32, read: UInt32) -> [UInt8] {
        let capture = "aa4c00a7247e220a01010000000050070100a307010050070100000000000000020035030000" +
            "c2fc13008046394b00000000bbe1636aa02d0000bbe1636aa02d0000c6e4636ac07c000000000447ea04"
        var payload: [UInt8] = stride(from: 0, to: capture.count, by: 2).map { off in
            let start = capture.index(capture.startIndex, offsetBy: off)
            return UInt8(capture[start ..< capture.index(start, offsetBy: 2)], radix: 16)!
        }
        payload.removeFirst(7)
        payload.replaceSubrange(11 ..< 15, with: littleEndian(write))
        payload.replaceSubrange(15 ..< 19, with: littleEndian(read))
        return payload
    }

    private func historicalEvents(_ events: [BandEvent]) -> [[HistoricalRecord]] {
        events.compactMap { event -> [HistoricalRecord]? in
            if case let .historical(records) = event { return records }
            return nil
        }
    }

    /// Sets a scripted band up and starts `drainFullHistory`, returning (task, cmd-22 baseline).
    /// The connect drain is ended first (see `endRunningDrain`). The scripted band answers the
    /// range read and the realtime re-arm, stays silent on the rewind write and the batch ack
    /// (mirroring OpenStrap's reference client: confirmed writes, no replies awaited), and hands
    /// each drain kick to `respondToKick` (1-based) so a test can script a batch — the scripted
    /// records then arrive through the notify path.
    private func startScriptedRestore(_ h: Harness, ring: [UInt8],
                                      respondToKick: @escaping @Sendable (_ kick: Int) -> [Frame] = { _ in [] }) async -> (task: Task<Void, Never>, cmd22Baseline: Int) {
        await h.controller.connectionOpened()
        await endRunningDrain(h)
        let cmd22Baseline = h.band.opcodes.filter { $0 == 22 }.count
        let kicks = AtomicCounter()
        h.band.setMultiResponder { request, _ in
            switch request.cmd {
            case 34: return [reply(to: request, payload: ring)]
            case 22: return respondToKick(kicks.increment())
            case 3: return [reply(to: request, payload: [])]
            default: return []
            }
        }
        let task = Task { await h.controller.drainFullHistory() }
        await settle { h.band.opcodes.filter { $0 == 22 }.count == cmd22Baseline + 1 }
        return (task, cmd22Baseline)
    }

    /// The connect trigger starts its own drain as soon as Tier B is ready. A restore asked for
    /// during that drain must wait for it to end, not have its first kick denied as "0 drains".
    @Test func drainFullHistoryWaitsOutTheInFlightConnectDrain() async throws {
        let h = Harness()
        await h.controller.connectionOpened()
        #expect(await h.controller.drainPhase == .draining, "the connect trigger started a drain")
        let rangeReadsBefore = h.band.opcodes.filter { $0 == 34 }.count

        let complete = Frame(type: PacketType.metadata.rawValue, seq: 24, cmd: 3, payload: [])
        h.band.setMultiResponder { request, _ in
            switch request.cmd {
            case 34: return [reply(to: request, payload: ringPayload(write: 100, read: 0))]
            case 22: return [complete]
            case 3: return [reply(to: request, payload: [])]
            default: return []
            }
        }
        let task = Task { await h.controller.drainFullHistory() }
        await flush()
        #expect(h.band.opcodes.filter { $0 == 34 }.count == rangeReadsBefore,
                "the range read waits for the in-flight drain")
        #expect(await h.controller.fullHistorySummary == "draining…")

        await endRunningDrain(h)
        await task.value

        #expect(h.band.opcodes.filter { $0 == 34 }.count == rangeReadsBefore + 1,
                "the range read runs after the connect drain")
        #expect(await h.controller.fullHistorySummary?.contains("finished") == true)
    }

    /// The restore's spine: GET_DATA_RANGE reads U behind W → the cursor is rewound to the ring
    /// start, then drains run back to back, continuing while records arrive and stopping on the
    /// first empty drain. Every acked batch flushes exactly once.
    @Test func drainFullHistoryRewindsTheCursorAndDrainsUntilEmpty() async throws {
        let h = Harness()
        // Drain 1's kick streams nothing (the records arrive below via the notify path); the
        // SECOND drain's kick is answered with an immediate HISTORY_COMPLETE — an EMPTY drain
        // (kept 0) — so the restore stops there.
        let complete = Frame(type: PacketType.metadata.rawValue, seq: 24, cmd: 3, payload: [])
        let (task, cmd22Baseline) = await startScriptedRestore(h, ring: ringPayload(write: 100, read: 40)) {
            $0 == 1 ? [] : [complete]
        }
        let older = historicalRecordFrame(unix: UInt32(ManualClock.origin.timeIntervalSince1970) - 7200)
        let newer = historicalRecordFrame(unix: UInt32(ManualClock.origin.timeIntervalSince1970) - 3600)
        await h.controller.receive(older)
        await h.controller.receive(newer)
        await h.controller.receive(metadataFrame(token: [0x2E, 0x47, 0x01, 0x00, 0x04, 0x00, 0x00, 0x00]))
        #expect(h.band.last?.cmd == 23, "the batch token is echoed")
        let record1 = try HistoricalRecord.parse(older)
        let record2 = try HistoricalRecord.parse(newer)
        #expect(historicalEvents(h.events.all) == [[record1, record2]])

        // Drain 1 ends (its quiet deadline is armed by the batch; the run cap is the fallback)
        // having KEPT records → the restore kicks the next drain, which completes empty and stops
        // the restore.
        await endRunningDrain(h)
        await task.value

        #expect(h.band.opcodes.filter { $0 == 33 }.count == 1, "exactly one rewind")
        #expect(h.band.opcodes.filter { $0 == 22 }.count == cmd22Baseline + 2, "the restore stopped after the empty drain")
        #expect(historicalEvents(h.events.all) == [[record1, record2]], "the batch flushed exactly once")
        let lines = BandLog.capturedLines(2000)
        #expect(lines.contains { $0.contains("rewinding read cursor 40→0") })
        #expect(lines.contains { $0.contains("full-history restore finished: 2 drain(s), 2 record(s) re-drained") })
        #expect(await h.controller.ringState == RingState(write: 100, read: 40, capacity: 131_072))
    }

    /// HISTORY_COMPLETE is the strap's "the whole store is drained" marker: the restore stops even
    /// though the last drain kept records.
    @Test func drainFullHistoryStopsOnHistoryComplete() async throws {
        let h = Harness()
        let (task, cmd22Baseline) = await startScriptedRestore(h, ring: ringPayload(write: 100, read: 40))

        let frame = historicalRecordFrame(unix: UInt32(ManualClock.origin.timeIntervalSince1970) - 3600)
        await h.controller.receive(frame)
        await h.controller.receive(metadataFrame(token: [1, 0, 0, 0, 1, 0, 0, 0]))
        await h.controller.receive(Frame(type: PacketType.metadata.rawValue, seq: 24, cmd: 3, payload: []))
        await task.value

        #expect(h.band.opcodes.filter { $0 == 33 }.count == 1)
        #expect(h.band.opcodes.filter { $0 == 22 }.count == cmd22Baseline + 1, "the restore kicked exactly one drain")
        #expect(historicalEvents(h.events.all).count == 1)
        #expect(BandLog.capturedLines(2000).contains { $0.contains("HISTORY_COMPLETE after 1 record(s)") })
    }

    /// The cursor already at the rewind target needs no SET_READ_POINTER write; the restore just
    /// drains the backlog (the plain connect path's shape, now also available on demand).
    @Test func drainFullHistorySkipsTheRewindWhenTheCursorIsAlreadyAtTheTarget() async throws {
        let h = Harness()
        let (task, cmd22Baseline) = await startScriptedRestore(h, ring: ringPayload(write: 100, read: 0))

        await h.controller.receive(historicalRecordFrame(unix: UInt32(ManualClock.origin.timeIntervalSince1970) - 3600))
        await h.controller.receive(Frame(type: PacketType.metadata.rawValue, seq: 24, cmd: 3, payload: []))
        await task.value

        #expect(!h.band.opcodes.contains(33), "U == target → no rewind write")
        #expect(h.band.opcodes.filter { $0 == 22 }.count == cmd22Baseline + 1)
        #expect(BandLog.capturedLines(2000).contains { $0.contains("full-history restore finished: 1 drain(s), 1 record(s) re-drained") })
    }

    /// An unreadable range aborts the restore before anything is written: without the ring state
    /// there is no honest rewind target, and guessing 0 could desync a healthy cursor.
    @Test func drainFullHistoryAbortsWhenTheRingStateIsUnreadable() async {
        let h = Harness()
        await h.controller.connectionOpened()
        await endRunningDrain(h) // end the connect drain before the restore's first kick
        let cmd22Baseline = h.band.opcodes.filter { $0 == 22 }.count

        await h.controller.drainFullHistory()

        #expect(!h.band.opcodes.contains(33))
        #expect(h.band.opcodes.filter { $0 == 22 }.count == cmd22Baseline, "no drain was kicked")
        #expect(await h.controller.ringState == nil)
        #expect(BandLog.capturedLines(2000).contains { $0.contains("full-history restore aborted: the GET_DATA_RANGE reply's ring state is unreadable") })
    }

    /// The guards: a disabled channel and an unopened link are no-ops that send nothing.
    @Test func drainFullHistoryIsANoOpWhenTheChannelIsOffOrTheLinkIsDown() async {
        let disabled = Harness(enabled: false)
        await disabled.controller.drainFullHistory()
        #expect(disabled.band.count == 0)

        let unlinked = Harness(responder: nil)
        await unlinked.controller.drainFullHistory()
        #expect(unlinked.band.count == 0, "state is .awaitingLink — never .ready")
    }
}

@Suite("Rhythm playback (PLAN.md 9.2)")
struct RhythmPlaybackTests {
    @Test func stepsStartOnTheirOwnTimeline() async throws {
        let h = Harness()
        await h.controller.connectionOpened()
        // Buzz: 2 loops at 1 s each. Pause: 500 ms. Buzz: 1 loop. Total 3.5 s.
        let rhythm = try Rhythm(steps: [.buzz(preset: 2, loops: 2), .pause(ms: 500), .buzz(preset: 3, loops: 1)])
        #expect(rhythm.durationSeconds == 3.5)
        let base = h.band.count

        let task = Task { try await h.controller.runRhythm(rhythm) }
        await settle { h.band.count == base + 1 }
        #expect(h.band.last?.cmd == 79)
        #expect(h.band.last?.payload == [2, 2, 0, 0, 0])

        await settle { h.clock.sleeperCount == 4 }
        h.clock.advance(by: 1.5)
        await flush()
        #expect(h.band.count == base + 1, "the pause must not start before the buzz slot ends")

        h.clock.advance(by: 0.5)
        await settle { h.clock.sleeperCount == 4 }
        await flush()
        #expect(h.band.count == base + 1, "the pause runs for 500 ms before the next buzz")

        h.clock.advance(by: 0.5)
        await settle { h.band.count == base + 2 }
        #expect(h.band.last?.payload == [3, 1, 0, 0, 0])

        await settle { h.clock.sleeperCount == 4 }
        h.clock.advance(by: 1)
        try await task.value
        #expect(Array(h.band.opcodes.suffix(2)) == [79, 79])
        #expect(!h.band.opcodes.contains(122), "a finished rhythm sends no STOP_HAPTICS")
    }

    @Test func cancelStopsTheRhythmAndSendsStopHapticsOnce() async throws {
        let h = Harness()
        await h.controller.connectionOpened()
        let rhythm = try Rhythm(steps: [.buzz(preset: 2, loops: 5), .buzz(preset: 4, loops: 1)])
        let base = h.band.count

        await h.controller.startRhythm(rhythm)
        await settle { h.band.count == base + 1 }
        await settle { h.clock.sleeperCount == 4 }

        await h.controller.stopHaptics()
        #expect(Array(h.band.opcodes.suffix(2)) == [79, 122])

        // Just under the realtime re-arm interval, so the keep-alive does not add a write here.
        h.clock.advance(by: TierBController.realtimeRearmInterval - 1)
        await flush()
        #expect(h.band.count == base + 2, "nothing is sent after the cancel")
    }

    @Test func aNewRhythmReplacesTheRunningOneWithoutAStopBetween() async throws {
        let h = Harness()
        await h.controller.connectionOpened()
        let base = h.band.count
        await h.controller.startRhythm(try Rhythm(steps: [.buzz(preset: 2, loops: 5)]))
        await settle { h.band.count == base + 1 }
        await settle { h.clock.sleeperCount == 4 }

        await h.controller.startRhythm(try Rhythm(steps: [.buzz(preset: 4, loops: 1)]))
        await settle { h.band.count == base + 3 }
        // The old rhythm is cancelled and its STOP is sent before the new RUN, so the new buzz is not cut short.
        #expect(Array(h.band.opcodes.suffix(3)) == [79, 122, 79])
        #expect(h.band.last?.payload == [4, 1, 0, 0, 0])
        await flush()
    }

    @Test func aRhythmIsRefusedUntilTheLinkIsReady() async throws {
        let h = Harness()
        let rhythm = try Rhythm(steps: [.buzz(preset: 2, loops: 1)])
        do {
            try await h.controller.runRhythm(rhythm)
            Issue.record("runRhythm must throw before the handshake")
        } catch {
            #expect((error as? TierBError) == .notReady)
        }
        #expect(h.band.count == 0)
    }
}

@Suite("Tier B transport stubs (UI tests)")
struct TierBTransportStubTests {
    @Test func fixtureTransportRecordsTierBRequestsWithoutSending() async throws {
        let transport = FixtureTransport(ndjson: "")
        let rhythm = try Rhythm(steps: [.pause(ms: 100)])
        await transport.setTierBEnabled(true)
        await transport.runRhythm(rhythm)
        await transport.stopHaptics()
        await transport.armBandAlarm(at: nil)
        #expect(await transport.tierBRequests == [.setEnabled(true), .runRhythm(rhythm), .stopHaptics, .armAlarm(nil)])
    }

    @Test func syntheticTransportRecordsTierBRequestsWithoutSending() async {
        let transport = SyntheticTransport(seed: 1, maxSamples: 0)
        await transport.setTierBEnabled(false)
        #expect(await transport.tierBRequests == [.setEnabled(false)])
    }
}
