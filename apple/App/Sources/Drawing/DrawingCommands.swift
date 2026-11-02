import Foundation
import HostKit
import PaneLayout
import GudoCore

/// Drawing commands on the focused pane (menu, ⌃⌘D, command palette). ⌃⌘D rather than the
/// ⇧⌘D the contract names: ⇧⌘D is Ghostty's Split Down.
@MainActor
enum DrawingCommands {
    /// Opens the draw overlay at the cursor row (Done when it is open).
    static func toggleDrawing(in workspace: Workspace) {
        guard let pane = workspace.focusedPane, let drawing = PaneDrawing.of(pane) else {
            CanvasWebView.log.info("draw: no daemon pane focused (\(String(describing: workspace.focusedPane), privacy: .public))")
            return
        }
        CanvasWebView.log.info("draw: toggle on pane \(pane.rawValue)")
        drawing.toggleDrawing()
    }

    /// Whether the focused pane can be drawn on (a daemon pane).
    static func canDraw(in workspace: Workspace) -> Bool {
        workspace.focusedPane.flatMap(PaneDrawing.of) != nil
    }

    /// Splits the focused pane with a canvas pane (a new Excalidraw scene on the daemon).
    static func newCanvas(in workspace: Workspace) {
        guard let pane = workspace.focusedPane, let drawing = PaneDrawing.of(pane) else { return }
        _ = drawing.hub.client.op(op: .split(paneId: pane.rawValue, axis: .horizontal, launch: .canvas(artifactId: nil)))
    }
}
