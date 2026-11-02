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

private func b64(_ text: String) throws -> Data { try #require(Base64URL.decode(text)) }
private func hex(_ text: String) throws -> Data { try #require(Hex.decode(text)) }

private func deviceKey(_ vectors: Vectors) throws -> Curve25519.KeyAgreement.PrivateKey {
    let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: b64(vectors.device_secret))
    #expect(key.publicKey.rawRepresentation == (try b64(vectors.device_public)))
    return key
}

@Test func info_matches_rust() throws {
    let vectors = try Vectors.load()
    #expect(PushCrypto.sealInfo == Data(vectors.info.utf8))
}

@Test func rfc9180_vector_opens() throws {
    let rfc = try Vectors.load().rfc9180_a21
    var recipient = try HPKE.Recipient(
        privateKey: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(rfc.skRm)),
        ciphersuite: .Curve25519_SHA256_ChachaPoly,
        info: hex(rfc.info),
        encapsulatedKey: hex(rfc.enc)
    )
    #expect(try recipient.open(hex(rfc.ct), authenticating: hex(rfc.aad)) == (try hex(rfc.pt)))
}

@Test func rust_payloads_open_and_verify() throws {
    let vectors = try Vectors.load()
    let key = try deviceKey(vectors)
    for payload in vectors.payloads {
        let opened = try PushCrypto.open(payload.sealed, deviceKey: key)
        #expect(String(decoding: opened.json, as: UTF8.self) == payload.json, "\(payload.name)")
        let note = try opened.notification()
        #expect(note.daemon == vectors.daemon_public)
        #expect(note.kind.categoryIdentifier == payload.category)
        #expect(note.host == "studio-mac")
        #expect(note.body.contains("«ünïcödé» ✓"))
        if payload.name == "approval" {
            let action = try #require(note.action)
            #expect(action.token == vectors.action.token)
            #expect(action.approve == "Yes")
        } else {
            #expect(note.action == nil)
        }
    }
}

@Test func activity_state_opens() throws {
    let vectors = try Vectors.load()
    let state = try PushCrypto.open(vectors.activity.sealed, deviceKey: deviceKey(vectors)).activity()
    #expect(state.blocked == 1)
    #expect(state.running == 2)
    #expect(state.headline == "claude: approve git push?")
}

@Test func tampered_payloads_are_rejected() throws {
    let vectors = try Vectors.load()
    let key = try deviceKey(vectors)
    for reject in vectors.rejects {
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
    let action = try Vectors.load().action
    let device = try Curve25519.Signing.PrivateKey(rawRepresentation: b64(action.device_seed))
    #expect(device.publicKey.rawRepresentation == (try b64(action.device_public)))
    let token = try b64(action.token)
    for signed in action.decisions {
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
    let vectors = try Vectors.load()
    let approval = try #require(vectors.payloads.first { $0.name == "approval" })
    let content = UNMutableNotificationContent()
    content.title = "New activity"
    content.body = "Open to view"
    content.categoryIdentifier = "AGENT_DONE"  // whatever the relay claimed
    content.userInfo = ["s": approval.sealed, "v": 1]

    let filled = PushContent.decrypt(content, deviceKey: try deviceKey(vectors)) { $0 == vectors.daemon_public }
    #expect(filled.title == "claude needs you")
    #expect(filled.subtitle == "studio-mac")
    #expect(filled.categoryIdentifier == "AGENT_APPROVAL")
    #expect(filled.interruptionLevel == .timeSensitive)
    #expect(filled.userInfo["s"] == nil)
    let note = try #require(PushContent.payload(from: filled.userInfo))
    #expect(note.action?.tokenData == (try b64(vectors.action.token)))

    // An unknown host, or no key: the placeholder stays.
    let unknown = PushContent.decrypt(content, deviceKey: try deviceKey(vectors)) { _ in false }
    #expect(unknown.title == "New activity")
    let keyless = PushContent.decrypt(content, deviceKey: nil) { _ in true }
    #expect(keyless.body == "Open to view")
}

@Test func relay_supplied_user_info_never_reaches_the_action_handler() throws {
    let vectors = try Vectors.load()
    let approval = try #require(vectors.payloads.first { $0.name == "approval" })
    // A relay that forges what the NSE would have stored, and a local-notification target.
    let forged = #"{"v":1,"daemon":"\#(vectors.daemon_public)","host":"x","kind":"approval","item":1,"pane":1,"title":"t","body":"b","at":0}"#
    let content = UNMutableNotificationContent()
    content.title = "Approval needed"
    content.userInfo = [
        "aps": ["category": "AGENT_APPROVAL"], "s": approval.sealed,
        PushContent.payloadKey: forged, "local": ["host": "h", "pane": 1, "request": 1, "approve": 0],
    ]
    let failed = PushContent.decrypt(content, deviceKey: nil) { _ in true }
    #expect(PushContent.payload(from: failed.userInfo) == nil)
    #expect(Set(failed.userInfo.keys.compactMap { $0 as? String }) == ["aps"])
    #expect(Set(PushContent.placeholder(content).userInfo.keys.compactMap { $0 as? String }) == ["aps"])

    let opened = PushContent.decrypt(content, deviceKey: try deviceKey(vectors)) { $0 == vectors.daemon_public }
    #expect(Set(opened.userInfo.keys.compactMap { $0 as? String }) == ["aps", PushContent.payloadKey, PushContent.signatureKey])
    #expect(PushContent.payload(from: opened.userInfo)?.title == "claude needs you")

    // A push that skips the extension (no `mutable-content`) delivers the relay's `userInfo`
    // as is: the forged payload, unsigned or with a signature over other bytes, is not read.
    #expect(PushContent.payload(from: content.userInfo) == nil)
    var resigned = content.userInfo
    resigned[PushContent.signatureKey] = opened.userInfo[PushContent.signatureKey]
    #expect(PushContent.payload(from: resigned) == nil)
}
