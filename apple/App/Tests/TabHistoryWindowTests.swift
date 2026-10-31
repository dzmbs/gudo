import HostKit
import PaneLayout
import SwiftUI
import XCTest
@testable import App

/// A window's tab history and selection on the projects fixture (two daemons and an SSH host,
/// two projects): what closing keeps, the selection's bulk actions and drag, and "A New Terminal".
@MainActor
final class TabHistoryWindowTests: XCTestCase {
    private var model: WindowModel!

    override func setUp() async throws {
        model = WindowModel(app: .shared)
        model.start()
        DesignFixtures.projects(model)
        XCTAssertEqual(model.projects.map(\.name), ["acme-app", "infra"])
    }

    override func tearDown() async throws {
        model.close()
        for id in ["fixture-studio", "fixture-hetzner", "fixture-box"] { AppModel.shared.hosts.disconnect(id) }
    }

    private func eventually(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), what)
    }

    /// A closed tab is remembered with its host, project and places; no terminal contents.
    func testClosingRemembersWhereTheTabWas() throws {
        let app = try XCTUnwrap(model.projects.first { $0.name == "acme-app" })
        let closing = app.tabs[1]
        model.closeTab(closing, undoable: true)
        XCTAssertFalse(model.groups.tabs.contains(closing))
        let entry = try XCTUnwrap(model.recentlyClosed.tabs.first)
        XCTAssertEqual(entry.title, "web")
        XCTAssertEqual(entry.hostName, "hetzner")
        XCTAssertEqual(entry.project?.id, app.id)
        XCTAssertEqual(entry.projectIndex, 1)
        XCTAssertEqual(entry.hostIndex, 0)
        XCTAssertNil(entry.batch)
    }

    /// Close Tabs on a selection: one batch (one ⇧⌘T or Undo brings all back), the selection ends.
    func testBulkCloseIsOneBatch() throws {
        let rows = Array(model.groups.tabs.prefix(3))
        model.clickTab(rows[0])
        model.clickTab(rows[2], modifiers: .shift)
        XCTAssertEqual(model.selectedTabs, rows)
        model.requestCloseSelectedTabs()
        XCTAssertNil(model.pendingBulkClose, "nothing runs in them: no question")
        XCTAssertTrue(rows.allSatisfy { !model.groups.tabs.contains($0) })
        let closed = model.recentlyClosed.tabs.prefix(3)
        XCTAssertEqual(Set(closed.compactMap(\.batch)).count, 1)
        XCTAssertEqual(closed.count, 3)
        XCTAssertFalse(model.tabSelection.isMultiple)
        XCTAssertEqual(model.recentlyClosed.takeLatest().count, 3, "⇧⌘T takes the whole close")
    }

    /// ⌘-click toggles from the tab on screen, a plain click goes back to one tab.
    func testClicksSelectLikeFinder() throws {
        let rows = model.groups.tabs
        model.focus(rows[0])
        model.clickTab(rows[3], modifiers: .command)
        XCTAssertEqual(model.selectedTabs, [rows[0], rows[3]])
        XCTAssertTrue(model.isInMultipleSelection(rows[3]))
        model.clickTab(rows[1])
        XCTAssertTrue(model.tabSelection.selected.isEmpty)
        XCTAssertEqual(model.currentTab, rows[1])
        model.selectAllTabs()
        XCTAssertEqual(model.selectedTabs, rows)
    }

    /// A selection dragged by one of its rows lands together, and the list while dragging is the
    /// list the drop leaves.
    func testDraggingASelectionMovesItTogether() throws {
        let infra = try XCTUnwrap(model.projects.first { $0.name == "infra" })
        let studio = try XCTUnwrap(model.groups.sections.first { $0.container == .host("fixture-studio") }?.rows.first)
        let hetzner = try XCTUnwrap(model.groups.sections.first { $0.container == .host("fixture-hetzner") }?.rows.first)
        model.clickTab(studio, modifiers: .command)
        model.clickTab(hetzner, modifiers: .command)
        model.tabSelection.toggle(model.currentTab!, current: nil)
        XCTAssertEqual(Set(model.selectedTabs), [studio, hetzner])
        let drop = SidebarDrop.insert(hetzner, into: .project(infra.id), at: 0)
        let preview = model.sidebarItems(drop: drop, projectMove: nil).items.map(\.id)
        model.commit(drop)
        XCTAssertEqual(model.sidebarItems(drop: nil, projectMove: nil).items.map(\.id), preview)
        XCTAssertEqual(Array(model.groups.project(infra.id)!.tabs.prefix(2)), [hetzner, studio])
    }

    /// "A New Terminal": what the hosts had stays out of sight (still on the hosts), a fresh
    /// terminal opens, and Restore brings the rest back.
    func testANewTerminalKeepsTheOldTabsAside() async throws {
        let before = model.groups.tabs.filter { $0.hostId != HostGroups.localId }
        model.startFresh(lastHost: nil)
        try await eventually("hidden") { before.allSatisfy { !self.model.groups.tabs.contains($0) } }
        XCTAssertEqual(Set(model.groups.restorableTabs), Set(before))
        XCTAssertTrue(model.sidebarItems(drop: nil, projectMove: nil).items.contains(.restoreTabs(before.count)))
        // Asking for one brings that one back.
        model.focus(before[0])
        XCTAssertTrue(model.groups.tabs.contains(before[0]))
        model.restoreHiddenTabs()
        XCTAssertTrue(before.allSatisfy { model.groups.tabs.contains($0) })
        XCTAssertFalse(model.sidebarItems(drop: nil, projectMove: nil).items.contains { if case .restoreTabs = $0 { true } else { false } })
    }

    /// ⌘W on a tab's last pane closes the tab into Recently Closed; ⇧⌘T brings one back on
    /// this device.
    func testCommandWAndReopen() async throws {
        let local = try XCTUnwrap(model.workspace(ofGroup: HostGroups.localId))
        model.focus(TabRef(hostId: HostGroups.localId, tab: try XCTUnwrap(local.session.tabs.first?.id)))
        let count = local.session.tabs.count
        model.closeFocusedPaneOrTab()
        XCTAssertEqual(local.session.tabs.count, count - 1)
        XCTAssertEqual(model.recentlyClosed.tabs.first?.hostId, HostGroups.localId)
        WorkspaceAction.reopenClosedTab.perform(on: local, window: model)
        try await eventually("reopened") { local.session.tabs.count == count }
        XCTAssertTrue(model.recentlyClosed.tabs.isEmpty)
    }
}
