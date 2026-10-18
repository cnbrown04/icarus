import BandKit
import Foundation
import Testing

@Suite struct ConnectionStateMachineTests {
    private let band = UUID(uuidString: "6C1F3A10-2B7D-4E0A-9C11-0000000000B1")!
    private let other = UUID(uuidString: "6C1F3A10-2B7D-4E0A-9C11-0000000000B2")!

    /// A machine that is streaming `band`, which is also the remembered band.
    private func streamingMachine() -> ConnectionStateMachine {
        var machine = ConnectionStateMachine(rememberedID: band)
        _ = machine.handle(.start)
        _ = machine.handle(.connected)
        _ = machine.handle(.servicesDiscovered)
        _ = machine.handle(.subscribed)
        return machine
    }

    // MARK: Start

    @Test func startWithoutRememberedBandScans() {
        var machine = ConnectionStateMachine()
        #expect(machine.handle(.start) == [.startScan])
        #expect(machine.state == .scanning)
        #expect(machine.targetID == nil)
    }

    @Test func startWithRememberedBandConnectsDirectly() {
        var machine = ConnectionStateMachine(rememberedID: band)
        #expect(machine.handle(.start) == [.connect(band)])
        #expect(machine.state == .connecting)
        #expect(machine.targetID == band)
    }

    @Test func startIsIgnoredWhileRunning() {
        var machine = ConnectionStateMachine()
        _ = machine.handle(.start)
        #expect(machine.handle(.start).isEmpty)
        #expect(machine.state == .scanning)
    }

    @Test func happyPathStreamsAndRemembersNothingNew() {
        var machine = ConnectionStateMachine(rememberedID: band)
        #expect(machine.handle(.start) == [.connect(band)])
        #expect(machine.handle(.connected) == [.discoverServices])
        #expect(machine.state == .discovering)
        #expect(machine.handle(.servicesDiscovered) == [.subscribe])
        #expect(machine.state == .subscribing)
        #expect(machine.handle(.subscribed).isEmpty)
        #expect(machine.state == .streaming)
    }

    // MARK: Pairing and the remembered band

    @Test func firstPairingRemembersTheBandOnceItStreams() {
        var machine = ConnectionStateMachine()
        _ = machine.handle(.start)
        #expect(machine.handle(.pairRequested(band)) == [.stopScan, .connect(band)])
        #expect(machine.state == .connecting)
        _ = machine.handle(.connected)
        _ = machine.handle(.servicesDiscovered)
        #expect(machine.handle(.subscribed) == [.rememberPeripheral(band)])
        #expect(machine.rememberedID == band)
    }

    @Test func rememberedBandUnavailableFallsBackToScanning() {
        var machine = ConnectionStateMachine(rememberedID: band)
        _ = machine.handle(.start)
        #expect(machine.handle(.rememberedPeripheralUnavailable) == [.startScan])
        #expect(machine.state == .scanning)
        #expect(machine.targetID == nil)
        #expect(machine.rememberedID == band)
    }

    @Test func scanFindsRememberedBandAndConnects() {
        var machine = ConnectionStateMachine(rememberedID: band)
        _ = machine.handle(.start)
        _ = machine.handle(.rememberedPeripheralUnavailable)
        #expect(machine.handle(.peripheralDiscovered(band)) == [.stopScan, .connect(band)])
        #expect(machine.state == .connecting)
    }

    @Test func scanIgnoresOtherBandsUntilUserPicksOne() {
        var machine = ConnectionStateMachine()
        _ = machine.handle(.start)
        #expect(machine.handle(.peripheralDiscovered(other)).isEmpty)
        #expect(machine.state == .scanning)
    }

    @Test func pairingWhileStreamingSwitchesBand() {
        var machine = streamingMachine()
        #expect(machine.handle(.pairRequested(other)) == [.cancelConnection(band), .connect(other)])
        #expect(machine.state == .connecting)
        #expect(machine.targetID == other)
        _ = machine.handle(.connected)
        _ = machine.handle(.servicesDiscovered)
        #expect(machine.handle(.subscribed) == [.rememberPeripheral(other)])
        #expect(machine.rememberedID == other)
    }

    @Test func pairingTheBandAlreadyStreamingIsANoOp() {
        var machine = streamingMachine()
        #expect(machine.handle(.pairRequested(band)).isEmpty)
        #expect(machine.state == .streaming)
    }

    @Test func pairingWhileIdleIsIgnored() {
        var machine = ConnectionStateMachine()
        #expect(machine.handle(.pairRequested(band)).isEmpty)
        #expect(machine.state == .idle)
    }

    @Test func pairingDuringBackoffCancelsTheRetry() {
        var machine = ConnectionStateMachine()
        _ = machine.handle(.start)
        _ = machine.handle(.pairRequested(band))
        _ = machine.handle(.connectFailed)
        #expect(machine.state == .backoff(attempt: 1))
        #expect(machine.handle(.pairRequested(other)) == [.cancelRetry, .connect(other)])
        #expect(machine.state == .connecting)
    }

    // MARK: Failures and backoff

    @Test func backoffDelaysFollowTheSchedule() {
        let delays = (1 ... 7).map { ConnectionStateMachine.backoffDelay(forAttempt: $0) }
        #expect(delays == [1, 2, 5, 15, 30, 30, 30])
        #expect(ConnectionStateMachine.backoffDelay(forAttempt: 0) == 1)
    }

