import BandProtocol
import Foundation
import Testing
@testable import BandKit

// The offload state machine runs on the shared ManualClock (TierBTestSupport): deadlines are read
// with now(), the driver fires .quietElapsed itself once advance(by:) passes the deadline.
@Suite("Offload state machine")
struct OffloadStateMachineTests {
    /// A token as METADATA frames carry it (the golden metadata frames' constant token).
    private let token: [UInt8] = [0x2E, 0x47, 0x01, 0x00, 0x04, 0x00, 0x00, 0x00]

    /// A record unix time far from the clock's now, so the live-edge rule does not fire.
    private var oldUnix: UInt32 {
        UInt32(ManualClock.origin.timeIntervalSince1970) - 3600
    }

    private func makeMachine() -> (OffloadStateMachine, ManualClock) {
        let clock = ManualClock()
        return (OffloadStateMachine(clock: clock), clock)
    }

    @Test func startEmitsSendHistoricalDataAndEntersDraining() {
        var (machine, _) = makeMachine()
        #expect(machine.phase == .idle)

        let effects = machine.handle(.sendHistoricalStarted)
        #expect(effects == [.sendHistoricalData])
        #expect(machine.phase == .draining)
        #expect(machine.quietDeadline == nil)
        #expect(machine.recordCount == 0)
    }

    @Test func metadataIsEchoedExactlyOncePerFrame() {
        var (machine, _) = makeMachine()
        machine.handle(.sendHistoricalStarted)

        #expect(machine.handle(.metadata(token: token)) == [.sendResult(token: token)])
        #expect(machine.handle(.metadata(token: token)) == [.sendResult(token: token)])
        #expect(machine.lastToken == token)
    }

    @Test func recordsExtendTheQuietDeadline() {
        var (machine, clock) = makeMachine()
        machine.handle(.sendHistoricalStarted)

        let first = clock.now().addingTimeInterval(OffloadStateMachine.quietTimeout)
        machine.handle(.record(unixSeconds: oldUnix))
        #expect(machine.quietDeadline == first)
        #expect(machine.recordCount == 1)

        clock.advance(by: 2)
        let second = clock.now().addingTimeInterval(OffloadStateMachine.quietTimeout)
        machine.handle(.record(unixSeconds: oldUnix + 1))
        #expect(machine.quietDeadline == second)
        #expect(machine.recordCount == 2)
    }

    @Test func quietTimeoutStopsTheDrain() {
        var (machine, clock) = makeMachine()
        machine.handle(.sendHistoricalStarted)
        machine.handle(.record(unixSeconds: oldUnix))

        clock.advance(by: OffloadStateMachine.quietTimeout - 0.001)
        #expect(machine.handle(.quietElapsed) == [])

        clock.advance(by: 0.001)
        #expect(machine.handle(.quietElapsed) == [.stop(.quietTimeout)])
        #expect(machine.phase == .stopped(.quietTimeout))
        #expect(machine.quietDeadline == nil)
    }

    @Test func recordWithinFifteenSecondsOfNowStopsTheDrain() {
        var (machine, clock) = makeMachine()
        machine.handle(.sendHistoricalStarted)

        let now = UInt32(clock.now().timeIntervalSince1970)
        #expect(machine.handle(.record(unixSeconds: now - 10)) == [.stop(.reachedLiveEdge)])
        #expect(machine.phase == .stopped(.reachedLiveEdge))
        #expect(machine.quietDeadline == nil)
    }

    @Test func recordFarFromNowDoesNotStopTheDrain() {
        var (machine, _) = makeMachine()
        machine.handle(.sendHistoricalStarted)

        #expect(machine.handle(.record(unixSeconds: oldUnix)) == [])
        #expect(machine.phase == .draining)
    }

    @Test func explicitRecordNearNowStopsTheDrain() {
        var (machine, _) = makeMachine()
        machine.handle(.sendHistoricalStarted)

        #expect(machine.handle(.recordNearNow) == [.stop(.reachedLiveEdge)])
        #expect(machine.phase == .stopped(.reachedLiveEdge))
    }

    @Test func linkDropStopsTheDrain() {
        var (machine, _) = makeMachine()
        machine.handle(.sendHistoricalStarted)
        machine.handle(.record(unixSeconds: oldUnix))

        #expect(machine.handle(.linkDropped) == [.stop(.linkDropped)])
        #expect(machine.phase == .stopped(.linkDropped))
    }

