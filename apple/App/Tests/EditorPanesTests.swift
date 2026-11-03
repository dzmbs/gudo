import HostKit
import PaneLayout
import WebKit
import XCTest
@testable import App

/// VS Code editors as panes: the window's editors, where Open in VS Code puts one, the keys an
/// editor leaves to the app, and suspending editors off screen.
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

    /// Each host editor keeps its own cookies (its server's `vscode-tkn`): two folders' tokens
    /// in one store would overwrite each other and the servers answer "Forbidden". The tunnel's
    /// vscode.dev shares the app's store, so one sign-in serves every tunnel editor.
    func testEachHostEditorHasItsOwnDataStoreAndTheTunnelSharesOne() {
        let editors = EditorPanes(suspendAfter: .seconds(600)) { _ in FakeSource() }
        defer { editors.stop() }
        let local = URL(string: "http://localhost:51234/?tkn=a&folder=/home/me/proj")!
        let projStore = editors.pane(for: proj).makeBrowser(for: local).webView.configuration.websiteDataStore
        let siteStore = editors.pane(for: site).makeBrowser(for: URL(string: "http://127.0.0.1:51235/?tkn=b")!)
            .webView.configuration.websiteDataStore
        XCTAssertNotEqual(projStore.identifier, siteStore.identifier, "two folders, two cookie jars")
        XCTAssertNotNil(projStore.identifier)

        let again = EditorMember(hostId: "h1", folder: "/home/me/proj")
        let reopened = EditorPanes(suspendAfter: .seconds(600)) { _ in FakeSource() }
        defer { reopened.stop() }
        XCTAssertEqual(reopened.pane(for: again).makeBrowser(for: local).webView.configuration.websiteDataStore.identifier,
                       projStore.identifier, "the same folder finds its state again")

        let tunnel = editors.pane(for: proj).makeBrowser(for: URL(string: "https://vscode.dev/tunnel/box/home/me/proj")!)
        XCTAssertNil(tunnel.webView.configuration.websiteDataStore.identifier, "vscode.dev uses the shared store")
    }

    func testTheDefaultIsTenMinutes() {
        XCTAssertEqual(EditorPanes.defaultSuspendAfter, .seconds(600))
    }

    // MARK: The window

    func testOpenInVSCodeMakesATabOrALeafBesideSeveralPerFolder() throws {
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

        // Another editor on the same folder: a tab of its own beside the first, with its own pane.
        let second = EditorMember(hostId: "h1", folder: proj.folder)
        model.showEditor(second, placement: .tab)
        XCTAssertEqual(model.composites.tabs.count, 3)
        XCTAssertEqual(model.activeMixed?.focusedEditor, second)
        XCTAssertFalse(model.editors.pane(for: second) === model.editors.pane(for: proj))
        model.closeEditor(second.id)
        model.focus(WindowModel.mixedRef(tab.id))

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
        model.sheet = .shortcuts
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

    func testFullScreenIsTheFocusedEditorsAndEndsWhenTheFocusMoves() throws {
        let model = WindowModel(app: .shared)
        model.startMixedTabs()
        var session = Session()
        session.apply(.split(PaneId(1), .horizontal))
        let id = model.composites.make(fromHost: "h1", tab: session.tabs[0])
        model.activeMixedTab = id
        model.toggleEditorFullScreen()
        XCTAssertFalse(model.isEditorFullScreen, "a terminal has the focus: nothing to show full screen")

        model.showEditor(proj, placement: .split)
        model.toggleEditorFullScreen()
        XCTAssertTrue(model.isEditorFullScreen)
        XCTAssertEqual(model.fullScreenEditor, proj.id)
        model.toggleEditorFullScreen()
        XCTAssertFalse(model.isEditorFullScreen, "⌃⌘F again: back")

        model.toggleEditorFullScreen()
        model.returnToTerminal()
        XCTAssertFalse(model.isEditorFullScreen, "the terminal beside it took the focus")
        model.editors.stop()
    }

    /// Leaving full screen's editor (another tab, pane or screen, closing it) ends full screen:
    /// coming back shows the window, never a bare workbench.
    func testFullScreenEndsForGoodWhenItsEditorLeavesTheFront() async throws {
        let model = WindowModel(app: .shared)
        model.startMixedTabs()
        model.followFullScreen()
        var session = Session()
        session.apply(.split(PaneId(1), .horizontal))
        let terminal = model.composites.make(fromHost: "h1", tab: session.tabs[0])
        model.focus(WindowModel.mixedRef(terminal))
        model.showEditor(proj, placement: .tab)
        let editorTab = try XCTUnwrap(model.activeMixedTab)

        func settled() async { for _ in 0..<5 { await Task.yield() } }

        // Another tab, then back.
        model.toggleEditorFullScreen()
        XCTAssertTrue(model.isEditorFullScreen)
        model.focus(WindowModel.mixedRef(terminal))
        await settled()
        XCTAssertNil(model.fullScreenEditor)
        model.focus(WindowModel.mixedRef(editorTab))
        XCTAssertFalse(model.isEditorFullScreen, "back on the editor's tab: the window, not full screen")

        // Another screen (Agents), then back.
        model.toggleEditorFullScreen()
        model.destination = .inbox
        await settled()
        model.destination = .terminal
        XCTAssertFalse(model.isEditorFullScreen)

        // The editor closed.
        model.toggleEditorFullScreen()
        XCTAssertTrue(model.isEditorFullScreen)
        model.closeEditor(proj.id)
        await settled()
        XCTAssertNil(model.fullScreenEditor)
        XCTAssertFalse(model.isEditorFullScreen)
        model.editors.stop()
    }

    /// The collapsed exit control snaps to the corner or edge nearest where it was let go, clear
    /// of VS Code's title and status bars.
    func testTheExitControlSnapsToTheNearestSpot() {
        typealias Spot = ExitFullScreenControl.Spot
        let size = CGSize(width: 1000, height: 800)
        XCTAssertEqual(Spot.nearest(to: CGPoint(x: 10, y: 10), in: size), .topLeading)
        XCTAssertEqual(Spot.nearest(to: CGPoint(x: 520, y: 30), in: size), .top)
        XCTAssertEqual(Spot.nearest(to: CGPoint(x: 990, y: 420), in: size), .trailing)
        XCTAssertEqual(Spot.nearest(to: CGPoint(x: 980, y: 790), in: size), .bottomTrailing)
        let top = Spot.topTrailing.center(in: size)
        XCTAssertGreaterThan(top.y - ExitFullScreenControl.size / 2, 35, "below the title bar")
        let bottom = Spot.bottom.center(in: size)
        XCTAssertLessThan(bottom.y + ExitFullScreenControl.size / 2, size.height - 22, "above the status bar")
    }

    #if canImport(UIKit)
    /// The editor's one web view stays with the newest view showing it: a view on its way out
    /// (full screen and back mid-transition) never takes it back and leaves the editor blank.
    func testTheWebViewStaysWithTheNewestViewShowingIt() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let webView = WKWebView()
        let split = EditorWebHost.Container()
        window.addSubview(split)
        split.claim(webView)
        XCTAssertTrue(webView.superview === split)

        let fullScreen = EditorWebHost.Container()
        fullScreen.claim(webView)
        split.show(webView)
        XCTAssertTrue(webView.superview === fullScreen, "the outgoing view's update leaves it alone")
        window.addSubview(fullScreen)
        split.removeFromSuperview()
        XCTAssertTrue(webView.superview === fullScreen)
        XCTAssertNotNil(webView.window, "on screen")

        // Back: the new split view shows it; full screen going away does not take it along.
        let back = EditorWebHost.Container()
        back.claim(webView)
        window.addSubview(back)
        fullScreen.show(webView)
        fullScreen.removeFromSuperview()
        XCTAssertTrue(webView.superview === back)
        XCTAssertNotNil(webView.window)

        // A view made but never shown hands it back to the one still on screen.
        let stillborn = EditorWebHost.Container()
        stillborn.claim(webView)
        window.addSubview(stillborn)
        stillborn.removeFromSuperview()
        XCTAssertTrue(webView.superview === back, "the one still on screen shows it again")
    }
    #endif

    func testOnlyTheWayOutLeavesVSCode() {
        let passing = WorkspaceAction.allShortcutActions.filter(\.passesEditor)
        XCTAssertEqual(Set(passing), Set((1...8).map(WorkspaceAction.selectTab) + [.lastTab, .closePane, .returnToTerminal, .fullScreenEditor]))
        XCTAssertFalse(WorkspaceAction.goToTab.passesEditor, "⌘P is VS Code's Quick Open")
        XCTAssertFalse(WorkspaceAction.commandPalette.passesEditor, "⌘K chords are VS Code's")
        XCTAssertFalse(WorkspaceAction.nextTab.passesEditor, "⇧⌘] is VS Code's next editor")
        XCTAssertFalse(WorkspaceAction.focus(.left).passesEditor, "⌥⌘← is VS Code's previous editor")
        XCTAssertEqual(WorkspaceAction.returnToTerminal.shortcut.symbols, ["⌃", "⌘", "`"])
    }
}
