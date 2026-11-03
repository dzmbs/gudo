import DesignSystem
import DrawingKit
import PaneLayout
import SwiftUI
import TerminalCore
import TerminalRenderer
import GudoCore
#if os(iOS)
import PencilKit
import UIKit
#else
import AppKit
#endif

/// The draw overlay on a terminal pane: a transparent layer anchored to a row that scrolls with
/// the output, holding one Excalidraw scene synced live with the daemon.
///
/// On touch devices one finger and the Pencil draw with the current tool, the Pencil always
/// draws, and two fingers scroll the terminal. Finishing renders a PNG on device and places it in
/// the pane's output; Cancel discards a new drawing and reverts a reopened one.
@MainActor
final class DrawOverlay: NSObject {
    let view = OverlayContainer()
    private(set) var artifactId: UInt64? {
        didSet { if artifactId != oldValue { drawing.publishDrawingFocus() } }
    }
    private unowned let drawing: PaneDrawing
    private var origin: RowPin
    private let reopened: Placement?
    /// A drawing that exists but is not placed yet, e.g. continued from another device.
    private let existing: UInt64?
    private let web = CanvasWebView()
    private var sync: SceneSync?
    private let model = OverlayModel()
    private var geometry: OverlayGeometry?
    private var created = false
    private var closed = false
    private var scrollRemainder: CGFloat = 0
    private let anchorMark = AnchorMark()
    private let firstRow = PlacementMarker(frame: .zero)
    /// Checked before another pane takes over draw mode.
    private(set) var isEdited = false
    private var closeHandlers: [(Placement?) -> Void] = []
    private var placed: Placement?
    private var pencilSwitch = PencilToolSwitch()
    /// Agents start and stop while the overlay is open.
    private var destinationsTimer: Timer?
    #if os(iOS)
    private(set) var ink: InkCanvasController?
    private var toolbar: UIHostingController<ThemedRoot<OverlayToolbar>>?
    #else
    private var toolbar: NSHostingView<ThemedRoot<OverlayToolbar>>?
    #endif

    /// A keyboard-opened overlay starts with the tool the last one closed with.
    static var lastTool: DrawTool = .pen

