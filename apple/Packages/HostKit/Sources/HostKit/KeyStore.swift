import CryptoKit
import Foundation
import Observation
import UnnamedCore

/// An SSH key the app holds. The private part is in the `SecretStore` (`key.<id>`), or in
/// the Secure Enclave (only its encrypted handle is stored).
nonisolated public struct SSHKey: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Generated on this device (ed25519).
        case generated
        /// Imported from a file or paste.
        case imported
        /// A Secure Enclave P-256 key: cannot leave the device.
        case secureEnclave
    }

    public var id: String
    public var label: String
    public var kind: Kind
    /// `authorized_keys` line.
    public var publicKey: String
    /// `SHA256:…`.
    public var fingerprint: String
    public var created = Date()

    var secretKey: String { "key.\(id)" }

    /// Appends the key to `~/.ssh/authorized_keys` on a host (what `ssh-copy-id` does), safe
    /// to paste into a shell there.
    public var authorizeCommand: String {
        let line = publicKey.replacingOccurrences(of: "'", with: "")
        return "mkdir -p ~/.ssh && chmod 700 ~/.ssh && grep -qxF '\(line)' ~/.ssh/authorized_keys 2>/dev/null || echo '\(line)' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    }

    /// The `ssh-copy-id` command to run from a computer that can already log in, given the
    /// public key saved as a file next to it.
    public func sshCopyIdCommand(for endpoint: SSHEndpoint) -> String {
        let port = endpoint.port == 22 ? "" : " -p \(endpoint.port)"
        return "echo '\(publicKey)' > /tmp/\(id.prefix(8)).pub && ssh-copy-id -f -i /tmp/\(id.prefix(8)).pub\(port) \(endpoint.user)@\(endpoint.host)"
    }
}

public enum KeyStoreError: Error, Equatable, LocalizedError {
    case unknownKey(String)
    case secureEnclaveUnavailable
    case invalidKey(String)

    public var errorDescription: String? {
        switch self {
        case .unknownKey(let id): "Key \(id) is missing"
        case .secureEnclaveUnavailable: "This device has no Secure Enclave"
        case .invalidKey(let reason): reason
        }
    }
}

/// The app's SSH keys: generate (ed25519 or Secure Enclave P-256), import, and turn into
/// `SshAuth` for a connection. The list is `keys.json`; private parts are secrets.
@MainActor
@Observable
public final class KeyStore {
    public private(set) var keys: [SSHKey] = []
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private let fileURL: URL

    public init(secrets: any SecretStore, directory: URL) {
        self.secrets = secrets
        fileURL = directory.appending(path: "keys.json")
        if let data = try? Data(contentsOf: fileURL) {
            keys = (try? JSONDecoder().decode([SSHKey].self, from: data)) ?? []
        }
    }

    public func key(_ id: String) -> SSHKey? {
        keys.first { $0.id == id }
    }

    /// A new ed25519 key, private part stored as OpenSSH PEM.
    public func generate(label: String) throws -> SSHKey {
        let generated = try generateEd25519Key(comment: label)
        let key = SSHKey(
            id: UUID().uuidString, label: label, kind: .generated,
            publicKey: generated.publicKey, fingerprint: generated.fingerprint)
        try secrets.set(generated.privateKey, for: key.secretKey)
        try add(key)
        return key
    }

    /// Imports a private key (OpenSSH/PEM). An encrypted key needs its passphrase, which is
    /// stored with it.
    public func importKey(pem: Data, passphrase: String?, label: String) throws -> SSHKey {
        let info = try inspectPrivateKey(pem: pem, passphrase: passphrase)
        if let existing = keys.first(where: { $0.fingerprint == info.fingerprint }) { return existing }
        let key = SSHKey(
            id: UUID().uuidString, label: label, kind: .imported,
            publicKey: info.publicKey, fingerprint: info.fingerprint)
        try secrets.set(pem, for: key.secretKey)
        if let passphrase { try secrets.set(passphrase, for: key.secretKey + ".passphrase") }
        try add(key)
        return key
    }

    /// A new Secure Enclave P-256 key.
    public func generateSecureEnclaveKey(label: String) throws -> SSHKey {
        guard SecureEnclave.isAvailable else { throw KeyStoreError.secureEnclaveUnavailable }
        let privateKey = try SecureEnclave.P256.Signing.PrivateKey()
        let signer = SecureEnclaveSigner(key: privateKey, comment: label)
        let key = SSHKey(
            id: UUID().uuidString, label: label, kind: .secureEnclave,
            publicKey: signer.publicKey(), fingerprint: signer.fingerprint)
        try secrets.set(privateKey.dataRepresentation, for: key.secretKey)
        try add(key)
        return key
    }

    public func remove(_ id: String) throws {
        guard let key = key(id) else { return }
        try secrets.remove(key.secretKey)
        try? secrets.remove(key.secretKey + ".passphrase")
        keys.removeAll { $0.id == id }
        try save()
    }

    /// The credential for a key.
    public func auth(for id: String) throws -> SshAuth {
        guard let key = key(id), let secret = try secrets.data(for: key.secretKey) else {
            throw KeyStoreError.unknownKey(id)
        }
        switch key.kind {
        case .generated, .imported:
            return .keyData(pem: secret, passphrase: try secrets.string(for: key.secretKey + ".passphrase"))
        case .secureEnclave:
            let privateKey = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: secret)
            return .signer(signer: SecureEnclaveSigner(key: privateKey, comment: key.label))
        }
    }

    private func add(_ key: SSHKey) throws {
        keys.append(key)
        try save()
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(keys).write(to: fileURL, options: .atomic)
    }
}

/// An SSH signer backed by a Secure Enclave P-256 key (`ecdsa-sha2-nistp256`). Signing may
/// wait for the user if the key requires it; the core calls it on a blocking thread.
nonisolated public final class SecureEnclaveSigner: SshSigner {
    private let key: SecureEnclave.P256.Signing.PrivateKey
    private let comment: String

    public init(key: SecureEnclave.P256.Signing.PrivateKey, comment: String) {
        self.key = key
        self.comment = comment
    }

    /// The SSH wire encoding of the public key (RFC 5656 §3.1).
    var publicKeyBlob: Data {
        var blob = Data()
        func string(_ bytes: Data) {
            var length = UInt32(bytes.count).bigEndian
            blob.append(Data(bytes: &length, count: 4))
            blob.append(bytes)
        }
        string(Data("ecdsa-sha2-nistp256".utf8))
        string(Data("nistp256".utf8))
        string(key.publicKey.x963Representation)
        return blob
    }

    public func publicKey() -> String {
        "ecdsa-sha2-nistp256 \(publicKeyBlob.base64EncodedString()) \(comment)"
    }

    var fingerprint: String {
        let digest = Data(SHA256.hash(data: publicKeyBlob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    public func sign(data: Data) throws(SignerError) -> Data {
        do {
            return try key.signature(for: data).rawRepresentation
        } catch {
            throw .Failed(message: error.localizedDescription)
        }
    }
}
