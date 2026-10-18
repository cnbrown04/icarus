import BandKit
import BandProtocol
import Foundation
import Testing

@Suite("TierBController queue, handshake and safety")
struct TierBControllerTests {
    private let alarmOpcode: UInt8 = 66
    private let batteryOpcode: UInt8 = 26

    // MARK: Handshake

    @Test func handshakeReadsTheClockAndRangeOnceAndNeverSetsTheClock() async {
        let h = Harness()
        await h.controller.connectionOpened()
        await h.controller.connectionOpened()
        #expect(h.band.opcodes == [11, 34, 26])
        #expect(!h.band.opcodes.contains(10))
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
        #expect(h.band.opcodes == [11, 34, 26, 11, 34])
    }

    @Test func aSilentBandFailsTheHandshakeAfterRetriesAndStaysUnavailable() async {
        let h = Harness(responder: nil)
        let opening = Task { await h.controller.connectionOpened() }
        for attempt in 1 ... 4 {
            await settle { h.band.count == attempt }
            await settle { h.clock.sleeperCount == 1 }
            h.clock.advance(by: TierBController.responseTimeout)
        }
        await opening.value
        #expect(await h.controller.state == .unavailable)
        #expect(h.band.opcodes == [11, 11, 11, 11])
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
        await settle { h.band.count == 4 }
        await flush()
        #expect(h.band.count == 4, "the second command must wait for the first reply")
        #expect(h.band.last?.cmd == 67)

        await h.controller.receive(reply(to: h.band.last!))
        let firstReply = try await first.value
        #expect(firstReply.cmd == 67)

        await settle { h.band.count == 5 }
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
            await settle { h.clock.sleeperCount == 1 }
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
        await settle { h.clock.sleeperCount == 1 }
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
        await settle { h.clock.sleeperCount == 1 }
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
        await settle { h.clock.sleeperCount == 1 }
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
        #expect(h.band.opcodes == [11, 34, 26])
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
        #expect(h.band.opcodes == [11, 34, alarmOpcode, batteryOpcode])
    }

    @Test func alarmTimesOutsideTheUInt32RangeAreNotSent() async {
        let h = Harness()
        await h.controller.connectionOpened()
        let base = h.band.count
        await h.controller.armAlarms([Date(timeIntervalSince1970: 5_000_000_000)])
        #expect(h.band.count == base)
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

        await settle { h.clock.sleeperCount == 1 }
        h.clock.advance(by: 1.5)
        await flush()
        #expect(h.band.count == base + 1, "the pause must not start before the buzz slot ends")

        h.clock.advance(by: 0.5)
        await settle { h.clock.sleeperCount == 1 }
        await flush()
        #expect(h.band.count == base + 1, "the pause runs for 500 ms before the next buzz")

        h.clock.advance(by: 0.5)
        await settle { h.band.count == base + 2 }
        #expect(h.band.last?.payload == [3, 1, 0, 0, 0])

        await settle { h.clock.sleeperCount == 1 }
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
        await settle { h.clock.sleeperCount == 1 }

        await h.controller.stopHaptics()
        #expect(Array(h.band.opcodes.suffix(2)) == [79, 122])

        h.clock.advance(by: 60)
        await flush()
        #expect(h.band.count == base + 2, "nothing is sent after the cancel")
    }

    @Test func aNewRhythmReplacesTheRunningOneWithoutAStopBetween() async throws {
        let h = Harness()
        await h.controller.connectionOpened()
        let base = h.band.count
        await h.controller.startRhythm(try Rhythm(steps: [.buzz(preset: 2, loops: 5)]))
        await settle { h.band.count == base + 1 }
        await settle { h.clock.sleeperCount == 1 }

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
