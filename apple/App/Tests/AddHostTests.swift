#if os(macOS)
import AppKit
import HostKit
import SwiftUI
import XCTest
@testable import App

/// Add Host, Pair a Device and Join a Session as a person uses them: typed into, clicked, and
/// against a real `gudo-hostd` on a temporary state directory.
@MainActor
final class AddHostTests: XCTestCase {
    private var window: HostWindow?
    private var daemons: [TestDaemon] = []
    private var pairedHosts: [String] = []

    override func setUp() async throws {
        try XCTSkipUnless(LaunchOptions.mock, "needs TEST_RUNNER_GUDO_MOCK=1")
    }

    override func tearDown() async throws {
        window?.close()
        window = nil
        let hosts = AppModel.shared.hosts
        for id in pairedHosts + hosts.records.filter({ $0.name.hasPrefix("add-host-") || $0.ssh?.host == "127.0.0.1" }).map(\.id) {
            hosts.remove(id)
        }
        for daemon in daemons { daemon.stop() }
    }

    private func daemon() throws -> TestDaemon {
        let daemon = try TestDaemon()
        daemons.append(daemon)
        return daemon
    }

    /// Add Host as a sheet of a window, on the app's real hosts.
    private func presentAddHost(mode: PairingSheet.Mode = .ssh) async throws -> (HostWindow, SheetPresenter) {
        let presenter = SheetPresenter()
        let directory = LiveHostDirectory(app: .shared)
        let window = HostWindow {
            PresentedSheet(presenter: presenter) {
                PairingSheet(directory: directory, live: AppModel.shared.hosts, initialMode: mode)
            }
        }
        self.window = window
        try await window.until("the sheet is up") { window.sheet != nil }
        await window.pump(0.5)
        return (window, presenter)
    }

    // MARK: SSH

    func testConnectWaitsForAnAddressItCanDial() async throws {
        let (window, _) = try await presentAddHost()
        XCTAssertTrue(window.isDisabled("pairing-confirm"), "nothing typed")

        try await window.enter("dev@", into: "pairing-destination")
        XCTAssertTrue(window.isDisabled("pairing-confirm"), "a user and no host")

        try await window.enter("dev@build-box", into: "pairing-destination")
        try await window.until("a user and a host can connect") { window.isEnabled("pairing-confirm") }

        for port in ["99999", "0", "ssh"] {
            try await window.enter(port, into: "ssh-port")
            try await window.until("port \(port) can't connect") { window.isDisabled("pairing-confirm") }
        }
        try await window.enter("2222", into: "ssh-port")
        try await window.until("port 2222 can connect") { window.isEnabled("pairing-confirm") }
    }

    func testAConnectThatFailsSaysWhyAndCanKeepTheHost() async throws {
        let port = try Self.closedPort()
        let (window, presenter) = try await presentAddHost()
        try await window.enter("dev@127.0.0.1", into: "pairing-destination")
        try await window.enter(String(port), into: "ssh-port")
        try await window.until("Connect is on") { window.isEnabled("pairing-confirm") }

        try await window.click("pairing-confirm")

        let failure = try await window.waitForElement("pairing-error", timeout: .seconds(30))
        XCTAssertTrue(presenter.isPresented, "the sheet stays to fix the address")
        XCTAssertFalse(window.texts().filter { $0.contains("refused") || $0.contains("reach") || $0.contains("connect") }.isEmpty,
                       "says why: \(failure.words) \(window.texts())")
        try await window.click("pairing-keep-host")
        try await window.until("Add Anyway closes the sheet") { !presenter.isPresented }
        let kept = AppModel.shared.hosts.records.first { $0.ssh?.host == "127.0.0.1" && $0.ssh?.port == port }
        XCTAssertNotNil(kept, "the host is saved: \(AppModel.shared.hosts.records.map(\.name))")
    }

