import Foundation
import HostKit
import NotifyKit
import Synchronization
import GudoCore
import UserNotifications
import XCTest
@testable import App

/// What a posted request said.
private struct Posted: Sendable {
    var title: String
    var subtitle: String
    var body: String
    var host: String?
}

nonisolated private final class RecordingPoster: NotificationPosting {
    let requests = Mutex<[Posted]>([])
    func add(_ request: UNNotificationRequest) async throws {
        let content = request.content
        let posted = Posted(title: content.title, subtitle: content.subtitle, body: content.body,
                            host: DeviceNotifications.hostId(from: content.userInfo))
        requests.withLock { $0.append(posted) }
    }
}

/// Pairings and host alerts reach the owner's other devices as notifications.
@MainActor
final class HostSecurityNotifierTests: XCTestCase {
    private let me = Actor(principal: "aa", device: String(repeating: "a", count: 64))
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "host-alerts-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func ownerSession() -> MultiplayerSession {
        MultiplayerSession.preview(
            me: JoinInfo(actor: me, name: "Mira’s iPad", roles: [.owner], scope: .daemon, grantId: nil, expiresMs: nil), participants: [])
    }

    private func device(_ key: Character, _ name: String, kind: DeviceKind = .owner) -> DeviceInfo {
        DeviceInfo(device: String(repeating: key, count: 64), principal: "aa", kind: kind, name: name,
                   firstSeenMs: UInt64(Date.now.timeIntervalSince1970 * 1000), grantId: nil, revoked: false, connected: 1)
    }

    func testAPairingPostsANotificationNamingTheDeviceAndHost() async {
        let poster = RecordingPoster()
        let notifier = HostSecurityNotifier(poster: poster, ledger: HostAlertLedger(defaults: defaults)) { true }
        await notifier.post(device("c", "owner"), hostId: "h1", hostName: "studio", session: ownerSession())

        let request = poster.requests.withLock { $0.first }
        XCTAssertEqual(request?.title, "New device paired: Unnamed device")
        XCTAssertTrue(request?.body.hasPrefix("Paired with studio at ") == true)
        XCTAssertEqual(request?.host, "h1", "a tap opens that host's devices")
    }

    func testNothingForThisDeviceAGuestOrWithoutPermission() async {
        let poster = RecordingPoster()
        let session = ownerSession()
        await HostSecurityNotifier(poster: poster, ledger: HostAlertLedger(defaults: defaults)) { true }
            .post(device("a", "Mira’s iPad"), hostId: "h1", hostName: "studio", session: session)
        await HostSecurityNotifier(poster: poster, ledger: HostAlertLedger(defaults: defaults)) { true }
            .post(device("e", "Kim", kind: .guest), hostId: "h1", hostName: "studio", session: session)
        await HostSecurityNotifier(poster: poster, ledger: HostAlertLedger(defaults: defaults)) { false }
            .post(device("c", "Laptop"), hostId: "h1", hostName: "studio", session: session)
        XCTAssertTrue(poster.requests.withLock { $0.isEmpty })
    }

    func testAHostAlertIsNotifiedOnceAcrossReconnectsAndLaunches() async {
        let poster = RecordingPoster()
        let alert = HostAlert(kind: .grantStoreReset, atMs: 1_000, title: "Earlier invites stopped working", body: "Send new invites.")

        // Denied first: the alert must still be told once permission is given.
        await HostSecurityNotifier(poster: poster, ledger: HostAlertLedger(defaults: defaults)) { false }.post(alert, hostId: "h1", hostName: "studio")
        let notifier = HostSecurityNotifier(poster: poster, ledger: HostAlertLedger(defaults: defaults)) { true }
        await notifier.post(alert, hostId: "h1", hostName: "studio")
        await notifier.post(alert, hostId: "h1", hostName: "studio")
        await HostSecurityNotifier(poster: poster, ledger: HostAlertLedger(defaults: defaults)) { true }.post(alert, hostId: "h1", hostName: "studio")

        let requests = poster.requests.withLock { $0 }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.title, "Earlier invites stopped working")
        XCTAssertEqual(requests.first?.subtitle, "studio")
    }

    func testRemovingAnOwnerDeviceSaysOnlyANewPairingCodeBringsItBack() {
        let message = RemoveDeviceDialog.message(device("c", "Laptop"), name: "Laptop", hostName: "studio")
        XCTAssertTrue(message.contains("signed out of studio"))
        XCTAssertTrue(message.contains("every invite it created"))
        XCTAssertTrue(message.contains("new pairing code"))
    }
}
