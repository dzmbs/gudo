#if os(macOS)
import AppKit
import HostKit
import SwiftUI
import XCTest
@testable import App

/// A host that stops answering, from a real window: the notice over its panes says so, and is
/// also the way to act. Retry Now dials again (and the host comes back where it was); Disconnect
/// leaves it.
@MainActor
final class ReconnectTests: XCTestCase {
    private var daemon: TestDaemon?
    private var zshDirectory: URL?
    private var hostId: String?
    private var window: HostWindow?
    private let menus = OpenedMenus()

    override func setUp() async throws {
        try XCTSkipUnless(LaunchOptions.mock, "needs TEST_RUNNER_GUDO_MOCK=1")
        let zsh = FileManager.default.temporaryDirectory.appending(path: "reconnect-zsh-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: zsh, withIntermediateDirectories: true)
        try "PROMPT='%# '\nRPROMPT=''\nunset HISTFILE\n".write(to: zsh.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        zshDirectory = zsh
        let daemon = try TestDaemon(shell: "/bin/zsh", environment: ["ZDOTDIR": zsh.path])
        self.daemon = daemon
        let hostId = try await AppModel.shared.hosts.pair(PairingTicket(try await daemon.ticket()), name: "reconnect-host")
        self.hostId = hostId
        let window = HostWindow()
        self.window = window
        window.model.show(.host(hostId))
        try await window.waitForShell()
    }

    override func tearDown() async throws {
        daemon?.resume()
        window?.close()
        if let hostId { AppModel.shared.hosts.remove(hostId) }
        daemon?.stop()
        if let zshDirectory { try? FileManager.default.removeItem(at: zshDirectory) }
    }

    private var connection: DaemonConnection? { hostId.flatMap { AppModel.shared.hosts.connection($0) as? DaemonConnection } }

    /// The host freezes; the window notices and says so in its notice.
    private func freezeHost() async throws -> HostWindow.Element {
        let window = try XCTUnwrap(window)
        daemon?.freeze()
        try await window.until("the link is lost", timeout: .seconds(40)) { !window.model.connection.isLive }
        return try await window.waitForElement("connection-notice", timeout: .seconds(5))
    }

    func testRetryNowFromTheNoticeDialsAgainAndTheHostComesBackAsItWas() async throws {
        let window = try XCTUnwrap(window)
        try await window.run("echo before-$((6*7))", showing: "before-42")
        let notice = try await freezeHost()
        XCTAssertTrue(notice.words.contains("reconnect-host"), "names the host: \(notice.words)")
        let dials = try XCTUnwrap(connection?.dials)

        daemon?.resume()
        menus.choice = ["Retry Now"]
        try await window.click(notice)

        XCTAssertEqual(menus.last.filter { !$0.isEmpty }, ["Retry Now", "Disconnect"], "the notice's own menu")
        try await window.until("it dials again at once") { (self.connection?.dials ?? 0) > dials }
        try await window.until("live again", timeout: .seconds(20)) { window.model.connection.isLive && window.pane?.connection == .live }
        try await window.until("the notice goes") { window.element("connection-notice") == nil }
        XCTAssertTrue(window.screenText.contains("before-42"), window.screenText)
        try await window.run("echo after-$((2+3))", showing: "after-5")
    }

    func testDisconnectFromTheNoticeLeavesTheHost() async throws {
        let window = try XCTUnwrap(window), hostId = try XCTUnwrap(hostId)
        let notice = try await freezeHost()
        menus.choice = ["Disconnect"]

        try await window.click(notice)

        try await window.until("the window leaves the host") { window.model.currentGroupId != hostId }
        try await window.until("and the notice with it") { window.element("connection-notice") == nil }
        XCTAssertNotNil(AppModel.shared.hosts.record(hostId), "the host stays saved")
    }
}

extension TestDaemon {
    /// Stops the daemon's process where it is (a host that stops answering).
    func freeze() { signal(SIGSTOP) }

    func resume() { signal(SIGCONT) }
}
#endif