    func testTheNameGivenNamesTheHostInTheSidebar() async throws {
        let port = try Self.closedPort()
        let (window, presenter) = try await presentAddHost()
        try await window.enter("dev@127.0.0.1", into: "pairing-destination")
        try await window.enter(String(port), into: "ssh-port")
        try await window.enter("add-host-ops", into: "ssh-name")
        try await window.until("Connect is on") { window.isEnabled("pairing-confirm") }
        try await window.click("pairing-confirm")
        _ = try await window.waitForElement("pairing-error", timeout: .seconds(30))
        try await window.click("pairing-keep-host")
        try await window.until("Add Anyway closes the sheet") { !presenter.isPresented }
        let hosts = AppModel.shared.hosts
        let kept = try XCTUnwrap(hosts.records.first { $0.ssh?.host == "127.0.0.1" && $0.ssh?.port == port })
        let groups = HostGroups(hosts: hosts)
        _ = try? groups.open(kept.id)
        XCTAssertEqual(groups.group(kept.id)?.name, "add-host-ops")
        window.close()

        let editPresenter = SheetPresenter()
        let editWindow = HostWindow {
            PresentedSheet(presenter: editPresenter) { EditSSHHostSheet(hosts: hosts, record: kept) }
        }
        self.window = editWindow
        try await editWindow.until("the sheet is up") { editWindow.sheet != nil }
        await editWindow.pump(0.5)
        try await editWindow.enter("add-host-web", into: "ssh-name")
        try await editWindow.click("ssh-save")
        try await editWindow.until("Save closes the sheet") { !editPresenter.isPresented }
        XCTAssertEqual(groups.group(kept.id)?.name, "add-host-web", "renamed in Edit Host")
    }

    // MARK: Ticket

    func testATicketFromAHostPairsWithIt() async throws {
        let daemon = try daemon()
        let ticket = try await daemon.ticket()
        let (window, presenter) = try await presentAddHost(mode: .ticket)
        XCTAssertTrue(window.isDisabled("pairing-confirm"), "no ticket yet")

        try await window.enter("not a ticket", into: "pairing-ticket")
        _ = try await window.waitForElement("pairing-not-a-ticket")
        XCTAssertTrue(window.isDisabled("pairing-confirm"), "only a ticket pairs")

        try await window.enter(ticket, into: "pairing-ticket")
        let host = try await window.waitForElement("pairing-ticket-host")
        XCTAssertTrue(host.words.contains("New host") || window.says("New host"), window.texts().joined(separator: " | "))
        XCTAssertNil(window.element("pairing-not-a-ticket"))
        try await window.until("Pair is on") { window.isEnabled("pairing-confirm") }
        let before = Set(AppModel.shared.hosts.records.map(\.id))

        try await window.click("pairing-confirm")

        try await window.until("pairing closes the sheet", timeout: .seconds(20)) { !presenter.isPresented }
        let paired = try XCTUnwrap(AppModel.shared.hosts.records.first { !before.contains($0.id) })
        pairedHosts.append(paired.id)
        XCTAssertEqual(paired.kind, .daemon)
        try await window.until("the paired host is live", timeout: .seconds(20)) {
            AppModel.shared.hosts.connection(paired.id)?.status.isLive == true
        }
    }

    func testATicketWhoseHostIsGoneSaysItCouldNotPair() async throws {
        let daemon = try daemon()
        let ticket = try await daemon.ticket()
        daemon.stop()
        let (window, presenter) = try await presentAddHost(mode: .ticket)
        try await window.enter(ticket, into: "pairing-ticket")
        try await window.until("Pair is on") { window.isEnabled("pairing-confirm") }

        try await window.click("pairing-confirm")

        _ = try await window.waitForElement("pairing-error", timeout: .seconds(60))
        XCTAssertTrue(window.says("Couldn't pair"), window.texts().joined(separator: " | "))
        XCTAssertTrue(presenter.isPresented, "the sheet stays")
        try await window.until("Pair is on again to retry") { window.isEnabled("pairing-confirm") }
    }

    // MARK: Pair a Device