    @Test func drainCompletedStopsTheDrain() {
        var (machine, _) = makeMachine()
        machine.handle(.sendHistoricalStarted)

        #expect(machine.handle(.drainCompleted) == [.stop(.drainCompleted)])
        #expect(machine.phase == .stopped(.drainCompleted))
    }

    // MARK: Run cap (NOOP's ~60 s offload cap)

    @Test func armQuietDeadlineStartsTheQuietClockBeforeAnyFrame() {
        var (machine, clock) = makeMachine()
        machine.armQuietDeadline()
        #expect(machine.quietDeadline == nil, "no-op while idle")
        machine.handle(.sendHistoricalStarted)
        machine.armQuietDeadline()
        #expect(machine.quietDeadline == clock.now().addingTimeInterval(OffloadStateMachine.quietTimeout))
    }

    @Test func startParksTheRunCapDeadline() {
        var (machine, clock) = makeMachine()
        machine.handle(.sendHistoricalStarted)
        #expect(machine.runCapDeadline == clock.now().addingTimeInterval(OffloadStateMachine.runCap))
        #expect(machine.quietDeadline == nil)
    }

    @Test func theRunCapStopsTheDrainAtSixtySeconds() {
        var (machine, clock) = makeMachine()
        machine.handle(.sendHistoricalStarted)
        machine.handle(.record(unixSeconds: oldUnix))   // pushes the quiet deadline out at 8 s

        clock.advance(by: OffloadStateMachine.runCap - 0.001)
        #expect(machine.handle(.runCapElapsed) == [], "an early fire is stale")
        #expect(machine.phase == .draining, "the pushed quiet deadline does not stop the cap")

        clock.advance(by: 0.001)
        #expect(machine.handle(.runCapElapsed) == [.stop(.runCap)])
        #expect(machine.phase == .stopped(.runCap))
        #expect(machine.runCapDeadline == nil)
        #expect(machine.quietDeadline == nil)
    }

    @Test func aRunCapFireAfterTheDrainEndedIsIgnored() {
        var (machine, clock) = makeMachine()
        machine.handle(.sendHistoricalStarted)
        machine.handle(.record(unixSeconds: oldUnix))
        clock.advance(by: OffloadStateMachine.quietTimeout)
        machine.handle(.quietElapsed)   // stops on quiet first

        clock.advance(by: OffloadStateMachine.runCap)
        #expect(machine.handle(.runCapElapsed) == [])
        #expect(machine.phase == .stopped(.quietTimeout))
    }

    @Test func eventsAfterStopAreIgnored() {
        var (machine, clock) = makeMachine()
        machine.handle(.sendHistoricalStarted)
        machine.handle(.record(unixSeconds: oldUnix))
        clock.advance(by: OffloadStateMachine.quietTimeout)
        machine.handle(.quietElapsed)
        #expect(machine.phase == .stopped(.quietTimeout))

        #expect(machine.handle(.metadata(token: token)) == [])
        #expect(machine.handle(.record(unixSeconds: oldUnix)) == [])
        #expect(machine.handle(.linkDropped) == [])
        #expect(machine.handle(.drainCompleted) == [])
        #expect(machine.lastToken == nil)
    }

    @Test func metadataBeforeStartIsIgnored() {
        var (machine, _) = makeMachine()
        #expect(machine.handle(.metadata(token: token)) == [])
        #expect(machine.handle(.record(unixSeconds: oldUnix)) == [])
        #expect(machine.phase == .idle)
    }

    @Test func restartAfterStopStartsANewDrain() {
        var (machine, _) = makeMachine()
        machine.handle(.sendHistoricalStarted)
        machine.handle(.record(unixSeconds: oldUnix))
        machine.handle(.linkDropped)

        #expect(machine.handle(.sendHistoricalStarted) == [.sendHistoricalData])
        #expect(machine.phase == .draining)
        #expect(machine.recordCount == 0)
        #expect(machine.lastToken == nil)
    }
}

// HistoricalOffloadHandler: the pure frame-to-effects bridge the transport wiring will call later.
@Suite("Historical offload handler")
struct HistoricalOffloadHandlerTests {
    private let token: [UInt8] = [0x2E, 0x47, 0x01, 0x00, 0x04, 0x00, 0x00, 0x00]

