import Foundation
import Testing
@testable import BandProtocol

// NOOP's ClockPolicy (github.com/ryanbr/noop @ ef165de4), ported with its boundary behaviour pinned:
// a healthy clock is never gratuitously reset; the threshold is inclusive (drift exactly at
// threshold fires) and symmetric (a strap ahead of the wall clock counts too).
@Suite("Clock policy")
struct ClockPolicyTests {
    private let wall = 1_791_382_500

    @Test func driftExactlyAtThresholdFires() {
        #expect(ClockPolicy.shouldSetClock(deviceClock: wall - 2, wallNow: wall))
        #expect(ClockPolicy.shouldSetClock(deviceClock: wall + 2, wallNow: wall))
    }

    @Test func driftJustInsideTheThresholdDoesNotFire() {
        #expect(!ClockPolicy.shouldSetClock(deviceClock: wall - 1, wallNow: wall))
        #expect(!ClockPolicy.shouldSetClock(deviceClock: wall + 1, wallNow: wall))
    }

    @Test func driftBeyondTheThresholdFires() {
        #expect(ClockPolicy.shouldSetClock(deviceClock: wall - 3, wallNow: wall))
        #expect(ClockPolicy.shouldSetClock(deviceClock: wall - 3_600, wallNow: wall))
        #expect(ClockPolicy.shouldSetClock(deviceClock: wall - 86_400, wallNow: wall))
    }

    @Test func negativeDriftCountsToo() {
        // A strap RTC reading AHEAD of the wall clock (a wandering/future RTC) is as unhealthy as
        // one behind — the policy is symmetric around zero.
        #expect(ClockPolicy.shouldSetClock(deviceClock: wall + 86_400, wallNow: wall))
    }

    @Test func zeroDriftDoesNotFire() {
        #expect(!ClockPolicy.shouldSetClock(deviceClock: wall, wallNow: wall))
    }

    /// A custom (non-default) threshold is honoured — NOOP's signature takes it as a parameter.
    @Test func theThresholdIsAParameter() {
        #expect(ClockPolicy.shouldSetClock(deviceClock: wall - 5, wallNow: wall, driftThreshold: 10) == false)
        #expect(ClockPolicy.shouldSetClock(deviceClock: wall - 10, wallNow: wall, driftThreshold: 10))
    }

    // MARK: GET_CLOCK reply decoding (NOOP PostHooks: u32 LE at reply payload bytes 2..6)

    @Test func deviceClockReadsTheLittleEndianU32AtPayloadBytes2To6() {
        // [resp_seq, result, clock u32 LE] — a real reply shape mirrors the GET_BATTERY_LEVEL one.
        #expect(ClockPolicy.deviceClock(replyPayload: [0x00, 0x01, 0x24, 0xFD, 0xAA, 0x6A]) == 1_789_590_820)
        #expect(ClockPolicy.deviceClock(replyPayload: [0x00, 0x01, 0xFF, 0xFF, 0xFF, 0xFF]) == Int(UInt32.max))
    }

    @Test func aShortOrEmptyReplyCarriesNoClockValue() {
        #expect(ClockPolicy.deviceClock(replyPayload: []) == nil)
        #expect(ClockPolicy.deviceClock(replyPayload: [0x00, 0x01]) == nil)
        #expect(ClockPolicy.deviceClock(replyPayload: [0x00, 0x01, 0x24, 0xFD, 0xAA]) == nil)
    }
}