    init(drawing: PaneDrawing, origin: RowPin, reopened: Placement?, tool: DrawTool, existing: UInt64? = nil) {
        self.drawing = drawing
        self.origin = origin
        self.reopened = reopened
        self.existing = existing
        super.init()
        model.readOnly = drawing.isReadOnly
        model.isReopened = reopened != nil
        model.tool = tool
        refreshDestinations()
        model.showsHint = !model.readOnly && !OverlayModel.hintSeen
        model.onAction = { [weak self] in self?.finish($0) }
        model.onCancel = { [weak self] in self?.cancel() }
        model.onRemove = { [weak self] in self?.remove() }
        model.onTool = { [weak self] in self?.setTool($0) }
        model.onWrite = { [weak self] in self?.switchToWriting() }
        model.onDebugRect = { [weak self] in self?.debugRect() }

        web.webView.frame = view.bounds
        #if os(iOS)
        web.webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #else
        web.webView.autoresizingMask = [.width, .height]
        #endif
        view.addSubview(web.webView)
        view.addSubview(anchorMark)
        firstRow.setIdentifier("drawing.firstRow", label: "First row")
        view.addSubview(firstRow)
        web.onMessage = { [weak self] in self?.message($0) }

        #if os(iOS)
        model.canWrite = UIDevice.current.userInterfaceIdiom == .pad && !model.readOnly
        if !model.readOnly {
            let ink = InkCanvasController(host: self)
            ink.canvas.frame = view.bounds
            view.addSubview(ink.canvas)
            self.ink = ink
            ink.setTool(tool)

            // Over either layer: the page ignores a second finger, and PencilKit drops the stroke
            // the first one started.
            let pan = UIPanGestureRecognizer(target: self, action: #selector(twoFingerPan(_:)))
            pan.minimumNumberOfTouches = 2
            pan.maximumNumberOfTouches = 2
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            pan.cancelsTouchesInView = false
            pan.delaysTouchesBegan = false
            pan.delegate = self
            view.addGestureRecognizer(pan)

            let pencil = UIPencilInteraction(delegate: self)
            view.addInteraction(pencil)
        }
        let host = UIHostingController(rootView: ThemedRoot { OverlayToolbar(model: model) })
        host.view.backgroundColor = .clear
        host.sizingOptions = [.intrinsicContentSize]
        host.overrideUserInterfaceStyle = drawing.isDarkTheme ? .dark : .light
        view.addSubview(host.view)
        toolbar = host
        #else
        let host = NSHostingView(rootView: ThemedRoot { OverlayToolbar(model: model) })
        host.appearance = NSAppearance(named: drawing.isDarkTheme ? .darkAqua : .aqua)
        view.addSubview(host)
        toolbar = host
        #endif
        view.onLayout = { [weak self] in self?.layout() }
        view.onEscape = { [weak self] in self?.cancel() }
        view.onKeep = { [weak self] in self?.finish(.keep) }
        view.onSend = { [weak self] in
            guard let self, !self.model.readOnly else { return }
            self.refreshDestinations()
            if let primary = self.model.primary { self.finish(.send(primary)) }
        }
        view.onTool = { [weak self] tool in
            guard let self, !self.model.readOnly else { return }
            self.setTool(tool)
        }
        CanvasWebView.log.info("draw: overlay opens on pane \(drawing.paneId) (\(reopened == nil ? "new" : "reopened", privacy: .public), tool \(tool.rawValue, privacy: .public))")
    }

    /// Nil for a new drawing.
    var reopenedPlacementId: UInt64? { reopened?.placementId }

    // MARK: Lifecycle

    func start() {
        if let reopened { drawing.hiddenPlacement = reopened.placementId }
        view.takeFocus()
        destinationsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDestinations() }
        }
        web.call("setTool", ["type": model.tool.excalidrawType])
        Task { await open() }
    }

    private func open() async {
        let client = drawing.hub.client
        if let reopened {
            artifactId = reopened.artifactId
        } else if let existing {
            artifactId = existing
        } else if !model.readOnly {
            do {
                let session = drawing.sessionId
                let info = try await anchored(origin) { anchor in
                    try await client.artifactCreate(create: ArtifactCreate(
                        sessionId: session, kind: .excalidraw, title: "Sketch", space: .canvas,
                        anchor: anchor, image: nil, ops: []))
                }
                artifactId = info.artifactId
                created = true
            } catch {
                model.status = "Could not start a drawing: \(Self.describe(error))"
                return
            }
        }
        guard let artifactId, !closed else { return }
        let sync = SceneSync(artifactId: artifactId, sessionId: drawing.sessionId, hub: drawing.hub, web: web)
        sync.readOnly = model.readOnly
        self.sync = sync
        if reopened != nil, let scene = try? await client.excalidrawGet(artifactId: artifactId, since: 0),
           let state = scene.appState.flatMap({ SceneSync.object($0) as? [String: Any] }),
           let row = state["overlayRow"] as? Int, row != 0,
           let shifted = drawing.tracker.terminal.pinRow(relativeTo: origin, offset: -row)
        {
            // The placement starts at the drawing's top row; the scene's origin is `row` below.
            origin = shifted
        }
        updateGeometry()
        #if os(iOS)
        ink?.convertNew()
        #endif
        await sync.load(mode: "overlay", theme: drawing.isDarkTheme ? "dark" : "light", viewport: viewport)
    }

    private var viewport: [String: Any]? {
        guard let geometry else { return nil }
        return ["originX": geometry.origin.x, "originY": geometry.origin.y, "zoom": geometry.zoom]
    }

    /// Moves the scene with its row after the terminal scrolled or re-laid out.
    func terminalMoved() {
        let before = geometry
        updateGeometry()
        if geometry != before, let viewport { web.call("setViewport", viewport) }
    }

    private func updateGeometry() {
        guard let surface = drawing.surface, let cell = surface.cellSize,
              let row = drawing.tracker.terminal.viewportRows(of: [origin]).first ?? nil
        else { return }
        let gridOrigin = surface.rect(for: GridPoint(x: 0, y: 0)).origin
        let updated = OverlayGeometry(cell: cell, gridOrigin: gridOrigin, anchorRow: row)
        let first = geometry == nil
        geometry = updated
        anchorMark.frame = CGRect(x: max(0, updated.origin.x - 3), y: updated.origin.y + 2, width: 2, height: cell.height - 4)
        firstRow.frame = CGRect(x: gridOrigin.x, y: gridOrigin.y, width: max(0, view.bounds.width - 2 * gridOrigin.x), height: cell.height)
        #if os(iOS)
        if first { ink?.convertNew() }
        #else
        _ = first
        #endif
    }

    private func layout() {
        let bounds = view.bounds
        #if os(iOS)
        guard let toolbarView = toolbar?.view else { return }
        var size = toolbarView.intrinsicContentSize
        if !model.compact, size.width > bounds.width - 24 {
            model.compact = true
            toolbarView.invalidateIntrinsicContentSize()
            size = toolbarView.intrinsicContentSize
        } else if model.compact, bounds.width > 760 {
            model.compact = false
            toolbarView.invalidateIntrinsicContentSize()
            size = toolbarView.intrinsicContentSize
        }
        let bottom = bounds.height - view.safeAreaInsets.bottom - 12
        toolbarView.frame = CGRect(x: (bounds.width - size.width) / 2, y: bottom - size.height, width: size.width, height: size.height)
        ink?.canvas.frame = bounds
        #else
        guard let toolbar else { return }
        var size = toolbar.fittingSize
        if !model.compact, size.width > bounds.width - 24 {
            model.compact = true
            size = toolbar.fittingSize
        } else if model.compact, bounds.width > 760 {
            model.compact = false
            size = toolbar.fittingSize
        }
        toolbar.frame = CGRect(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - 12, width: size.width, height: size.height)
        #endif
        terminalMoved()
    }

    /// Runs `handler` when the overlay closes, with the placement it made, if any.
    func onClose(_ handler: @escaping (Placement?) -> Void) {
        if closed { handler(placed) } else { closeHandlers.append(handler) }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        destinationsTimer?.invalidate()
        Self.lastTool = model.tool
        sync?.close()
        web.tearDown()
        #if os(iOS)
        ink?.tearDown()
        #endif
        drawing.overlayClosed()
        let handlers = closeHandlers
        closeHandlers = []
        for handler in handlers { handler(placed) }
    }

    // MARK: Editor messages

    private func message(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "change":
            isEdited = true
            sync?.changed(body)
        case "files": sync?.filesAdded(body)
        case "done": commit()
        case "cancel": cancel()
        case "wheel":
            guard let surface = drawing.surface, let cell = surface.cellSize else { return }
            scrollRemainder += CGFloat(body["dy"] as? Double ?? 0) / cell.height
            let rows = Int(scrollRemainder.rounded(.towardZero))
            scrollRemainder -= CGFloat(rows)
            if rows != 0 { surface.scroll(rows: rows) }
        case "loaded":
            CanvasWebView.log.info("draw: scene loaded (\(body["count"] as? Int ?? 0) element(s))")
            model.loaded = true
            #if os(iOS)
            ink?.pageLoaded()
            #endif
        case "tool":
            // The editor changed tool itself, e.g. back to selection after text.
            guard let type = body["tool"] as? String, let tool = DrawTool(excalidrawType: type), tool != model.tool else { return }
            CanvasWebView.log.info("draw: the editor switched to \(type, privacy: .public)")
            setTool(tool, fromEditor: true)
        case "inkApplied":
            #if os(iOS)
            ink?.applied(ids: body["ids"] as? [String] ?? [])
            #endif
        case "log":
            CanvasWebView.log.info("page: \(body["message"] as? String ?? "", privacy: .public)")
        default:
            break
        }
    }

    /// The page holds the ink until its scene has loaded.
    func addInk(_ elements: [[String: Any]]) {
        isEdited = true
        web.call("addElements", ["elements": elements])
    }

    func markEdited() { isEdited = true }

    var currentGeometry: OverlayGeometry? { geometry }
    var client: DaemonClient { drawing.hub.client }

    /// Debug and tests: runs a script in the editor page.
    func webEval(_ script: String) {
        Task {
            await web.waitUntilReady()
            _ = try? await web.webView.evaluateJavaScript(script)
        }
    }

    func peerInk(_ ink: InkLive) {
        drawing.peerInk.add(ink, geometry: { [weak self] in self?.geometry }, color: PeerInkView.color(for: ink.actor.principal))
    }

    #if os(iOS)
    /// The Pencil stroke that opened draw mode becomes its first stroke.
    func adoptFirstStroke(_ samples: [PencilSample], from source: UIView) {
        guard let ink else { return }
        let converted = samples.map { sample -> PencilSample in
            var moved = sample
            moved.location = source.convert(sample.location, to: ink.canvas)
            return moved
        }
        ink.adopt(converted)
    }
    #endif

    // MARK: Actions

    private func setTool(_ tool: DrawTool, fromEditor: Bool = false) {
        model.tool = tool
        #if os(iOS)
        ink?.setTool(tool)
        #endif
        if !fromEditor { web.call("setTool", ["type": tool.excalidrawType]) }
    }

    private func debugRect() {
        // Around the anchor row and the three above it, not the live prompt below.
        let width = (geometry?.sceneColumnWidth ?? 10) * 8
        web.call("debugRect", ["x": 10, "y": -55, "width": Double(width), "height": 70])
    }

    func commit() { finish(.keep) }

    func refreshDestinations() {
        let list = drawing.agentDestinations()
        let primary = SketchTargeting.primary(target: drawing.paneId, in: list)
        let canStart = drawing.canStartAgent
        // Assigned only on change: the toolbar's width follows the Send label, so it re-lays out.
        if model.destinations != list { model.destinations = list }
        if model.primary != primary {
            model.primary = primary
            view.setNeedsLayoutSoon()
        }
        if model.canStart != canStart { model.canStart = canStart }
    }

    /// Every way out but Cancel: places the drawing in the pane's output, closes, then does
    /// `action`. A failed placement keeps the overlay open with the reason shown.
    func finish(_ action: DrawingAction) {
        guard !model.busy, !closed else { return }
        if model.readOnly { return close() }
        model.busy = true
        if case .send(let destination) = action { model.status = "Sending to \(destination.agent.title)…" }
        Task {
            switch await place() {
            case .failed: return
            case .placed(let placement, let png):
                placed = placement
                OverlayModel.hintSeen = true
                let anchor = toolbarFrame
                close()
                drawing.finished(placement, png: png, action: action, anchor: anchor)
            case .empty:
                close()
            }
        }
    }

    /// Where share sheets point, in the pane's coordinates.
    private var toolbarFrame: CGRect {
        #if os(iOS)
        toolbar?.view.frame ?? view.bounds
        #else
        toolbar?.frame ?? view.bounds
        #endif
    }

    enum PlaceOutcome {
        case placed(Placement, Data)
        /// A new drawing was deleted, or a reopened placement removed.
        case empty
        case failed
    }

    private func remove() {
        guard let reopened else { return close() }
        Task {
            try? await drawing.hub.client.unplace(placementId: reopened.placementId)
            drawing.hub.noteRemoved(reopened.placementId, pane: drawing.paneId)
            close()
        }
    }

    /// A reopened drawing's edits were synced live, so cancelling overwrites them with the
    /// elements it was opened with.
    func cancel() {
        guard !closed else { return }
        CanvasWebView.log.info("draw: cancel on pane \(self.drawing.paneId)")
        if created, let artifactId {
            let client = drawing.hub.client
            Task { try? await client.artifactDelete(artifactId: artifactId) }
            return close()
        }
        guard reopened != nil, isEdited, let sync, !model.readOnly else { return close() }
        model.busy = true
        Task {
            let reverted = await web.runAsync("""
            window.canvas.revert();
            await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
            window.canvas.flushNow();
            return 1;
            """)
            await sync.settle()
            CanvasWebView.log.info("draw: cancel reverted the reopened scene (\(reverted == nil ? "page gone" : "ok", privacy: .public))")
            close()
        }
    }

    /// A drawing with content is placed first; an empty one closes.
    private func switchToWriting() {
        let drawing = drawing
        if isEdited {
            onClose { _ in drawing.startWriting() }
            commit()
        } else {
            cancel()
            drawing.startWriting()
        }
    }

    /// Renders the covered cells to PNG and places it.
    private func place() async -> PlaceOutcome {
        #if os(iOS)
        await ink?.settle()
        #endif
        guard let artifactId, let sync, let geometry, let surface = drawing.surface, let grid = surface.grid else {
            return fail("The drawing is not ready yet")
        }
        web.call("flushNow")
        _ = await web.value("1")
        await sync.settle()
        guard let bounds = await web.value("canvas.bounds()") as? [String: Any],
              let x = bounds["x"] as? Double, let y = bounds["y"] as? Double,
              let width = bounds["width"] as? Double, let height = bounds["height"] as? Double
        else {
            if let reopened {
                try? await drawing.hub.client.unplace(placementId: reopened.placementId)
                drawing.hub.noteRemoved(reopened.placementId, pane: drawing.paneId)
            } else if created {
                try? await drawing.hub.client.artifactDelete(artifactId: artifactId)
            }
            CanvasWebView.log.info("done: empty scene")
            return .empty
        }
        let box = geometry.cells(covering: CGRect(x: x, y: y, width: width, height: height), maxCols: Int(grid.cols))
        let scale = geometry.zoom * surface.layer.contentsScale
        guard let png = await web.export(scale: scale, bounds: geometry.sceneRect(of: box))?.data,
              let top = drawing.tracker.terminal.pinRow(relativeTo: origin, offset: box.row)
        else {
            return fail("Could not render the drawing")
        }
        sync.setAppState(["overlayRow": box.row])
        await sync.settle()
        do {
            let client = drawing.hub.client
            let paneId = drawing.paneId
            let replace = reopened?.placementId
            let placement = try await anchored(top) { anchor in
                try await client.placePng(
                    request: PlaceRequest(
                        paneId: paneId, artifactId: artifactId, version: nil, anchor: anchor,
                        col: UInt16(box.col), cols: UInt16(box.cols), rows: UInt16(box.rows), replace: replace),
                    png: png)
            }
            // Show it at once from this device's own render, without a round trip for the blob.
            drawing.hub.seed(hash: placement.image.hash, png: png)
            if let pixels = DrawingHub.decode(png) { surface.setInlineImage(pixels, key: placement.image.hash) }
            drawing.hub.noteLocal(placement, replacing: reopened?.placementId)
            CanvasWebView.log.info("placed \(placement.placementId) \(box.cols)x\(box.rows) at col \(box.col)")
            return .placed(placement, png)
        } catch {
            return fail("Could not place the drawing: \(Self.describe(error))")
        }
    }

    /// While the pane is being resized the daemon's grid can briefly differ from ours and refuse
    /// the row; the request is retried with the anchor taken again once sizes settle.
    private func anchored<T>(_ pin: RowPin, _ request: (AnchorRequest) async throws -> T) async throws -> T {
        try await drawing.anchored(pin, request)
    }

    private func fail(_ message: String) -> PlaceOutcome {
        CanvasWebView.log.error("done: \(message, privacy: .public)")
        model.status = message
        model.busy = false
        return .failed
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? ArtifactError {
            switch error {
            case .Forbidden: return "view only"
            case .NotAgentPane: return "no agent in that pane"
            case .Disconnected: return "disconnected"
            case .NotFound(let message), .TooLarge(let message), .Invalid(let message), .Failed(let message): return message
            }
        }
        return error.localizedDescription
    }
}

