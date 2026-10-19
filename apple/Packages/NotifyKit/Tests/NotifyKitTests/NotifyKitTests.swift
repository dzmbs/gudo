import CryptoKit
import Foundation
import PushCrypto
import Synchronization
import Testing
import UserNotifications

@testable import NotifyKit

/// The vectors crates/push writes (PushCrypto keeps the byte-identical copy the Rust test
/// enforces; read it in place rather than keeping a third copy).
private struct Vectors: Decodable {
    struct Payload: Decodable {
        var name: String
        var sealed: String
        var json: String
        var category: String
    }
    struct Reject: Decodable {
        var name: String
        var sealed: String
    }
    var device_secret: String
    var payloads: [Payload]
    var rejects: [Reject]

    static func load() throws -> Vectors {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "PushCrypto/Tests/PushCryptoTests/Resources/push-v1.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    func deviceKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: #require(Base64URL.decode(device_secret)))
    }

    var daemon: String {
        let json = payloads[0].json
        let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        return object?["daemon"] as? String ?? ""
    }
}

private func placeholder(_ sealed: String) -> UNMutableNotificationContent {
    let content = UNMutableNotificationContent()
    content.title = "Approval needed"
    content.body = "An agent is waiting for you."
    content.categoryIdentifier = "RELAY_SAYS_SOMETHING_ELSE"
    content.userInfo = [PushContent.sealedKey: sealed, "v": 1]
    return content
}

@Suite struct ServiceExtensionTests {
    @Test func opensEveryVectorAndTakesTheCategoryFromThePayload() throws {
        let vectors = try Vectors.load()
        let key = try vectors.deviceKey()
        let nse = ServiceExtensionCore(deviceKey: { key }, pairedDaemons: { [vectors.daemon] })
        for payload in vectors.payloads {
            let out = nse.process(placeholder(payload.sealed))
            let expected = try JSONDecoder().decode(PushNotification.self, from: Data(payload.json.utf8))
            #expect(out.title == expected.title, "\(payload.name)")
            #expect(out.subtitle == expected.host)
            #expect(out.body == expected.body)
            #expect(out.categoryIdentifier == payload.category)
            #expect(out.threadIdentifier == expected.daemon)
            // The handler reads the opened payload back; the sealed blob is gone.
            #expect(out.userInfo[PushContent.sealedKey] == nil)
            #expect(PushContent.payload(from: out.userInfo) == expected)
            #expect(NotificationTarget(userInfo: out.userInfo) == .push(expected))
        }
    }

    @Test func approvalIsTimeSensitive() throws {
        let vectors = try Vectors.load()
        let key = try vectors.deviceKey()
        let nse = ServiceExtensionCore(deviceKey: { key }, pairedDaemons: { [vectors.daemon] })
        let approval = try #require(vectors.payloads.first { $0.name == "approval" })
        #expect(nse.process(placeholder(approval.sealed)).interruptionLevel == .timeSensitive)
    }

    @Test func keepsThePlaceholderOnEveryFailure() throws {
        let vectors = try Vectors.load()
        let key = try vectors.deviceKey()
        // Rejected payloads: wrong key, bit flip, wrong signer.
        let nse = ServiceExtensionCore(deviceKey: { key }, pairedDaemons: { [vectors.daemon] })
        for reject in vectors.rejects {
            let out = nse.process(placeholder(reject.sealed))
            #expect(out.title == "Approval needed", "\(reject.name)")
            #expect(out.categoryIdentifier == "RELAY_SAYS_SOMETHING_ELSE")
        }
        // A good payload from a daemon that is not paired here.
        let stranger = ServiceExtensionCore(deviceKey: { key }, pairedDaemons: { [] })
        #expect(stranger.process(placeholder(vectors.payloads[0].sealed)).title == "Approval needed")
        // No key (the build has no push entitlement).
        let keyless = ServiceExtensionCore(deviceKey: { nil }, pairedDaemons: { [vectors.daemon] })
        #expect(keyless.process(placeholder(vectors.payloads[0].sealed)).title == "Approval needed")
    }

    @Test func sharedStoreWithoutEntitlementReadsNothing() {
        let store = SharedPushStore(keychainGroup: "$(PUSH_KEYCHAIN_GROUP)", appGroup: "")
        #expect(!store.isAvailable)
        #expect(store.sealKey() == nil)
        #expect(store.pairedDaemons().isEmpty)
        #expect(!store.setSealKey(Data(repeating: 1, count: 32)))
    }
}

