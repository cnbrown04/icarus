/// Text from a CONSOLE_LOGS (type 50, 0x32) frame: the strap's own firmware console (whoop-parity §3.5).
///
/// [Unverified] layout: the payload is taken as UTF-8 text from its first byte. Any header bytes
/// the firmware puts in front of the text are non-printable and are stripped, so a header that
/// happens to be printable would show up as a stray prefix. Invalid UTF-8 is replaced (lossy) and
/// the replacement characters are stripped with the other non-printables.
public enum ConsoleLog {
    /// The non-empty lines in one console frame, with control characters removed. Never throws.
    public static func lines(payload: [UInt8]) -> [String] {
        let text = String(decoding: payload, as: UTF8.self)
        var lines: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A:
                lines.append(current)
                current = ""
            case 0x09:
                current.append(" ")
            case 0x20 ... 0x7E:
                current.unicodeScalars.append(scalar)
            case 0xA0 ... 0xD7FF, 0xE000 ... 0xFFFC, 0x10000 ... 0x10FFFF:
                // Printable non-ASCII. U+FFFD (lossy replacement) falls outside these ranges.
                current.unicodeScalars.append(scalar)
            default:
                continue
            }
        }
        lines.append(current)
        return lines
            .map { $0.trimmingWhitespace() }
            .filter { !$0.isEmpty }
    }
}

private extension String {
    func trimmingWhitespace() -> String {
        var view = Substring(self)
        while view.first == " " { view = view.dropFirst() }
        while view.last == " " { view = view.dropLast() }
        return String(view)
    }
}
