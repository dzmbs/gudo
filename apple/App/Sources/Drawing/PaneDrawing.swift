import DrawingKit
import Foundation
import HostKit
import PaneLayout
import Synchronization
import TerminalCore
import TerminalRenderer
import UnnamedCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// placements as image quads pinned to rows, opens the draw overlay (Pencil, two-finger long
/// press, ⌃⌘D), reopens a tapped placement, imports pasted or dropped images and `.excalidraw`
/// files, draws other people's live ink, and turns the pane into a canvas when the daemon says
/// it is one. Attached once per pane by `Workspace` (`PaneDrawing.attach`); local and plain-SSH
/// panes have none.
@MainActor
final class PaneDrawing: NSObject {
    let paneId: UInt64
    weak var pane: Pane?
    weak var workspace: Workspace?
    let backend: DaemonPaneBackend
    let hub: DrawingHub
    let tracker: RowTracker
    let peerInk: PeerInkView

    private struct Entry {
        var placement: Placement
        var pin: RowPin?
    }

    private var entries: [UInt64: Entry] = [:]
    /// The placement being edited in the overlay (not drawn underneath it).
    var hiddenPlacement: UInt64? {
        didSet { surface?.invalidateInlineImages() }
    }

    private(set) var overlay: DrawOverlay?
    private var keyboardBeforeOverlay = false
    private(set) var canvas: CanvasPaneView?
    private var artifactPins: [UInt64: RowPin] = [:]
    private var markers: [UInt64: PlatformView] = [:]

    private static let registry = NSMapTable<NSNumber, PaneDrawing>.strongToWeakObjects()

    /// The drawing controller of a pane, if it is on a daemon.
    static func of(_ pane: PaneId) -> PaneDrawing? { registry.object(forKey: NSNumber(value: pane.rawValue)) }

