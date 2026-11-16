#if os(macOS)
import AppKit
import DesignSystem
import SwiftUI
import TerminalCore
import TerminalRenderer
import XCTest
@testable import App

/// Showing or hiding the sidebar tells each terminal its new size once, the size it settles at:
/// a program never redraws for a width it does not get (a shell would draw its right prompt
/// there, and a host's terminal would keep it, scaled down to fit the pane).
@MainActor
final class HiddenSidebarGridTests: XCTestCase {
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        override var canBecomeKey: Bool { true }
    }

    private func pump(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func sceneWindow(model: WindowModel, width: CGFloat) -> NSWindow {
        let frame = NSRect(x: -30000, y: -30000, width: width, height: 760)
        let window = OffscreenWindow(
            contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        let controller = NSHostingController(rootView: ThemedRoot { WindowContent(request: nil, model: model).environment(AppModel.shared) })
        controller.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = controller
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        return window
    }

    /// The grid a pane's view holds: whole cells inside the padding on every side.
    private func fittingGrid(of pane: Pane) throws -> (cols: Int, rows: Int) {
        let surface = pane.view.surface
        let grid = try XCTUnwrap(surface.grid)
        let scale = pane.view.window?.backingScaleFactor ?? 2
        let padding = Int((DS.Space.xs * scale).rounded())
        let width = Int((pane.view.bounds.width * scale).rounded()), height = Int((pane.view.bounds.height * scale).rounded())
        return ((width - 2 * padding) / Int(grid.cellWidth), (height - 2 * padding) / Int(grid.cellHeight))
    }

    func testTheSidebarComingOrGoingResizesEachTerminalOnceToTheSizeItSettlesAt() async throws {
        try XCTSkipUnless(LaunchOptions.mock, "renders the mock workspace")
        let model = WindowModel(app: .shared)
        model.start()
        defer { model.close() }
        let window = sceneWindow(model: model, width: 1260)
        defer { window.close() }
        for _ in 0..<50 where model.workspace?.focusedPane == nil { await pump(0.1) }
        let workspace = try XCTUnwrap(model.workspace)
        let pane = try XCTUnwrap(workspace.focusedPane.flatMap { workspace.panes[$0] })
        model.isSidebarShown = true
        await pump(1.5)

        for shown in [false, true, false] {
            var grids: [TerminalSurface.Grid] = []
            pane.onGridChange = { grids.append($0) }
            model.isSidebarShown = shown
            await pump(1.5)
            pane.onGridChange = nil
            let settled = try fittingGrid(of: pane)
            let grid = try XCTUnwrap(pane.view.surface.grid)
            XCTAssertEqual(Int(grid.cols), settled.cols, "sidebar shown: \(shown)")
            XCTAssertEqual(Int(grid.rows), settled.rows, "sidebar shown: \(shown)")
            XCTAssertEqual(grids, [grid], "one resize, to where it settles (sidebar shown: \(shown))")
            let origin = pane.view.surface.rect(for: GridPoint(x: 0, y: 0)).origin
            XCTAssertGreaterThanOrEqual(origin.x, DS.Space.xs, "sidebar shown: \(shown)")
        }
    }
}
#endif