/// Records what the handler asked for.
private final class FakeClient: NotificationActionClient {
    enum Call: Equatable {
        case decide(host: String, pane: UInt64, request: UInt64, option: UInt32)
        case push(daemon: String, token: Data, approve: Bool)
        case open(host: String?, daemon: String?, pane: UInt64)
    }
    struct Refused: LocalizedError {
        var errorDescription: String? { "rejected: already decided" }
    }

    let calls = Mutex<[Call]>([])
    let fail: Bool

    init(fail: Bool = false) {
        self.fail = fail
    }

    var recorded: [Call] { calls.withLock { $0 } }

    func decide(hostId: String, paneId: UInt64, requestId: UInt64, optionId: UInt32) async throws {
        calls.withLock { $0.append(.decide(host: hostId, pane: paneId, request: requestId, option: optionId)) }
        if fail { throw Refused() }
    }

    func sendPushAction(daemonId: String, token: Data, approve: Bool) async throws {
        calls.withLock { $0.append(.push(daemon: daemonId, token: token, approve: approve)) }
        if fail { throw Refused() }
    }

    func open(hostId: String?, daemonId: String?, paneId: UInt64) async {
        calls.withLock { $0.append(.open(host: hostId, daemon: daemonId, pane: paneId)) }
    }
}

@Suite struct ActionHandlerTests {
    let note = AttentionNote(
        hostId: "h1", hostName: "studio", itemId: 9, paneId: 7,
        kind: .approval(requestId: 31, approve: .init(id: 1, label: "Yes"), deny: .init(id: 3, label: "No")),
        title: "Claude wants to run", body: "git push --force", agent: "Claude Code")

    @Test func localApproveAndDenyDecideWithTheMatchingOption() async {
        let client = FakeClient()
        let handler = NotificationActionHandler(client: client)
        let info = LocalNotifications.content(for: note).userInfo
        #expect(await handler.handle(actionIdentifier: PushAction.approve, userInfo: info) == .decided(approve: true))
        #expect(await handler.handle(actionIdentifier: PushAction.deny, userInfo: info) == .decided(approve: false))
        #expect(client.recorded == [
            .decide(host: "h1", pane: 7, request: 31, option: 1),
            .decide(host: "h1", pane: 7, request: 31, option: 3),
        ])
    }

    @Test func openAndDefaultTapShowThePane() async {
        let client = FakeClient()
        let handler = NotificationActionHandler(client: client)
        let info = LocalNotifications.content(for: note).userInfo
        #expect(await handler.handle(actionIdentifier: PushAction.open, userInfo: info) == .opened)
        #expect(await handler.handle(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: info) == .opened)
        #expect(await handler.handle(actionIdentifier: UNNotificationDismissActionIdentifier, userInfo: info) == .ignored)
        #expect(client.recorded == [.open(host: "h1", daemon: nil, pane: 7), .open(host: "h1", daemon: nil, pane: 7)])
    }

    @Test func pushApproveSendsTheTokenOnAOneShotConnection() async throws {
        let token = Data([1, 2, 3, 4])
        let expires = UInt64((Date.now.timeIntervalSince1970 + 600) * 1000)
        let json = Data("""
            {"v":1,"daemon":"ab","host":"studio","kind":"approval","item":42,"pane":7,"session":1,
             "title":"t","body":"b","at":0,
             "action":{"token":"\(Base64URL.encode(token))","approve":"Yes","deny":"No","expires":\(expires)}}
            """.utf8)
        #expect(throws: Never.self) { try JSONDecoder().decode(PushNotification.self, from: json) }
        let info: [AnyHashable: Any] = [PushContent.payloadKey: String(decoding: json, as: UTF8.self)]
        let client = FakeClient()
        let handler = NotificationActionHandler(client: client)
        #expect(await handler.handle(actionIdentifier: PushAction.deny, userInfo: info) == .decided(approve: false))
        #expect(await handler.handle(actionIdentifier: PushAction.open, userInfo: info) == .opened)
        #expect(client.recorded == [.push(daemon: "ab", token: token, approve: false), .open(host: nil, daemon: "ab", pane: 7)])
    }

    @Test func expiredTokensAndRefusalsBecomeFailures() async throws {
        // The shared vector's token expired long ago: nothing is sent.
        let vectors = try Vectors.load()
        let key = try vectors.deviceKey()
        let nse = ServiceExtensionCore(deviceKey: { key }, pairedDaemons: { [vectors.daemon] })
        let approval = try #require(vectors.payloads.first { $0.name == "approval" })
        let opened = nse.process(placeholder(approval.sealed))
        let client = FakeClient()
        let result = await NotificationActionHandler(client: client).handle(actionIdentifier: PushAction.approve, userInfo: opened.userInfo)
        #expect(result == .failed("This request expired. Open it to answer."))
        #expect(client.recorded.isEmpty)

        // The host refuses (already decided elsewhere).
        let refusing = FakeClient(fail: true)
        let info = LocalNotifications.content(for: note).userInfo
        #expect(await NotificationActionHandler(client: refusing).handle(actionIdentifier: PushAction.approve, userInfo: info)
            == .failed("rejected: already decided"))
        // A blocked item without options cannot be approved in place.
        var blocked = note
        blocked.kind = .approval(requestId: 5, approve: nil, deny: nil)
        let none = await NotificationActionHandler(client: client).handle(
            actionIdentifier: PushAction.approve, userInfo: LocalNotifications.content(for: blocked).userInfo)
        #expect(none == .failed("This request has no approve option."))
    }

    @Test func unknownPayloadsAreIgnored() async {
        let client = FakeClient()
        #expect(await NotificationActionHandler(client: client).handle(actionIdentifier: PushAction.approve, userInfo: ["x": 1]) == .ignored)
        #expect(client.recorded.isEmpty)
    }
}

