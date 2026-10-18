import CryptoKit
import Foundation
import Testing
import UserNotifications

@testable import PushCrypto

/// The shared vectors crates/push/tests/vectors.rs writes (a byte-identical copy; the Rust
/// test fails if they diverge).
private struct Vectors: Decodable {
    struct Payload: Decodable {
        var name: String
        var sealed: String
        var json: String
        var category: String
    }
    struct Sealed: Decodable {
        var sealed: String
        var json: String
    }
    struct Reject: Decodable {
        var name: String
        var sealed: String
        var error: String
    }
    struct Action: Decodable {
        struct Signed: Decodable {
            var decision: String
            var message: String
            var signature: String
        }
        var device_seed: String
        var device_public: String
        var token: String
        var decisions: [Signed]
    }
    struct Rfc: Decodable {
        var info: String
        var skRm: String
        var enc: String
        var aad: String
        var ct: String
        var pt: String
    }
    var info: String
    var device_secret: String
    var device_public: String
    var daemon_public: String
    var payloads: [Payload]
    var activity: Sealed
    var rejects: [Reject]
    var action: Action
    var rfc9180_a21: Rfc

    static func load() throws -> Vectors {
        let url = try #require(Bundle.module.url(forResource: "push-v1", withExtension: "json"))
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }
}

private func b64(_ s: String) throws -> Data { try #require(Base64URL.decode(s)) }
private func hex(_ s: String) throws -> Data { try #require(Hex.decode(s)) }

private func deviceKey(_ v: Vectors) throws -> Curve25519.KeyAgreement.PrivateKey {
    let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: b64(v.device_secret))
    #expect(key.publicKey.rawRepresentation == (try b64(v.device_public)))
    return key
}

@Test func info_matches_rust() throws {
    let v = try Vectors.load()
    #expect(PushCrypto.sealInfo == Data(v.info.utf8))
}

/// CryptoKit's HPKE opens RFC 9180 A.2.1 (sanity check of the suite choice).
@Test func rfc9180_vector_opens() throws {
    let r = try Vectors.load().rfc9180_a21
    var recipient = try HPKE.Recipient(
        privateKey: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(r.skRm)),
        ciphersuite: .Curve25519_SHA256_ChachaPoly,
        info: hex(r.info),
        encapsulatedKey: hex(r.enc)
    )
    #expect(try recipient.open(hex(r.ct), authenticating: hex(r.aad)) == (try hex(r.pt)))
}

@Test func rust_payloads_open_and_verify() throws {
    let v = try Vectors.load()
    let key = try deviceKey(v)
    for payload in v.payloads {
        let opened = try PushCrypto.open(payload.sealed, deviceKey: key)
        #expect(String(decoding: opened.json, as: UTF8.self) == payload.json, "\(payload.name)")
        let note = try opened.notification()
        #expect(note.daemon == v.daemon_public)
        #expect(note.kind.categoryIdentifier == payload.category)
        #expect(note.host == "studio-mac")
        #expect(note.body.contains("«ünïcödé» ✓"))
        if payload.name == "approval" {
            let action = try #require(note.action)
            #expect(action.token == v.action.token)
            #expect(action.approve == "Yes")
        } else {
            #expect(note.action == nil)
        }
    }
}

@Test func activity_state_opens() throws {
    let v = try Vectors.load()
    let state = try PushCrypto.open(v.activity.sealed, deviceKey: deviceKey(v)).activity()
    #expect(state.blocked == 1)
    #expect(state.running == 2)
    #expect(state.headline == "claude: approve git push?")
}

@Test func tampered_payloads_are_rejected() throws {
    let v = try Vectors.load()
    let key = try deviceKey(v)
    for reject in v.rejects {
        let expected: PushCryptoError = reject.error == "open" ? .open : .signature
        #expect(throws: expected, "\(reject.name)") {
            try PushCrypto.open(reject.sealed, deviceKey: key).notification()
        }
    }
    #expect(throws: PushCryptoError.malformed) {
        try PushCrypto.open("not*base64", deviceKey: key)
    }
}

@Test func decision_signatures_match_rust() throws {
    let a = try Vectors.load().action
    let device = try Curve25519.Signing.PrivateKey(rawRepresentation: b64(a.device_seed))
    #expect(device.publicKey.rawRepresentation == (try b64(a.device_public)))
    let token = try b64(a.token)
    for signed in a.decisions {
        let decision = try #require(Decision(rawValue: signed.decision))
        let message = PushCrypto.decisionMessage(token: token, decision: decision)
        #expect(message == (try hex(signed.message)))
        // Rust's (deterministic) signature verifies here, and ours (randomised) verifies too.
        #expect(device.publicKey.isValidSignature(try b64(signed.signature), for: message))
        let ours = try PushCrypto.signDecision(token: token, decision: decision, deviceKey: device)
        #expect(device.publicKey.isValidSignature(ours, for: message))
    }
}

@Test func notification_content_is_filled_from_the_payload() throws {
    let v = try Vectors.load()
    let approval = try #require(v.payloads.first { $0.name == "approval" })
    let content = UNMutableNotificationContent()
    content.title = "New activity"
    content.body = "Open to view"
    content.categoryIdentifier = "AGENT_DONE"  // whatever the relay claimed
    content.userInfo = ["s": approval.sealed, "v": 1]

    let out = PushContent.decrypt(content, deviceKey: try deviceKey(v)) { $0 == v.daemon_public }
    #expect(out.title == "claude needs you")
    #expect(out.subtitle == "studio-mac")
    #expect(out.categoryIdentifier == "AGENT_APPROVAL")
    #expect(out.interruptionLevel == .timeSensitive)
    #expect(out.userInfo["s"] == nil)
    let note = try #require(PushContent.payload(from: out.userInfo))
    #expect(note.action?.tokenData == (try b64(v.action.token)))

    // An unknown host, or no key: the placeholder stays.
    let unknown = PushContent.decrypt(content, deviceKey: try deviceKey(v)) { _ in false }
    #expect(unknown.title == "New activity")
    let keyless = PushContent.decrypt(content, deviceKey: nil) { _ in true }
    #expect(keyless.body == "Open to view")
}
