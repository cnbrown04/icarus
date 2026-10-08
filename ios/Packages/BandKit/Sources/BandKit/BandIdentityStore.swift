import Foundation

/// The band Icarus reconnects to. The name is for display only.
public struct RememberedBand: Sendable, Equatable, Codable {
    public let id: UUID
    public let name: String?

    public init(id: UUID, name: String?) {
        self.id = id
        self.name = name
    }
}

/// Persists the remembered band between launches (PLAN.md §7.2).
public protocol BandIdentityStore: Sendable {
    func load() -> RememberedBand?
    /// Passing nil forgets the band.
    func save(_ band: RememberedBand?)
}

/// UserDefaults-backed store. Holds only a peripheral identifier and a display name.
public struct UserDefaultsBandIdentityStore: BandIdentityStore, @unchecked Sendable {
    public static let defaultKey = "icarus.band.remembered"

    // UserDefaults is thread-safe but not Sendable in the SDK, hence @unchecked.
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = Self.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> RememberedBand? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RememberedBand.self, from: data)
    }

    public func save(_ band: RememberedBand?) {
        guard let band else {
            defaults.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(band) {
            defaults.set(data, forKey: key)
        }
    }
}
