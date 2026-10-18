import Foundation

/// The 8-character pairing code (api-contract.md, Devices and pairing).
public enum PairingCode {
    public static let length = 8
    public static let alphabet = Set("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    /// Uppercased, with spaces and hyphens dropped. Nil unless the rest is 8 characters of the alphabet.
    public static func normalized(_ text: String) -> String? {
        let cleaned = text.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard cleaned.count == length, cleaned.allSatisfy(alphabet.contains) else { return nil }
        return cleaned
    }
}

/// `icarus://pair?code=<code>&server=<url>`, the link the website QR code opens (api-contract.md).
public struct PairingLink: Equatable, Sendable {
    public let code: String?
    public let serverURL: URL?

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "icarus", url.host?.lowercased() == "pair" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        code = items.first { $0.name == "code" }?.value.flatMap(PairingCode.normalized)
        serverURL = items.first { $0.name == "server" }?.value.flatMap(ServerURL.parse)
    }
}
