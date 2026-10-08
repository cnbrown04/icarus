import Foundation
import Testing
@testable import SyncKit

struct BodyEncodingTests {
    @Test func linuxSendsTheBodyUnchangedWithoutContentEncoding() {
        let json = Data(#"{"schema":1}"#.utf8)
        let (body, encoding) = BodyEncoding.encode(json)
        #if canImport(Darwin)
        #expect(encoding == "gzip")
        #expect(body.prefix(2) == Data([0x1f, 0x8b]))
        #else
        #expect(encoding == nil)
        #expect(body == json)
        #endif
    }

    @Test func crc32MatchesTheStandardCheckValue() {
        #expect(GzipFraming.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(GzipFraming.crc32(Data()) == 0)
    }

    @Test func gzipFrameHasHeaderAndLittleEndianTrailer() {
        let deflate = Data([0x01, 0x00, 0x00, 0xFF, 0xFF])
        let framed = GzipFraming.frame(deflate: deflate, crc32: 0xCBF4_3926, inputSize: 300)
        #expect(Array(framed.prefix(10)) == [0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])
        #expect(Array(framed.dropFirst(10).prefix(5)) == [0x01, 0x00, 0x00, 0xFF, 0xFF])
        #expect(Array(framed.suffix(8)) == [0x26, 0x39, 0xF4, 0xCB, 0x2C, 0x01, 0x00, 0x00])
    }
}

struct BackoffTests {
    @Test func ceilingDoublesFromFiveSecondsToTheTenMinuteCap() {
        let delays = (0..<10).map { attempt in
            Backoff.delay(attempt: attempt, retryAfter: nil, uniform: { $0 })
        }
        #expect(delays == [5, 10, 20, 40, 80, 160, 320, 600, 600, 600])
    }

    @Test func fullJitterDrawsWithinTheCeiling() {
        #expect(Backoff.delay(attempt: 0, retryAfter: nil, uniform: { $0 / 2 }) == 2.5)
        #expect(Backoff.delay(attempt: 3, retryAfter: nil, uniform: { $0 * 0 }) == 0)
    }

    @Test func serverRetryAfterIsAFloor() {
        #expect(Backoff.delay(attempt: 0, retryAfter: 30, uniform: { $0 }) == 30)
        #expect(Backoff.delay(attempt: 0, retryAfter: 30, uniform: { $0 * 0 }) == 30)
        #expect(Backoff.delay(attempt: 4, retryAfter: 5, uniform: { $0 }) == 80)
    }

    @Test func syncIntervalDefaultsToFiveMinutes() {
        let defaults = UserDefaults(suiteName: "synckit-tests-\(UUID().uuidString)")!
        #expect(SyncInterval.stored(in: defaults) == .fiveMinutes)
        defaults.set(15, forKey: SyncInterval.storageKey)
        #expect(SyncInterval.stored(in: defaults) == .fifteenMinutes)
        #expect(SyncInterval.hour.label == "1 h")
        #expect(SyncInterval.oneMinute.seconds == 60)
    }
}