    func testPairADeviceShowsACodeAndWhoMayUseIt() async throws {
        let daemon = try daemon()
        let hostId = try await AppModel.shared.hosts.pair(PairingTicket(try await daemon.ticket()), name: "add-host-pair-device")
        pairedHosts.append(hostId)
        try await HostWindow.untilStatic("owner identity", timeout: .seconds(20)) {
            (AppModel.shared.hosts.connection(hostId) as? DaemonConnection)?.multiplayer.me != nil
        }
        let presenter = SheetPresenter()
        let window = HostWindow { PresentedSheet(presenter: presenter) { PairDeviceSheet(hostId: hostId) } }
        self.window = window

        let name = DeviceHosts.name(hostId, hosts: AppModel.shared.hosts)
        let code = try await window.waitForElement("pair-device-qr", timeout: .seconds(15))
        XCTAssertEqual(code.label, "QR code to pair a device with \(name)", "the code is there for VoiceOver too")
        let warning = try await window.waitForElement("pair-device-warning")
        XCTAssertTrue(warning.words.contains("Anyone with this code can control \(name)"), warning.words)
        XCTAssertTrue(window.says("Works once, for"), window.texts().joined(separator: " | "))
        _ = try await window.waitForElement("pair-device-copy")

        try await window.click("pair-device-done")
        try await window.until("Done closes it") { !presenter.isPresented }
    }

    // MARK: Join

    func testJoinShowsTheInviteAndJoinsItsSession() async throws {
        let daemon = try daemon()
        let owner = Self.otherDevice()
        let ownerHost = try await owner.pair(PairingTicket(try await daemon.ticket()), name: "owner")
        let ownerConnection = try XCTUnwrap(owner.connection(ownerHost) as? DaemonConnection)
        try await HostWindow.untilStatic("owner identity", timeout: .seconds(20)) { ownerConnection.multiplayer.me != nil }
        var draft = InviteDraft()
        draft.name = "add-host-guest"
        draft.knock = false
        let invite = try await ownerConnection.multiplayer.createInvite(draft.options(inviter: "Alex", session: nil, tab: nil, pane: nil))
        defer { owner.remove(ownerHost) }

        let presenter = SheetPresenter()
        let window = HostWindow { PresentedSheet(presenter: presenter) { JoinSheet() } }
        self.window = window
        try await window.until("the sheet is up") { window.sheet != nil }
        await window.pump(0.5)
        XCTAssertNil(window.element("join-button"), "no link, nothing to join")

        try await window.enter("gudo-pair-ticket-nonsense", into: "join-field")
        try await window.until("says it isn't an invite") { window.says("That isn't an invite link") }

        try await window.enter(invite.link, into: "join-field")
        try await window.until("the invite's card shows who invited") { window.says("Alex") }
        let before = Set(AppModel.shared.hosts.records.map(\.id))
        try await window.click("join-button")

        try await window.until("joining closes the sheet", timeout: .seconds(20)) { !presenter.isPresented }
        let joined = try XCTUnwrap(AppModel.shared.hosts.records.first { !before.contains($0.id) })
        pairedHosts.append(joined.id)
        XCTAssertTrue(joined.isGuest)
        try await window.until("the owner sees the guest", timeout: .seconds(20)) {
            ownerConnection.multiplayer.others.contains { $0.name == "add-host-guest" }
        }
    }

    // MARK: Helpers

    /// Another device: hosts and keys of its own, relays off.
    static func otherDevice() -> HostsModel {
        var configuration = HostsModel.Configuration()
        configuration.relay = .disabled
        let directory = FileManager.default.temporaryDirectory.appending(path: "other-device-\(UUID().uuidString)", directoryHint: .isDirectory)
        return HostsModel(secrets: MemorySecretStore(), repository: HostRepository(directory: directory), configuration: configuration)
    }

    /// A loopback port nothing listens on.
    static func closedPort() throws -> UInt16 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0 }
        }
        try XCTSkipUnless(bound, "no loopback port")
        return UInt16(bigEndian: address.sin_port)
    }
}

extension HostWindow {
    static func untilStatic(_ what: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TimedOut(what: what, screen: "") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
#endif
