import Foundation
import Synchronization
#if canImport(Security)
import Security
#endif

/// Holds the device token (PLAN.md 11.6). The Keychain implementation is the app's; tests use memory.
public protocol TokenStore: Sendable {
    func load() throws -> String?
    func save(_ token: String) throws
    func delete() throws
}

public final class InMemoryTokenStore: TokenStore {
    private let storage: Mutex<String?>

    public init(token: String? = nil) {
        storage = Mutex(token)
    }

    public func load() throws -> String? {
        storage.withLock { $0 }
    }

    public func save(_ token: String) throws {
        storage.withLock { $0 = token }
    }

    public func delete() throws {
        storage.withLock { $0 = nil }
    }
}

#if canImport(Security)
public enum TokenStoreError: Error, Equatable, Sendable {
    case keychain(OSStatus)
}

/// Generic-password item, readable after the first unlock so background sync works while the phone is locked.
public struct KeychainTokenStore: TokenStore {
    private let service: String
    private let account = "device-token"

    public init(service: String = "com.cnbrown04.icarus.sync") {
        self.service = service
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw TokenStoreError.keychain(status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ token: String) throws {
        try delete()
        var attributes = query
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw TokenStoreError.keychain(status)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.keychain(status)
        }
    }
}
#endif
