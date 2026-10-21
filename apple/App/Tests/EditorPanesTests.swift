import HostKit
import PaneLayout
import XCTest
@testable import App

/// VS Code editors as panes (docs/APP-ARCHITECTURE.md §20): the window's editors, where Open in
/// VS Code puts one, the keys an editor leaves to the app, and suspending editors off screen.
@MainActor
final class EditorPanesTests: XCTestCase {
    /// A source that records what the pane asks of it.
    @Observable
    final class FakeSource: EditorSource {
        var phase = EditorPhase.idle
        var mode = EditorMode.server
        var folder = "/home/me/proj"
        var hostName = "studio"
        var unavailableReason: String? { nil }
        var pendingURL: URL?
        var tunnelDesktopURI: URL? { nil }
        var calls: [String] = []
        func open() async { calls.append("open") }
        func open(path: String, line: Int?, column: Int?) async { calls.append("open \(path)") }
        func didLoad() {
            calls.append("didLoad")
            if case .loading(let url) = phase { phase = .ready(url) }
        }
        func close(stopServer: Bool) async { calls.append("close \(stopServer)") }
        func acceptLicence() async {}
        func declineLicence() {}
        func resumeIfAccepted() async {}
        func openTunnel(account: EditorTunnelAccount) async {}
    }

    private let proj = EditorMember(hostId: "h1", folder: "/home/me/proj")
    private let site = EditorMember(hostId: "h1", folder: "/home/me/site")

    // MARK: EditorPanes

    func testAPaneIsMadeOnceAndGoesWithItsLeaf() async throws {
        var made: [FakeSource] = []
        let editors = EditorPanes(suspendAfter: .seconds(600)) { _ in
            let source = FakeSource()
            made.append(source)
            return source
        }
        let first = editors.pane(for: proj)
        XCTAssertTrue(editors.pane(for: proj) === first, "one pane per editor")
        XCTAssertNil(editors.existing(site.id), "made only when shown")
        _ = editors.pane(for: site)
        XCTAssertEqual(made.count, 2)

        editors.prune(keeping: [site.id])
        XCTAssertNil(editors.existing(proj.id))
        XCTAssertNotNil(editors.existing(site.id))
        for _ in 0..<50 where made[0].calls.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(made[0].calls, ["close false"], "the server keeps running on the host")
        XCTAssertTrue(made[1].calls.isEmpty)
        editors.stop()
    }

    func testTheWebViewSurvivesBeingOffScreenUntilItsTime() async throws {
        let editors = EditorPanes(suspendAfter: .seconds(600)) { _ in FakeSource() }
        let pane = editors.pane(for: proj)
        let url = URL(string: "http://localhost:9/?tkn=t&folder=/home/me/proj")!
        pane.phaseChanged(.loading(url))
        let webView = try XCTUnwrap(pane.webView, "the address loads in the pane's own web view")
        pane.isWorkbenchVisible = true

        // Shown, hidden (a tab switch), shown again: the same web view, never reloaded.
        pane.appeared()
        pane.disappeared()
        pane.appeared()
        XCTAssertTrue(pane.webView === webView)
        pane.phaseChanged(.ready(url))
        XCTAssertTrue(pane.webView === webView, "the same address does not load again")

        // On screen it is never suspended; off screen not before its time.
        await editors.sweep(now: .now + .seconds(3600))
        XCTAssertNotNil(pane.webView, "on screen")
        pane.disappeared()
        await editors.sweep(now: .now + .seconds(60))
        XCTAssertTrue(pane.webView === webView, "off screen for a minute: kept")
        XCTAssertFalse(pane.isSuspended)

        // Past ten minutes off screen: released.
        await editors.sweep(now: .now + .seconds(601))
        XCTAssertNil(pane.webView, "the web view is released")
        XCTAssertTrue(pane.isSuspended)
        XCTAssertFalse(pane.isWorkbenchVisible)

        // Shown again: a new web view reloads where it was.
        pane.appeared()
        let again = try XCTUnwrap(pane.webView)
        XCTAssertFalse(again === webView)
        XCTAssertTrue(pane.isSuspended, "until the workbench has loaded again")
        editors.stop()
    }

    func testTheDefaultIsTenMinutes() {
        XCTAssertEqual(EditorPanes.defaultSuspendAfter, .seconds(600))
    }

    // MARK: The window

