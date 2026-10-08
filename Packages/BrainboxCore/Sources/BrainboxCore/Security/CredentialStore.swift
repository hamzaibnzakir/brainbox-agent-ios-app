import Foundation
#if canImport(Security)
import Security
#endif

/// Where secrets live. Production uses the iOS Keychain; tests and Linux
/// CI use the in-memory store. Secrets never go to UserDefaults.
public protocol CredentialStore: AnyObject, Sendable {
    func read(_ key: CredentialKey) throws -> String?
    func write(_ value: String, for key: CredentialKey) throws
    func delete(_ key: CredentialKey) throws
}

public struct CredentialKey: Hashable, Sendable, RawRepresentable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Bearer token presented to the Brainbox gateway in `auth.hello`.
    public static let gatewayToken = CredentialKey(rawValue: "gateway.token")
}

public enum CredentialStoreError: Error, Equatable, LocalizedError {
    case unexpectedStatus(Int32)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status): return "Keychain error \(status)."
        case .invalidData: return "Stored credential is not valid UTF-8."
        }
    }
}

public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let values = Locked<[CredentialKey: String]>([:])
    public init() {}
    public func read(_ key: CredentialKey) throws -> String? { values.withLock { $0[key] } }
    public func write(_ value: String, for key: CredentialKey) throws { values.withLock { $0[key] = value } }
    public func delete(_ key: CredentialKey) throws { values.withLock { _ = $0.removeValue(forKey: key) } }
}

#if canImport(Security)
/// Generic-password Keychain items, device-only, available after first
/// unlock (so a reconnect can happen while the app is backgrounded but
/// the item never syncs to iCloud or migrates to another device).
public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    private let service: String

    public init(service: String = "app.brainbox.agent.credentials") {
        self.service = service
    }

    private func baseQuery(_ key: CredentialKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
    }

    public func read(_ key: CredentialKey) throws -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else { throw CredentialStoreError.invalidData }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError.unexpectedStatus(status)
        }
    }

    public func write(_ value: String, for key: CredentialKey) throws {
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(baseQuery(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(key)
            add.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialStoreError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw CredentialStoreError.unexpectedStatus(status)
        }
    }

    public func delete(_ key: CredentialKey) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError.unexpectedStatus(status) }
    }
}
#endif

/// Token hygiene helpers.
public enum TokenValidator {
    /// Rejects obviously wrong input (whitespace, too short, newlines) before
    /// it is saved, so typos don't become confusing auth errors later.
    public static func validate(_ token: String) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Token is empty." }
        if trimmed.count < 16 { return "Token looks too short (min 16 characters)." }
        if trimmed.contains(where: { $0.isWhitespace }) { return "Token must not contain spaces." }
        return nil
    }

    /// For display only: shows the last 4 characters.
    public static func redacted(_ token: String) -> String {
        guard token.count > 4 else { return "••••" }
        return "••••••••" + token.suffix(4)
    }
}
