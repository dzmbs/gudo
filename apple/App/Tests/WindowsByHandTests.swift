#if os(macOS)
import AppKit
import GudoCore
import HostKit
import XCTest
@testable import App

/// Windows used by hand: a tab's menu opens the tab in a window of its own, and a window brought
/// back after a relaunch shows the tab and pane it had.
@MainActor
final class WindowsByHandTests: XCTestCase {
    private var drivers: [WorkspaceDriver] = []

    override func tearDown() async throws {
        for driver in drivers.reversed() { driver.close() }
        drivers = []
    }

    private func start(request: WindowRequest? = nil) async throws -> WorkspaceDriver {
        let driver = try await WorkspaceDriver.start(width: 1000, height: 700, request: request)
        drivers.append(driver)
        return driver
    }

    /// The window shows `ref`, and its own terminal for it has the keyboard and echoes typing.
    private func assertShows(_ ref: TabRef, in driver: WorkspaceDriver, _ context: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        await driver.expect("\(context): shows \(ref)", file: file, line: line) { driver.model.shownTab == ref && driver.terminal()?.window === driver.window }
        await driver.settle()
        let terminal = try XCTUnwrap(driver.terminal(), file: file, line: line)
        XCTAssertTrue(driver.window.firstResponder === terminal, "\(context): its terminal has the keyboard", file: file, line: line)
        let marker = "q\(Int.random(in: 100...999))"
        driver.type(marker)
        let workspace = try driver.workspace
        let pane = try XCTUnwrap(workspace.focusedPane, file: file, line: line)
        await driver.expect("\(context): typing shows", file: file, line: line) {
            workspace.pane(pane)?.view.surface.terminal.visibleText().contains(marker) ?? false
        }
    }

    func testOpenInNewWindowFromARowsMenuShowsThatTab() async throws {
        let first = try await start()
        first.command("t")
        await first.settle()
        let moving = try XCTUnwrap(first.model.groups.tabs.first)
        XCTAssertNotEqual(first.model.shownTab, moving)

        await first.contextMenu(on: first.sidebarRowFrame(of: moving), choose: ["Open in New Window"])
        await first.expect("the window asks for one") { !first.requestedWindows.isEmpty }
        let request = try XCTUnwrap(first.requestedWindows.last)
        XCTAssertEqual(request.tab, moving)

        let second = try await start(request: request)
        try await assertShows(moving, in: second, "the tab's own window")
        XCTAssertNotEqual(first.model.shownTab, moving, "the first window keeps its own tab in front")
    }

    /// The window's state as the scene saves it, given to a window opened after a relaunch as
    /// the scene restores it, against a real host on a temporary state directory.
    func testAWindowRestoredAfterARelaunchShowsItsTabAndPane() async throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let hostId = try await AppModel.shared.hosts.pair(PairingTicket(try await daemon.ticket()), name: "restore-by-hand")
        defer { AppModel.shared.hosts.remove(hostId) }

        let before = try await start()
        before.model.show(.host(hostId))
        // On screen behind another app's window: an offscreen test window's scene is in the background.
        before.model.isOnScreen = true
        await before.expect("the host connects", timeout: 20) { AppModel.shared.hosts.connection(hostId)?.isReady == true }
        for count in 1...2 {
            before.command("t")
            await before.expect("tab \(count) on the host is live", timeout: 20) {
                guard let workspace = before.model.workspace, workspace.groupId == hostId, workspace.session.tabs.count == count,
                      let id = workspace.focusedPane else { return false }
                return workspace.panes[id]?.connection == .live
            }
        }
        await before.settle()
        before.command("d")
        await before.expect("the tab splits", timeout: 10) { (before.model.workspace?.session.activeTab?.root.panes.count ?? 0) == 2 }
        await before.settle()
        let workspace = try before.workspace
        let left = try XCTUnwrap(workspace.session.activeTab?.root.panes.first)
        await before.click(before.frame(of: try XCTUnwrap(before.terminal(of: left))))
        await before.expect("the left pane takes the focus") { workspace.focusedPane == left }
        let savedHosts = before.model.groups.openHosts
        let savedTab = try XCTUnwrap(before.model.currentTab)
        let savedPane = try XCTUnwrap(before.model.currentPane)
        before.close()
        drivers.removeAll { $0 === before }
        AppModel.shared.hosts.disconnect(hostId)

        let after = try await start(request: WindowRequest(hosts: [], tab: nil))
        after.model.isOnScreen = true
        after.model.restore(openHosts: savedHosts, collapsed: [], focus: savedTab, pane: savedPane)
        await after.expect("the restored window shows the tab", timeout: 20) {
            after.model.currentTab == savedTab && after.model.workspace?.focusedPane == savedPane
                && after.terminal()?.window === after.window
        }
        await after.settle()
        XCTAssertEqual(after.model.workspace?.session.activeTab?.root.panes.count, 2, "with both its panes")
        XCTAssertTrue(after.window.firstResponder === after.terminal(), "the pane it had has the keyboard")
    }
}
#endif