#if os(iOS)
extension DrawOverlay: InkHost {}

extension DrawOverlay: UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    @objc private func twoFingerPan(_ pan: UIPanGestureRecognizer) {
        guard let surface = drawing.surface, let cell = surface.cellSize else { return }
        switch pan.state {
        case .began:
            ink?.cancelStroke()
            scrollRemainder = 0
            pan.setTranslation(.zero, in: view)
            CanvasWebView.log.info("draw: two fingers scroll the terminal")
        case .changed:
            // Content follows the fingers: dragging down shows older output.
            scrollRemainder -= pan.translation(in: view).y / cell.height
            pan.setTranslation(.zero, in: view)
            let rows = Int(scrollRemainder.rounded(.towardZero))
            scrollRemainder -= CGFloat(rows)
            if rows != 0 { surface.scroll(rows: rows) }
        default:
            break
        }
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    /// Pencil double tap and squeeze do what the user chose in Settings ▸ Apple Pencil.
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        respondToPencil(PencilPreference(UIPencilInteraction.preferredTapAction))
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        respondToPencil(PencilPreference(UIPencilInteraction.preferredSqueezeAction))
    }

    private func respondToPencil(_ preference: PencilPreference) {
        guard !model.readOnly, let tool = pencilSwitch.respond(to: preference, current: model.tool) else { return }
        setTool(tool)
    }
}
#endif

