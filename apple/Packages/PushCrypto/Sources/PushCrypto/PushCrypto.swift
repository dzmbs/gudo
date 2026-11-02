import CryptoKit
import Foundation

/// Opens push payloads sealed by a host daemon (crates/push, docs/PUSH.md).
///
/// Wire format of `sealed` (unpadded base64url):
///
///     enc (32 bytes, HPKE encapsulated key) || HPKE ciphertext
///
/// HPKE is RFC 9180 base mode, DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 / ChaCha20-Poly1305,
/// `info = "push-seal/v1"`, empty AAD. The plaintext is
///
///     0x01 || Ed25519 signature (64) || JSON
///
/// where the signature is the daemon's (its iroh key) over `"push-payload/v1\0" || JSON`. The
/// JSON names the daemon; callers must check it is a host they paired with.
public enum PushCrypto {
    public static let sealInfo = Data("push-seal/v1".utf8)
    /// Domain prefix of the daemon's payload signature.
    public static let payloadDomain = Data("push-payload/v1\0".utf8)
    /// Domain prefix of a device's decision signature.
    public static let decisionDomain = Data("push-action/v1\0".utf8)

    static let ciphersuite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    static let envelopeV1: UInt8 = 1

    /// Decrypts a sealed payload with the device's X25519 key (kept in the shared Keychain
    /// group, readable after first unlock so the extension works on a locked phone).
    public static func open(
        _ sealed: String,
        deviceKey: Curve25519.KeyAgreement.PrivateKey
    ) throws(PushCryptoError) -> Opened {
        guard let sealedBytes = Base64URL.decode(sealed), sealedBytes.count >= 32 + 16 else {
            throw .malformed
        }
        let encapsulatedKey = sealedBytes.prefix(32)
        let ciphertext = sealedBytes.dropFirst(32)
        let plaintext: Data
        do {
            var recipient = try HPKE.Recipient(
                privateKey: deviceKey,
                ciphersuite: ciphersuite,
                info: sealInfo,
                encapsulatedKey: Data(encapsulatedKey)
            )
            plaintext = try recipient.open(Data(ciphertext), authenticating: Data())
        } catch {
            throw .open
        }
        guard plaintext.first == envelopeV1, plaintext.count >= 1 + 64 else {
            throw .malformed
        }
        let signedJSON = plaintext.dropFirst()
        return Opened(
            signature: Data(signedJSON.prefix(64)),
            json: Data(signedJSON.dropFirst(64))
        )
    }

    /// The bytes a device signs to answer an action: `decisionDomain || token || decision`
    /// (1 approve, 0 deny).
    public static func decisionMessage(token: Data, decision: Decision) -> Data {
        var message = decisionDomain
        message.append(token)
        message.append(decision == .approve ? 1 : 0)
        return message
    }

    /// Signs a decision with the device's Ed25519 key (the iroh key from the Keychain). The
    /// app passes the token, decision and this signature to the daemon over iroh.
    public static func signDecision(
        token: Data,
        decision: Decision,
        deviceKey: Curve25519.Signing.PrivateKey
    ) throws -> Data {
        try deviceKey.signature(for: decisionMessage(token: token, decision: decision))
    }
}

/// A decrypted payload whose signature has not been checked yet.
public struct Opened: Sendable {
    public let signature: Data
    public let json: Data

    public func verify(daemonKey: Curve25519.Signing.PublicKey) throws(PushCryptoError) {
        var message = PushCrypto.payloadDomain
        message.append(json)
        guard daemonKey.isValidSignature(signature, for: message) else {
            throw .signature
        }
    }

    /// Parses the notification and verifies the signature against the daemon it names.
    public func notification() throws(PushCryptoError) -> PushNotification {
        let note: PushNotification = try decode()
        try verify(daemonKey: try Self.key(hex: note.daemon))
        return note
    }

    public func activity() throws(PushCryptoError) -> ActivityState {
        let state: ActivityState = try decode()
        try verify(daemonKey: try Self.key(hex: state.daemon))
        return state
    }

    private func decode<T: Decodable>() throws(PushCryptoError) -> T {
        do {
            return try JSONDecoder().decode(T.self, from: json)
        } catch {
            throw .json
        }
    }

    static func key(hex: String) throws(PushCryptoError) -> Curve25519.Signing.PublicKey {
        guard let raw = Hex.decode(hex),
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        else { throw .signature }
        return key
    }
}

/// Why a payload could not be used. Show the relay's placeholder text in every case.
public enum PushCryptoError: Error, Equatable, Sendable {
    /// Not base64url, too short, or an unknown envelope version.
    case malformed
    /// HPKE failed: another device's key, or the data was changed.
    case open
    /// The daemon signature does not verify (or names an invalid key).
    case signature
    /// Not the expected JSON.
    case json
}

public enum Decision: String, Sendable {
    case approve
    case deny
}

/// What the notification is about; decides the category (action buttons).
public enum PushKind: String, Codable, Sendable {
    case approval
    case blocked
    case done
    case failed
    case command

    /// The `UNNotificationCategory` identifier the app registers.
    public var categoryIdentifier: String {
        switch self {
        case .approval: "AGENT_APPROVAL"
        case .blocked: "AGENT_BLOCKED"
        case .done, .failed: "AGENT_DONE"
        case .command: "COMMAND_DONE"
        }
    }
}

public enum PushAction {
    public static let approve = "APPROVE"
    public static let deny = "DENY"
    public static let open = "OPEN"
}

/// A decrypted notification (crates/push `Notification`).
public struct PushNotification: Codable, Equatable, Sendable {
    public var v: Int
    /// The daemon's Ed25519 key (iroh endpoint id), hex.
    public var daemon: String
    public var host: String
    public var kind: PushKind
    /// Attention item id.
    public var item: UInt64
    public var pane: UInt64
    public var session: UInt64?
    public var title: String
    public var body: String
    /// Unix ms.
    public var at: UInt64
    public var action: ActionOffer?
}

/// Approve / Deny for an approval notification.
public struct ActionOffer: Codable, Equatable, Sendable {
    /// Opaque daemon-signed token (base64url); send it back with the decision.
    public var token: String
    public var approve: String
    public var deny: String
    /// Unix ms.
    public var expires: UInt64

    public var tokenData: Data? { Base64URL.decode(token) }
}

/// One host's row of the aggregated Live Activity.
public struct ActivityState: Codable, Equatable, Sendable {
    public var v: Int
    public var daemon: String
    public var host: String
    public var running: UInt32
    public var blocked: UInt32
    public var done: UInt32
    public var headline: String
    public var at: UInt64
}

/// Unpadded base64url (RFC 4648 §5).
public enum Base64URL {
    public static func decode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }

    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum Hex {
    static func decode(_ text: String) -> Data? {
        guard text.count % 2 == 0 else { return nil }
        var bytes = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
