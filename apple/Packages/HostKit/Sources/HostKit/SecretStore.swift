import Foundation
import os
import Security
import Synchronization

/// Where secrets live: the device key, pairing tickets, SSH private keys and passwords,
/// known_hosts. Keys are short names (`device-key`, `host.<id>.ticket`, …).
nonisolated public protocol SecretStore: Sendable {
    func data(for key: String) throws -> Data?
    func set(_ data: Data, for key: String) throws
    func remove(_ key: String) throws
}

nonisolated extension SecretStore {
    public func string(for key: String) throws -> String? {
        try data(for: key).map { String(decoding: $0, as: UTF8.self) }
    }

    public func set(_ string: String, for key: String) throws {
        try set(Data(string.utf8), for: key)
    }
}

nonisolated public struct SecretStoreError: Error, Equatable, CustomStringConvertible {
    public let status: OSStatus
    public let operation: String
    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Keychain \(operation): \(message)"
    }
}

/// The Keychain (data-protection keychain), generic passwords under one service, readable
/// after the first unlock and never migrated to another device
/// (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
nonisolated public final class KeychainStore: SecretStore {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func data(for key: String) throws -> Data? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretStoreError(status: status, operation: "read \(key)") }
        return result as? Data
    }

    public func set(_ data: Data, for key: String) throws {
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query(key) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(key)
            add.merge(update) { $1 }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SecretStoreError(status: status, operation: "write \(key)") }
    }

    public func remove(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError(status: status, operation: "delete \(key)")
        }
    }

    /// Whether the Keychain is usable by this build (ad-hoc signed macOS apps have no
    /// keychain-access-group entitlement, so the data-protection keychain refuses them with
    /// `errSecMissingEntitlement`).
    public func isUsable() -> Bool {
        let probe = "probe-\(UUID().uuidString)"
        do {
            try set(Data([1]), for: probe)
            try remove(probe)
            return true
        } catch {
            return false
        }
    }
}

/// Files in a directory with owner-only permissions and complete file protection: the
/// fallback when the Keychain is unavailable (an ad-hoc signed Mac build), and the store
/// tests use.
nonisolated public final class FileSecretStore: SecretStore {
    public let directory: URL
    private let lock = Mutex(())

    public init(directory: URL) {
        self.directory = directory
    }

    private func url(_ key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" }
        return directory.appending(path: String(safe))
    }

    public func data(for key: String) throws -> Data? {
        try lock.withLock { _ in
            let url = url(key)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try Data(contentsOf: url)
        }
    }

    public func set(_ data: Data, for key: String) throws {
        try lock.withLock { _ in
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            #if os(iOS)
            try data.write(to: url(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url(key), options: .atomic)
            #endif
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(key).path)
        }
    }

    public func remove(_ key: String) throws {
        try lock.withLock { _ in
            let url = url(key)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
}

/// An in-memory store (tests, previews).
nonisolated public final class MemorySecretStore: SecretStore {
    private let items = Mutex<[String: Data]>([:])

    public init() {}

    public func data(for key: String) throws -> Data? { items.withLock { $0[key] } }
    public func set(_ data: Data, for key: String) throws { items.withLock { $0[key] = data } }
    public func remove(_ key: String) throws { _ = items.withLock { $0.removeValue(forKey: key) } }
}

nonisolated public enum SecretStores {
    /// The app's store: the Keychain when this build may use it, else owner-only files in
    /// Application Support (logged once).
    public static func appDefault(service: String, fallbackDirectory: URL) -> any SecretStore {
        let keychain = KeychainStore(service: service)
        if keychain.isUsable() { return keychain }
        Logger(subsystem: Log.subsystem, category: "secrets").warning(
            "Keychain unavailable to this build; secrets go to \(fallbackDirectory.path, privacy: .public)")
        return FileSecretStore(directory: fallbackDirectory)
    }
}
