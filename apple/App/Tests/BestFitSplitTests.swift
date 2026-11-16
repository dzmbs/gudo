#if os(macOS)
import AppKit
import PaneLayout
import SwiftUI
import XCTest
@testable import App

/// Split Pane Best Fit splits the focused pane when it has room, else the largest pane that
/// does, and says so when none has.
@MainActor
final class BestFitSplitTests: XCTestCase {
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private var model: WindowModel!
    private var window: NSWindow!
    private var openedTab: (workspace: Workspace, tab: TabId)?

    override func setUp() async throws {
        try XCTSkipIf(!LaunchOptions.mock, "needs the mock hosts (TEST_RUNNER_GUDO_MOCK=1)")
        model = WindowModel(app: .shared)
        model.start()
        let frame = NSRect(x: -30000, y: -30000, width: 1400, height: 170)
        window = OffscreenWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: WindowContent(request: nil, model: model).environment(AppModel.shared))
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        for _ in 0..<50 where model.workspace?.focusedPane == nil { await pump(0.1) }
        let workspace = try XCTUnwrap(model.workspace)
        let before = Set(workspace.session.tabs.map(\.id))
        workspace.apply(.newTab)
        openedTab = workspace.session.tabs.first { !before.contains($0.id) }.map { (workspace, $0.id) }
        for _ in 0..<20 where workspace.focusedPane == nil { await pump(0.1) }
        await pump(0.5)
    }

    override func tearDown() async throws {
        guard let model else { return }
        if let openedTab { openedTab.workspace.apply(.closeTab(openedTab.tab)) }
        await pump(0.5)
        window?.close()
        model.close()
    }

    private func pump(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    func testASmallFocusedPaneLeavesTheSplitToTheLargestPaneWithRoom() async throws {
        let workspace = try XCTUnwrap(model.workspace)
        let first = try XCTUnwrap(workspace.focusedPane)
        // Halve the newest pane until it has no room left.
        for _ in 0..<8 {
            guard let focused = workspace.focusedPane, workspace.hasRoomToSplit(focused, .horizontal) else { break }
            workspace.apply(.split(focused, .horizontal))
            await pump(0.6)
        }
        let small = try XCTUnwrap(workspace.focusedPane)
        XCTAssertFalse(workspace.hasRoomToSplit(small, .horizontal), "the focused pane is too narrow to split")
        XCTAssertFalse(workspace.hasRoomToSplit(small, .vertical), "and too short")

        let split = try XCTUnwrap(model.bestFitSplit(in: workspace), "a pane still has room")
        XCTAssertEqual(split.pane, first, "the largest pane, the first, takes the split")
        let panes = workspace.session.activeTab?.root.panes.count ?? 0
        model.splitBestFit()
        XCTAssertEqual(workspace.session.activeTab?.root.panes.count, panes + 1)
    }
}
#endif
