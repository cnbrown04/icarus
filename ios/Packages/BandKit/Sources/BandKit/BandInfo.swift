import Foundation

/// Best-effort identity strings decoded from the GET_HELLO reply (PLAN.md 5.3.4).
///
/// The observed live 4.0 reply leads with a response counter and a status byte (`01` = ok, the same
/// header `GET_BATTERY_LEVEL` replies carry) and carries ASCII strings later in the frame; the
/// capture `00 01 04 D8 03 00 00 00 A2 8F E2 01 28 03 00 00 34 43 31 35 35 31 35 30 30 00 38 65 32
/// 37 …` decodes to "4C1551500" and "8e27…" as NUL-terminated ASCII runs. The exact offsets are
/// [Unverified], so the decoder scans for printable runs instead of trusting fixed offsets, and
/// every field stays nil when nothing confident is found. Unexpected bytes never fail the decode.
public struct BandInfo: Sendable, Equatable {
    /// Firmware version string (a build id such as "8e27…" in the observed reply). [Unverified]
    public let firmwareVersion: String?
    /// Hardware revision. The observed reply does not obviously carry one, so this stays nil.
    public let hardwareRevision: String?
    /// The strap's serial number, e.g. "4C1551500". [Unverified]
    public let serial: String?

    public init(firmwareVersion: String?, hardwareRevision: String?, serial: String?) {
        self.firmwareVersion = firmwareVersion
        self.hardwareRevision = hardwareRevision
        self.serial = serial
    }

    /// Printable ASCII bounds for the string scan.
    private static let printableRange: ClosedRange<UInt8> = 0x20 ... 0x7E
    /// Shorter runs are treated as binary junk, not strings. [Unverified]
    private static let minimumRunLength = 4

    /// Decodes a GET_HELLO reply payload. Never throws: bytes that do not fit simply leave fields nil.
    public static func helloReply(_ payload: [UInt8]) -> BandInfo {
        var strings: [String] = []
        var run: [UInt8] = []
        for byte in payload {
            if byte == 0 || !printableRange.contains(byte) {
                // A run only counts when NUL-terminated (or at the end of the payload); a
                // non-printable byte mid-frame marks binary data, not a string.
                if byte == 0, let text = text(from: run) {
                    strings.append(text)
                }
                run.removeAll()
            } else {
                run.append(byte)
            }
        }
        if let text = text(from: run) {
            strings.append(text)
        }

        // [Unverified] classification: the observed serial is a short run of digits and uppercase
        // letters ("4C1551500"); the firmware string mixes in lowercase ("8e27…").
        let serial = strings.first(where: looksLikeSerial)
        let firmware = strings.first { $0 != serial }
        return BandInfo(firmwareVersion: firmware, hardwareRevision: nil, serial: serial)
    }

    private static func text(from bytes: [UInt8]) -> String? {
        guard bytes.count >= minimumRunLength else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func looksLikeSerial(_ string: String) -> Bool {
        guard (8 ... 12).contains(string.count) else { return false }
        return string.allSatisfy { $0.isNumber || $0.isUppercase }
    }
}
