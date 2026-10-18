import Testing
@testable import BandProtocol

@Suite("CRC")
struct CRCTests {
    private let check = Array("123456789".utf8)

    @Test func crc32CheckValue() {
        // Standard CRC-32 (zlib) check value for "123456789".
        #expect(CRC.crc32(check) == 0xCBF4_3926)
    }

    @Test func crc32OfEmptyInputIsZero() {
        #expect(CRC.crc32([]) == 0)
    }

    @Test func crc8CheckValue() {
        // CRC-8, polynomial 0x07, init 0, no reflection: check value for "123456789" is 0xF4.
        #expect(CRC.crc8(check) == 0xF4)
    }

    @Test func crc8OfEmptyInputIsZero() {
        #expect(CRC.crc8([]) == 0)
    }

    @Test func crc8OfLengthBytesMatchesWhoopEnvelope() {
        // The 2 length bytes of the aa 08 00 a8 23... frames: len = 8 -> crc8 0xA8.
        #expect(CRC.crc8([0x08, 0x00]) == 0xA8)
        // len = 16 (the alarm frames aa 10 00 57 23...) -> crc8 0x57.
        #expect(CRC.crc8([0x10, 0x00]) == 0x57)
    }
}
