import BandKit
import BandProtocol
import Foundation
import Testing

@Suite struct NDJSONFixtureTests {
    private var sample: String {
        [
            heartRateLine(t: 100, bpm: 60),
            "{\"t\": 101.0, \"char\": \"2a37\"",          // invalid JSON
            "",                                                // blank: not counted
            #"{"t": 102.0, "char": "2a19", "hex": "64"}"#,     // other characteristic
            #"{"t": 103.0, "char": "2a37", "hex": "16zz0004"}"#, // bad hex
            #"{"t": 103.5, "char": "2a37", "hex": "163"}"#,    // odd hex length
            #"{"t": 104.0, "char": "2a37", "hex": ""}"#,       // parser rejects empty payload
            heartRateLine(t: 104, bpm: 62),
        ].joined(separator: "\n")
    }

    @Test func keepsValidFramesInFileOrderAndCountsSkippedLines() {
        let result = NDJSONFixture.parse(sample)
        #expect(result.frames.map(\.timestamp) == [100, 104])
        #expect(result.frames.map(\.measurement.bpm) == [60, 62])
        #expect(result.skippedLineCount == 5)
    }
}

@Suite struct FixtureTransportTests {
    private let band = DiscoveredBand(
        id: UUID(uuidString: "6C1F3A10-2B7D-4E0A-9C11-0000000000B1")!,
        name: "Fixture band",
        rssi: -48
    )

    @Test func rememberedBandStreamsWithoutPairing() async {
        let transport = FixtureTransport(ndjson: heartRateLine(t: 100, bpm: 60), clock: RecordingClock(), band: band)
        await transport.start()
        var received: [BandEvent] = []
        for await event in transport.events {
            received.append(event)
        }
        #expect(Array(received.prefix(3)) == [
            .discovered(band),
            .remembered(band.id),
            .state(.streaming),
        ])
    }

    @Test func stopBeforePairingEndsWithoutStreaming() async {
        let transport = FixtureTransport(
            ndjson: heartRateLine(t: 100, bpm: 60),
            clock: RecordingClock(),
            band: band,
            pairingRequired: true
        )
        await transport.start()
        await transport.pair(UUID())
        await transport.stop()
        var received: [BandEvent] = []
        for await event in transport.events {
            received.append(event)
        }
        #expect(received == [.discovered(band), .state(.scanning)])
    }

    @Test func pairingStartsTheReplayForThePairedBandOnly() async {
        let transport = FixtureTransport(
            ndjson: heartRateLine(t: 100, bpm: 60),
            clock: RecordingClock(),
            band: band,
            pairingRequired: true
        )
        let collected = Task {
            var received: [BandEvent] = []
            for await event in transport.events {
                received.append(event)
            }
            return received
        }
        await transport.start()
        await transport.pair(UUID())
        await transport.pair(band.id)

        let received = await collected.value
        #expect(Array(received.prefix(4)) == [
            .discovered(band),
            .state(.scanning),
            .remembered(band.id),
            .state(.streaming),
        ])
        #expect(received.count == 6)
    }

    @Test func replaysEventsInOrderPacedBySpeed() async throws {
        let text = [
            heartRateLine(t: 100, bpm: 60),
            heartRateLine(t: 101, bpm: 61),
            "not json",
            heartRateLine(t: 104, bpm: 62),
        ].joined(separator: "\n")
        let clock = RecordingClock()
        let transport = FixtureTransport(ndjson: text, speed: 2, clock: clock)
        #expect(transport.skippedLineCount == 1)

        await transport.start()
        var received: [BandEvent] = []
        for await event in transport.events {
            received.append(event)
        }

        // .state(.streaming), then .raw and .hr for each of the three valid frames.
        #expect(received.count == 7)
        #expect(received.first == .state(.streaming))
        let raw = received.compactMap { event -> [UInt8]? in
            guard case let .raw(char, bytes, _) = event, char == "2a37" else { return nil }
            return bytes
        }
        #expect(raw.map { $0.count } == [4, 4, 4])
        let heartRates = received.compactMap { event -> (Int, Date)? in
            guard case let .hr(measurement, receivedAt) = event else { return nil }
            return (measurement.bpm, receivedAt)
        }
        #expect(heartRates.map(\.0) == [60, 61, 62])
        #expect(heartRates.map(\.1) == [Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 101), Date(timeIntervalSince1970: 104)])

        // Gaps of 1 s and 3 s at 2x speed; no sleep for the first frame.
        let sleeps = await clock.requestedSeconds
        #expect(sleeps == [0.5, 1.5])
    }

    @Test func emptyFixtureEmitsOnlyConnectedAndFinishes() async {
        let transport = FixtureTransport(ndjson: "", clock: RecordingClock())
        await transport.start()
        var received: [BandEvent] = []
        for await event in transport.events {
            received.append(event)
        }
        #expect(received == [.state(.streaming)])
    }

    @Test func bundledRestingDayFixtureReplaysCleanly() async throws {
        // #filePath: ios/Packages/BandKit/Tests/BandKitTests/FixtureTransportTests.swift
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // BandKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // BandKit
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // ios
            .appendingPathComponent("Fixtures/resting_day.ndjson")
        let text = try String(contentsOf: fixtureURL, encoding: .utf8)

        let result = NDJSONFixture.parse(text)
        #expect(result.skippedLineCount == 0)
        #expect(result.frames.count == 900)
        #expect(result.frames.first?.timestamp == 1_791_382_500)
        #expect(result.frames.last?.timestamp == 1_791_383_399)
        #expect(result.frames.allSatisfy { (58 ... 66).contains($0.measurement.bpm) })
        #expect(result.frames.allSatisfy { $0.measurement.sensorContact == .detected })
        #expect(result.frames.allSatisfy { $0.measurement.rrIntervalsMs.count == 1 })
        let gaps = zip(result.frames, result.frames.dropFirst()).map { $1.timestamp - $0.timestamp }
        #expect(gaps.allSatisfy { $0 == 1 })
    }
}
