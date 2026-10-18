import BandKit
import BandProtocol
import Foundation
import Testing

@Suite("TierBController queue, handshake and safety")
struct TierBControllerTests {
    private let alarmOpcode: UInt8 = 66
    private let batteryOpcode: UInt8 = 26

    // MARK: Handshake

    @Test func handshakeSetsTheClockThenReadsTheClockAndRangeOncePerConnection() async {
        let h = Harness()
        await h.controller.connectionOpened()
        await h.controller.connectionOpened()
        // The handshake writes SET_CLOCK in BOTH forms (8-byte and legacy 9-byte: which one a given
        // firmware latches is firmware-specific), then hello, clock, range, battery, realtime, drain.
        #expect(h.band.opcodes == [10, 10, 35, 11, 34, 26, 3, 22])
        #expect(h.band.opcodes.filter { $0 == 10 }.count == 2, "both SET_CLOCK forms per connection")
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
        #expect(h.band.opcodes == [10, 10, 35, 11, 34, 26, 3, 22, 10, 10, 35, 11, 34, 3, 22])
    }

    @Test func aSilentBandFailsTheHandshakeAfterRetriesAndStaysUnavailable() async {
        let h = Harness(responder: nil)
        let opening = Task { await h.controller.connectionOpened() }
        for attempt in 1 ... 4 {
            // +2: the two SET_CLOCK writes precede the retried GET_HELLO.
            await settle { h.band.count >= attempt + 2 }
            await settle { h.clock.sleeperCount == 1 }
            h.clock.advance(by: TierBController.responseTimeout)
        }
        await opening.value
        #expect(await h.controller.state == .unavailable)
        #expect(h.band.opcodes == [10, 10, 35, 35, 35, 35])
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
            // Attempt timer + realtime keep-alive + offload cadence.
            await settle { h.clock.sleeperCount == 3 }
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
        await settle { h.clock.sleeperCount == 3 }
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
        await settle { h.clock.sleeperCount == 3 }
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
        await settle { h.clock.sleeperCount == 3 }
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
        #expect(h.band.opcodes == [10, 10, 35, 11, 34, 26, 3, 22])
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
        #expect(h.band.opcodes == [10, 10, 35, 11, 34, alarmOpcode, batteryOpcode, 3, 22])
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

    /// SET_CLOCK goes out in both forms per connection (8-byte and legacy 9-byte): which one a
    /// given firmware latches is firmware-specific (NOOP hardware-verified), and double-latching
    /// the same seconds is harmless.
    @Test func setClockIsWrittenTwicePerConnectionInBothForms() async {
        let h = Harness()
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

        await settle { h.clock.sleeperCount == 3 }
        h.clock.advance(by: 1.5)
        await flush()
        #expect(h.band.count == base + 1, "the pause must not start before the buzz slot ends")

        h.clock.advance(by: 0.5)
        await settle { h.clock.sleeperCount == 3 }
        await flush()
        #expect(h.band.count == base + 1, "the pause runs for 500 ms before the next buzz")

        h.clock.advance(by: 0.5)
        await settle { h.band.count == base + 2 }
        #expect(h.band.last?.payload == [3, 1, 0, 0, 0])

        await settle { h.clock.sleeperCount == 3 }
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
        await settle { h.clock.sleeperCount == 3 }

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
        await settle { h.clock.sleeperCount == 3 }

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
