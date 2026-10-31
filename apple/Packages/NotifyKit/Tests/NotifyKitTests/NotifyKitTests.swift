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
    struct Activity: Decodable {
        var json: String
        var sealed: String
    }
    var device_secret: String
    var payloads: [Payload]
    var rejects: [Reject]
    var activity: Activity

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
            #expect(NotificationTarget(userInfo: out.userInfo, remote: true) == .push(expected))
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
        #expect(await handler.handle(actionIdentifier: PushAction.approve, userInfo: info, remote: false) == .decided(approve: true))
        #expect(await handler.handle(actionIdentifier: PushAction.deny, userInfo: info, remote: false) == .decided(approve: false))
        #expect(client.recorded == [
            .decide(host: "h1", pane: 7, request: 31, option: 1),
            .decide(host: "h1", pane: 7, request: 31, option: 3),
        ])
    }

    @Test func openAndDefaultTapShowThePane() async {
        let client = FakeClient()
        let handler = NotificationActionHandler(client: client)
        let info = LocalNotifications.content(for: note).userInfo
        #expect(await handler.handle(actionIdentifier: PushAction.open, userInfo: info, remote: false) == .opened)
        #expect(await handler.handle(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: info, remote: false) == .opened)
        #expect(await handler.handle(actionIdentifier: UNNotificationDismissActionIdentifier, userInfo: info, remote: false) == .ignored)
        #expect(client.recorded == [.open(host: "h1", daemon: nil, pane: 7), .open(host: "h1", daemon: nil, pane: 7)])
    }

    /// What the extension stores for an approval payload signed by `daemon`.
    private func signedApproval(_ daemon: Curve25519.Signing.PrivateKey, token: Data) throws -> (info: [AnyHashable: Any], id: String) {
        let id = daemon.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        let expires = UInt64((Date.now.timeIntervalSince1970 + 600) * 1000)
        let json = Data("""
            {"v":1,"daemon":"\(id)","host":"studio","kind":"approval","item":42,"pane":7,"session":1,
             "title":"t","body":"b","at":0,
             "action":{"token":"\(Base64URL.encode(token))","approve":"Yes","deny":"No","expires":\(expires)}}
            """.utf8)
        let signature = try daemon.signature(for: PushCrypto.payloadDomain + json)
        return ([PushContent.payloadKey: String(decoding: json, as: UTF8.self), PushContent.signatureKey: signature.base64EncodedString()], id)
    }

    @Test func pushApproveSendsTheTokenOnAOneShotConnection() async throws {
        let token = Data([1, 2, 3, 4])
        let (info, daemon) = try signedApproval(Curve25519.Signing.PrivateKey(), token: token)
        let client = FakeClient()
        let handler = NotificationActionHandler(client: client)
        #expect(await handler.handle(actionIdentifier: PushAction.deny, userInfo: info, remote: true) == .decided(approve: false))
        #expect(await handler.handle(actionIdentifier: PushAction.open, userInfo: info, remote: true) == .opened)
        #expect(client.recorded == [.push(daemon: daemon, token: token, approve: false), .open(host: nil, daemon: daemon, pane: 7)])
    }

    @Test func aPushThatSkipsTheExtensionCannotForgeAPayload() async throws {
        // Without `mutable-content` the extension never runs and `userInfo` is the relay's.
        let daemon = Curve25519.Signing.PrivateKey()
        let (info, id) = try signedApproval(daemon, token: Data([1, 2, 3, 4]))
        let json = try #require(info[PushContent.payloadKey] as? String)
        let signature = try #require(info[PushContent.signatureKey] as? String)
        let (other, _) = try signedApproval(Curve25519.Signing.PrivateKey(), token: Data([1, 2, 3, 4]))
        let forgeries: [[AnyHashable: Any]] = [
            [PushContent.payloadKey: json],
            [PushContent.payloadKey: json.replacingOccurrences(of: "\"pane\":7", with: "\"pane\":8"), PushContent.signatureKey: signature],
            // Another key's valid signature over a payload that names this daemon.
            [PushContent.payloadKey: json, PushContent.signatureKey: try #require(other[PushContent.signatureKey])],
            [PushContent.payloadKey: json, PushContent.signatureKey: "!!"],
        ]
        let client = FakeClient()
        for forged in forgeries {
            #expect(await NotificationActionHandler(client: client).handle(actionIdentifier: PushAction.approve, userInfo: forged, remote: true) == .ignored)
        }
        #expect(client.recorded.isEmpty)
        #expect(PushContent.payload(from: info)?.daemon == id)
    }

    @Test func expiredTokensAndRefusalsBecomeFailures() async throws {
        // The shared vector's token expired long ago: nothing is sent.
        let vectors = try Vectors.load()
        let key = try vectors.deviceKey()
        let nse = ServiceExtensionCore(deviceKey: { key }, pairedDaemons: { [vectors.daemon] })
        let approval = try #require(vectors.payloads.first { $0.name == "approval" })
        let opened = nse.process(placeholder(approval.sealed))
        let client = FakeClient()
        let result = await NotificationActionHandler(client: client).handle(actionIdentifier: PushAction.approve, userInfo: opened.userInfo, remote: true)
        #expect(result == .failed("This request expired. Open it to answer."))
        #expect(client.recorded.isEmpty)

        // The host refuses (already decided elsewhere).
        let refusing = FakeClient(fail: true)
        let info = LocalNotifications.content(for: note).userInfo
        #expect(await NotificationActionHandler(client: refusing).handle(actionIdentifier: PushAction.approve, userInfo: info, remote: false)
            == .failed("rejected: already decided"))
        // A blocked item without options cannot be approved in place.
        var blocked = note
        blocked.kind = .approval(requestId: 5, approve: nil, deny: nil)
        let none = await NotificationActionHandler(client: client).handle(
            actionIdentifier: PushAction.approve, userInfo: LocalNotifications.content(for: blocked).userInfo, remote: false)
        #expect(none == .failed("This request has no approve option."))
    }

    @Test func aPushCannotPoseAsALocalApproval() async throws {
        // Whoever can push to this device (the relay, or anyone holding a capability) sends a
        // local notification's target, hoping an Approve tap decides that request.
        let forged = LocalNotifications.content(for: note).userInfo
        let client = FakeClient()
        #expect(await NotificationActionHandler(client: client).handle(actionIdentifier: PushAction.approve, userInfo: forged, remote: true) == .ignored)
        #expect(client.recorded.isEmpty)
        // Even if the extension timed out and delivered the push as it came.
        let content = placeholder("AAAA")
        content.userInfo = content.userInfo.merging(forged) { a, _ in a }
        let delivered = ServiceExtensionCore.placeholder(content)
        #expect(NotificationTarget(userInfo: delivered.userInfo, remote: false) == nil)
    }

    @Test func unknownPayloadsAreIgnored() async {
        let client = FakeClient()
        #expect(await NotificationActionHandler(client: client).handle(actionIdentifier: PushAction.approve, userInfo: ["x": 1], remote: true) == .ignored)
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

    /// What a cut summary hides could be anything: no Approve from the lock screen, Open only.
    @Test func aCutApprovalSummaryIsOpenOnly() {
        let cut = AttentionNote(
            hostId: "h1", hostName: "studio", itemId: 1, paneId: 2,
            kind: .approval(requestId: 3, approve: .init(id: 1, label: "Yes"), deny: .init(id: 2, label: "No")),
            title: "", body: "npm test xxxxxxxx…", agent: "Claude Code")
        let content = LocalNotifications.content(for: cut)
        #expect(content.categoryIdentifier == "AGENT_BLOCKED")
        let local = content.userInfo[LocalNotifications.localKey] as? [String: Any]
        #expect(local?["approve"] == nil)
        #expect(local?["request"] == nil)
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

/// The agents Live Activity's content state (docs/PUSH.md §6): the shared activity vector
/// opens to its host's row, other hosts' rows are kept and summed, stale and foreign ones are
/// not.
@Suite struct AgentsActivityTests {
    final class Rows: @unchecked Sendable {
        let value = Mutex<[AgentsBoard.Host]>([])
    }

    private func reader(_ vectors: Vectors, rows: Rows, paired: Set<String>? = nil) throws -> AgentsActivityReader {
        let key = try vectors.deviceKey()
        let daemons = paired ?? [vectors.daemon]
        return AgentsActivityReader(
            deviceKey: { key }, pairedDaemons: { daemons },
            loadRows: { rows.value.withLock { $0 } }, saveRows: { new in rows.value.withLock { $0 = new } })
    }

    private func row(_ daemon: String, running: UInt32 = 0, blocked: UInt32 = 0, done: UInt32 = 0, at: UInt64) throws -> AgentsBoard.Host {
        let json = """
        {"v":1,"daemon":"\(daemon)","host":"box","running":\(running),"blocked":\(blocked),"done":\(done),"headline":"codex is working","at":\(at)}
        """
        return AgentsBoard.Host(try JSONDecoder().decode(ActivityState.self, from: Data(json.utf8)))
    }

    @Test func opensTheVectorAndSumsEveryHost() throws {
        let vectors = try Vectors.load()
        let rows = Rows()
        // When the vector was made (Unix ms 1760000000000) plus a minute.
        let now = Date(timeIntervalSince1970: 1_760_000_060)
        let other = try row(String(repeating: "b", count: 64), running: 1, at: 1_759_999_990_000)
        let stale = try row(String(repeating: "c", count: 64), running: 4, at: 1_759_990_000_000)
        rows.value.withLock { $0 = [other, stale] }
        let board = try #require(try reader(vectors, rows: rows).board(for: AgentsActivityState(s: vectors.activity.sealed), now: now))
        // The vector's host: 2 working, 1 needs you, 3 done; the other host 1 working; the
        // stale one (over 20 minutes old) is gone.
        #expect(board.hosts.map(\.host) == ["studio-mac", "box"])
        #expect(board.running == 3)
        #expect(board.blocked == 1)
        #expect(board.done == 3)
        #expect(board.phase == .blocked)
        #expect(board.headline.hasPrefix("claude: approve"))
        #expect(board.summary == "1 needs you · 3 working · 3 done")
        #expect(rows.value.withLock { $0.count } == 2, "kept for the next push")
    }

    @Test func aLatePushNeverReplacesANewerRow() throws {
        let vectors = try Vectors.load()
        let rows = Rows()
        let newer = try row(vectors.daemon, at: 1_760_000_050_000)
        rows.value.withLock { $0 = [newer] }
        let board = try #require(try reader(vectors, rows: rows).board(
            for: AgentsActivityState(s: vectors.activity.sealed), now: Date(timeIntervalSince1970: 1_760_000_060)))
        #expect(board.hosts.isEmpty, "the newer row says nothing runs")
        #expect(board.summary == "All quiet")
    }

    @Test func refusesUnpairedHostsMissingKeysAndOtherFormats() throws {
        let vectors = try Vectors.load()
        let state = AgentsActivityState(s: vectors.activity.sealed)
        #expect(try reader(vectors, rows: Rows(), paired: []).board(for: state) == nil)
        var keyless = try reader(vectors, rows: Rows())
        keyless.deviceKey = { nil }
        #expect(keyless.board(for: state) == nil)
        #expect(try reader(vectors, rows: Rows()).board(for: AgentsActivityState(s: vectors.activity.sealed, v: 2)) == nil)
        #expect(try reader(vectors, rows: Rows()).board(for: AgentsActivityState(s: vectors.payloads[0].sealed)) == nil, "a notification is no activity")
    }
}
