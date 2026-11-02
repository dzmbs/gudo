#if os(macOS)
import AppKit
import PaneLayout
import SwiftUI
import WebKit
import XCTest
@testable import App

/// Web leaves (a page, a popup, VS Code) landing in a split tree right after a split, close or
/// zoom, while it animates and before the new pane says where it is: each page keeps one view,
/// and the window lives on. A page's `WebView` made twice is a WebKit trap, so a regression
/// here crashes the test host.
@MainActor
final class SplitWebLeavesTests: XCTestCase {
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private var model: WindowModel!
    private var window: NSWindow!

    override func setUp() async throws {
        try XCTSkipIf(!LaunchOptions.mock, "needs the mock hosts (TEST_RUNNER_GUDO_MOCK=1)")
        model = WindowModel(app: .shared)
        model.start()
        window = show(WindowContent(request: nil, model: model).environment(AppModel.shared))
        for _ in 0..<50 where model.workspace?.focusedPane == nil { await pump(0.1) }
        let workspace = try XCTUnwrap(model.workspace)
        for tab in workspace.session.tabs { workspace.apply(.closeTab(tab.id)) }
        workspace.apply(.newTab)
        for _ in 0..<20 where workspace.focusedPane == nil { await pump(0.1) }
        // Settled: the tab's pane has said where it is.
        await pump(1.5)
    }

    override func tearDown() async throws {
        guard let model else { return }
        for tab in model.composites.tabs { model.closeMixedTab(tab.id) }
        await pump(0.5)
        window?.close()
        model.close()
    }

    /// Far off screen, never key.
    private func show(_ root: some View) -> NSWindow {
        let frame = NSRect(x: -30000, y: -30000, width: 1180, height: 760)
        let window = OffscreenWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: root)
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        return window
    }

    private func pump(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func perform(_ action: WorkspaceAction) throws {
        action.perform(on: try XCTUnwrap(model.workspace), window: model)
    }

    /// Open Browser Beside, then the page's own view once it has one.
    @discardableResult
    /// `url`: a page on this Mac (no host's `localhost`).
    private func openBeside(_ url: URL? = nil) async throws -> BrowserPane {
        let member = model.openBrowser(url ?? URL(string: "about:blank")!, hostId: url == nil ? model.workspace?.hostId : nil, placement: .split)
        for _ in 0..<50 where model.browsers.existing(member.id)?.shownBy == nil { await pump(0.05) }
        return try XCTUnwrap(model.browsers.existing(member.id), "the leaf made its page")
    }

    /// The page keeps the view it first had while the window settles (no second one made).
    private func assertKeepsItsView(_ pane: BrowserPane, file: StaticString = #filePath, line: UInt = #line) async {
        let view = pane.shownBy
        XCTAssertNotNil(view, "the page is shown", file: file, line: line)
        await pump(2)
        XCTAssertEqual(pane.shownBy, view, "the page kept its view", file: file, line: line)
    }

    func testBrowserBesideRightAfterSplit() async throws {
        try perform(.splitRight)
        await pump(0.03)
        let pane = try await openBeside()
        await assertKeepsItsView(pane)
        XCTAssertEqual(model.activeMixed?.browsers.count, 1)
    }

    func testBrowserBesideRightAfterClose() async throws {
        try perform(.splitRight)
        await pump(0.03)
        try perform(.closePane)
        await pump(0.03)
        let pane = try await openBeside()
        await assertKeepsItsView(pane)
    }

    func testBrowserBesideRightAfterZoom() async throws {
        try perform(.splitDown)
        await pump(0.03)
        try perform(.toggleZoom)
        await pump(0.03)
        let pane = try await openBeside()
        await assertKeepsItsView(pane)
    }

    /// `window.open` from a page beside a terminal that just split: the popup gets a leaf of its
    /// own, shown once.
    func testPopupRightAfterSplit() async throws {
        let server = try await FixtureServer(pages: ["/opener": "<p>opener</p>", "/popped": "<p>popped</p>"])
        defer { server.stop() }
        let opener = try await openBeside(server.url("/opener"))
        for _ in 0..<100 where opener.page.isLoading || opener.frames.tokens.isEmpty { await pump(0.05) }
        let tab = try XCTUnwrap(model.activeMixed)
        let terminal = try XCTUnwrap(tab.leaves.first { tab.members[$0] != nil })
        model.focusLeaf(terminal, inMixedTab: tab.id)
        try perform(.splitRight)
        await pump(0.03)
        opener.agentActing = true
        _ = try await opener.page.run("window.open('/popped', 'popup'); return 1", in: .page)
        for _ in 0..<50 where (model.activeMixed?.browsers.count ?? 0) < 2 { await pump(0.05) }
        let popup = try XCTUnwrap(model.activeMixed?.browsers.values.first { $0.id != opener.id }.flatMap { model.browsers.existing($0.id) })
        XCTAssertNotNil(popup.popupPage, "WebKit's own web view, with the opener")
        await pump(2)
        XCTAssertNotNil(popup.popupPage?.webView.window, "the popup is on screen")
        XCTAssertNotNil(opener.shownBy, "and its opener")
    }

    /// VS Code beside a terminal that just split: its one web view on screen.
    func testEditorRightAfterSplit() async throws {
        try perform(.splitRight)
        await pump(0.03)
        let member = EditorMember(hostId: "studio", folder: "~/projects/gudo")
        let editor = model.showEditor(member, placement: .split)
        let browser = editor.makeBrowser(for: URL(string: "about:blank")!)
        await pump(2)
        XCTAssertNotNil(model.activeMixed?.leaf(forEditor: member.id), "the editor is a leaf")
        XCTAssertNotNil(browser.webView.window, "its web view is on screen")
    }

    /// The titlebar's folder follows the tab without remaking the window's views.
    func testRepresentedFolderFollowsTheTab() async throws {
        for _ in 0..<40 where window.representedURL == nil { await pump(0.05) }
        let directory = try XCTUnwrap(model.workspace?.session.activeTab.flatMap { model.workspace?.absoluteDirectory(of: $0) })
        XCTAssertEqual(window.representedURL, URL(fileURLWithPath: directory, isDirectory: true))
    }

    /// Two views of one page at once, or one swapped for another in one update (a parent's
    /// identity changing): the newer waits for the older to go, then shows the page.
    func testASecondViewOfAPageWaitsForTheFirst() async throws {
        let pane = BrowserPane(url: URL(string: "about:blank")!)
        final class Views: ObservableObject { @Published var ids = [0] }
        struct Root: View {
            let pane: BrowserPane
            @ObservedObject var views: Views
            var body: some View {
                HStack { ForEach(views.ids, id: \.self) { _ in BrowserView(pane: pane) } }
            }
        }
        let views = Views()
        let extra = show(Root(pane: pane, views: views).environment(model))
        defer { extra.close() }
        func shown(besides old: UUID?) async throws -> UUID {
            for _ in 0..<40 where pane.shownBy == nil || pane.shownBy == old { await pump(0.05) }
            return try XCTUnwrap(pane.shownBy)
        }
        let first = try await shown(besides: nil)
        views.ids = [0, 1]
        await pump(0.5)
        XCTAssertEqual(pane.shownBy, first, "the first view keeps the page")
        views.ids = [1]
        let second = try await shown(besides: first)
        views.ids = [2]
        let third = try await shown(besides: second)
        XCTAssertNotEqual(third, first)
    }
}
#endif