@Suite struct LocalNotificationTests {
    @Test func contentPerKind() {
        let approval = AttentionNote(
            hostId: "h1", hostName: "studio", itemId: 1, paneId: 2,
            kind: .approval(requestId: 3, approve: .init(id: 1, label: "Yes"), deny: .init(id: 2, label: "No")),
            title: "", body: "rm -rf build", agent: "Claude Code")
        let content = LocalNotifications.content(for: approval)
        #expect(content.title == "Approval needed")
        #expect(content.subtitle == "Claude Code · studio")
        #expect(content.categoryIdentifier == "AGENT_APPROVAL")
        #expect(content.threadIdentifier == "h1")
        #expect(content.interruptionLevel == .timeSensitive)

        var blocked = approval
        blocked.kind = .approval(requestId: 3, approve: nil, deny: nil)
        #expect(LocalNotifications.content(for: blocked).categoryIdentifier == "AGENT_BLOCKED")

        var command = approval
        command.kind = .command
        command.title = "cargo test finished"
        let done = LocalNotifications.content(for: command)
        #expect(done.categoryIdentifier == "COMMAND_DONE")
        #expect(done.interruptionLevel == .active)
        #expect(done.title == "cargo test finished")
        #expect(LocalNotifications.identifier(hostId: "h1", paneId: 2) == "pane.h1.2")
    }

    @Test func prefsGateKindsAndForeground() {
        var prefs = NotificationPrefs()
        let note = AttentionNote(hostId: "h", hostName: "s", itemId: 1, paneId: 1, kind: .done, title: "t", body: "b")
        #expect(LocalNotifications.shouldPost(note, prefs: prefs, appIsActive: false))
        #expect(!LocalNotifications.shouldPost(note, prefs: prefs, appIsActive: true))
        prefs.done = false
        #expect(!LocalNotifications.shouldPost(note, prefs: prefs, appIsActive: false))
        prefs.onlyInBackground = false
        var command = note
        command.kind = .command
        #expect(LocalNotifications.shouldPost(command, prefs: prefs, appIsActive: true))

        let defaults = UserDefaults(suiteName: "notifykit-tests-\(UUID().uuidString)")!
        prefs.save(to: defaults)
        #expect(NotificationPrefs.load(from: defaults) == prefs)
    }

    @Test func categoriesCarryTheActions() {
        let categories = Dictionary(uniqueKeysWithValues: NotificationCategories.all.map { ($0.identifier, $0) })
        let approval = categories["AGENT_APPROVAL"]
        #expect(approval?.actions.map(\.identifier) == ["APPROVE", "DENY", "OPEN"])
        #expect(approval?.actions[0].options.contains(.authenticationRequired) == true)
        #expect(approval?.actions[1].options.contains(.destructive) == true)
        #expect(approval?.actions[2].options.contains(.foreground) == true)
        #expect(categories["AGENT_BLOCKED"]?.actions.map(\.identifier) == ["OPEN"])
        #expect(categories.keys.sorted() == ["AGENT_APPROVAL", "AGENT_BLOCKED", "AGENT_DONE", "COMMAND_DONE"])
    }
}