    private var oldUnix: UInt32 {
        UInt32(ManualClock.origin.timeIntervalSince1970) - 3600
    }

    private func makeHandler() -> (HistoricalOffloadHandler, ManualClock) {
        let clock = ManualClock()
        return (HistoricalOffloadHandler(clock: clock), clock)
    }

    private func recordPayload(unix: UInt32) -> [UInt8] {
        // Payload offsets = NOOP's frame-absolute offsets minus the 7-byte envelope:
        // unix @4, heart rate @14, skin contact @48, resp rate @73.
        var payload = [UInt8](repeating: 0, count: 77)
        payload[4] = UInt8(unix & 0xFF)
        payload[5] = UInt8((unix >> 8) & 0xFF)
        payload[6] = UInt8((unix >> 16) & 0xFF)
        payload[7] = UInt8(unix >> 24)
        payload[14] = 55
        payload[48] = 1
        payload[73] = 0x94
        payload[74] = 0x02
        return payload
    }

    private func recordFrame(unix: UInt32) -> Frame {
        Frame(type: PacketType.historicalData.rawValue, seq: 24, cmd: 7, payload: recordPayload(unix: unix))
    }

    private func metadataFrame(token: [UInt8]) -> Frame {
        var payload = [UInt8](repeating: 0, count: 21)
        for (index, byte) in token.enumerated() {
            payload[10 + index] = byte
        }
        return Frame(type: PacketType.metadata.rawValue, seq: 24, cmd: 2, payload: payload)
    }

    @Test func startReturnsTheSendHistoricalDataEffect() {
        var (handler, _) = makeHandler()
        #expect(handler.start() == [.sendHistoricalData])
    }

    @Test func recordFramesFeedTheStateMachineAndMetadataEchoesTheToken() {
        var (handler, _) = makeHandler()
        handler.start()

        #expect(handler.handle(recordFrame(unix: oldUnix)) == [])
        #expect(handler.recordCount == 1)
        #expect(handler.handle(metadataFrame(token: token)) == [.sendResult(token: token)])
    }

    @Test func unsupportedVersionRecordsAreSkippedNotFatal() {
        var (handler, _) = makeHandler()
        handler.start()

        let version12 = Frame(type: PacketType.historicalData.rawValue, seq: 12, cmd: 7, payload: [UInt8](repeating: 0, count: 85))
        #expect(handler.handle(version12) == [])
        #expect(handler.recordCount == 0)
        #expect(handler.phase == .draining)
    }

    @Test func aLiveEdgeRecordStopsTheDrain() {
        var (handler, clock) = makeHandler()
        handler.start()

        let now = UInt32(clock.now().timeIntervalSince1970)
        #expect(handler.handle(recordFrame(unix: now)) == [.stop(.reachedLiveEdge)])
        #expect(handler.phase == .stopped(.reachedLiveEdge))
    }

    @Test func quietElapsedIsForwarded() {
        var (handler, clock) = makeHandler()
        handler.start()
        handler.handle(recordFrame(unix: oldUnix))
        #expect(handler.quietDeadline == clock.now().addingTimeInterval(OffloadStateMachine.quietTimeout))

        clock.advance(by: OffloadStateMachine.quietTimeout)
        #expect(handler.quietElapsed() == [.stop(.quietTimeout)])
    }

    @Test func runCapElapsedIsForwarded() {
        var (handler, clock) = makeHandler()
        handler.start()
        #expect(handler.runCapDeadline == clock.now().addingTimeInterval(OffloadStateMachine.runCap))

        clock.advance(by: OffloadStateMachine.runCap)
        #expect(handler.runCapElapsed() == [.stop(.runCap)])
    }

    @Test func otherFrameTypesAreIgnored() {
        var (handler, _) = makeHandler()
        handler.start()

        let event = Frame(type: PacketType.event.rawValue, seq: 0, cmd: 9, payload: [])
        #expect(handler.handle(event) == [])
        let command = Frame(type: PacketType.commandResponse.rawValue, seq: 0, cmd: 26, payload: [0x69, 0x03])
        #expect(handler.handle(command) == [])
    }
}