    func testOpenInVSCodeMakesATabOrALeafBesideAndBringsAnOpenOneForward() throws {
        let model = WindowModel(app: .shared)
        model.startMixedTabs()
        // A tab of its own.
        model.showEditor(proj, placement: .tab)
        let tab = try XCTUnwrap(model.activeMixed)
        XCTAssertTrue(tab.isEditorOnly)
        XCTAssertEqual(tab.focusedEditor, proj)
        XCTAssertEqual(model.title(ofMixedTab: tab), "proj")
        XCTAssertEqual(model.programIdentity(ofMixedTab: tab), .vscode)

        // Another folder: another tab, listed with the first.
        model.showEditor(site, placement: .tab)
        XCTAssertEqual(model.composites.tabs.count, 2)
        XCTAssertEqual(model.activeMixed?.focusedEditor, site)
        XCTAssertEqual(model.groups.mixedTabs.count, 2)

        // The first again: its tab comes forward, no third.
        model.showEditor(proj, placement: .tab)
        XCTAssertEqual(model.composites.tabs.count, 2)
        XCTAssertEqual(model.activeMixedTab, tab.id)

        // Beside: in the tab on screen.
        let docs = EditorMember(hostId: "h2", folder: "/srv/docs")
        model.showEditor(docs, placement: .split)
        XCTAssertEqual(model.activeMixed?.leaves.count, 2)
        XCTAssertEqual(model.activeMixed?.focusedEditor, docs)
        XCTAssertEqual(model.activeMixed?.hosts, ["h1", "h2"])

        // ⌘W on the editor: its leaf goes; the pane with it once the window prunes.
        model.closeEditor(docs.id)
        XCTAssertEqual(model.activeMixed?.leaves.count, 1)
        XCTAssertNil(model.composites.tab(containingEditor: docs.id))
    }

    func testBesideATerminalAndBackToIt() throws {
        let model = WindowModel(app: .shared)
        model.startMixedTabs()
        var session = Session()
        session.apply(.split(PaneId(1), .horizontal))
        let id = model.composites.make(fromHost: "h1", tab: session.tabs[0])
        model.activeMixedTab = id
        model.showEditor(proj, placement: .split)
        let tab = try XCTUnwrap(model.activeMixed)
        XCTAssertEqual(tab.leaves.count, 3, "two terminals and the editor")
        XCTAssertEqual(tab.focusedEditor, proj)
        XCTAssertFalse(tab.isEditorOnly)

        // The editor has the keyboard once its workbench shows; a sheet takes it back.
        XCTAssertFalse(model.editorHasKeys, "not before the workbench is up")
        model.editors.pane(for: proj).isWorkbenchVisible = true
        XCTAssertTrue(model.editorHasKeys)
        model.sheet = .settings
        XCTAssertFalse(model.editorHasKeys)
        model.sheet = nil

        // ⌃⌘`: a terminal of the same tab.
        model.returnToTerminal()
        XCTAssertNotNil(model.activeMixed?.focusedMember, "a terminal has the focus")
        XCTAssertFalse(model.editorHasKeys)
        model.editors.stop()
    }

    func testAnEditorTabGoesBackToTheTabItWasOpenedFrom() throws {
        let model = WindowModel(app: .shared)
        model.startMixedTabs()
        var session = Session()
        session.apply(.split(PaneId(1), .horizontal))
        let mixed = model.composites.make(fromHost: "h1", tab: session.tabs[0])
        model.focus(WindowModel.mixedRef(mixed))
        model.showEditor(proj, placement: .tab)
        XCTAssertNotEqual(model.activeMixedTab, mixed)
        XCTAssertEqual(model.lastTerminalTab, WindowModel.mixedRef(mixed))
        model.returnToTerminal()
        XCTAssertEqual(model.activeMixedTab, mixed, "back to the terminal it came from")

        // Closing an editor tab shows that terminal again too.
        model.showEditor(proj, placement: .tab)
        model.closeEditor(proj.id)
        XCTAssertEqual(model.activeMixedTab, mixed)
    }

    func testOnlyTheWayOutLeavesVSCode() {
        let passing = WorkspaceAction.allShortcutActions.filter(\.passesEditor)
        XCTAssertEqual(Set(passing), Set((1...8).map(WorkspaceAction.selectTab) + [.lastTab, .closePane, .returnToTerminal]))
        XCTAssertFalse(WorkspaceAction.goToTab.passesEditor, "⌘P is VS Code's Quick Open")
        XCTAssertFalse(WorkspaceAction.commandPalette.passesEditor, "⌘K chords are VS Code's")
        XCTAssertFalse(WorkspaceAction.nextTab.passesEditor, "⇧⌘] is VS Code's next editor")
        XCTAssertFalse(WorkspaceAction.focus(.left).passesEditor, "⌥⌘← is VS Code's previous editor")
        XCTAssertEqual(WorkspaceAction.returnToTerminal.shortcut.symbols, ["⌃", "⌘", "`"])
    }
}
