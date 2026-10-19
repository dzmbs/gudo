import CryptoKit
import Foundation
import LocalAuthentication
import Security
import Synchronization

/// Which saved password a prompt may use: one host, one kind of program, one prompt text.
/// Stored as a hash, so the Keychain never holds the prompt (it can name users and hosts).
nonisolated public struct AskpassVaultKey: Hashable, Sendable {
    public let account: String

    /// - Parameters:
    ///   - host: the host's id in the app.
    ///   - kind: who asks (`sudo`, `ssh`, …, or `terminal` for a detected prompt).
    ///   - prompt: the prompt text as shown.
    public init(host: String, kind: String, prompt: String) {
        let material = "askpass-v1\n\(host)\n\(kind)\n\(prompt)"
        let digest = SHA256.hash(data: Data(material.utf8))
        account = "askpass." + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// Passwords the user chose to remember ("Remember in Keychain"), each behind Face ID / Touch ID
/// (or the device passcode), never synced, never readable while the device is locked.
nonisolated public protocol AskpassVault: Sendable {
    /// Whether this build can keep passwords at all (an ad-hoc signed Mac build cannot).
    var isAvailable: Bool { get }
    /// Whether a password is saved for `key` (no authentication).
    func contains(_ key: AskpassVaultKey) -> Bool
    /// Saves `secret` for `key`, replacing any earlier one.
    func save(_ secret: String, for key: AskpassVaultKey) throws
    /// Reads the password for `key` after Face ID / Touch ID; `reason` is shown by the system.
    func read(_ key: AskpassVaultKey, reason: String) async throws -> String
    func remove(_ key: AskpassVaultKey) throws
    /// Forgets every saved password; returns how many there were.
    @discardableResult func removeAll() throws -> Int
    /// How many passwords are saved.
    func count() -> Int
}

nonisolated public enum AskpassVaultError: Error, Equatable, LocalizedError {
    case notFound
    case cancelled
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .notFound: "No saved password."
        case .cancelled: "Cancelled."
        case .keychain(let status):
            "Keychain: " + (SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)")
        }
    }
}

/// The Keychain, one service, items protected by `.userPresence` access control and
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
nonisolated public final class KeychainAskpassVault: AskpassVault {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    private func base() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func query(_ key: AskpassVaultKey) -> [String: Any] {
        var query = base()
        query[kSecAttrAccount as String] = key.account
        return query
    }

    public var isAvailable: Bool {
        // A plain item in the same service proves the data-protection keychain is usable.
        var probe = base()
        probe[kSecAttrAccount as String] = "probe-\(UUID().uuidString)"
        probe[kSecValueData as String] = Data([1])
        probe[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(probe as CFDictionary, nil) == errSecSuccess else { return false }
        probe[kSecValueData as String] = nil
        SecItemDelete(probe as CFDictionary)
        return true
    }

    public func contains(_ key: AskpassVaultKey) -> Bool {
        var query = query(key)
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecReturnAttributes as String] = true
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        // An item that needs authentication to read still exists.
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    public func save(_ secret: String, for key: AskpassVaultKey) throws {
        try? remove(key)
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &error)
        else { throw AskpassVaultError.keychain(errSecParam) }
        var add = query(key)
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrAccessControl as String] = access
        add[kSecAttrLabel as String] = "Saved terminal password"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw AskpassVaultError.keychain(status) }
    }

    public func read(_ key: AskpassVaultKey, reason: String) async throws -> String {
        let query = query(key)
        // SecItemCopyMatching blocks while Face ID runs: off the main actor.
        return try await Task.detached(priority: .userInitiated) {
            var query = query
            let context = LAContext()
            context.localizedReason = reason
            query[kSecUseAuthenticationContext as String] = context
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                guard let data = result as? Data else { throw AskpassVaultError.notFound }
                return String(decoding: data, as: UTF8.self)
            case errSecItemNotFound: throw AskpassVaultError.notFound
            case errSecUserCanceled, errSecAuthFailed: throw AskpassVaultError.cancelled
            default: throw AskpassVaultError.keychain(status)
            }
        }.value
    }

    public func remove(_ key: AskpassVaultKey) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AskpassVaultError.keychain(status) }
    }

    @discardableResult public func removeAll() throws -> Int {
        let count = count()
        let status = SecItemDelete(base() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AskpassVaultError.keychain(status) }
        return count
    }

    public func count() -> Int {
        var query = base()
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return 0 }
        return (result as? [[String: Any]])?.count ?? 0
    }
}

/// An in-memory vault (tests, previews, builds without a usable Keychain report unavailable).
nonisolated public final class MemoryAskpassVault: AskpassVault {
    private let items = Mutex<[String: String]>([:])
    public let isAvailable: Bool
    /// Reads fail with this, to exercise a cancelled Face ID.
    public let failReads = Mutex<AskpassVaultError?>(nil)

    public init(isAvailable: Bool = true) {
        self.isAvailable = isAvailable
    }

    public func contains(_ key: AskpassVaultKey) -> Bool { items.withLock { $0[key.account] != nil } }
    public func save(_ secret: String, for key: AskpassVaultKey) throws { items.withLock { $0[key.account] = secret } }
    public func read(_ key: AskpassVaultKey, reason: String) async throws -> String {
        if let error = failReads.withLock({ $0 }) { throw error }
        guard let secret = items.withLock({ $0[key.account] }) else { throw AskpassVaultError.notFound }
        return secret
    }
    public func remove(_ key: AskpassVaultKey) throws { _ = items.withLock { $0.removeValue(forKey: key.account) } }
    @discardableResult public func removeAll() throws -> Int {
        items.withLock { items in
            defer { items = [:] }
            return items.count
        }
    }
    public func count() -> Int { items.withLock { $0.count } }
}

nonisolated public enum AskpassVaults {
    /// The app's vault: the Keychain service `<bundle id>.askpass`.
    public static func appDefault(bundleId: String) -> any AskpassVault {
        KeychainAskpassVault(service: bundleId + ".askpass")
    }
}
