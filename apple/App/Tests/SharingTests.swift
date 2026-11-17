#if os(macOS)
import AppKit
import HostKit
import SwiftUI
import XCTest
@testable import App

/// Sharing a session from a real window on a real `gudo-hostd`: Share Session makes an invite
/// that another device (a second hosts model, keys of its own) joins with; the owner sees them,
/// follows them, hands control over and takes it back, and removes them. The sizing chip shows
/// only while another device is connected.
@MainActor
final class SharingTests: XCTestCase {
    private var daemon: TestDaemon?
    private var zshDirectory: URL?
    private var hostId: String?
    private var window: HostWindow?
    private var guest: HostsModel?
    private var guestHost: String?

    override func setUp() async throws {
        try XCTSkipUnless(LaunchOptions.mock, "needs TEST_RUNNER_GUDO_MOCK=1")
        let zsh = FileManager.default.temporaryDirectory.appending(path: "sharing-zsh-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: zsh, withIntermediateDirectories: true)
        try "PROMPT='%# '\nRPROMPT=''\nunset HISTFILE\n".write(to: zsh.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        zshDirectory = zsh
        let daemon = try TestDaemon(shell: "/bin/zsh", environment: ["ZDOTDIR": zsh.path])
        self.daemon = daemon
        let hostId = try await AppModel.shared.hosts.pair(PairingTicket(try await daemon.ticket()), name: "sharing-host")
        self.hostId = hostId
        let window = HostWindow(width: 1100, height: 720)
        self.window = window
        window.model.show(.host(hostId))
        try await window.waitForShell()
        try await window.until("this device is the owner", timeout: .seconds(15)) { self.session?.me != nil }
    }

    override func tearDown() async throws {
        window?.close()
        if let guestHost { guest?.remove(guestHost) }
        if let hostId { AppModel.shared.hosts.remove(hostId) }
        daemon?.stop()
        if let zshDirectory { try? FileManager.default.removeItem(at: zshDirectory) }
    }

    private var connection: DaemonConnection? { hostId.flatMap { AppModel.shared.hosts.connection($0) as? DaemonConnection } }
    private var session: MultiplayerSession? { connection?.multiplayer }

    /// Share Session up, an invite named `name` for `role` made from it, its link read off the sheet.
    private func invite(_ name: String, role: String) async throws -> String {
        let window = try XCTUnwrap(window)
        window.model.sheet = .invite
        _ = try await window.waitForElement("create-invite")
        try await window.enter(name, into: "invite-name")
        try await window.click("role-\(role)")
        try await window.click("create-invite")
        _ = try await window.waitForElement("invite-link", timeout: .seconds(10))
        // What Copy Link puts on the pasteboard, without touching the pasteboard.
        let session = try XCTUnwrap(session)
        let grant = try XCTUnwrap(session.activeGrants.first { $0.grant.label == name }, "the invite is under Active Links")
        let link = await session.link(for: grant)
        return try XCTUnwrap(link)
    }

    /// Another device joins with `link`, and follows the window's pane at its own size.
    private func join(_ link: String) async throws -> (DaemonConnection, any PaneBackend) {
        let guest = AddHostTests.otherDevice()
        self.guest = guest
        let id = try await guest.join(invite: link)
        guestHost = id
        let connection = try XCTUnwrap(guest.connection(id) as? DaemonConnection)
        try await window?.until("the guest is in", timeout: .seconds(15)) { connection.multiplayer.me != nil }
        let pane = try XCTUnwrap(window?.pane?.id)
        let backend = try connection.makeBackend(for: pane)
        backend.start(events: { _ in })
        backend.resize(cols: 60, rows: 18, cellWidth: 8, cellHeight: 16)
        return (connection, backend)
    }

    func testShareSessionInvitesSomeoneWhoJoinsIsFollowedAndRemoved() async throws {
        let window = try XCTUnwrap(window)
        let link = try await invite("Dee", role: "driver")
        XCTAssertTrue(window.says("Driver"), "the invite says what it gives: \(window.texts())")

        let (guestConnection, _) = try await join(link)

        let row = try await window.waitForElement("person-Dee", timeout: .seconds(15))
        XCTAssertTrue(row.words.contains("Dee"), row.words)
        if let follow = window.element("follow-Dee") {
            try await window.click(follow)
            try await window.until("following Dee") { self.session?.following == guestConnection.multiplayer.myPrincipal }
            try await window.click("follow-Dee")
            try await window.until("not following any more") { self.session?.following == nil }
        }

        try await window.click("remove-Dee")
        try await window.click(try await window.waitForElement("Remove", inSheet: true))

        try await window.until("Dee is out", timeout: .seconds(15)) {
            guestConnection.multiplayer.isRevoked || !guestConnection.status.isLive
        }
        try await window.until("and gone from People", timeout: .seconds(15)) { window.element("person-Dee") == nil }
    }

    func testTheSizingChipShowsOnlyWhileAnotherDeviceIsConnectedAndUseThisSizeTakesItBack() async throws {
        let window = try XCTUnwrap(window)
        await window.pump(1)
        XCTAssertNil(window.element("terminal-sizing-takeover"), "alone: nothing says who sizes the pane")
        let link = try await invite("Sam", role: "driver")
        window.model.sheet = nil
        let (_, backend) = try await join(link)

        // The guest types, so its size is the pane's.
        Array("echo sam\r".utf8).withUnsafeBytes { backend.write($0) }
        let chip = try await window.waitForElement("terminal-sizing-takeover", timeout: .seconds(15))
        try await window.click(chip)

        try await window.until("the window's size is the pane's again", timeout: .seconds(10)) {
            guard let pane = window.pane, let grid = pane.view.surface.grid else { return false }
            let size = pane.view.surface.terminal.size
            return size.cols == Int(grid.cols) && size.rows == Int(grid.rows)
        }
        try await window.until("and the chip goes") { window.element("terminal-sizing-takeover") == nil }
    }

    func testHandingControlOverAndTakingItBack() async throws {
        let window = try XCTUnwrap(window)
        let link = try await invite("Kim", role: "driver")
        window.model.sheet = nil
        let (guestConnection, backend) = try await join(link)
        let guestSession = guestConnection.multiplayer
        let pane = try XCTUnwrap(window.pane?.id.rawValue)
        // The owner holds the pane by typing in it.
        try await window.run("echo mine-$((1+1))", showing: "mine-2")
        try await window.until("the owner holds the pane", timeout: .seconds(10)) { guestSession.holder(of: pane) == self.session?.myPrincipal }

        Task { _ = await guestSession.takeControl(pane) }
        _ = try await window.waitForElement("lease-request", timeout: .seconds(10))
        XCTAssertTrue(window.says("Kim wants control"), window.texts().joined(separator: " | "))
        try await window.click("hand-over")
        try await window.until("Kim drives", timeout: .seconds(10)) { guestSession.isDriving(pane) }
        Array("echo kim-$((2+2))\r".utf8).withUnsafeBytes { backend.write($0) }
        try await window.until("Kim's keys arrive") { window.rows.contains("kim-4") }

        let take = try await window.waitForElement("take-control", timeout: .seconds(10))
        XCTAssertTrue(window.says("Kim is driving"), window.texts().joined(separator: " | "))
        try await window.click(take)
        try await window.until("Kim is asked", timeout: .seconds(10)) { !guestSession.leaseRequests.isEmpty }
        let request = try XCTUnwrap(guestSession.leaseRequests.first)
        await guestSession.answer(request, give: true)
        try await window.until("the owner drives again", timeout: .seconds(10)) { self.session?.isDriving(pane) == true }
        try await window.run("echo back-$((3+3))", showing: "back-6")
    }
}
#endif
