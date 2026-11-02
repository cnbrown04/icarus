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
        #expect(h.band.opcodes == [35, 11, 11, 34, 26, 98, 3, 22])
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
        #expect(h.band.opcodes == [35, 11, 11, 34, 26, 98, 3, 22, 35, 11, 11, 34, 3])
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
        // The handshake now ends with GET_EXTENDED_BATTERY_INFO (8 writes), so the first command is the 9th.
        await settle { h.band.count == 9 }
        await flush()
        #expect(h.band.count == 9, "the second command must wait for the first reply")
        #expect(h.band.last?.cmd == 67)

        await h.controller.receive(reply(to: h.band.last!))
        let firstReply = try await first.value
        #expect(firstReply.cmd == 67)

        await settle { h.band.count == 10 }
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
            // Attempt timer + realtime re-arm + LINK_VALID keep-alive + offload cadence + drain run cap.
            await settle { h.clock.sleeperCount == 5 }
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
        await settle { h.clock.sleeperCount == 5 }
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
        await settle { h.clock.sleeperCount == 5 }
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
        await settle { h.clock.sleeperCount == 5 }
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
        #expect(h.band.opcodes == [35, 11, 11, 34, 26, 98, 3, 22])
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

    /// The band stamps its events: bytes 1–4 of the payload are unix seconds (payload of a real charging-on event).
    @Test func eventsCarryTheBandsOwnTime() {
        let arrived = Date(timeIntervalSince1970: 1_793_584_800)
        let event = BandEventRecord(id: 7, payload: [0x00, 0x42, 0xEE, 0xE7, 0x6A, 0x58, 0x3D, 0x00, 0x00], at: arrived)
        #expect(event.bandTime == Date(timeIntervalSince1970: 0x6AE7_EE42))
        let notATime = BandEventRecord(id: 7, payload: [0x00, 0x01, 0x00, 0x00, 0x00], at: arrived)
        #expect(notATime.bandTime == nil)
        #expect(BandEventRecord(id: 7, payload: [0x00], at: arrived).bandTime == nil)
    }

    @Test func bandEventsAreEmittedAndUnknownIdsAreKept() async {
        let h = Harness()
        await h.controller.connectionOpened()
        for id: UInt8 in [9, 10, 14, 23, 24] {
            await h.controller.receive(eventFrame(id))
        }
        #expect(h.events.all.hasBandEvent(.wristOn))
        #expect(h.events.all.hasBandEvent(.wristOff))
        #expect(h.events.all.hasBandEvent(.doubleTap))
        #expect(h.events.all.hasBandEvent(.bleBonded))
        #expect(h.events.all.hasBandEvent(.unknown(24)))
        // The whole event travels: its id and payload, so an unnamed id can be identified later.
        let unknown = h.events.all.compactMap { event -> BandEventRecord? in
            if case let .bandEvent(record) = event, record.id == 24 { record } else { nil }
        }
        #expect(unknown.count == 1)
    }

    /// The battery EVENT (id 3) carries a percent [Unverified]; the controller decodes it and
    /// emits the same `.battery` the GET_BATTERY_LEVEL reply produces.
    @Test func aBatteryEventAlsoEmitsItsDecodedPercent() async {
        let h = Harness()
        await h.controller.connectionOpened()
        await h.controller.receive(Frame(type: PacketType.event.rawValue, seq: 0, cmd: 3, payload: [0xD8, 0x03]))
        #expect(h.events.all.hasBandEvent(.batteryLevel))
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
        // SET_ALARM_TIME, then the GET_ALARM_TIME read-back.
        #expect(h.band.count == base + 2)
        let alarm = h.band.commands[base]
        #expect(alarm.cmd == alarmOpcode)
        // 1_791_382_800 (2026-10-08 ... + 300 s from the test origin), little-endian, inside the golden layout.
        #expect(alarm.payload == [0x01, 0x10, 0x55, 0xC6, 0x6A, 0, 0, 0, 0])
        #expect(alarm.payload == BandCommand.setAlarmTime(unix: UInt32(soon.timeIntervalSince1970)).payload)

        await h.controller.armAlarms([later, past, soon])
        #expect(h.band.count == base + 2, "the same next occurrence is not sent twice")
    }

    @Test func rearmsTheNextAlarmAfterTheBandReportsOneExecuted() async {
        let h = Harness()
        await h.controller.connectionOpened()
        let now = h.clock.now()
        let soon = now.addingTimeInterval(300)
        let later = now.addingTimeInterval(900)
        await h.controller.armAlarms([soon, later])
        // The last SET_ALARM_TIME; the GET_ALARM_TIME read-back after it is not an arming.
        let lastArming = { h.band.commands.last { $0.cmd == alarmOpcode } }
        #expect(lastArming()?.payload == BandCommand.setAlarmTime(unix: UInt32(soon.timeIntervalSince1970)).payload)

        await h.controller.receive(eventFrame(57))
        #expect(h.events.all.hasBandEvent(.strapDrivenAlarmExecuted))
        #expect(lastArming()?.payload == BandCommand.setAlarmTime(unix: UInt32(later.timeIntervalSince1970)).payload)
    }

    @Test func alarmsSetBeforeTheLinkAreSentAfterTheHandshake() async {
        let h = Harness()
        await h.controller.armAlarms([h.clock.now().addingTimeInterval(300)])
        #expect(h.band.count == 0)
        await h.controller.connectionOpened()
        // Arming reads back once (67) before the battery poll (26, 98).
        #expect(h.band.opcodes == [35, 11, 11, 34, alarmOpcode, 67, batteryOpcode, 98, 3, 22])
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
        #expect(setClocks[0].payload == secs + [0, 0, 0, 0] + [0], "the 8-byte form first, plus one zero of command padding")
        #expect(setClocks[1].payload == secs + [0, 0, 0, 0, 0], "then the legacy 9-byte form")
        #expect(setClocks[2].payload == secs + [0, 0, 0, 0] + [0])
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

    /// Regression (device log 2026-10-23): the strap streams history and does not answer the 30 s
    /// TOGGLE_REALTIME_HR re-arm. The re-arm must be written once and left alone, not waited on, timed
    /// out and retried while the drain runs.
    @Test func aRealtimeRearmDuringADrainIsWrittenOnceAndNotRetried() async {
        let h = Harness()
        await h.controller.connectionOpened()
        let armsBefore = h.band.opcodes.filter { $0 == 3 }.count
        // From here on the strap answers everything except the realtime toggle.
        h.band.setResponder { request, index in request.cmd == 3 ? nil : answerAll(request, index) }

        // A record and its batch metadata every 5 s keep the drain running (quiet deadline 8 s, run cap 60 s)
        // across the 30 s re-arm, as a streaming strap does.
        let base = UInt32(ManualClock.origin.timeIntervalSince1970)
        for step in 0 ..< 7 {
            h.clock.advance(by: 5)
            await flush()
            await h.controller.receive(historicalRecordFrame(unix: base - 3600 + UInt32(step)))
            await h.controller.receive(metadataFrame(token: [UInt8(step + 1), 0, 0, 0, 1, 0, 0, 0]))
            await flush()
        }
        #expect(await h.controller.drainPhase == .draining)
        #expect(h.band.opcodes.filter { $0 == 3 }.count == armsBefore + 1, "the re-arm is written once at 30 s")

        // Past the 5 s response timeout a waiting re-arm would retry here. A fire-and-forget one does not.
        h.clock.advance(by: TierBController.responseTimeout)
        await flush()
        #expect(h.band.opcodes.filter { $0 == 3 }.count == armsBefore + 1, "no timeout, no retry")
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

    /// Persist-then-ack: with a sink installed the batch is stored BEFORE its ack is written, and
    /// the store's verdict decides whether the ack goes out at all.
    @Test func aSinkStoresTheBatchBeforeTheAck() async throws {
        let h = Harness()
        let stored = SinkRecorder(succeeds: true, band: h.band)
        await h.controller.setHistoricalSink { await stored.store($0) }
        await h.controller.connectionOpened()
        let frame = historicalRecordFrame(unix: UInt32(ManualClock.origin.timeIntervalSince1970) - 3600)
        await h.controller.receive(frame)
        let record = try HistoricalRecord.parse(frame)

        let token: [UInt8] = [0x2E, 0x47, 0x01, 0x00, 0x04, 0x00, 0x00, 0x00]
        await h.controller.receive(metadataFrame(token: token))
        #expect(await stored.batches == [[record]])
        #expect(await stored.acksSeenWhileStoring == 0, "the store ran before any ack was written")
        #expect(h.band.last?.cmd == 23, "the stored batch is acked")
        // The UI event still follows the store, exactly once.
        let historical = h.events.all.compactMap { event -> [HistoricalRecord]? in
            if case let .historical(records) = event { return records }
            return nil
        }
        #expect(historical == [[record]])
    }

    @Test func aFailedStoreLeavesTheBatchUnacked() async throws {
        let h = Harness()
        let stored = SinkRecorder(succeeds: false, band: h.band)
        await h.controller.setHistoricalSink { await stored.store($0) }
        await h.controller.connectionOpened()
        await h.controller.receive(historicalRecordFrame(unix: UInt32(ManualClock.origin.timeIntervalSince1970) - 3600))
        await h.controller.receive(metadataFrame(token: [0x2E, 0x47, 0x01, 0x00, 0x04, 0x00, 0x00, 0x00]))
        #expect(await stored.batches.count == 1)
        #expect(!h.band.opcodes.contains(23), "an unstored batch must not be acked; the strap re-sends it")
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

    // MARK: Sync of pending history (the History "Sync all pending band data" button)

    private func historicalEvents(_ events: [BandEvent]) -> [[HistoricalRecord]] {
        events.compactMap { event -> [HistoricalRecord]? in
            if case let .historical(records) = event { return records }
            return nil
        }
    }

    /// Sets a scripted band up and starts `drainFullHistory`, returning (task, cmd-22 baseline).
    /// The connect drain is ended first (see `endRunningDrain`). The scripted band stays silent on the
    /// batch ack (mirroring OpenStrap's reference client: confirmed writes, no replies awaited) and hands
    /// each drain kick to `respondToKick` (1-based), so a test can script a batch: the scripted records
    /// then arrive through the notify path.
    private func startScriptedSync(_ h: Harness,
                                   respondToKick: @escaping @Sendable (_ kick: Int) -> [Frame] = { _ in [] }) async -> (task: Task<Void, Never>, cmd22Baseline: Int) {
        await h.controller.connectionOpened()
        await endRunningDrain(h)
        let cmd22Baseline = h.band.opcodes.filter { $0 == 22 }.count
        let kicks = AtomicCounter()
        h.band.setMultiResponder { request, _ in
            switch request.cmd {
            // The sync reads the backlog first: 60 pages pending.
            case 34: return [reply(to: request, payload: ringPayload(write: 100, read: 40))]
            case 22: return respondToKick(kicks.increment())
            case 3: return [reply(to: request, payload: [])]
            default: return []
            }
        }
        let task = Task { await h.controller.drainFullHistory() }
        await settle { h.band.opcodes.filter { $0 == 22 }.count == cmd22Baseline + 1 }
        return (task, cmd22Baseline)
    }

    /// Ends the running drain like `endRunningDrain`, but stops as soon as the sync kicks the next drain.
    /// `endRunningDrain` keeps advancing until the phase leaves `.draining`, which would also end the
    /// next drain the moment the sync starts it.
    private func endDrainUntilNextKick(_ h: Harness) async {
        let kicks = h.band.opcodes.filter { $0 == 22 }.count
        for _ in 0 ..< 8 {
            guard await h.controller.drainPhase == .draining, h.band.opcodes.filter({ $0 == 22 }).count == kicks else { return }
            h.clock.advance(by: OffloadStateMachine.runCap)
            await flush()
        }
        Issue.record("the drain did not end")
    }

    /// The connect trigger starts its own drain as soon as Tier B is ready. A sync asked for during that
    /// drain must wait for it to end, not have its first kick denied as "0 drains".
    @Test func drainFullHistoryWaitsOutTheInFlightConnectDrain() async throws {
        let h = Harness()
        await h.controller.connectionOpened()
        #expect(await h.controller.drainPhase == .draining, "the connect trigger started a drain")
        let kicksBefore = h.band.opcodes.filter { $0 == 22 }.count

        let complete = Frame(type: PacketType.metadata.rawValue, seq: 24, cmd: 3, payload: [])
        h.band.setMultiResponder { request, _ in
            switch request.cmd {
            case 34: return [reply(to: request, payload: ringPayload(write: 100, read: 40))]
            case 22: return [complete]
            case 3: return [reply(to: request, payload: [])]
            default: return []
            }
        }
        let task = Task { await h.controller.drainFullHistory() }
        await flush()
        #expect(h.band.opcodes.filter { $0 == 22 }.count == kicksBefore, "the sync's kick waits for the in-flight connect drain")
        #expect(await h.controller.fullHistorySummary == "draining…")

        await endRunningDrain(h)
        await task.value

        #expect(h.band.opcodes.filter { $0 == 22 }.count == kicksBefore + 1, "one kick after the connect drain ends")
        #expect(await h.controller.fullHistorySummary == "synced: 1 drain(s), 0 record(s)")
    }

    /// Back-to-back drains continue while records arrive and stop on the first empty drain: drain 1 keeps
    /// two records, drain 2 keeps one, drain 3 completes empty. Every batch flushes exactly once, and the
    /// summary reports the oldest and newest kept records.
    @Test func drainFullHistoryKeepsDrainingWhileRecordsArriveAndStopsOnAnEmptyDrain() async throws {
        let h = Harness()
        let complete = Frame(type: PacketType.metadata.rawValue, seq: 24, cmd: 3, payload: [])
        let origin = UInt32(ManualClock.origin.timeIntervalSince1970)
        let record1 = historicalRecordFrame(unix: origin - 7200)
        let record2 = historicalRecordFrame(unix: origin - 3600)
        let record3 = historicalRecordFrame(unix: origin - 1800)
        let token1 = metadataFrame(token: [0x2E, 0x47, 0x01, 0x00, 0x04, 0x00, 0x00, 0x00])
        let token2 = metadataFrame(token: [0x2E, 0x47, 0x01, 0x00, 0x05, 0x00, 0x00, 0x00])
        // Each kick's batch arrives in its reply, as the scripted band delivers it: drain 1 keeps two
        // records, drain 2 keeps one, drain 3 completes empty.
        let (task, cmd22Baseline) = await startScriptedSync(h) { kick in
            switch kick {
            case 1: return [record1, record2, token1]
            case 2: return [record3, token2]
            default: return [complete]
            }
        }
        // Each batch is acked (cmd 23) once its batch-end marker has been handled.
        await endDrainUntilNextKick(h)
        await settle { h.band.opcodes.filter { $0 == 22 }.count == cmd22Baseline + 2 }
        await endDrainUntilNextKick(h)
        await task.value

        let parsed1 = try HistoricalRecord.parse(record1)
        let parsed2 = try HistoricalRecord.parse(record2)
        let parsed3 = try HistoricalRecord.parse(record3)
        #expect(h.band.opcodes.filter { $0 == 22 }.count == cmd22Baseline + 3, "drain 3 is the empty one that stops the sync")
        #expect(historicalEvents(h.events.all) == [[parsed1, parsed2], [parsed3]], "each batch flushed exactly once")
        let summary = await h.controller.fullHistorySummary ?? ""
        #expect(summary.hasPrefix("synced: 3 drain(s), 3 record(s), oldest "), "\(summary)")
        #expect(summary.hasSuffix("(1.5 h)"), "the newest record is 1.5 h after the oldest")
        #expect(BandLog.capturedLines(2000).contains { $0.contains("the last drain completed empty — stopping") })
    }

    /// A sync never writes SET_READ_POINTER (cmd 33): the band's cursor word is not where a drain
    /// starts, so a rewind would only confirm a move that changes nothing.
    @Test func drainFullHistoryNeverSendsSetReadPointer() async throws {
        let h = Harness()
        let complete = Frame(type: PacketType.metadata.rawValue, seq: 24, cmd: 3, payload: [])
        let (task, cmd22Baseline) = await startScriptedSync(h) { _ in [complete] }
        await task.value

        #expect(h.band.opcodes.filter { $0 == 22 }.count == cmd22Baseline + 1, "one empty drain, then stop")
        #expect(!h.band.opcodes.contains(33), "no SET_READ_POINTER was written")
        #expect(await h.controller.fullHistorySummary == "synced: 1 drain(s), 0 record(s)")
    }

    /// Nothing pending (W == U) ends the sync at once with an "up to date" summary and no drain at all,
    /// instead of a silent drain that waits out its run cap.
    @Test func drainFullHistoryWithNothingPendingIsUpToDateWithoutADrain() async throws {
        let h = Harness()
        await h.controller.connectionOpened()
        await endRunningDrain(h)
        let kicksBefore = h.band.opcodes.filter { $0 == 22 }.count
        h.band.setMultiResponder { request, _ in
            request.cmd == 34 ? [reply(to: request, payload: ringPayload(write: 40, read: 40))] : []
        }
        await h.controller.drainFullHistory()
        #expect(h.band.opcodes.filter { $0 == 22 }.count == kicksBefore, "no drain was kicked")
        #expect(await h.controller.fullHistorySummary == "up to date: nothing pending on the band")
    }

    /// A full sync reports how far through its backlog it is: 60 pages pending from page 40, and a batch acked
    /// at page 70 is half way.
    @Test func drainFullHistoryReportsItsProgressFraction() async throws {
        let h = Harness()
        let origin = UInt32(ManualClock.origin.timeIntervalSince1970)
        let complete = Frame(type: PacketType.metadata.rawValue, seq: 24, cmd: 3, payload: [])
        let record = historicalRecordFrame(unix: origin - 3600)
        let halfway = metadataFrame(token: [70, 0, 0, 0, 1, 0, 0, 0])
        let (task, _) = await startScriptedSync(h) { kick in kick == 1 ? [record, halfway] : [complete] }
        // Mid-drain emissions are throttled on the (frozen) test clock; the drain-end emission is forced.
        await endDrainUntilNextKick(h)
        await task.value
        let fractions = h.events.all.compactMap { event -> Double? in
            if case let .drainProgress(progress) = event { return progress.fraction }
            return nil
        }
        #expect(fractions.contains(0.5), "\(fractions)")
    }

    /// Runs a sync against a scripted ring strap to its end. The connect drain is ended first, and the
    /// strap's newest record is stamped with the clock's now at that point, so the drain reaches the live edge.
    private func runRingSync(capacity: Int, write: Int, cursor: Int, wrapped: Bool) async -> (Harness, RingStrap) {
        let h = Harness()
        await h.controller.connectionOpened()
        await endRunningDrain(h)
        let strap = RingStrap(capacity: capacity, write: write, cursor: cursor, wrapped: wrapped, newest: h.clock.now())
        h.band.setMultiResponder { request, _ in strap.respond(to: request) }
        await h.controller.drainFullHistory()
        return (h, strap)
    }

    /// The strap streams from its own internal position, so one drain carries everything from there up to
    /// the live edge, and the sync stops there. Nothing is rewound.
    @Test func syncStopsAtTheLiveEdgeWithoutAnyRewind() async throws {
        let (_, strap) = await runRingSync(capacity: 1000, write: 950, cursor: 70, wrapped: true)
        #expect(strap.rewinds.isEmpty, "no SET_READ_POINTER was written")
        #expect(BandLog.capturedLines(2000).contains { $0.contains("caught up to the live edge after 880 record(s)") })
    }

    /// The summary carries the kept count and the oldest record's age behind the newest. Slots 70…949
    /// are 880 records, 36 s apart, so the oldest is 879 × 36 s = 8.8 h behind the newest.
    @Test func syncSummaryReportsTheOldestAndNewestRecord() async throws {
        let (h, _) = await runRingSync(capacity: 1000, write: 950, cursor: 70, wrapped: true)
        #expect(await h.controller.fullHistorySummary?.hasPrefix("synced: 1 drain(s), 880 record(s), oldest ") == true)
        #expect(await h.controller.fullHistorySummary?.hasSuffix("(8.8 h)") == true)
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

        await settle { h.clock.sleeperCount == 5 }
        h.clock.advance(by: 1.5)
        await flush()
        #expect(h.band.count == base + 1, "the pause must not start before the buzz slot ends")

        h.clock.advance(by: 0.5)
        await settle { h.clock.sleeperCount == 5 }
        await flush()
        #expect(h.band.count == base + 1, "the pause runs for 500 ms before the next buzz")

        h.clock.advance(by: 0.5)
        await settle { h.band.count == base + 2 }
        #expect(h.band.last?.payload == [3, 1, 0, 0, 0])

        await settle { h.clock.sleeperCount == 5 }
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
        await settle { h.clock.sleeperCount == 5 }

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
        await settle { h.clock.sleeperCount == 5 }

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

/// A history sink that records its batches and how many acks the band had seen when each arrived.
private actor SinkRecorder {
    let succeeds: Bool
    let band: FakeBand
    private(set) var batches: [[HistoricalRecord]] = []
    private(set) var acksSeenWhileStoring = 0

    init(succeeds: Bool, band: FakeBand) {
        self.succeeds = succeeds
        self.band = band
    }

    func store(_ records: [HistoricalRecord]) -> Bool {
        batches.append(records)
        acksSeenWhileStoring += band.opcodes.filter { $0 == 23 }.count
        return succeeds
    }
}
