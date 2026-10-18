/// Sensor contact status (flags bits 1-2) of the Heart Rate Measurement characteristic.
public enum SensorContact: Sendable, Equatable {
    case notSupported
    case notDetected
    case detected
}

public struct HeartRateMeasurement: Sendable, Equatable {
    public let bpm: Int
    public let sensorContact: SensorContact
    public let energyExpendedKJ: Int?
    /// R-R intervals in milliseconds (raw value / 1024 * 1000).
    public let rrIntervalsMs: [Double]

    public init(bpm: Int, sensorContact: SensorContact, energyExpendedKJ: Int?, rrIntervalsMs: [Double]) {
        self.bpm = bpm
        self.sensorContact = sensorContact
        self.energyExpendedKJ = energyExpendedKJ
        self.rrIntervalsMs = rrIntervalsMs
    }
}

public enum HeartRateParseError: Error, Equatable, Sendable {
    case empty
    /// A field needs bytes up to `needed`, but the value has only `available`.
    case truncated(needed: Int, available: Int)
    /// The R-R section must be a whole number of u16 values.
    case oddRRPayload(byteCount: Int)
    /// Bytes remain after the fields that the flags declare.
    case trailingBytes(count: Int)
}

/// Parses the Bluetooth SIG Heart Rate Measurement characteristic (0x2A37).
///
/// Flags: bit 0 HR format (0 = u8, 1 = u16 LE); bits 1-2 sensor contact;
/// bit 3 energy expended present (u16 LE, kJ); bit 4 R-R intervals present (u16 LE, 1/1024 s each).
public enum HeartRateMeasurementParser {
    public static func parse(_ bytes: [UInt8]) throws -> HeartRateMeasurement {
        guard let flags = bytes.first else { throw HeartRateParseError.empty }
        var reader = FieldReader(bytes: bytes, offset: 1)

        let bpm: Int
        if flags & 0x01 != 0 {
            bpm = try reader.uint16()
        } else {
            bpm = try reader.uint8()
        }

        var energy: Int?
        if flags & 0x08 != 0 {
            energy = try reader.uint16()
        }

        var rr: [Double] = []
        if flags & 0x10 != 0 {
            guard reader.remaining % 2 == 0 else {
                throw HeartRateParseError.oddRRPayload(byteCount: reader.remaining)
            }
            while reader.remaining > 0 {
                rr.append(Double(try reader.uint16()) * 1000.0 / 1024.0)
            }
        }

        guard reader.remaining == 0 else {
            throw HeartRateParseError.trailingBytes(count: reader.remaining)
        }

        return HeartRateMeasurement(
            bpm: bpm,
            sensorContact: sensorContact(flags: flags),
            energyExpendedKJ: energy,
            rrIntervalsMs: rr
        )
    }

    /// Values 0b00 and 0b01 both mean the feature is not supported.
    private static func sensorContact(flags: UInt8) -> SensorContact {
        switch (flags >> 1) & 0b11 {
        case 0b10: .notDetected
        case 0b11: .detected
        default: .notSupported
        }
    }
}

private struct FieldReader {
    let bytes: [UInt8]
    var offset: Int

    var remaining: Int { bytes.count - offset }

    mutating func uint8() throws -> Int {
        guard remaining >= 1 else {
            throw HeartRateParseError.truncated(needed: offset + 1, available: bytes.count)
        }
        defer { offset += 1 }
        return Int(bytes[offset])
    }

    mutating func uint16() throws -> Int {
        guard remaining >= 2 else {
            throw HeartRateParseError.truncated(needed: offset + 2, available: bytes.count)
        }
        let value = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
        offset += 2
        return value
    }
}
