import DesignSystem
import Foundation
import HostKit
import PaneLayout
import GudoCore

/// Sketch commands on the focused pane. ⌃⌘D rather than ⇧⌘D, which is Ghostty's Split Down.
@MainActor
enum DrawingCommands {
    /// Opens the sketch overlay at the cursor row, or finishes it when open.
    static func toggleDrawing(in workspace: Workspace) {
        guard let pane = workspace.focusedPane, let drawing = PaneDrawing.of(pane) else {
            CanvasWebView.log.info("draw: no daemon pane focused (\(String(describing: workspace.focusedPane), privacy: .public))")
            ActiveWindow.model?.toasts.show(Toast(
                "Sketching works on panes of a computer running the helper", systemImage: "pencil.tip", style: .neutral))
            return
        }
        CanvasWebView.log.info("draw: toggle on pane \(pane.rawValue)")
        drawing.toggleDrawing()
    }

    /// Only daemon panes can be drawn on.
    static func canDraw(in workspace: Workspace) -> Bool {
        workspace.focusedPane.flatMap(PaneDrawing.of) != nil
    }

    /// Splits the focused pane with an unsaved canvas pane (the demo's).
    static func newCanvas(in workspace: Workspace) {
        guard let pane = workspace.focusedPane, let drawing = PaneDrawing.of(pane) else { return }
        _ = drawing.hub.client.op(op: .split(paneId: pane.rawValue, axis: .horizontal, launch: .canvas(artifactId: nil)))
    }
}
