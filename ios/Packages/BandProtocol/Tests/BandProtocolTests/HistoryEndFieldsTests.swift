import Foundation
import Testing
@testable import BandProtocol

// The HISTORY_END field readers (NOOP PostHooks `metadata` layout '<LHLL'): unix u32 @ payload 0,
// trim cursor u32 @ payload 10 (the first word of the 8-byte ack token).
@Suite("HISTORY_END fields")
struct HistoryEndFieldsTests {
    private func endPayload(unix: UInt32, trim: UInt32) -> [UInt8] {
        var payload = [UInt8](repeating: 0, count: 18)
        func put(_ value: UInt32, at offset: Int) {
            payload[offset] = UInt8(value & 0xFF)
            payload[offset + 1] = UInt8((value >> 8) & 0xFF)
            payload[offset + 2] = UInt8((value >> 16) & 0xFF)
            payload[offset + 3] = UInt8(value >> 24)
        }
        put(unix, at: 0)
        put(trim, at: 10)
        return payload
    }

    @Test func endUnixAndTrimCursorDecodeLittleEndian() {
        let payload = endPayload(unix: 1_791_382_500, trim: 83)
        #expect(HistoricalMetadata.endUnix(fromPayload: payload) == 1_791_382_500)
        #expect(HistoricalMetadata.trimCursor(fromPayload: payload) == 83)
        // The trim cursor is the first u32 of the 8-byte ack token (payload[10:14]).
        #expect(HistoricalMetadata.token(fromPayload: payload) == Array(payload[10..<18]))
    }

    @Test func theNoCursorSentinelReadsBackAs0xFFFFFFFF() {
        let payload = endPayload(unix: 1_791_382_500, trim: 0xFFFFFFFF)
        #expect(HistoricalMetadata.trimCursor(fromPayload: payload) == 0xFFFFFFFF)
    }

    @Test func shortPayloadsDecodeNil() {
        #expect(HistoricalMetadata.endUnix(fromPayload: []) == nil)
        #expect(HistoricalMetadata.endUnix(fromPayload: [1, 2, 3]) == nil)
        #expect(HistoricalMetadata.trimCursor(fromPayload: [UInt8](repeating: 0, count: 13)) == nil)
    }
}
