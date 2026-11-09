import CryptoKit
import Foundation
import Synchronization

nonisolated enum CacheSealError: Error, Equatable {
    /// The key was never made, or is gone: what it sealed can never be opened again.
    case missingKey
}

/// AES-GCM with a key of this device's own, made on first use and kept in the `SecretStore`
/// (the Keychain: after first unlock, this device only, never synced). A cache it seals is
/// opened only on this device; losing the key only loses the cache.
nonisolated final class CacheSeal: Sendable {
    static let keyName = "cache-seal-key"

    private let secrets: any SecretStore
    private let cachedKey = Mutex<SymmetricKey?>(nil)

    init(secrets: any SecretStore) {
        self.secrets = secrets
    }

    /// `context` is authenticated with the data: opening with any other context fails.
    func seal(_ plaintext: Data, context: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: try keyCreatingIfNeeded(), authenticating: context)
        guard let combined = box.combined else { throw CryptoKitError.incorrectParameterSize }
        return combined
    }

    /// Throws `CacheSealError.missingKey` without a key, `CryptoKitError` for data that is not
    /// what this key sealed with `context`, and the store's error when it cannot be read now.
    func open(_ sealed: Data, context: Data) throws -> Data {
        guard let key = try existingKey() else { throw CacheSealError.missingKey }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: context)
    }

    private func existingKey() throws -> SymmetricKey? {
        try cachedKey.withLock { cached in
            if let cached { return cached }
            cached = try storedKey()
            return cached
        }
    }

    private func keyCreatingIfNeeded() throws -> SymmetricKey {
        // Under the lock: two first saves at once must not each make a key, or the first
        // one's cache could never be opened.
        try cachedKey.withLock { cached in
            if let cached { return cached }
            if let stored = try storedKey() {
                cached = stored
                return stored
            }
            let made = SymmetricKey(size: .bits256)
            try secrets.set(made.withUnsafeBytes { Data($0) }, for: Self.keyName)
            cached = made
            return made
        }
    }

    private func storedKey() throws -> SymmetricKey? {
        guard let data = try secrets.data(for: Self.keyName), data.count == SymmetricKeySize.bits256.bitCount / 8 else {
            return nil
        }
        return SymmetricKey(data: data)
    }
}