    @Test func repeatedConnectFailuresWalkTheScheduleAndCap() {
        var machine = ConnectionStateMachine()
        _ = machine.handle(.start)
        _ = machine.handle(.pairRequested(band))

        var delays: [TimeInterval] = []
        for attempt in 1 ... 6 {
            let effects = machine.handle(.connectFailed)
            #expect(machine.state == .backoff(attempt: attempt))
            guard case let .scheduleRetry(after: delay) = effects.last else {
                Issue.record("expected scheduleRetry, got \(effects)")
                return
            }
            delays.append(delay)
            #expect(machine.handle(.retryTimerFired) == [.connect(band)])
            #expect(machine.state == .connecting)
        }
        #expect(delays == [1, 2, 5, 15, 30, 30])
    }

    @Test func disconnectWhileStreamingBacksOffFromAttemptOne() {
        var machine = streamingMachine()
        #expect(machine.handle(.disconnected) == [.scheduleRetry(after: 1)])
        #expect(machine.state == .backoff(attempt: 1))
        #expect(machine.handle(.retryTimerFired) == [.connect(band)])
    }

    @Test func successfulSubscribeResetsTheAttemptCount() {
        var machine = ConnectionStateMachine(rememberedID: band)
        _ = machine.handle(.start)
        _ = machine.handle(.connectFailed)
        _ = machine.handle(.retryTimerFired)
        _ = machine.handle(.connected)
        _ = machine.handle(.servicesDiscovered)
        _ = machine.handle(.subscribed)
        #expect(machine.handle(.disconnected) == [.scheduleRetry(after: 1)])
        #expect(machine.state == .backoff(attempt: 1))
    }

    @Test func disconnectWhileConnectingBacksOff() {
        var machine = ConnectionStateMachine(rememberedID: band)
        _ = machine.handle(.start)
        #expect(machine.handle(.disconnected) == [.scheduleRetry(after: 1)])
        #expect(machine.state == .backoff(attempt: 1))
    }

    @Test func missingHeartRateServiceCancelsTheConnectionAndBacksOff() {
        var machine = ConnectionStateMachine(rememberedID: band)
        _ = machine.handle(.start)
        _ = machine.handle(.connected)
        #expect(machine.handle(.heartRateUnavailable) == [.cancelConnection(band), .scheduleRetry(after: 1)])
        #expect(machine.state == .backoff(attempt: 1))
    }

    @Test func missingCharacteristicWhileSubscribingCancelsTheConnection() {
        var machine = ConnectionStateMachine(rememberedID: band)
        _ = machine.handle(.start)
        _ = machine.handle(.connected)
        _ = machine.handle(.servicesDiscovered)
        #expect(machine.handle(.heartRateUnavailable) == [.cancelConnection(band), .scheduleRetry(after: 1)])
    }

    @Test func startAfterStopWithoutRememberedBandScans() {
        var machine = ConnectionStateMachine()
        _ = machine.handle(.start)
        _ = machine.handle(.pairRequested(band))
        _ = machine.handle(.connectFailed)
        _ = machine.handle(.stop)
        _ = machine.handle(.start)
        #expect(machine.state == .scanning)
    }

    // MARK: Stop and forget

    @Test func stopWhileStreamingCancelsButKeepsTheRememberedBand() {
        var machine = streamingMachine()
        #expect(machine.handle(.stop) == [.cancelConnection(band)])
        #expect(machine.state == .idle)
        #expect(machine.rememberedID == band)
    }

    @Test func stopWhileScanningStopsTheScan() {
        var machine = ConnectionStateMachine()
        _ = machine.handle(.start)
        #expect(machine.handle(.stop) == [.stopScan])
        #expect(machine.state == .idle)
    }

    @Test func stopDuringBackoffCancelsTheRetry() {
        var machine = streamingMachine()
        _ = machine.handle(.disconnected)
        #expect(machine.handle(.stop) == [.cancelRetry])
        #expect(machine.state == .idle)
    }

    @Test func stopWhenIdleDoesNothing() {
        var machine = ConnectionStateMachine()
        #expect(machine.handle(.stop).isEmpty)
    }

    @Test func forgetCancelsClearsAndForgetsThePeripheral() {
        var machine = streamingMachine()
        #expect(machine.handle(.forget) == [.cancelConnection(band), .forgetPeripheral])
        #expect(machine.state == .idle)
        #expect(machine.rememberedID == nil)
        #expect(machine.targetID == nil)
    }

    @Test func staleCallbacksAfterStopAreIgnored() {
        var machine = ConnectionStateMachine(rememberedID: band)
        _ = machine.handle(.start)
        _ = machine.handle(.stop)
        #expect(machine.handle(.connectFailed).isEmpty)
        #expect(machine.handle(.connected).isEmpty)
        #expect(machine.handle(.disconnected).isEmpty)
        #expect(machine.handle(.retryTimerFired).isEmpty)
        #expect(machine.state == .idle)
    }

    @Test func startAgainAfterStopConnectsToTheRememberedBand() {
        var machine = streamingMachine()
        _ = machine.handle(.stop)
        #expect(machine.handle(.start) == [.connect(band)])
    }

    // MARK: Out-of-order input

    @Test func inputsForOtherStatesAreIgnored() {
        var machine = ConnectionStateMachine()
        #expect(machine.handle(.connected).isEmpty)
        #expect(machine.handle(.servicesDiscovered).isEmpty)
        #expect(machine.handle(.subscribed).isEmpty)
        #expect(machine.handle(.retryTimerFired).isEmpty)
        #expect(machine.handle(.rememberedPeripheralUnavailable).isEmpty)
        #expect(machine.state == .idle)
    }

    @Test func retryTimerOutsideBackoffIsIgnored() {
        var machine = streamingMachine()
        #expect(machine.handle(.retryTimerFired).isEmpty)
        #expect(machine.state == .streaming)
    }
}