/// Hosts the overlay over the terminal. While drawing it holds the keyboard focus: draw mode is
/// modal, so no keystroke reaches the shell underneath (⌘ chords still reach the menus).
final class OverlayContainer: PlatformView {
    var onLayout: (() -> Void)?
    var onEscape: (() -> Void)?
    var onKeep: (() -> Void)?
    var onSend: (() -> Void)?
    var onTool: ((DrawTool) -> Void)?

    /// Lays out again once SwiftUI has applied a toolbar change, since its size follows its content.
    func setNeedsLayoutSoon() {
        DispatchQueue.main.async { [weak self] in
            #if os(iOS)
            self?.setNeedsLayout()
            #else
            self?.needsLayout = true
            #endif
        }
    }

    #if os(iOS)
    override init(frame: CGRect) {
        super.init(frame: frame)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = .clear
        accessibilityIdentifier = "drawing.overlay"
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }

    /// A hidden text view, because UIKit delivers hardware keys reliably only to a text input.
    private lazy var keys: DrawKeySink = {
        let sink = DrawKeySink(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        sink.container = self
        addSubview(sink)
        return sink
    }()

    // Unhandled presses would travel up the responder chain to the terminal and on to the shell.
    // ⌘ chords go on to the menus.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let chords = presses.filter { $0.key?.modifierFlags.contains(.command) == true }
        if !chords.isEmpty { super.pressesBegan(chords, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let chords = presses.filter { $0.key?.modifierFlags.contains(.command) == true }
        if !chords.isEmpty { super.pressesEnded(chords, with: event) }
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {}

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let chords = presses.filter { $0.key?.modifierFlags.contains(.command) == true }
        if !chords.isEmpty { super.pressesCancelled(chords, with: event) }
    }

    /// Takes the keyboard focus from the terminal, so its key bar and the software keyboard go away.
    func takeFocus() {
        let taken = keys.becomeFirstResponder()
        CanvasWebView.log.info("draw: overlay \(taken ? "has" : "could not take", privacy: .public) the keyboard focus")
    }
    #else
    override init(frame: CGRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        setAccessibilityIdentifier("drawing.overlay")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override var acceptsFirstResponder: Bool { onEscape != nil }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { return onEscape?() ?? () }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty, let characters = event.charactersIgnoringModifiers?.lowercased(),
           let tool = DrawTool.allCases.first(where: { String($0.key) == characters }) {
            onTool?(tool)
        }
        // Anything else stops here, since the next responder is the terminal.
    }

    func takeFocus() {
        window?.makeFirstResponder(self)
    }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

#if os(iOS)
/// Draw mode's keyboard: a hidden, empty text view that is first responder while the overlay is
/// open. Its input views are empty, so no software keyboard, shortcuts bar or key bar shows.
final class DrawKeySink: UITextView {
    weak var container: OverlayContainer?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
        isScrollEnabled = false
        // UIKit does not deliver key presses to a responder that takes no interaction.
        isUserInteractionEnabled = true
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        inlinePredictionType = .no
        inputView = UIView(frame: .zero)
        inputAccessoryView = UIView(frame: .zero)
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        isAccessibilityElement = false
        accessibilityIdentifier = "drawing.keys"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFirstResponder: Bool { container?.onEscape != nil }

    /// Typed characters reach a text input before key commands, so the tool letters are read in
    /// `pressesBegan`; the text system keeps Esc from `pressesBegan`, so it is a command.
    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape)),
            UIKeyCommand(title: "Cancel Drawing", action: #selector(escape), input: ".", modifierFlags: .command),
            UIKeyCommand(title: "Keep in Terminal", action: #selector(keep), input: "\r", modifierFlags: .command),
            UIKeyCommand(title: "Send", action: #selector(send), input: "\r", modifierFlags: [.command, .shift]),
        ]
        for command in commands { command.wantsPriorityOverSystemBehavior = true }
        return commands
    }

    @objc private func escape() { container?.onEscape?() }
    @objc private func keep() { container?.onKeep?() }
    @objc private func send() { container?.onSend?() }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var chords: Set<UIPress> = []
        for press in presses {
            guard let key = press.key else { continue }
            if Self.commandKeys.contains(key.keyCode) { commandHeld = true }
            // A text view's presses can come without the held ⌘ in their flags.
            var modifiers = key.modifierFlags.union(event?.modifierFlags ?? []).intersection([.command, .control, .alternate, .shift])
            if commandHeld { modifiers.insert(.command) }
            if key.keyCode == .keyboardPeriod, modifiers == .command {
                // ⌘. is Esc on iPad keyboards; the terminal up the chain would type it.
                container?.onEscape?()
            } else if key.keyCode == .keyboardReturnOrEnter, modifiers == .command {
                container?.onKeep?()
            } else if key.keyCode == .keyboardReturnOrEnter, modifiers == [.command, .shift] {
                container?.onSend?()
            } else if modifiers.contains(.command) {
                chords.insert(press)
            } else if key.keyCode == .keyboardEscape {
                container?.onEscape?()
            } else if modifiers.isEmpty, let tool = DrawTool.allCases.first(where: { String($0.key) == key.charactersIgnoringModifiers.lowercased() }) {
                container?.onTool?(tool)
            }
        }
        if !chords.isEmpty { super.pressesBegan(chords, with: event) }
    }

    private static let commandKeys: Set<UIKeyboardHIDUsage> = [.keyboardLeftGUI, .keyboardRightGUI]
    private var commandHeld = false

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.key.map { Self.commandKeys.contains($0.keyCode) } ?? false }) { commandHeld = false }
        let chords = presses.filter { $0.key?.modifierFlags.contains(.command) == true }
        if !chords.isEmpty { super.pressesEnded(chords, with: event) }
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {}

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        commandHeld = false
        let chords = presses.filter { $0.key?.modifierFlags.contains(.command) == true }
        if !chords.isEmpty { super.pressesCancelled(chords, with: event) }
    }

    override func resignFirstResponder() -> Bool {
        commandHeld = false
        return super.resignFirstResponder()
    }

    /// Touches go to the drawing underneath.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override func insertText(_ text: String) {}
    override func deleteBackward() {}
    override func paste(_ sender: Any?) {}
}
#endif

/// A thin accent bar at the left edge of the row the drawing is pinned to.
final class AnchorMark: PlatformView {
    #if os(iOS)
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = UIColor(ChromePalette.fromPreferences().accentColor)
        layer.cornerRadius = 1
    }
    #else
    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(ChromePalette.fromPreferences().accentColor).cgColor
        layer?.cornerRadius = 1
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

#if os(iOS)
extension PencilPreference {
    init(_ action: UIPencilPreferredAction) {
        switch action {
        case .switchEraser: self = .switchEraser
        case .switchPrevious: self = .switchPrevious
        case .showColorPalette, .showInkAttributes, .showContextualPalette: self = .showPalette
        default: self = .ignore
        }
    }
}
#endif
