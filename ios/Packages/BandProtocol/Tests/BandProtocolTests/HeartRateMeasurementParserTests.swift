import Testing
@testable import BandProtocol

// Vectors follow the Bluetooth SIG Heart Rate Measurement layout (PLAN.md 5.3.1).
// Flags: bit 0 HR format, bits 1-2 contact, bit 3 energy expended, bit 4 R-R.
@Suite("HeartRateMeasurementParser (0x2A37)")
struct HeartRateMeasurementParserTests {
    @Test func uint8HeartRateWithNoOptionalFields() throws {
        // flags 0x00, HR 0x48 = 72
        let m = try HeartRateMeasurementParser.parse([0x00, 0x48])
        #expect(m == HeartRateMeasurement(bpm: 72, sensorContact: .notSupported, energyExpendedKJ: nil, rrIntervalsMs: []))
    }

    @Test func uint16HeartRate() throws {
        // flags 0x01, HR = 0x0094 LE = 148
        let m = try HeartRateMeasurementParser.parse([0x01, 0x94, 0x00])
        #expect(m.bpm == 148)
        #expect(m.sensorContact == .notSupported)
    }

    @Test(arguments: [
        (UInt8(0x00), SensorContact.notSupported), // bits 1-2 = 00
        (UInt8(0x02), SensorContact.notSupported), // bits 1-2 = 01, reserved, treated as not supported
        (UInt8(0x04), SensorContact.notDetected),  // bits 1-2 = 10
        (UInt8(0x06), SensorContact.detected),     // bits 1-2 = 11
    ])
    func sensorContactStates(flags: UInt8, expected: SensorContact) throws {
        let m = try HeartRateMeasurementParser.parse([flags, 0x50])
        #expect(m.sensorContact == expected)
        #expect(m.bpm == 80)
    }

    @Test func energyExpendedWithUint8HeartRate() throws {
        // flags 0x08, HR 0x50 = 80, energy 0x012C LE = 300 kJ
        let m = try HeartRateMeasurementParser.parse([0x08, 0x50, 0x2C, 0x01])
        #expect(m.bpm == 80)
        #expect(m.energyExpendedKJ == 300)
        #expect(m.rrIntervalsMs.isEmpty)
    }

    @Test func energyExpendedWithUint16HeartRate() throws {
        // flags 0x09, HR 0x0050 LE = 80, energy 0x012C LE = 300 kJ
        let m = try HeartRateMeasurementParser.parse([0x09, 0x50, 0x00, 0x2C, 0x01])
        #expect(m.bpm == 80)
        #expect(m.energyExpendedKJ == 300)
    }

    @Test func noRRIntervalsWhenFlagSetButNoBytesFollow() throws {
        let m = try HeartRateMeasurementParser.parse([0x10, 0x50])
        #expect(m.rrIntervalsMs.isEmpty)
    }

    @Test func oneRRIntervalConvertsFrom1024ths() throws {
        // raw 0x0400 = 1024 units. 1024 * 1000 / 1024 = 1000 ms.
        let m = try HeartRateMeasurementParser.parse([0x10, 0x50, 0x00, 0x04])
        #expect(m.rrIntervalsMs == [1000.0])
    }

    @Test func severalRRIntervals() throws {
        // 0x0400 = 1024 -> 1000 ms; 0x0200 = 512 -> 500 ms; 0x0300 = 768 -> 750 ms
        let m = try HeartRateMeasurementParser.parse([0x10, 0x50, 0x00, 0x04, 0x00, 0x02, 0x00, 0x03])
        #expect(m.rrIntervalsMs == [1000.0, 500.0, 750.0])
    }

    @Test func allFieldsTogether() throws {
        // flags 0x1F = u16 HR | detected | energy | R-R
        // HR 0x0064 = 100, energy 0x000A = 10 kJ, R-R 0x0200 = 512 -> 500 ms
        let m = try HeartRateMeasurementParser.parse([0x1F, 0x64, 0x00, 0x0A, 0x00, 0x00, 0x02])
        #expect(m == HeartRateMeasurement(bpm: 100, sensorContact: .detected, energyExpendedKJ: 10, rrIntervalsMs: [500.0]))
    }

    @Test func emptyInputThrows() {
        #expect(throws: HeartRateParseError.empty) {
            try HeartRateMeasurementParser.parse([])
        }
    }

    @Test func truncatedUint16HeartRateThrows() {
        #expect(throws: HeartRateParseError.truncated(needed: 3, available: 2)) {
            try HeartRateMeasurementParser.parse([0x01, 0x94])
        }
    }

    @Test func truncatedEnergyExpendedThrows() {
        #expect(throws: HeartRateParseError.truncated(needed: 4, available: 3)) {
            try HeartRateMeasurementParser.parse([0x08, 0x50, 0x2C])
        }
    }

    @Test func oddRRByteCountThrows() {
        #expect(throws: HeartRateParseError.oddRRPayload(byteCount: 1)) {
            try HeartRateMeasurementParser.parse([0x10, 0x50, 0x00])
        }
    }

    @Test func trailingBytesWithoutRRFlagThrow() {
        #expect(throws: HeartRateParseError.trailingBytes(count: 1)) {
            try HeartRateMeasurementParser.parse([0x00, 0x48, 0xFF])
        }
    }
}
