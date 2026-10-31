import BandKit
import BandProtocol
import Foundation
import Testing

@Suite("Band diagnostics: keep-alive, charging, console, alarm read-back")
struct BandDiagnosticsTests {
    private func count(_ h: Harness, _ opcode: UInt8) -> Int {
        h.band.opcodes.filter { $0 == opcode }.count
    }

    // MARK: LINK_VALID keep-alive (cmd 1)

    @Test func keepAliveIsNotSentBeforeTheLinkIsReady() async {
        let h = Harness()
        h.clock.advance(by: TierBController.linkValidInterval * 3)
        await flush()
        #expect(count(h, 1) == 0)
    }

    @Test func keepAliveWritesLinkValidEveryIntervalWhileReady() async {
        let h = Harness()
        await h.controller.connectionOpened()
        #expect(await h.controller.state == .ready)
        await settle { h.clock.sleeperCount > 0 }

        h.clock.advance(by: TierBController.linkValidInterval)
        await flush()
        #expect(count(h, 1) == 1)
        #expect(h.band.commands.last { $0.cmd == 1 }?.payload == [0x00])
        #expect(await h.controller.lastLinkValidAt != nil)
        #expect(h.events.all.contains(.linkKeepAlive(sentAt: h.clock.now(), consecutiveFailures: 0)))

        h.clock.advance(by: TierBController.linkValidInterval)
        await flush()
        #expect(count(h, 1) == 2)
    }

    @Test func keepAliveStopsWhenTheChannelIsSwitchedOffOrTheLinkCloses() async {
        let h = Harness()
        await h.controller.connectionOpened()
        await settle { h.clock.sleeperCount > 0 }

        await h.controller.setEnabled(false)
        let afterDisable = count(h, 1)
        h.clock.advance(by: TierBController.linkValidInterval * 4)
        await flush()
        #expect(count(h, 1) == afterDisable, "no LINK_VALID once the channel is off")

        await h.controller.setEnabled(true)
        await h.controller.connectionOpened()
        await settle { h.clock.sleeperCount > 0 }
        let beforeClose = count(h, 1)
        h.clock.advance(by: TierBController.linkValidInterval)
        await flush()
        #expect(count(h, 1) == beforeClose + 1, "a fresh connection restarts the keep-alive")

        await h.controller.connectionClosed()
        let afterClose = count(h, 1)
        h.clock.advance(by: TierBController.linkValidInterval * 4)
        await flush()
        #expect(count(h, 1) == afterClose, "no LINK_VALID once the link has closed")
    }

    @Test func failedLinkValidWritesAreCountedAndTheNextSuccessResetsTheCount() async {
        let band = FakeBand(responder: answerAll)
        let writer = FlakyLinkWriter(band: band)
        let clock = ManualClock()
        let events = EventLog()
        let controller = TierBController(writer: writer, clock: clock, enabled: true, emit: { events.append($0) })
        band.bind(controller)
        await controller.connectionOpened()
        await settle { clock.sleeperCount > 0 }

        writer.failLinkValid = true
        clock.advance(by: TierBController.linkValidInterval)
        await flush()
        clock.advance(by: TierBController.linkValidInterval)
        await flush()
        #expect(await controller.linkValidFailures == 2)
        #expect(events.all.contains(.linkKeepAlive(sentAt: nil, consecutiveFailures: 2)))
        #expect(await controller.state == .ready, "failures are counted, not a reason to drop the link")

        writer.failLinkValid = false
        clock.advance(by: TierBController.linkValidInterval)
        await flush()
        #expect(await controller.linkValidFailures == 0)
        #expect(await controller.lastLinkValidAt != nil)
    }

    // MARK: Battery (cmd 26 and cmd 98)

    @Test func extendedBatteryReadRidesTheSameLimiterAsCommand26() async {
        let h = Harness()
        await h.controller.connectionOpened()
        #expect(count(h, 26) == 1)
        #expect(count(h, 98) == 1)

        h.clock.advance(by: TierBController.batteryInterval - 1)
        await h.controller.refreshBattery()
        #expect(count(h, 98) == 1)

        h.clock.advance(by: 1)
        await h.controller.refreshBattery()
        #expect(count(h, 26) == 2)
        #expect(count(h, 98) == 2)
    }

