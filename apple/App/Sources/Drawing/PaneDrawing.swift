import DesignSystem
import DrawingKit
import Foundation
import HostKit
import PaneLayout
import SwiftUI
import Synchronization
import TerminalCore
import TerminalRenderer
import GudoCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Drawing on one daemon pane: inline placements pinned to rows, the draw overlay, imports,
/// other people's live ink, canvas panes, the loose tray and Write mode. One pane draws or
/// writes at a time. Local and plain-SSH panes have none.
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
    /// The placement being edited in the overlay, so not drawn underneath it.
    var hiddenPlacement: UInt64? {
        didSet { surface?.invalidateInlineImages() }
    }

    private(set) var overlay: DrawOverlay?
    private var keyboardBeforeOverlay = false
    private(set) var canvas: CanvasPaneView?
    private var artifactPins: [UInt64: RowPin] = [:]
    private var markers: [UInt64: PlacementMarker] = [:]
    /// A placement just made, outlined once its marker exists.
    private var flashPlacement: UInt64?
    #if os(iOS)
    private(set) var writer: WriteOverlay?
    private var notice: UIHostingController<ThemedRoot<PlacedNotice>>?
    private var tray: UIHostingController<ThemedRoot<LooseTray>>?
    #else
    private var notice: NSHostingView<ThemedRoot<PlacedNotice>>?
    private var tray: NSHostingView<ThemedRoot<LooseTray>>?
    #endif
    private var noticeDismiss: Task<Void, Never>?
    private let looseModel = LooseTrayModel()
    private var looseTimer: Timer?

    private static let registry = NSMapTable<NSNumber, PaneDrawing>.strongToWeakObjects()

    /// The pane in draw or write mode, across every window.
    private static weak var active: PaneDrawing?

    static func of(_ pane: PaneId) -> PaneDrawing? { registry.object(forKey: NSNumber(value: pane.rawValue)) }

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
        looseModel.onPlace = { [weak self] in self?.placeLooseAtCursor($0) }
        looseModel.onSend = { [weak self] in self?.sendLoose($0) }
        looseModel.onRemove = { [weak self] in self?.removeLoose($0) }
        hub.register(self)
        canvasChanged()
    }

    private var pendingAnchors: Flag?

    var surface: TerminalSurface? { pane?.view.surface }

    /// Viewers' overlays open read-only; the daemon refuses their writes anyway.
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
        refreshLoose()
    }

    private func repinAll() {
        for (id, entry) in entries where entry.pin == nil {
            entries[id]?.pin = pin(entry.placement.anchor)
        }
        artifactPins = artifactPins.filter { tracker.terminal.screenRow(of: $0.value) != nil }
        surface?.invalidateInlineImages()
        refreshLoose()
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

    /// Pins are resolved under one terminal lock.
    private func inlineImages() -> [InlineImagePlacement] {
        let live = entries.values.filter { $0.pin != nil && $0.placement.placementId != hiddenPlacement }
        guard !live.isEmpty else { return [] }
        let rows = tracker.terminal.viewportRows(of: live.map { $0.pin! })
        return zip(live, rows).compactMap { entry, row in
            guard let row else { return nil }
            let placement = entry.placement
            return InlineImagePlacement(
                key: placement.image.hash, col: Int(placement.col), row: row, cols: Int(placement.cols), rows: Int(placement.rows))
        }
    }

    func placement(at point: CGPoint) -> Placement? {
        guard let surface else { return nil }
        for drawn in surface.inlineImages(at: point) {
            if let entry = entries.values.first(where: { $0.placement.image.hash == drawn.key && Int($0.placement.col) == drawn.col }) {
                return entry.placement
            }
        }
        return nil
    }

    func pin(ofPlacement id: UInt64) -> RowPin? { entries[id]?.pin }

    func placement(id: UInt64) -> Placement? { entries[id]?.placement }

    /// Nothing modal on the pane, so drawings in the output answer taps.
    var isIdle: Bool {
        #if os(iOS)
        overlay == nil && writer == nil && canvas == nil
        #else
        overlay == nil && canvas == nil
        #endif
    }

    private func frameRendered() {
        overlay?.terminalMoved()
        peerInk.setNeedsRedraw()
        updateMarkers()
    }

    /// Accessibility elements over drawn placements, for VoiceOver and UI tests; a placement just
    /// made is outlined for a moment, so the user sees where it went.
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
                marker.offerMenu(drawing: self, placementId: id)
                view.addSubview(marker)
                markers[id] = marker
                return marker
            }()
            if marker.frame != rect { marker.frame = rect }
            if flashPlacement == id {
                flashPlacement = nil
                marker.flash()
            }
        }
        for (id, marker) in markers where !seen.contains(id) {
            marker.removeFromSuperview()
            markers[id] = nil
        }
    }

    // MARK: Loose tray

    /// Placements that can no longer be drawn at their row are listed in the tray, never dropped
    /// silently.
    private func refreshLoose() {
        let applied = tracker.appliedSeq
        let pins = entries.values.compactMap(\.pin)
        let onScreen = Dictionary(zip(pins.map(ObjectIdentifier.init), tracker.terminal.screenRows(of: pins).map { $0 != nil }), uniquingKeysWith: { first, _ in first })
        let loose = entries.values
            .filter { entry in
                let anchor = entry.placement.anchor
                return PlacementPlace.classify(
                    live: anchor.state == .live, pinned: entry.pin != nil,
                    rowOnScreen: entry.pin.map { onScreen[ObjectIdentifier($0)] ?? false } ?? false,
                    atSeq: anchor.atSeq, applied: applied) == .loose
            }
            .map(\.placement)
            .sorted { $0.atMs < $1.atMs }
        let items = loose.enumerated().map { index, placement in
            LooseTrayModel.Item(id: placement.placementId, title: "Drawing \(index + 1) · \(Self.age(ms: placement.atMs))")
        }
        if items != looseModel.items {
            if items.count > looseModel.items.count {
                CanvasWebView.log.info("loose: \(items.count - self.looseModel.items.count) drawing(s) lost their row on pane \(self.paneId)")
            }
            looseModel.items = items
        }
        looseModel.agentName = agentTarget()?.name
        updateTray()
        if entries.isEmpty {
            looseTimer?.invalidate()
            looseTimer = nil
        } else if looseTimer == nil {
            // Rows leave the scrollback ring with output, which fires no event.
            looseTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshLoose() }
            }
        }
    }

    private static func age(ms: UInt64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        return date.formatted(.relative(presentation: .named))
    }

    private func updateTray() {
        guard let view = pane?.view else { return }
        if looseModel.items.isEmpty {
            #if os(iOS)
            tray?.view.removeFromSuperview()
            #else
            tray?.removeFromSuperview()
            #endif
            tray = nil
            return
        }
        #if os(iOS)
        let host = tray ?? {
            let host = UIHostingController(rootView: ThemedRoot { LooseTray(model: looseModel) })
            host.view.backgroundColor = .clear
            host.sizingOptions = [.intrinsicContentSize]
            host.overrideUserInterfaceStyle = isDarkTheme ? .dark : .light
            host.view.autoresizingMask = [.flexibleLeftMargin, .flexibleBottomMargin]
            view.addSubview(host.view)
            tray = host
            return host
        }()
        let size = host.view.intrinsicContentSize
        host.view.frame = CGRect(x: view.bounds.width - size.width - 8, y: 8, width: size.width, height: size.height)
        #else
        let host = tray ?? {
            let host = NSHostingView(rootView: ThemedRoot { LooseTray(model: looseModel) })
            host.appearance = NSAppearance(named: isDarkTheme ? .darkAqua : .aqua)
            host.autoresizingMask = [.minXMargin, .maxYMargin]
            view.addSubview(host)
            tray = host
            return host
        }()
        let size = host.fittingSize
        host.frame = CGRect(x: view.bounds.width - size.width - 8, y: 8, width: size.width, height: size.height)
        #endif
    }

    private func placeLooseAtCursor(_ id: UInt64) {
        guard let placement = entries[id]?.placement, let surface, !isReadOnly else { return }
        let cursor = min(max(surface.terminal.cursorPosition.y, 0), Int(surface.grid?.rows ?? 1) - 1)
        guard let pin = tracker.terminal.pinRow(viewportRow: max(0, cursor - Int(placement.rows))) else { return }
        let client = hub.client
        let paneId = paneId
        Task {
            do {
                let blob = try await client.blobDownload(hash: placement.image.hash, progress: nil)
                let placed = try await anchored(pin) { anchor in
                    try await client.placePng(
                        request: PlaceRequest(
                            paneId: paneId, artifactId: placement.artifactId, version: nil, anchor: anchor,
                            col: placement.col, cols: placement.cols, rows: placement.rows, replace: placement.placementId),
                        png: blob.data)
                }
                hub.seed(hash: placed.image.hash, png: blob.data)
                hub.noteLocal(placed, replacing: placement.placementId)
                flashPlacement = placed.placementId
                CanvasWebView.log.info("loose: placed \(placement.placementId) again as \(placed.placementId) at the cursor")
            } catch {
                CanvasWebView.log.error("loose: place again: \(DrawOverlay.describe(error), privacy: .public)")
            }
        }
    }

    private func sendLoose(_ id: UInt64) {
        guard let placement = entries[id]?.placement, let target = agentTarget() else { return }
        let client = hub.client
        Task {
            do {
                _ = try await client.sendToAgent(paneId: target.pane, artifactId: placement.artifactId, version: nil, png: nil)
                showToast("Sent to \(target.name)")
            } catch {
                showToast("\(target.name) did not get it: \(DrawOverlay.describe(error))", failure: true)
            }
        }
    }

    private func removeLoose(_ id: UInt64) {
        let client = hub.client
        Task {
            try? await client.unplace(placementId: id)
            hub.noteRemoved(id, pane: paneId)
        }
    }

    func showToast(_ message: String, failure: Bool = false) {
        ActiveWindow.model?.toasts.show(Toast(
            message, systemImage: failure ? "exclamationmark.triangle.fill" : "arrow.up.circle.fill", style: failure ? .failure : .success))
    }

    /// Outlines a placement this device just made, once it is drawn.
    func flash(_ placementId: UInt64) {
        flashPlacement = placementId
        surface?.invalidateInlineImages()
    }

    // MARK: Draw mode

    /// Opens the draw overlay at the viewport row under `point`, or near the cursor. `then` runs
    /// once it is up, which may wait for another pane to finish drawing.
    func beginDrawing(at point: CGPoint? = nil, tool: DrawTool? = nil, then: ((DrawOverlay) -> Void)? = nil) {
        guard overlay == nil, canvas == nil, pane != nil else { return }
        if isReadOnly { return }
        claim { [weak self] in
            guard let self, self.overlay == nil else { return }
            self.openOverlay(at: point, tool: tool ?? DrawOverlay.lastTool)
            if let overlay = self.overlay { then?(overlay) }
        }
    }

    private func openOverlay(at point: CGPoint?, tool: DrawTool) {
        guard let pane, let surface = pane.view.surface as TerminalSurface? else { return }
        let row: Int
        if let point {
            row = surface.cell(at: point).y
        } else {
            // The last line of output above the prompt, else the cursor row: the shell redraws
            // the live prompt line (clocks, git status), which would detach a drawing pinned to it.
            let terminal = pane.view.surface.terminal
            let cursor = min(max(terminal.cursorPosition.y, 0), Int(surface.grid?.rows ?? 1) - 1)
            let lines = terminal.visibleText().split(separator: "\n", omittingEmptySubsequences: false)
            row = stride(from: cursor - 1, through: max(0, cursor - 12), by: -1).first {
                $0 < lines.count && !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty
            } ?? cursor
        }
        guard let origin = tracker.terminal.pinRow(viewportRow: row) else { return }
        present(DrawOverlay(drawing: self, origin: origin, reopened: nil, tool: tool))
    }

    func reopen(_ placement: Placement) {
        guard overlay == nil, canvas == nil else { return }
        claim { [weak self] in
            guard let self, self.overlay == nil, let pin = self.entries[placement.placementId]?.pin else { return }
            self.present(DrawOverlay(drawing: self, origin: pin, reopened: placement, tool: DrawOverlay.lastTool))
        }
    }

    private func present(_ overlay: DrawOverlay) {
        guard let view = pane?.view else { return }
        dismissNotice()
        self.overlay = overlay
        Self.active = self
        #if os(iOS)
        keyboardBeforeOverlay = view.isFirstResponder
        #else
        keyboardBeforeOverlay = view.window?.firstResponder === view
        #endif
        overlay.view.frame = view.bounds
        view.addSubview(overlay.view)
        publishDrawingFocus()
        if let tray = trayView {
            #if os(iOS)
            view.bringSubviewToFront(tray)
            #else
            view.addSubview(tray, positioned: .above, relativeTo: nil)
            #endif
        }
        overlay.start()
    }

    private var trayView: PlatformView? {
        #if os(iOS)
        tray?.view
        #else
        tray
        #endif
    }

    func overlayClosed() {
        overlay?.view.removeFromSuperview()
        overlay = nil
        hiddenPlacement = nil
        publishDrawingFocus()
        if Self.active === self, !isWriting { Self.active = nil }
        // Give the keyboard back only if the terminal had it, so the software one never pops up.
        guard keyboardBeforeOverlay else { return }
        #if os(iOS)
        _ = pane?.view.becomeFirstResponder()
        #else
        pane?.view.window?.makeFirstResponder(pane?.view)
        #endif
    }

    func toggleDrawing() {
        if let overlay {
            overlay.commit()
        } else {
            beginDrawing()
        }
    }

    // MARK: One pane at a time

    private var isWriting: Bool {
        #if os(iOS)
        writer != nil
        #else
        false
        #endif
    }

    var hasUnsavedWork: Bool {
        #if os(iOS)
        if let writer, !writer.isEmpty { return true }
        if overlay?.ink?.hasStrokes == true { return true }
        #endif
        return overlay?.isEdited ?? false
    }

    /// Runs `open` once no other pane draws or writes: an empty one closes quietly; one holding a
    /// drawing or handwriting is asked about first.
    func claim(_ open: @escaping () -> Void) {
        let other = Self.active.flatMap { $0 !== self && ($0.overlay != nil || $0.isWriting) ? $0 : nil }
        let decision = DrawExclusivity.decide(
            requester: UInt64(UInt(bitPattern: ObjectIdentifier(self).hashValue)),
            active: other.map { UInt64(UInt(bitPattern: ObjectIdentifier($0).hashValue)) },
            activeHasContent: other?.hasUnsavedWork ?? false)
        switch decision {
        case .open, .alreadyOpen:
            open()
        case .closeOtherAndOpen:
            CanvasWebView.log.info("draw: pane \(other?.paneId ?? 0) had nothing drawn; it closes for pane \(self.paneId)")
            other?.discard()
            open()
        case .ask:
            guard let other else { return open() }
            CanvasWebView.log.info("draw: pane \(other.paneId) holds a drawing; asking before pane \(self.paneId) draws")
            askToFinish(other, then: open)
        }
    }

    /// Closes draw or write mode here without keeping anything.
    func discard() {
        #if os(iOS)
        writer?.cancel()
        #endif
        overlay?.cancel()
    }

    private func askToFinish(_ other: PaneDrawing, then open: @escaping () -> Void) {
        let writing = other.isWriting
        let title = writing ? "Discard the handwriting in the other pane?" : "Finish the drawing in the other pane?"
        let message = "One pane draws at a time."
        var actions: [(String, Bool, () -> Void)] = []
        if !writing, let overlay = other.overlay {
            actions.append(("Place It and Draw Here", false, {
                overlay.onClose { _ in open() }
                overlay.commit()
            }))
        }
        actions.append(("Discard It and Draw Here", true, {
            other.discard()
            open()
        }))
        let keep = { [weak other, weak workspace = other.workspace] in
            guard let other, let workspace else { return }
            workspace.apply(.focus(PaneId(other.paneId)))
        }
        #if os(iOS)
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        for (label, destructive, action) in actions {
            alert.addAction(UIAlertAction(title: label, style: destructive ? .destructive : .default) { _ in action() })
        }
        alert.addAction(UIAlertAction(title: writing ? "Keep Writing There" : "Keep Drawing There", style: .cancel) { _ in keep() })
        guard var presenter = pane?.view.window?.rootViewController else { return }
        while let next = presenter.presentedViewController { presenter = next }
        presenter.present(alert, animated: true)
        #else
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        for (label, destructive, _) in actions {
            let button = alert.addButton(withTitle: label)
            button.hasDestructiveAction = destructive
        }
        alert.addButton(withTitle: "Keep Drawing There")
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            if actions.indices.contains(index) { actions[index].2() } else { keep() }
        }
        if let window = pane?.view.window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
        #endif
    }

    // MARK: After a drawing is finished

    func finished(_ placement: Placement, png: Data, action: DrawingAction, anchor: CGRect) {
        flashPlacement = placement.placementId
        surface?.invalidateInlineImages()
        deliver(placement, png: png, action: action, anchor: anchor)
    }

    /// Does `action` with a placed drawing and shows a notice while it runs and after.
    /// A nil `png` is fetched.
    func deliver(_ placement: Placement, png: Data?, action: DrawingAction, anchor: CGRect) {
        let model = PlacedNoticeModel()
        let primary = primaryDestination(in: agentDestinations())
        switch action {
        case .keep:
            model.phase = .done(.kept)
            model.agentName = primary?.agent.title
        case .send(let destination):
            model.phase = .working("Sending to \(destination.agent.title)…")
        case .start(let kind):
            model.phase = .working("Starting \(kind.title)…")
        case .copy, .copyText, .share, .export:
            model.phase = .working("Preparing the drawing…")
        }
        model.onDismiss = { [weak self] in self?.dismissNotice() }
        model.onSend = { [weak self] in
            guard let self, let primary else { return }
            self.deliver(placement, png: png, action: .send(primary), anchor: anchor)
        }
        let quiet = action.isTakeaway
        if !quiet { showNotice(model) }
        guard action != .keep else {
            CanvasWebView.log.info("done: kept (\(primary.map { "Send to \($0.agent.title) offered" } ?? "no agent", privacy: .public))")
            scheduleNoticeDismiss(after: primary != nil ? .seconds(6) : .seconds(4))
            return
        }
        Task {
            do {
                let image: Data
                if let png {
                    image = png
                } else {
                    image = try await hub.client.blobDownload(hash: placement.image.hash, progress: nil).data
                }
                let outcome = try await perform(action, artifactId: placement.artifactId, png: image, anchor: anchor)
                if outcome == .shared { return dismissNotice() }
                if notice?.rootView.content.model !== model { showNotice(model) }
                model.phase = .done(outcome)
                layoutNotice()
                scheduleNoticeDismiss(after: .seconds(3))
            } catch {
                let failure: String = switch action {
                case .send(let destination): "\(destination.agent.title) did not get it: \(DrawOverlay.describe(error))"
                case .start(let kind): "\(kind.title) did not start with it: \(DrawOverlay.describe(error))"
                default: "Could not export the drawing: \(DrawOverlay.describe(error))"
                }
                CanvasWebView.log.error("done: \(failure, privacy: .public)")
                if notice?.rootView.content.model !== model { showNotice(model) }
                model.phase = .failed(failure)
                layoutNotice()
                scheduleNoticeDismiss(after: .seconds(6))
            }
        }
    }

    private func showNotice(_ model: PlacedNoticeModel) {
        guard let view = pane?.view else { return }
        dismissNotice()
        #if os(iOS)
        let host = UIHostingController(rootView: ThemedRoot { PlacedNotice(model: model) })
        host.view.backgroundColor = .clear
        host.sizingOptions = [.intrinsicContentSize]
        host.overrideUserInterfaceStyle = isDarkTheme ? .dark : .light
        host.view.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin]
        host.view.alpha = 0
        view.addSubview(host.view)
        notice = host
        layoutNotice()
        UIView.animate(withDuration: 0.2) { host.view.alpha = 1 }
        #else
        let host = NSHostingView(rootView: ThemedRoot { PlacedNotice(model: model) })
        host.appearance = NSAppearance(named: isDarkTheme ? .darkAqua : .aqua)
        host.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        view.addSubview(host)
        notice = host
        layoutNotice()
        #endif
    }

    /// Centres the notice at the bottom of the pane; its size changes with the phase.
    private func layoutNotice() {
        guard let view = pane?.view, let notice else { return }
        #if os(iOS)
        notice.view.invalidateIntrinsicContentSize()
        let size = notice.view.intrinsicContentSize
        notice.view.frame = CGRect(
            x: (view.bounds.width - size.width) / 2, y: view.bounds.height - view.safeAreaInsets.bottom - 12 - size.height,
            width: size.width, height: size.height)
        #else
        let size = notice.fittingSize
        notice.frame = CGRect(x: (view.bounds.width - size.width) / 2, y: view.bounds.height - size.height - 12, width: size.width, height: size.height)
        #endif
        // SwiftUI settles the new size on its next update.
        DispatchQueue.main.async { [weak self] in
            guard let self, let notice = self.notice, let view = self.pane?.view else { return }
            #if os(iOS)
            let size = notice.view.intrinsicContentSize
            notice.view.frame = CGRect(
                x: (view.bounds.width - size.width) / 2, y: view.bounds.height - view.safeAreaInsets.bottom - 12 - size.height,
                width: size.width, height: size.height)
            #else
            let size = notice.fittingSize
            notice.frame = CGRect(x: (view.bounds.width - size.width) / 2, y: view.bounds.height - size.height - 12, width: size.width, height: size.height)
            #endif
        }
    }

    private func scheduleNoticeDismiss(after delay: Duration) {
        noticeDismiss?.cancel()
        noticeDismiss = Task { [weak self] in
            guard (try? await Task.sleep(for: delay)) != nil else { return }
            self?.dismissNotice()
        }
    }

    func dismissNotice() {
        noticeDismiss?.cancel()
        noticeDismiss = nil
        guard let notice else { return }
        self.notice = nil
        #if os(iOS)
        let view = notice.view
        UIView.animate(withDuration: 0.2, animations: { view?.alpha = 0 }, completion: { _ in view?.removeFromSuperview() })
        #else
        notice.removeFromSuperview()
        #endif
    }

    // MARK: A placement's menu

    func menu(for placement: Placement) -> DrawingMenu {
        let list = agentDestinations()
        let primary = primaryDestination(in: list)
        var menu = DrawingMenu.make(
            destinations: list, primary: primary, canStart: canStartAgent, includeKeep: false, placement: true,
            history: !isReadOnly && hub.client.offersDrawingHistory())
        if isReadOnly {
            // Viewers can take a copy; nothing that changes the host.
            menu.sections = menu.sections.compactMap { section in
                var kept = section
                kept.items = section.items.filter { $0.action?.isTakeaway == true }
                return kept.items.isEmpty ? nil : kept
            }
        }
        return menu
    }

    func perform(_ item: DrawingMenu.Item, on placement: Placement, anchor: CGRect) {
        if let action = item.action {
            deliver(placement, png: nil, action: action, anchor: anchor)
            return
        }
        switch item.placementAction {
        case .edit: reopen(placement)
        case .history: break  // a submenu, filled when it opens
        case .delete:
            let client = hub.client
            Task {
                do {
                    try await client.unplace(placementId: placement.placementId)
                    hub.noteRemoved(placement.placementId, pane: paneId)
                } catch {
                    showToast("Could not delete the drawing: \(DrawOverlay.describe(error))", failure: true)
                }
            }
        case nil: break
        }
    }

    /// In pane coordinates, for menus and share sheets.
    func frame(of placement: Placement) -> CGRect? {
        markers[placement.placementId]?.frame
    }

    // MARK: Anchors

    /// While the pane is being resized the daemon's grid can briefly differ from ours and refuse
    /// the row; the request is retried with the anchor taken again once sizes settle.
    func anchored<T>(_ pin: RowPin, _ request: (AnchorRequest) async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            guard let anchor = tracker.anchor(of: pin) else { throw ArtifactError.Invalid(message: "that row is gone") }
            do {
                return try await request(AnchorRequest(paneId: paneId, atSeq: anchor.atSeq, fromBottom: anchor.fromBottom))
            } catch ArtifactError.Invalid(let message) where attempt < 5 {
                attempt += 1
                CanvasWebView.log.info("anchor refused (\(message, privacy: .public)); retrying")
                try? await Task.sleep(for: .milliseconds(250 * attempt))
            }
        }
    }

    // MARK: Write (handwriting at the prompt)

    /// Apple Pencil handwriting becomes text at the prompt, sent only on Return (iPad only).
    func startWriting() {
        #if os(iOS)
        guard writer == nil, overlay == nil, canvas == nil, !isReadOnly else { return }
        claim { [weak self] in
            guard let self, self.writer == nil, self.overlay == nil, let pane = self.pane else { return }
            let writer = WriteOverlay(drawing: self, terminal: pane.view)
            self.writer = writer
            Self.active = self
            self.dismissNotice()
            writer.frame = pane.view.bounds
            pane.view.addSubview(writer)
            writer.start()
        }
        #endif
    }

    func writerClosed() {
        #if os(iOS)
        writer?.removeFromSuperview()
        writer = nil
        if Self.active === self, overlay == nil { Self.active = nil }
        #endif
    }

    // MARK: Agents

    /// This pane if it runs an agent, else the first agent pane in its tab.
    func agentTarget() -> (pane: UInt64, name: String)? {
        guard let workspace, let daemon = workspace.host as? DaemonConnection else { return nil }
        func agentName(_ id: PaneId) -> String? {
            guard let kind = daemon.meta[id]?.agent?.kind else { return nil }
            return kind.lowercased().contains("codex") ? "Codex" : kind.lowercased().contains("claude") ? "Claude" : kind.capitalized
        }
        let thisPane = PaneId(paneId)
        if let agent = agentName(thisPane) { return (paneId, agent) }
        let tab = workspace.session.tabs.first { $0.root.panes.contains(thisPane) }
        for id in tab?.root.panes ?? [] where id != thisPane {
            if let agent = agentName(id) { return (id.rawValue, agent) }
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
        publishDrawingFocus()
    }

    // MARK: Handoff

    /// Tells the window which drawing this pane has open, for its Handoff activity.
    func publishDrawingFocus() {
        let open: HandoffPayload.Drawing? = if let canvas {
            HandoffPayload.Drawing(artifact: canvas.artifactId, canvas: true)
        } else if let overlay, let artifact = overlay.artifactId {
            HandoffPayload.Drawing(artifact: artifact, placement: overlay.reopenedPlacementId, canvas: false)
        } else {
            nil
        }
        let pane = PaneId(paneId)
        guard let workspace, workspace.drawingFocus[pane] != open else { return }
        workspace.drawingFocus[pane] = open
    }

    /// Opens a drawing continued from another device. False while the pane is not ready for it
    /// yet, so the caller tries again; `settled` once placements had time to arrive, so an
    /// unplaced drawing opens.
    func continueDrawing(_ ref: HandoffPayload.Drawing, settled: Bool) -> Bool {
        if ref.canvas { return canvas?.artifactId == ref.artifact }
        if overlay?.artifactId == ref.artifact { return true }
        guard overlay == nil, canvas == nil, pane != nil, !isReadOnly, surface?.grid != nil else { return false }
        let placed = entries.values.filter { $0.pin != nil && $0.placement.artifactId == ref.artifact }
        if let entry = placed.first(where: { $0.placement.placementId == ref.placement }) ?? placed.first {
            reopen(entry.placement)
            return true
        }
        guard settled else { return false }
        claim { [weak self] in
            guard let self, self.overlay == nil, let origin = self.tracker.terminal.pinRow(viewportRow: self.cursorRow) else { return }
            self.present(DrawOverlay(drawing: self, origin: origin, reopened: nil, tool: DrawOverlay.lastTool, existing: ref.artifact))
        }
        return true
    }

    private var cursorRow: Int {
        let rows = Int(surface?.grid?.rows ?? 1)
        return min(max(surface?.terminal.cursorPosition.y ?? 0, 0), rows - 1)
    }

    var sessionId: UInt64 {
        (workspace?.host as? DaemonConnection)?.layout.sessionId ?? 0
    }

    /// From the terminal's background, for the canvas and the overlay's theme.
    var isDarkTheme: Bool {
        let background = pane?.view.surface.appearance.background ?? RGB(r: 0x28, g: 0x2C, b: 0x34)
        return 0.2126 * Double(background.r) + 0.7152 * Double(background.g) + 0.0722 * Double(background.b) < 128
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

    /// Places image or `.excalidraw` data at the cursor row; with `send` on an agent pane, sends
    /// an image to the agent instead.
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
                CanvasWebView.log.error("import \(name, privacy: .private): \(String(describing: error), privacy: .public)")
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
