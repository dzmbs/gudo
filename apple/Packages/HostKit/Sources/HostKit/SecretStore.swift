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
/// (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). With an access group the items are
/// shared with the app's extensions that hold the same group. Items never sync to iCloud.
///
/// `dataProtection: false` is the Mac's login keychain instead, for a Developer ID build
/// without a provisioning profile: its items are readable by this app's signature only (other
/// apps make the system ask the user).
nonisolated public final class KeychainStore: SecretStore {
    public let service: String
    public let accessGroup: String?
    public let dataProtection: Bool

    public init(service: String, accessGroup: String? = nil, dataProtection: Bool = true) {
        self.service = service
        self.accessGroup = accessGroup
        self.dataProtection = dataProtection
    }

    private func query(_ key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    private var accessibility: [String: Any] {
        // The login keychain has no accessibility classes; it locks with the user's session.
        dataProtection ? [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] : [:]
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
        var update: [String: Any] = [kSecValueData as String: data]
        update.merge(accessibility) { $1 }
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
            // Also a folder made before (or by someone else): owner-only.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
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

    /// The stored keys (file names: keys made only of letters, digits, `-` and `.` are their
    /// own file names).
    public func keys() -> [String] {
        lock.withLock { _ in
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
                .filter { !$0.hasPrefix(".") }
                .sorted()
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
    /// The app's store: the data-protection Keychain when this build may use it; on a Mac
    /// signed by a team without one (Developer ID, no provisioning profile), the login
    /// keychain; else owner-only files in Application Support (ad-hoc builds, whose signature
    /// changes with every build, would make the login keychain ask each time). Secrets an
    /// earlier build left in those files move into the Keychain.
    public static func appDefault(service: String, fallbackDirectory: URL) -> any SecretStore {
        let log = Logger(subsystem: Log.subsystem, category: "secrets")
        let files = FileSecretStore(directory: fallbackDirectory)
        var candidates = [KeychainStore(service: service)]
        #if os(macOS)
        if CodeSignature.teamIdentifier != nil { candidates.append(KeychainStore(service: service, dataProtection: false)) }
        #endif
        if let keychain = candidates.first(where: { $0.isUsable() }) {
            do {
                try migrate(from: files, to: keychain)
            } catch {
                log.error("moving file secrets into the Keychain failed: \(String(describing: error), privacy: .public)")
            }
            return keychain
        }
        log.warning("Keychain unavailable to this build; secrets go to owner-only files")
        return files
    }

    /// Moves every secret from `files` into `store` (an item already in `store` wins), then
    /// deletes the files.
    public static func migrate(from files: FileSecretStore, to store: any SecretStore) throws {
        for key in files.keys() {
            if let data = try files.data(for: key), try store.data(for: key) == nil {
                try store.set(data, for: key)
            }
            try files.remove(key)
        }
    }
}

#if os(macOS)
/// This process's code signature.
nonisolated enum CodeSignature {
    /// The signing team (nil when ad-hoc signed).
    static let teamIdentifier: String? = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }()
}
#endif
