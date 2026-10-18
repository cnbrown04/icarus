import BandKit
import BandProtocol
import Foundation
import Testing

@Suite struct SyntheticHeartRateSourceTests {
    @Test func sameSeedProducesIdenticalOutput() {
        var first = SyntheticHeartRateSource(seed: 42)
        var second = SyntheticHeartRateSource(seed: 42)
        let a = (0 ..< 300).map { _ in first.nextPayload() }
        let b = (0 ..< 300).map { _ in second.nextPayload() }
        #expect(a == b)
    }

    @Test func differentSeedsDiverge() {
        var first = SyntheticHeartRateSource(seed: 1)
        var second = SyntheticHeartRateSource(seed: 2)
        let a = (0 ..< 50).map { _ in first.nextPayload() }
        let b = (0 ..< 50).map { _ in second.nextPayload() }
        #expect(a != b)
    }

    @Test func payloadsAreRealHeartRateFramesAndParse() throws {
        var source = SyntheticHeartRateSource(seed: 7)
        for _ in 0 ..< 1000 {
            let payload = source.nextPayload()
            #expect(payload.count == 4)
            #expect(payload[0] == 0x16)
            let measurement = try source.nextMeasurement()
            #expect((55 ... 70).contains(measurement.bpm))
            #expect(measurement.sensorContact == .detected)
            #expect(measurement.rrIntervalsMs.count == 1)
            #expect(measurement.rrIntervalsMs.allSatisfy { (800 ... 1200).contains($0) })
        }
    }
}

@Suite struct SyntheticTransportTests {
    @Test func emitsConnectedThenPacedSamples() async {
        let clock = RecordingClock()
        let transport = SyntheticTransport(seed: 3, interval: 1, maxSamples: 5, clock: clock)
        await transport.start()
        var received: [BandEvent] = []
        for await event in transport.events {
            received.append(event)
        }
        #expect(received.first == .state(.streaming))
        let heartRateEvents = received.dropFirst().compactMap { event -> Int? in
            guard case let .hr(measurement, _) = event else { return nil }
            return measurement.bpm
        }
        #expect(heartRateEvents.count == 5)
        #expect(heartRateEvents.allSatisfy { (55 ... 70).contains($0) })
        let sleeps = await clock.requestedSeconds
        #expect(sleeps == [1, 1, 1, 1])
    }
}
