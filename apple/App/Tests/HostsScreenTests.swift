#if os(macOS)
import AppKit
import HostKit
import SwiftUI
import XCTest
@testable import App

/// The Hosts screen on the app's real hosts, with a real `gudo-hostd` on a temporary state
/// directory: each host listed with its state, opened by a click, renamed, disconnected and
/// removed from its menu.
@MainActor
final class HostsScreenTests: XCTestCase {
    private var window: HostWindow?
    private var daemon: TestDaemon?
    private var hostId: String?
    private let menus = OpenedMenus()
    private let hostName = "hosts-screen-\(UUID().uuidString.prefix(4))"

    override func setUp() async throws {
        try XCTSkipUnless(LaunchOptions.mock, "needs TEST_RUNNER_GUDO_MOCK=1")
        let daemon = try TestDaemon()
        self.daemon = daemon
        let hostId = try await AppModel.shared.hosts.pair(PairingTicket(try await daemon.ticket()), name: hostName)
        self.hostId = hostId
        let directory = LiveHostDirectory(app: .shared)
        let window = HostWindow(width: 800, height: 600) {
            NavigationStack { HostsView(directory: directory, live: AppModel.shared.hosts) }
        }
        directory.window = window.model
        self.window = window
    }

    override func tearDown() async throws {
        window?.close()
        if let hostId { AppModel.shared.hosts.remove(hostId) }
        daemon?.stop()
    }

    private var row: String { "host-\(hostName)" }

    private func rowWords() -> String { window?.element(row)?.words ?? "" }

    func testAConnectedHostIsListedAsConnectedAndOpensOnAClick() async throws {
        let window = try XCTUnwrap(window), hostId = try XCTUnwrap(hostId)
        try await window.until("the row says Connected", timeout: .seconds(15)) { self.rowWords().contains("Connected") }
        window.model.destination = .hosts

        try await window.click(row)

        try await window.until("the host opens in the window") {
            window.model.currentGroupId == hostId && window.model.destination == .terminal
        }
    }

    func testRenameFromTheRowsMenu() async throws {
        let window = try XCTUnwrap(window), hostId = try XCTUnwrap(hostId)
        _ = try await window.waitForElement(row)
        menus.choice = ["Rename…"]

        try await window.click(row, button: .right)

        let alert = try await waitForAlert()
        let field = try XCTUnwrap(HostWindow.descendant(of: alert.contentView) { $0 is NSTextField && ($0 as? NSTextField)?.isEditable == true } as? NSTextField)
        XCTAssertEqual(field.stringValue, hostName, "the field starts on the name")
        alert.makeFirstResponder(field)
        let editor = try XCTUnwrap(alert.fieldEditor(false, for: field) as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("  build box  ", replacementRange: editor.selectedRange())
        try await window.click(try XCTUnwrap(window.element("Rename", inSheet: true)))

        try await window.until("the host has its new name, trimmed") { AppModel.shared.hosts.record(hostId)?.name == "build box" }
        try await window.until("and the list shows it") { window.element("host-build box") != nil }
    }

    func testRemoveAsksFirstThenForgetsTheHost() async throws {
        let window = try XCTUnwrap(window), hostId = try XCTUnwrap(hostId)
        _ = try await window.waitForElement(row)
        menus.choice = ["Remove Host…"]

        try await window.click(row, button: .right)

        let confirm = try await window.waitForElement("confirm-removeHost", inSheet: true)
        XCTAssertNotNil(AppModel.shared.hosts.record(hostId), "nothing is removed before the answer")
        try await window.click(confirm)

        try await window.until("the host is gone") { AppModel.shared.hosts.record(hostId) == nil }
        try await window.until("and so is its row") { window.element(self.row, inSheet: false) == nil }
        self.hostId = nil
    }

    func testADisconnectedHostSaysWhenItWasLastUsed() async throws {
        let window = try XCTUnwrap(window), hostId = try XCTUnwrap(hostId)
        try await window.until("connected first", timeout: .seconds(15)) { self.rowWords().contains("Connected") }
        menus.choice = ["Disconnect"]

        try await window.click(row, button: .right)

        try await window.until("the link is closed") { AppModel.shared.hosts.connection(hostId)?.status.isLive != true }
        try await window.until("the row says when it was last used") { self.rowWords().contains("Last used") }
        XCTAssertFalse(rowWords().contains("Not connected yet"), rowWords())
    }

    func testAHostThatGoesAwaySaysItIsReconnecting() async throws {
        let window = try XCTUnwrap(window), hostId = try XCTUnwrap(hostId)
        try await window.until("connected first", timeout: .seconds(15)) {
            AppModel.shared.hosts.connection(hostId)?.status.isLive == true && self.rowWords().contains("Connected")
        }

        daemon?.stop()
        daemon = nil

        try await window.until("the row says it is reconnecting", timeout: .seconds(30)) {
            self.rowWords().contains("Reconnecting") || self.rowWords().contains("Can't reach")
        }
        XCTAssertFalse(rowWords().contains("Connected ·"), rowWords())
    }

    // MARK: Helpers

    private func waitForAlert() async throws -> NSWindow {
        let window = try XCTUnwrap(window)
        var alert: NSWindow?
        try await window.until("the alert is up") {
            alert = window.window.attachedSheet ?? NSApp.windows.first { $0.isVisible && $0 !== window.window && $0.className.contains("Alert") }
            return alert != nil
        }
        return try XCTUnwrap(alert)
    }
}

extension HostWindow {
    static func descendant(of view: NSView?, where matches: (NSView) -> Bool) -> NSView? {
        guard let view else { return nil }
        if matches(view) { return view }
        for subview in view.subviews {
            if let found = descendant(of: subview, where: matches) { return found }
        }
        return nil
    }
}
#endif