    // MARK: Charging events

    @Test func chargingEventsEmitTheStateAndReadTheBatteryAtOnce() async {
        let h = Harness()
        await h.controller.connectionOpened()
        let reads = count(h, 26)

        await h.controller.receive(eventFrame(7))
        #expect(h.events.all.contains(.charging(true)))
        #expect(h.events.all.contains(.bandEvent(.chargingOn)))
        // Inside the 10-minute window, so only the forced refresh can produce this read.
        await settle { count(h, 26) == reads + 1 }

        await h.controller.receive(eventFrame(8))
        #expect(h.events.all.contains(.charging(false)))
        await settle { count(h, 26) == reads + 2 }
    }

    // MARK: Console (type 50)

    @Test func consoleFramesEmitTheirPrintableLines() async {
        let h = Harness()
        await h.controller.connectionOpened()
        let frame = Frame(type: PacketType.consoleLogs.rawValue, seq: 0, cmd: 0, payload: Array("boot\nrtc ok".utf8))
        await h.controller.receive(frame)
        #expect(h.events.all.contains(.consoleLines(["boot", "rtc ok"], at: h.clock.now())))
    }

    @Test func consoleRingKeepsOnlyTheNewest200Lines() {
        var ring = BandConsoleLog()
        for index in 0 ..< 250 {
            ring.append("line \(index)", at: ManualClock.origin)
        }
        #expect(ring.lines.count == BandConsoleLog.capacity)
        #expect(ring.lines.first?.text == "line 50")
        #expect(ring.lines.last?.text == "line 249")
    }

    // MARK: Unknown events

    @Test func unknownEventTallyCountsByIdMostFrequentFirst() {
        var tally = UnknownEventTally()
        for id: UInt8 in [7, 100, 100, 21] {
            tally.record(id)
        }
        #expect(tally.sorted.map { "\($0.id):\($0.count)" } == ["100:2", "7:1", "21:1"])
    }

    // MARK: Alarm read-back (GET_ALARM_TIME after arming)

    @Test func alarmReadBackMatchesTheArmedTime() async {
        let armed = ManualClock.origin.addingTimeInterval(300)
        let armedUnix = UInt32(armed.timeIntervalSince1970)
        let h = Harness(responder: { request, _ in
            if request.cmd == 67 {
                return reply(to: request, payload: [0x00, 0x01] + littleEndian(armedUnix))
            }
            return reply(to: request, payload: request.cmd == 26 ? [0x00, 0x01, 0x69, 0x03] : [])
        })
        await h.controller.connectionOpened()
        await h.controller.armAlarms([armed])
        #expect(h.band.opcodes.contains(67))
        #expect(await h.controller.lastAlarmReadBack == .matched)
    }

    @Test func alarmReadBackReportsAMismatchWhenTheStrapHoldsAnotherTime() async {
        let armed = ManualClock.origin.addingTimeInterval(300)
        let h = Harness(responder: { request, _ in
            if request.cmd == 67 {
                return reply(to: request, payload: [0x00, 0x01] + littleEndian(1_000))
            }
            return reply(to: request, payload: request.cmd == 26 ? [0x00, 0x01, 0x69, 0x03] : [])
        })
        await h.controller.connectionOpened()
        await h.controller.armAlarms([armed])
        #expect(await h.controller.lastAlarmReadBack == .mismatched)
    }
}

/// Wraps the fake band and fails only LINK_VALID (cmd 1) writes while `failLinkValid` is set.
final class FlakyLinkWriter: CommandWriter, @unchecked Sendable {
    private let band: FakeBand
    private let lock = NSLock()
    private var failing = false

    init(band: FakeBand) {
        self.band = band
    }

    var failLinkValid: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    func writeCommand(_ frame: [UInt8]) async throws {
        if failLinkValid, (try? FrameCodec.decode(frame))?.cmd == 1 {
            throw TierBError.writeFailed
        }
        try await band.writeCommand(frame)
    }
}