    /// Attaches drawing to a pane whose backend is a daemon pane; no-op otherwise.
    @discardableResult
    static func attach(to pane: Pane, workspace: Workspace) -> PaneDrawing? {
        guard let backend = pane.backend as? DaemonPaneBackend, let client = backend.daemonClient else { return nil }
        let drawing = PaneDrawing(pane: pane, backend: backend, hub: DrawingHub.shared(for: client), workspace: workspace)
        objc_setAssociatedObject(pane.view, &associationKey, drawing, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        registry.setObject(drawing, forKey: NSNumber(value: pane.id.rawValue))
        #if DEBUG
        DrawingDemo.run(on: drawing)
        #endif
        return drawing
    }

    private static nonisolated(unsafe) var associationKey: UInt8 = 0

    private init(pane: Pane, backend: DaemonPaneBackend, hub: DrawingHub, workspace: Workspace) {
        paneId = pane.id.rawValue
        self.pane = pane
        self.backend = backend
        self.hub = hub
        self.workspace = workspace
        tracker = RowTracker(terminal: pane.view.surface.terminal)
        peerInk = PeerInkView()
        super.init()

        let tracker = tracker
        let pending = Flag()
        backend.onOutputApplied { [weak self] seq, snapshot in
            tracker.observe(seq: seq, snapshot: snapshot)
            if snapshot || pending.value.load(ordering: .relaxed) {
                Task { @MainActor in
                    guard let self else { return }
                    if snapshot { self.hub.reloadPlacements(pane: self.paneId) } else { self.repinAll() }
                    pending.value.store(self.entries.values.contains { $0.pin == nil && $0.placement.anchor.state == .live }, ordering: .relaxed)
                }
            }
        }
        pendingAnchors = pending

        let surface = pane.view.surface
        surface.inlineImages = { [weak self] in self?.inlineImages() ?? [] }
        let previous = surface.onFrameRendered
        surface.onFrameRendered = { [weak self] in
            previous?()
            self?.frameRendered()
        }
        peerInk.frame = pane.view.bounds
        pane.view.addSubview(peerInk)
        installInput(on: pane.view)
        hub.register(self)
        canvasChanged()
    }

    private var pendingAnchors: Flag?

    var surface: TerminalSurface? { pane?.view.surface }

    /// Viewers draw nothing: overlays open read-only (the daemon refuses their writes anyway).
    var isReadOnly: Bool { workspace?.multiplayer?.isViewOnly ?? false }

    // MARK: Placements

    func placementsChanged() {
        let current = hub.placements[paneId] ?? [:]
        for id in entries.keys where current[id] == nil {
            entries[id] = nil
        }
        for (id, placement) in current {
            if let entry = entries[id], entry.placement == placement, entry.pin != nil { continue }
            entries[id] = Entry(placement: placement, pin: pin(placement.anchor))
            loadImage(placement.image.hash)
        }
        if entries.values.contains(where: { $0.pin == nil && $0.placement.anchor.state == .live }) {
            pendingAnchors?.value.store(true, ordering: .relaxed)
        }
        let pinned = entries.values.filter { $0.pin != nil }.count
        let anchors = entries.values.map { "\($0.placement.anchor.state == .live ? "live" : "detached")@\($0.placement.anchor.atSeq)/\($0.placement.anchor.fromBottom)" }
        CanvasWebView.log.debug("placements pane \(self.paneId): \(self.entries.count) (\(pinned) pinned) applied \(self.tracker.appliedSeq) \(anchors.joined(separator: " "), privacy: .public)")
        surface?.invalidateInlineImages()
    }

    private func repinAll() {
        for (id, entry) in entries where entry.pin == nil {
            entries[id]?.pin = pin(entry.placement.anchor)
        }
        artifactPins = artifactPins.filter { tracker.terminal.screenRow(of: $0.value) != nil }
        surface?.invalidateInlineImages()
    }

    func pin(_ anchor: RowAnchor) -> RowPin? {
        guard anchor.state == .live, anchor.paneId == paneId else { return nil }
        return tracker.pin(atSeq: anchor.atSeq, fromBottom: anchor.fromBottom)
    }

    private func loadImage(_ hash: String) {
        guard let surface, !surface.hasInlineImage(key: hash) else { return }
        Task { [weak self] in
            guard let pixels = await self?.hub.pixels(hash: hash) else { return }
            self?.surface?.setInlineImage(pixels, key: hash)
        }
    }

    /// Placements for the frame being built (pins resolved under one terminal lock).
    private func inlineImages() -> [InlineImagePlacement] {
        let live = entries.values.filter { $0.pin != nil && $0.placement.placementId != hiddenPlacement }
        guard !live.isEmpty else { return [] }
        let rows = tracker.terminal.viewportRows(of: live.map { $0.pin! })
        return zip(live, rows).compactMap { entry, row in
            guard let row else { return nil }
            let p = entry.placement
            return InlineImagePlacement(key: p.image.hash, col: Int(p.col), row: row, cols: Int(p.cols), rows: Int(p.rows))
        }
    }

    /// The placement drawn under a view point, if any.
    func placement(at point: CGPoint) -> Placement? {
        guard let surface else { return nil }
        for drawn in surface.inlineImages(at: point) {
            if let entry = entries.values.first(where: { $0.placement.image.hash == drawn.key && Int($0.placement.col) == drawn.col }) {
                return entry.placement
            }
        }
        return nil
    }

    /// The pin of a placement's row.
    func pin(ofPlacement id: UInt64) -> RowPin? { entries[id]?.pin }

    private func frameRendered() {
        overlay?.terminalMoved()
        peerInk.setNeedsRedraw()
        updateMarkers()
    }

    /// Accessibility elements over drawn placements ("Drawing"), for VoiceOver and UI tests.
    private func updateMarkers() {
        guard let surface, let view = pane?.view else { return }
        var seen: Set<UInt64> = []
        for (drawn, rect) in surface.inlineImageFrames {
            guard let entry = entries.values.first(where: { $0.placement.image.hash == drawn.key && Int($0.placement.col) == drawn.col }) else { continue }
            let id = entry.placement.placementId
            seen.insert(id)
            let marker = markers[id] ?? {
                let marker = PlacementMarker(frame: rect)
                marker.setIdentifier("placement-\(id)", label: "Drawing")
                view.addSubview(marker)
                markers[id] = marker
                return marker
            }()
            if marker.frame != rect { marker.frame = rect }
        }
        for (id, marker) in markers where !seen.contains(id) {
            marker.removeFromSuperview()
            markers[id] = nil
        }
    }

    // MARK: Draw mode

    /// Opens the draw overlay anchored at the viewport row under `point` (view points), or the
    /// cursor row.
    func beginDrawing(at point: CGPoint? = nil) {
        guard overlay == nil, canvas == nil, let pane, let surface = pane.view.surface as TerminalSurface? else { return }
        if isReadOnly { return }
        let row: Int
        if let point {
            row = surface.cell(at: point).y
        } else {
            // From the keyboard: the last line of output above the prompt (what you just ran is
            // what you annotate), else the cursor row. The live prompt line itself is redrawn by
            // the shell (clocks, git status), which would detach a drawing pinned to it.
            let terminal = pane.view.surface.terminal
            let cursor = min(max(terminal.cursorPosition.y, 0), Int(surface.grid?.rows ?? 1) - 1)
            let lines = terminal.visibleText().split(separator: "\n", omittingEmptySubsequences: false)
            row = stride(from: cursor - 1, through: max(0, cursor - 12), by: -1).first {
                $0 < lines.count && !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty
            } ?? cursor
        }
        guard let origin = tracker.terminal.pinRow(viewportRow: row) else { return }
        let overlay = DrawOverlay(drawing: self, origin: origin, reopened: nil)
        present(overlay)
    }

    /// Reopens a placement's scene in place.
    func reopen(_ placement: Placement) {
        guard overlay == nil, canvas == nil, let pin = entries[placement.placementId]?.pin else { return }
        let overlay = DrawOverlay(drawing: self, origin: pin, reopened: placement)
        present(overlay)
    }

    private func present(_ overlay: DrawOverlay) {
        guard let view = pane?.view else { return }
        self.overlay = overlay
        #if os(iOS)
        keyboardBeforeOverlay = view.isFirstResponder
        #else
        keyboardBeforeOverlay = view.window?.firstResponder === view
        #endif
        overlay.view.frame = view.bounds
        view.addSubview(overlay.view)
        overlay.start()
    }

    func overlayClosed() {
        overlay?.view.removeFromSuperview()
        overlay = nil
        hiddenPlacement = nil
        // Give the keyboard back only if the terminal had it (never pop up the software one).
        guard keyboardBeforeOverlay else { return }
        #if os(iOS)
        _ = pane?.view.becomeFirstResponder()
        #else
        pane?.view.window?.makeFirstResponder(pane?.view)
        #endif
    }

    /// Toggles draw mode (⌃⌘D, the palette): Done when open.
    func toggleDrawing() {
        if let overlay {
            overlay.commit()
        } else {
            beginDrawing()
        }
    }

    // MARK: Agents

    /// Where "Send to agent" goes: this pane if it runs an agent, else the first agent pane in
    /// its tab; with the agent's name.
    func agentTarget() -> (pane: UInt64, name: String)? {
        guard let workspace, let daemon = workspace.host as? DaemonConnection else { return nil }
        func name(_ id: PaneId) -> String? {
            guard let kind = daemon.meta[id]?.agent?.kind else { return nil }
            return kind.lowercased().contains("codex") ? "Codex" : kind.lowercased().contains("claude") ? "Claude" : kind.capitalized
        }
        let me = PaneId(paneId)
        if let n = name(me) { return (paneId, n) }
        let tab = workspace.session.tabs.first { $0.root.panes.contains(me) }
        for id in tab?.root.panes ?? [] where id != me {
            if let n = name(id) { return (id.rawValue, n) }
        }
        return nil
    }

    // MARK: Canvas panes

    func canvasChanged() {
        let artifact = hub.canvases[paneId]
        if let artifact, canvas?.artifactId != artifact, let view = pane?.view {
            canvas?.close()
            let canvas = CanvasPaneView(drawing: self, artifactId: artifact)
            canvas.view.frame = view.bounds
            view.addSubview(canvas.view)
            self.canvas = canvas
            canvas.start()
        } else if artifact == nil, let canvas {
            canvas.close()
            self.canvas = nil
        }
    }

    var sessionId: UInt64 {
        (workspace?.host as? DaemonConnection)?.layout.sessionId ?? 0
    }

    /// The terminal's background, for the canvas and the overlay's theme.
    var isDarkTheme: Bool {
        let bg = pane?.view.surface.appearance.background ?? RGB(r: 0x28, g: 0x2C, b: 0x34)
        return 0.2126 * Double(bg.r) + 0.7152 * Double(bg.g) + 0.0722 * Double(bg.b) < 128
    }

    // MARK: Peer ink

    func peerInkArrived(_ ink: InkLive, info: ArtifactInfo?) {
        guard overlay?.artifactId != ink.artifactId else {
            overlay?.peerInk(ink)
            return
        }
        let pin: RowPin?
        if let cached = artifactPins[ink.artifactId] {
            pin = cached
        } else if let anchor = info?.anchor, let made = self.pin(anchor) {
            artifactPins[ink.artifactId] = made
            pin = made
        } else {
            pin = nil
        }
        guard let pin, let surface, let cell = surface.cellSize,
              let row = tracker.terminal.viewportRows(of: [pin]).first ?? nil
        else { return }
        _ = row
        let origin = surface.rect(for: GridPoint(x: 0, y: 0)).origin
        peerInk.add(ink, geometry: { [weak self] in
            guard let self, let row = self.tracker.terminal.viewportRows(of: [pin]).first ?? nil else { return nil }
            return OverlayGeometry(cell: cell, gridOrigin: origin, anchorRow: row)
        }, color: PeerInkView.color(for: ink.actor.principal))
    }

    // MARK: Import (paste / drop)

    /// Imports image or `.excalidraw` data as an artifact placed at the cursor row; with
    /// `send` onto an agent pane, sends an image to the agent instead.
    func importAttachment(name: String, data: Data, send: Bool = false) {
        guard !isReadOnly else { return }
        let paneId = paneId
        let client = hub.client
        Task {
            do {
                if send, sniffImage(data: data) != nil, let target = agentTarget(), target.pane == paneId {
                    _ = try await client.sendToAgent(paneId: paneId, artifactId: nil, version: nil, png: data)
                } else {
                    let placement = try await client.importToPane(paneId: paneId, name: name, data: data)
                    hub.seed(hash: placement.image.hash, png: data)
                    hub.noteLocal(placement, replacing: nil)
                }
            } catch {
                CanvasWebView.log.error("import \(name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    static func acceptsFile(named name: String) -> Bool {
        ["png", "jpg", "jpeg", "excalidraw"].contains((name as NSString).pathExtension.lowercased())
    }
}

/// A flag shared with the connection thread.
nonisolated final class Flag: Sendable {
    let value = Atomic<Bool>(false)
}
