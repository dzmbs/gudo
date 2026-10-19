import Foundation
import TerminalCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A canvas pane (`PaneLaunch.canvas`, docs/DAEMON.md §7.2): the full Excalidraw editor in a
/// split leaf, on the terminal's background, synced live with every device through the daemon
/// (`excalidrawGet` / `excalidrawPut` / `ArtifactEvent.excalidraw`). It covers the pane's
/// (empty) terminal view; viewers get it read-only.
@MainActor
final class CanvasPaneView {
    let artifactId: UInt64
    let view = OverlayContainer()
    private unowned let drawing: PaneDrawing
    private let web = CanvasWebView()
    private var sync: SceneSync?

    init(drawing: PaneDrawing, artifactId: UInt64) {
        self.drawing = drawing
        self.artifactId = artifactId
        let bg = drawing.pane?.view.surface.appearance.background ?? RGB(r: 0x28, g: 0x2C, b: 0x34)
        #if os(iOS)
        view.backgroundColor = UIColor(red: CGFloat(bg.r) / 255, green: CGFloat(bg.g) / 255, blue: CGFloat(bg.b) / 255, alpha: 1)
        view.accessibilityIdentifier = "drawing.canvas"
        web.webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #else
        view.wantsLayer = true
        view.layer?.backgroundColor = CGColor(srgbRed: CGFloat(bg.r) / 255, green: CGFloat(bg.g) / 255, blue: CGFloat(bg.b) / 255, alpha: 1)
        view.setAccessibilityIdentifier("drawing.canvas")
        web.webView.autoresizingMask = [.width, .height]
        #endif
        web.webView.frame = view.bounds
        view.addSubview(web.webView)
        web.onMessage = { [weak self] body in
            switch body["type"] as? String {
            case "change": self?.sync?.changed(body)
            case "files": self?.sync?.filesAdded(body)
            default: break
            }
        }
    }

    func start() {
        let sync = SceneSync(artifactId: artifactId, sessionId: drawing.sessionId, hub: drawing.hub, web: web)
        sync.readOnly = drawing.isReadOnly
        self.sync = sync
        let theme = drawing.isDarkTheme ? "dark" : "light"
        Task { await sync.load(mode: "canvas", theme: theme, viewport: nil) }
    }

    /// Debug: calls a bridge function once the editor is up.
    func call(_ function: String, _ argument: Any) {
        web.call(function, argument)
    }

    func close() {
        sync?.close()
        web.tearDown()
        view.removeFromSuperview()
    }
}
