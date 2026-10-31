import Foundation
import Metal
import QuartzCore
import Synchronization
import TerminalCore

/// Platform-neutral terminal view logic: owns the `CAMetalLayer`, the render loop, the grid
/// geometry and per-frame overlays (cursor and text blink, echo predictions, IME preedit, hovered
/// links). A thin host view (`TerminalView`: an AppKit `NSView` or a UIKit `UIView`) forwards
/// layout, the display link, focus, pointer input and keys.
///
/// Rendering only happens when something changed: the display link pauses itself on a clean frame
/// and `setNeedsRender()` (callable from any thread, e.g. the PTY reader) resumes it.
@MainActor
public final class TerminalSurface {
    public struct Grid: Equatable, Sendable {
        public var cols: UInt16
        public var rows: UInt16
        public var cellWidth: UInt32
        public var cellHeight: UInt32
    }

    /// IME composition shown inline at the cursor.
    public struct Preedit: Equatable, Sendable {
        public var text: String
        public init(text: String) { self.text = text }
    }

    public let terminal: Terminal
    /// Replaced with a fresh one when the surface goes off screen (`releaseGPUResources`), which
    /// is the only way to give back the drawables it holds; hosts re-install it from
    /// `onLayerReplaced`.
    public private(set) var layer = CAMetalLayer()
    /// The layer was replaced: swap `old` for `new` in the host's layer tree.
    public var onLayerReplaced: ((_ old: CAMetalLayer, _ new: CAMetalLayer) -> Void)?
    public let stats = FrameStats()
    /// Called when the cell grid changes size, e.g. to send TIOCSWINSZ to the PTY.
    public var onGridChange: ((Grid) -> Void)?
    /// Called after the user scrolled the viewport (negative = towards history), e.g. to fetch
    /// older scrollback from a remote host when the top is reached.
    public var onScroll: ((Int) -> Void)?
    /// Called after each presented frame (hosts reposition selection handles, which follow
    /// scrolling and output).
    public var onFrameRendered: (() -> Void)?
    public private(set) var grid: Grid?
    /// The cursor cell in view points as of the last rendered frame (IME candidate window
    /// placement); nil when the cursor is hidden or scrolled out of the viewport.
    public private(set) var cursorRect: CGRect?
    public var isFocused = true {
        didSet {
            guard isFocused != oldValue else { return }
            displayLink?.preferredFrameRateRange = frameRateRange
            restartBlink()
            invalidateOverlay()
        }
    }

    public var appearance: TerminalAppearance {
        didSet {
            builder.style = Self.frameStyle(appearance)
            if appearance.background != oldValue.background { applyBackground() }
            if appearance.terminalConfiguration != oldValue.terminalConfiguration {
                terminal.setDefaults(appearance.terminalConfiguration)
            }
            if appearance.fontFamily != oldValue.fontFamily || appearance.fontSize != oldValue.fontSize
                || appearance.padding != oldValue.padding || appearance.paddingBalance != oldValue.paddingBalance
            {
                fonts = nil
                if let lastLayout { layout(size: lastLayout.size, scale: lastLayout.scale) }
            }
            invalidate()
        }
    }

    public var fontSize: CGFloat { appearance.fontSize }

    /// IME marked text, drawn at the cursor with an underline (never sent to the PTY).
    public var preedit: Preedit? {
        didSet { if preedit != oldValue { invalidateOverlay() } }
    }

    /// The hovered OSC 8 link's cells in viewport coordinates, underlined while hovered.
    public private(set) var hoveredLink: (row: Int, columns: ClosedRange<Int>)?

    /// Echo prediction for this surface, once `enablePrediction` was called (remote backends).
    public private(set) var predictor: EchoPredictor?

    /// Inline images over the grid (placements), asked for before every frame so they follow
    /// pinned rows as the output scrolls. Call `invalidateInlineImages()` when the set changes
    /// without the terminal changing.
    public var inlineImages: (() -> [InlineImagePlacement])? {
        didSet { invalidateInlineImages() }
    }

    /// The placements drawn in the last frame and their frames in view points (hit testing).
    public private(set) var inlineImageFrames: [(placement: InlineImagePlacement, rect: CGRect)] = []
    private var imageTextures: [String: MTLTexture] = [:]
    private var lastImages: [InlineImagePlacement] = []
    private var imagesDirty = false

    /// Stripes in the left gutter (shell command marks), asked for before every frame so they
    /// follow pinned rows. Call `invalidateGutterMarks()` when they change without the terminal
    /// changing.
    public var gutterMarks: (() -> [GutterMark])? {
        didSet { invalidateGutterMarks() }
    }

    /// The marks drawn in the last frame and the rows they cover in view points: the full
    /// width of the view (a command's rows, for hit testing), clipped to the grid.
    public private(set) var gutterMarkFrames: [(mark: GutterMark, rect: CGRect)] = []
    private var gutterTextures = GutterTextures()
    private var lastMarks: [GutterMark] = []
    private var marksDirty = false

    /// Kitty graphics: the terminal's placements as of the last frame, a texture per image on
    /// screen (only those, so memory follows what is shown), and the draws of the last frame.
    public private(set) var kittyPlacements: [ImagePlacement] = []
    private var kittyTextures: [UInt32: KittyTexture] = [:]
    private var kittyGenerations: (placements: UInt64, storage: UInt64)?
    private var kittyDraws = KittyDraws()
    private var animationWake: Task<Void, Never>?

    private let renderer: MetalRenderer
    private(set) var fonts: FontGrid?
    private let state = RenderState()
    private var builder = FrameBuilder()
    private var frame = FrameContents()
    private var displayLink: CADisplayLink?
    private var displayLinkTarget: DisplayLinkTarget?
    private var pixelSize = CGSize.zero
    private var lastLayout: (size: CGSize, scale: CGFloat)?
    private var paddingPx = SIMD4<Float>.zero
    private var needsFullRender = true
    private var lastOverlay = FrameOverlay()
    private var overlayDirty = false
    private var offscreenTexture: MTLTexture?
    /// The GPU side was dropped (`releaseGPUResources`): the next frame rebuilds it.
    private var gpuReleased = false
    private nonisolated let wakePending = Atomic<Bool>(false)
    private nonisolated let outputPending = Atomic<Bool>(false)
    /// Output arrived since the search last caught up (its own flag: the predictor takes the other).
    private nonisolated let searchOutputPending = Atomic<Bool>(false)

    // Blink: both phases flip on one timer while something blinks.
    private var cursorBlinkOn = true
    private var textBlinkOn = true
    private var cursorBlinks = false
    private var blinkTask: Task<Void, Never>?

    public init(terminal: Terminal, appearance: TerminalAppearance = .init()) throws {
        self.terminal = terminal
        self.appearance = appearance
        renderer = try MetalRenderer()
        builder.style = Self.frameStyle(appearance)
        configure(layer)
    }

    private func configure(_ layer: CAMetalLayer) {
        layer.device = renderer.device
        layer.pixelFormat = MetalRenderer.pixelFormat
        layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 3
        layer.isOpaque = true
        applyBackground()
    }

    /// The layer shows the terminal background until its first frame and wherever a resize
    /// outruns a frame, never black.
    private func applyBackground() {
        let bg = appearance.background
        layer.backgroundColor = CGColor(
            srgbRed: CGFloat(bg.r) / 255, green: CGFloat(bg.g) / 255, blue: CGFloat(bg.b) / 255, alpha: 1)
    }

    /// The background as a color, for the host view behind the layer.
    public var backgroundColor: CGColor? { layer.backgroundColor }

    public convenience init(terminal: Terminal, fontSize: CGFloat) throws {
        var appearance = TerminalAppearance()
        appearance.fontSize = fontSize
        try self.init(terminal: terminal, appearance: appearance)
    }

    private static func frameStyle(_ a: TerminalAppearance) -> FrameStyle {
        FrameStyle(
            selectionBackground: a.selectionBackground, selectionForeground: a.selectionForeground,
            faintAlpha: UInt8(clamping: Int((a.faintOpacity * 255).rounded())),
            search: SearchColors(
                background: a.searchBackground, foreground: a.searchForeground,
                selectedBackground: a.searchSelectedBackground, selectedForeground: a.searchSelectedForeground))
    }

    /// Seconds spent compiling shaders.metal at startup.
    public var shaderCompileSeconds: Double { renderer.shaderCompileSeconds }

    /// Atlas edge lengths in pixels (grayscale, color).
    public var atlasSizes: (grayscale: Int, color: Int) {
        (fonts?.grayscale.size ?? 0, fonts?.color.size ?? 0)
    }

    // MARK: Display link

    /// Starts frame pacing. `make` creates a display link on the host platform
    /// (`NSView.displayLink(target:selector:)` or `CADisplayLink(target:selector:)`). Replaces a
    /// running link, e.g. when the host view moves to another window or screen.
    public func startDisplayLink(_ make: (_ target: Any, _ selector: Selector) -> CADisplayLink) {
        stopDisplayLink()
        let target = DisplayLinkTarget(surface: self)
        let link = make(target, #selector(DisplayLinkTarget.tick(_:)))
        link.preferredFrameRateRange = frameRateRange
        link.add(to: .main, forMode: .common)
        displayLinkTarget = target
        displayLink = link
        restartBlink()
    }

    /// ProMotion's 120 Hz for the terminal being typed in; 60 Hz for the others, which only
    /// stream output (the fastest view sets the display's rate, WWDC22 10083). The link pauses
    /// when nothing changes either way.
    private var frameRateRange: CAFrameRateRange {
        isFocused
            ? CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            : CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    }

    public func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget = nil
        blinkTask?.cancel()
        blinkTask = nil
        animationWake?.cancel()
        animationWake = nil
    }

    // MARK: Geometry

    /// A remote pane's terminal is resized by its stream (where the remote PTY changed size), not
    /// by layout: layout only reports the new grid (`onGridChange`), and the renderer draws the
    /// terminal at whatever size it has until the resize arrives (about one round trip).
    public var sizeFollowsStream = false

    /// Sizes the drawable for a view of `size` points at `scale` pixels/point, and the cell grid
    /// to fit it: a whole number of cells, the remainder becoming right/bottom padding (Ghostty
    /// without `window-padding-balance`).
    ///
    /// The drawable follows every layout; the grid does not. A grid change reflows the screen
    /// and sends the program SIGWINCH (a shell redraws its prompt), so it is coalesced the way
    /// Ghostty's IO thread coalesces resizes: during an animated layout change
    /// (`holdGrids(for:)`) the grid waits until the view settles and changes once; otherwise it
    /// changes once the size has held for `steadyInterval` (a size that lasts a single layout
    /// pass, as keyboard avoidance produces, never reaches the program), and at most every
    /// `gridInterval` while the size keeps changing (a divider drag, a live window resize),
    /// always ending at the final size. Meanwhile the
    /// current grid stays drawn where it was, anchored top-left: clipped by a shrinking view,
    /// on background in a growing one, never reflowed.
    public func layout(size: CGSize, scale: CGFloat) {
        lastLayout = (size, scale)
        if fonts == nil || layer.contentsScale != scale {
            layer.contentsScale = scale
            fonts = FontGrid.shared(pixelSize: appearance.fontSize * scale, family: appearance.fontFamily)
            builder = FrameBuilder()
            builder.style = Self.frameStyle(appearance)
        }
        guard let fonts else { return }
        let newPixelSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        if newPixelSize != pixelSize { lastSizeChange = .now }
        pixelSize = newPixelSize
        layer.drawableSize = pixelSize

        let m = fonts.metrics
        let pad = Int((appearance.padding * scale).rounded())
        let cols = max(1, (Int(pixelSize.width) - 2 * pad) / m.cellWidth)
        let rows = max(1, (Int(pixelSize.height) - 2 * pad) / m.cellHeight)
        let target = Grid(cols: UInt16(cols), rows: UInt16(rows), cellWidth: UInt32(m.cellWidth), cellHeight: UInt32(m.cellHeight))

        if let grid, target == grid {
            pendingGrid = nil
            pendingIsHeld = false
            if ContinuousClock.now >= Self.gridHoldUntil { updateInset(for: grid) }
        } else if let grid, pixelSize.width > 0, pixelSize.height > 0,
                  target.cellWidth == grid.cellWidth, target.cellHeight == grid.cellHeight
        {
            if pendingGrid == nil { pendingSince = .now }
            pendingGrid = target
            if ContinuousClock.now < Self.gridHoldUntil { pendingIsHeld = true }
            scheduleGridCommit()
        } else if pixelSize.width > 0, pixelSize.height > 0 {
            // The first real size, or new cells (font, scale): at once.
            commitGrid(target)
        }
        placeGrid()
        invalidate()
        // On screen: draw at the new size now, presented with the transaction that resizes the
        // layer, rather than on the next display-link tick a frame later (a split's new pane,
        // or a pane resizing under an animation, would show a blank or stretched frame).
        if displayLink != nil, layer.drawableSize != previousDrawableSize {
            previousDrawableSize = layer.drawableSize
            layer.presentsWithTransaction = true
            _ = renderIfDirty()
            layer.presentsWithTransaction = false
        }
    }

    // MARK: Grid commits

    /// The least time between two grid changes while the size keeps changing (Ghostty
    /// coalesces for 25 ms; kitty waits 100 ms before redrawing a live resize).
    public static let gridInterval = Duration.milliseconds(100)
    /// How long a held view's size must stay put before its grid changes: a spring's tail
    /// still moves it after the animation's nominal duration.
    static let settleInterval = Duration.milliseconds(50)
    /// How long a size must hold before its grid applies (Ghostty coalesces for 25 ms).
    static let steadyInterval = Duration.milliseconds(25)
    static var gridHoldUntil = ContinuousClock.now

    /// An animated layout change starts (a split, a close, a zoom, a sidebar): every surface
    /// keeps its grid while its view resizes during `duration`, then changes it once, at the
    /// size it settles at. Hosts call this before the animation's first frame.
    public static func holdGrids(for duration: Duration) {
        gridHoldUntil = max(gridHoldUntil, .now + duration)
    }

    /// The grid the view's size calls for, waiting to be applied.
    private var pendingGrid: Grid?
    /// The pending grid came from a held layout: it waits for the view to settle.
    private var pendingIsHeld = false
    private var pendingSince = ContinuousClock.now
    private var lastGridCommit: ContinuousClock.Instant?
    private var lastSizeChange = ContinuousClock.now
    private var gridCommitTask: Task<Void, Never>?
    /// The grid's top-left inset in pixels when it was last applied, kept while a grid waits.
    private var gridInset = SIMD2<Int>(0, 0)

    /// When the pending grid may be applied; nil when it may be now.
    private func commitDue() -> ContinuousClock.Instant? {
        let now = ContinuousClock.now
        // A hold that starts while a grid waits holds it too: a layout can start moving
        // before the change that explains it is announced (the keyboard).
        if now < Self.gridHoldUntil { pendingIsHeld = true }
        let due = pendingIsHeld
            ? max(Self.gridHoldUntil, lastSizeChange + Self.settleInterval)
            : max(
                lastGridCommit.map { $0 + Self.gridInterval } ?? now,
                min(lastSizeChange + Self.steadyInterval, pendingSince + Self.gridInterval))
        return due > now ? due : nil
    }

    private func scheduleGridCommit() {
        guard gridCommitTask == nil else { return }
        gridCommitTask = Task { [weak self] in
            while let self, self.pendingGrid != nil, !Task.isCancelled {
                guard let due = self.commitDue() else { break }
                // In steps: the hold can end early.
                try? await Task.sleep(until: min(due, .now + Self.steadyInterval), clock: .continuous)
            }
            guard let self else { return }
            self.gridCommitTask = nil
            guard let pending = self.pendingGrid, !Task.isCancelled else { return }
            self.commitGrid(pending)
            self.placeGrid()
            self.invalidate()
        }
    }

    private func commitGrid(_ newGrid: Grid) {
        pendingGrid = nil
        pendingIsHeld = false
        gridCommitTask?.cancel()
        gridCommitTask = nil
        // The first grid is a starting point, not a step of a resize: the next may follow at once.
        if grid != nil { lastGridCommit = .now }
        let changed = newGrid != grid
        grid = newGrid
        updateInset(for: newGrid)
        guard changed else { return }
        if !sizeFollowsStream {
            terminal.resize(cols: newGrid.cols, rows: newGrid.rows, cellWidth: newGrid.cellWidth, cellHeight: newGrid.cellHeight)
        }
        predictor?.reset()
        onGridChange?(newGrid)
    }

    /// `window-padding-balance`: split the space left over after whole cells evenly, so the grid
    /// sits centered instead of hugging the top-left edge.
    private func updateInset(for grid: Grid) {
        let pad = Int((appearance.padding * layer.contentsScale).rounded())
        guard appearance.paddingBalance else { return gridInset = SIMD2(pad, pad) }
        let extraX = Int(pixelSize.width) - 2 * pad - Int(grid.cols) * Int(grid.cellWidth)
        let extraY = Int(pixelSize.height) - 2 * pad - Int(grid.rows) * Int(grid.cellHeight)
        gridInset = SIMD2(pad + max(0, extraX) / 2, pad + max(0, extraY) / 2)
    }

    /// Padding around the applied grid in the current drawable: the kept inset on the top and
    /// left, whatever remains (none when clipped) on the right and bottom.
    private func placeGrid() {
        guard let grid else { return }
        let width = Int(grid.cols) * Int(grid.cellWidth), height = Int(grid.rows) * Int(grid.cellHeight)
        paddingPx = SIMD4(
            Float(gridInset.y),
            Float(max(0, Int(pixelSize.width) - gridInset.x - width)),
            Float(max(0, Int(pixelSize.height) - gridInset.y - height)),
            Float(gridInset.x))
    }

    /// The grid the view's size calls for while the applied one waits (nil: none waits).
    public var pendingGridSize: Grid? { pendingGrid }

    private var previousDrawableSize = CGSize.zero

    /// One cell in points (nil before the first layout).
    public var cellSize: CGSize? {
        guard let grid else { return nil }
        let scale = layer.contentsScale
        return CGSize(width: CGFloat(grid.cellWidth) / scale, height: CGFloat(grid.cellHeight) / scale)
    }

    /// Fixed (top/left) padding in points.
    public var paddingPoints: CGFloat { CGFloat(paddingPx.x) / layer.contentsScale }
    /// The grid's origin in points (differs from `paddingPoints` with padding balance).
    private var gridOrigin: CGPoint {
        CGPoint(x: CGFloat(paddingPx.w) / layer.contentsScale, y: CGFloat(paddingPx.x) / layer.contentsScale)
    }

    /// The viewport cell under a point in view coordinates, clamped into the grid.
    public func cell(at point: CGPoint) -> GridPoint {
        guard let grid, let size = cellSize else { return GridPoint(x: 0, y: 0) }
        let origin = gridOrigin
        let x = Int(((point.x - origin.x) / size.width).rounded(.down))
        let y = Int(((point.y - origin.y) / size.height).rounded(.down))
        return GridPoint(x: min(max(x, 0), Int(grid.cols) - 1), y: min(max(y, 0), Int(grid.rows) - 1))
    }

    /// A viewport cell's frame in view points.
    public func rect(for cell: GridPoint, span: Int = 1) -> CGRect {
        guard let size = cellSize else { return .zero }
        let origin = gridOrigin
        return CGRect(x: origin.x + CGFloat(cell.x) * size.width, y: origin.y + CGFloat(cell.y) * size.height,
                      width: size.width * CGFloat(span), height: size.height)
    }

    /// A view point in surface pixels, as the mouse encoder and selection gestures expect.
    public func pixels(_ point: CGPoint) -> (x: Double, y: Double) {
        (Double(point.x * layer.contentsScale), Double(point.y * layer.contentsScale))
    }

    public var mouseGeometry: MouseGeometry {
        let grid = grid ?? Grid(cols: 1, rows: 1, cellWidth: 1, cellHeight: 1)
        return MouseGeometry(
            screenWidth: UInt32(pixelSize.width), screenHeight: UInt32(pixelSize.height),
            cellWidth: grid.cellWidth, cellHeight: grid.cellHeight,
            paddingTop: UInt32(paddingPx.x), paddingRight: UInt32(paddingPx.y),
            paddingBottom: UInt32(paddingPx.z), paddingLeft: UInt32(paddingPx.w))
    }

    public var selectionGeometry: SelectionGesture.Geometry {
        let grid = grid ?? Grid(cols: 1, rows: 1, cellWidth: 1, cellHeight: 1)
        return SelectionGesture.Geometry(
            columns: UInt32(grid.cols), cellWidth: grid.cellWidth, paddingLeft: UInt32(paddingPx.w),
            screenHeight: UInt32(pixelSize.height))
    }

    // MARK: Input

    /// Scrolls the viewport through scrollback; negative is up.
    public func scroll(rows: Int) {
        guard rows != 0 else { return }
        terminal.scrollViewport(by: rows)
        setNeedsRender()
        onScroll?(rows)
    }

    /// Encodes a key press for the PTY and snaps the viewport back to the bottom, as Ghostty does.
    /// The input also goes through the echo predictor and restarts the cursor blink.
    public func encode(_ key: KeyEvent) -> [UInt8] {
        let bytes = terminal.encode(key)
        if !bytes.isEmpty { noteInput(bytes) }
        return bytes
    }

    /// Bookkeeping for bytes about to be sent as user input (keys, key bar, mouse-free paths).
    public func noteInput(_ bytes: [UInt8]) {
        terminal.scrollToBottom()
        if let predictor {
            predictor.predict(PredictedInput(bytes: bytes), screen: terminal)
            invalidateOverlay()
        }
        restartBlink()
        setNeedsRender()
    }

    /// Pastes through libghostty-vt (bracketed when enabled); the bytes reach the PTY through the
    /// terminal's `writePty`.
    public func paste(_ text: String, source: PasteSource = .clipboard, allowUnsafe: Bool = false) -> PasteResult {
        let result = terminal.paste(text, source: source, allowUnsafe: allowUnsafe)
        if result == .written {
            predictor?.predict(.other, screen: terminal)
            terminal.scrollToBottom()
            restartBlink()
            setNeedsRender()
        }
        return result
    }

    // MARK: Pointer

    /// Whether pointer input goes to the program (mouse tracking on) rather than to selection.
    /// Shift overrides, as in Ghostty.
    public func reportsMouse(shift: Bool) -> Bool {
        !shift && terminal.modes.mouseTracking
    }

    private var pressedButtons = 0

    /// Encodes a pointer event at a view point for the program; [] when it does not track the
    /// mouse or the event is filtered (motion in the same cell, motion in normal mode).
    public func mouse(_ action: MouseEvent.Action, button: MouseEvent.Button?, at point: CGPoint, mods: KeyModifiers = []) -> [UInt8] {
        if action == .press, button != nil { pressedButtons += 1 }
        if action == .release, button != nil { pressedButtons = max(0, pressedButtons - 1) }
        let px = pixels(point)
        let bytes = terminal.encodeMouse(
            MouseEvent(action: action, button: button, mods: mods, x: px.x, y: px.y),
            geometry: mouseGeometry, anyButtonPressed: pressedButtons > 0)
        if action == .release { terminal.resetMouseEncoder() }
        return bytes
    }

    /// Routes scrolling of `rows` (negative = towards history) like Ghostty: wheel events to a
    /// program that tracks the mouse, arrow keys on the alt screen when it does not (alternate
    /// scroll, DECSET 1007), else the viewport through scrollback. Returns bytes for the PTY.
    public func wheel(rows: Int, at point: CGPoint, mods: KeyModifiers = []) -> [UInt8] {
        guard rows != 0 else { return [] }
        let modes = terminal.modes
        let count = min(abs(rows), 20)
        if modes.mouseTracking, !mods.contains(.shift) {
            let button: MouseEvent.Button = rows < 0 ? .wheelUp : .wheelDown
            var bytes: [UInt8] = []
            for _ in 0..<count { bytes += mouse(.press, button: button, at: point, mods: mods) }
            pressedButtons = max(0, pressedButtons - count)
            return bytes
        }
        if AlternateScroll.applies(modes) {
            let key: PhysicalKey = rows < 0 ? .arrowUp : .arrowDown
            var bytes: [UInt8] = []
            for _ in 0..<count { bytes += terminal.encode(.press(key)) }
            return bytes
        }
        scroll(rows: rows)
        return []
    }

    /// The link under a view point: an OSC 8 hyperlink, or a URL or path printed there
    /// (`Terminal.link(atViewport:)`), with the cells it covers on that row.
    public func link(at point: CGPoint) -> TerminalLink? {
        guard grid != nil else { return nil }
        return terminal.link(atViewport: cell(at: point))
    }

    /// The selection's ends in view points: the top-left of its first cell and the bottom-right
    /// of its last, or nil for an end scrolled out of view.
    public func selectionEnds() -> (start: CGRect?, end: CGRect?)? {
        guard let selection = terminal.selection else { return nil }
        let start = terminal.viewportPoint(fromScreen: selection.start).map { rect(for: $0) }
        let end = terminal.viewportPoint(fromScreen: selection.end).map { rect(for: $0) }
        return (start, end)
    }

    /// Underlines a hovered link (nil clears).
    public func setHoveredLink(_ link: (row: Int, columns: ClosedRange<Int>)?) {
        let same = link?.row == hoveredLink?.row && link?.columns == hoveredLink?.columns
        guard !same else { return }
        hoveredLink = link
        invalidateOverlay()
    }

    // MARK: Prediction

    /// Turns on echo prediction (for backends that feed `PredictionUpdate`s).
    @discardableResult
    public func enablePrediction(configuration: EchoPredictor.Configuration = .init()) -> EchoPredictor {
        if let predictor { return predictor }
        let predictor = EchoPredictor(configuration: configuration)
        self.predictor = predictor
        return predictor
    }

    public func applyPrediction(_ update: PredictionUpdate) {
        predictor?.apply(update)
        invalidateOverlay()
    }

    /// Output was written to the terminal (any thread). Wakes the renderer and has the predictor
    /// reconcile against the new screen on the next frame.
    public nonisolated func outputArrived() {
        outputPending.store(true, ordering: .releasing)
        searchOutputPending.store(true, ordering: .releasing)
        setNeedsRender()
    }

    // MARK: Search

    /// The scrollback search (libghostty-vt's, over this terminal's own scrollback), while one is
    /// running: every match in view is highlighted, the selected one in the stronger color.
    public private(set) var search: TerminalSearch?
    /// The search's count and selection changed (main actor; after frames and `selectMatch`).
    public var onSearchStatus: ((SearchStatus) -> Void)?
    private var lastSearchStatus = SearchStatus.idle

    /// Searches for `needle` (empty ends the search and clears the highlights). The same needle
    /// again keeps the selection.
    public func setSearch(_ needle: String, caseSensitive: Bool = false) {
        if needle.isEmpty {
            search = nil
        } else {
            let search = self.search ?? TerminalSearch(terminal: terminal)
            search.setNeedle(needle, caseSensitive: caseSensitive)
            self.search = search
            searchOutputPending.store(true, ordering: .releasing)
        }
        reportSearchStatus(search?.status ?? .idle)
        invalidateOverlay()
    }

    /// Selects the next (older) or previous (newer) match and scrolls to it. False without matches.
    @discardableResult
    public func selectMatch(_ direction: TerminalSearch.Direction) -> Bool {
        guard let search else { return false }
        // Catch up first, so the match is chosen among everything printed so far.
        if !search.status.isComplete || searchOutputPending.exchange(false, ordering: .acquiringAndReleasing) {
            search.run()
        }
        let found = search.select(direction)
        reportSearchStatus(search.status)
        invalidateOverlay()
        return found
    }

    private func reportSearchStatus(_ status: SearchStatus) {
        guard status != lastSearchStatus else { return }
        lastSearchStatus = status
        onSearchStatus?(status)
    }

    /// Advances the search on a frame and returns the highlights for the viewport.
    private func searchHighlights() -> [SearchHighlight] {
        guard let search, let grid else { return [] }
        // The viewport's match list is refreshed by feeding, so feed on every frame it is shown.
        let output = searchOutputPending.exchange(false, ordering: .acquiringAndReleasing)
        reportSearchStatus(search.update(outputChanged: output))
        return search.viewportHighlights(rows: Int(grid.rows), cols: Int(grid.cols))
    }

    // MARK: Inline images

    /// Makes `pixels` available to placements under `key` (replacing an image with that key).
    public func setInlineImage(_ pixels: InlineImagePixels, key: String) {
        imageTextures[key] = renderer.makeTexture(pixels)
        invalidateInlineImages()
    }

    public func hasInlineImage(key: String) -> Bool { imageTextures[key] != nil }

    public func removeInlineImage(key: String) {
        guard imageTextures.removeValue(forKey: key) != nil else { return }
        invalidateInlineImages()
    }

    /// The placements changed (added, removed, re-anchored): draw again.
    public func invalidateInlineImages() {
        imagesDirty = true
        setNeedsRender()
    }

    /// The placements the last frame drew whose frame contains `point` (view points), topmost
    /// first.
    public func inlineImages(at point: CGPoint) -> [InlineImagePlacement] {
        inlineImageFrames.reversed().filter { $0.rect.contains(point) }.map(\.placement)
    }

    private func imageDraws(_ placements: [InlineImagePlacement], metrics m: CellMetrics) -> [ImageDraw] {
        var draws: [ImageDraw] = []
        var frames: [(placement: InlineImagePlacement, rect: CGRect)] = []
        let gridRows = Int(grid?.rows ?? 0)
        let scale = layer.contentsScale
        for p in placements {
            guard let texture = imageTextures[p.key], p.cols > 0, p.rows > 0, p.row + p.rows > 0, p.row < gridRows else { continue }
            let size = SIMD2(Float(p.cols * m.cellWidth), Float(p.rows * m.cellHeight))
            draws.append(ImageDraw(texture: texture, vertex: ImageVertex(
                gridPos: SIMD2(Float(p.col), Float(p.row)), cellOffset: .zero,
                sourceRect: SIMD4(0, 0, Float(texture.width), Float(texture.height)), destSize: size)))
            frames.append((p, CGRect(
                x: (CGFloat(paddingPx.w) + CGFloat(p.col * m.cellWidth)) / scale,
                y: (CGFloat(paddingPx.x) + CGFloat(p.row * m.cellHeight)) / scale,
                width: CGFloat(size.x) / scale, height: CGFloat(size.y) / scale)))
        }
        inlineImageFrames = frames
        return draws
    }

    /// The grid area in drawable pixels: images never draw into the padding.
    private var imageClip: MTLScissorRect? {
        guard let grid, pixelSize.width > 0 else { return nil }
        let x = max(0, Int(paddingPx.w)), y = max(0, Int(paddingPx.x))
        let width = min(Int(grid.cols) * Int(grid.cellWidth), Int(pixelSize.width) - x)
        let height = min(Int(grid.rows) * Int(grid.cellHeight), Int(pixelSize.height) - y)
        guard width > 0, height > 0 else { return nil }
        return MTLScissorRect(x: x, y: y, width: width, height: height)
    }

    // MARK: Kitty graphics

    /// Reads the placements again when they or the storage changed (an image added, moved,
    /// deleted, its pixels arriving after a restore, an animation frame) and uploads the
    /// pixels of images whose texture is missing or stale. Returns whether anything changed.
    private func refreshKittyImages(full: Bool) -> Bool {
        let generations = (state.imagePlacementsGeneration, terminal.kittyStorageGeneration)
        guard full || kittyGenerations.map({ $0 != generations }) ?? true else { return false }
        kittyGenerations = generations
        let placements = state.imagePlacements()
        let changed = placements != kittyPlacements || !placements.isEmpty
        kittyPlacements = placements
        var shown = Set<UInt32>()
        for p in placements {
            shown.insert(p.imageID)
            guard kittyTextures[p.imageID]?.generation != p.generation else { continue }
            // Pixels still on the way (after a restore) or replaced since the update: the
            // image appears, at its final size, once a later frame finds them.
            guard let pixels = terminal.kittyImage(id: p.imageID), pixels.generation == p.generation,
                  let texture = KittyTexture(pixels, renderer: renderer)
            else { continue }
            kittyTextures[p.imageID] = texture
        }
        kittyTextures = kittyTextures.filter { shown.contains($0.key) }
        return changed || full
    }

    /// The placements as quads in their layers, lowest z first, scaled from the terminal's cell
    /// pixels to the renderer's (a remote pane lays images out in the host's cells).
    private func kittyImageDraws(metrics m: CellMetrics) -> KittyDraws {
        var draws = KittyDraws()
        guard !kittyPlacements.isEmpty, let grid else { return draws }
        let vtCell = terminal.cellPixelSize
        guard vtCell.width > 0, vtCell.height > 0 else { return draws }
        let sx = Float(m.cellWidth) / Float(vtCell.width), sy = Float(m.cellHeight) / Float(vtCell.height)
        let sorted = kittyPlacements.sorted { ($0.layer, $0.z) < ($1.layer, $1.z) }
        for p in sorted {
            guard let image = kittyTextures[p.imageID], image.generation == p.generation else { continue }
            let top = Float(p.row) * Float(m.cellHeight) + Float(p.offsetY) * sy
            let height = Float(p.height) * sy
            guard top + height > 0, top < Float(Int(grid.rows) * m.cellHeight) else { continue }
            let t = image.scale
            let draw = ImageDraw(texture: image.texture, vertex: ImageVertex(
                gridPos: SIMD2(Float(p.col), Float(p.row)),
                cellOffset: SIMD2(Float(p.offsetX) * sx, Float(p.offsetY) * sy),
                sourceRect: SIMD4(Float(p.sourceX) * t, Float(p.sourceY) * t, Float(p.sourceWidth) * t, Float(p.sourceHeight) * t),
                destSize: SIMD2(Float(p.width) * sx, height)))
            switch p.layer {
            case .belowBackground: draws.belowBackground.append(draw)
            case .belowText: draws.belowText.append(draw)
            case .aboveText: draws.aboveText.append(draw)
            }
        }
        return draws
    }

    /// Wakes the renderer when the next animation frame is due; nothing while none plays.
    private func scheduleAnimationFrame(_ dueMs: UInt64?) {
        animationWake?.cancel()
        animationWake = nil
        guard let dueMs, displayLink != nil else { return }
        // Never sooner than a 120 Hz frame.
        let delay = max(Int64(dueMs) - Int64(Self.nowMs()), 8)
        animationWake = Task { [weak self] in
            guard (try? await Task.sleep(for: .milliseconds(delay))) != nil else { return }
            self?.setNeedsRender()
        }
    }

    /// The animation clock: milliseconds of monotonic uptime, the same for every terminal.
    private static func nowMs() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000_000 }

    // MARK: Gutter marks

    /// The gutter marks changed (added, finished, re-anchored): draw again.
    public func invalidateGutterMarks() {
        marksDirty = true
        setNeedsRender()
    }

    /// The gutter mark whose rows contain `point` (view points), from the last frame.
    public func gutterMark(at point: CGPoint) -> GutterMark? {
        gutterMarkFrames.last { $0.rect.minY <= point.y && point.y < $0.rect.maxY }?.mark
    }

    private func gutterDraws(_ marks: [GutterMark], colors: RenderState.Colors, metrics m: CellMetrics) -> [ImageDraw] {
        var draws: [ImageDraw] = []
        var frames: [(mark: GutterMark, rect: CGRect)] = []
        let gridRows = Int(grid?.rows ?? 0)
        let scale = layer.contentsScale
        let left = Int(paddingPx.w)
        let width = Self.gutterWidth(paddingLeft: left, scale: scale)
        // Right-aligned towards the text with 2 pt of air when the padding allows, else at
        // the pane's edge.
        let x = max(0, left - width - Int((2 * scale).rounded()))
        let inset = Self.gutterInset(cellHeight: m.cellHeight, scale: scale)
        for mark in marks {
            let top = max(mark.row, 0), bottom = min(mark.row + mark.rows, gridRows)
            guard mark.rows > 0, bottom > top else { continue }
            frames.append((mark, CGRect(
                x: 0, y: (CGFloat(paddingPx.x) + CGFloat(top * m.cellHeight)) / scale,
                width: pixelSize.width / scale, height: CGFloat((bottom - top) * m.cellHeight) / scale)))
            guard let texture = gutterTextures.texture(mark.color(colors), opacity: mark.opacity, device: renderer.device) else { continue }
            // The whole stripe (its ends may be off screen; the clip trims them).
            let height = mark.rows * m.cellHeight - 2 * inset
            guard height > 0 else { continue }
            draws.append(ImageDraw(texture: texture, vertex: ImageVertex(
                gridPos: SIMD2(0, Float(mark.row)), cellOffset: SIMD2(Float(x - left), Float(inset)),
                sourceRect: SIMD4(0, 0, 1, 1), destSize: SIMD2(Float(width), Float(height)))))
        }
        gutterMarkFrames = frames
        return draws
    }

    /// Tints across the grid over marks that ask for one (a failed command's rows), drawn in
    /// the image pass under any inline image and clipped to the grid.
    private func rowTintDraws(_ marks: [GutterMark], colors: RenderState.Colors, metrics m: CellMetrics) -> [ImageDraw] {
        guard let grid, marks.contains(where: { $0.rowTint > 0 }) else { return [] }
        let width = Int(grid.cols) * m.cellWidth
        return marks.compactMap { mark in
            guard mark.rowTint > 0, mark.rows > 0,
                  let texture = gutterTextures.texture(mark.color(colors), opacity: mark.rowTint, device: renderer.device)
            else { return nil }
            return ImageDraw(texture: texture, vertex: ImageVertex(
                gridPos: SIMD2(0, Float(mark.row)), cellOffset: SIMD2(0, 0),
                sourceRect: SIMD4(0, 0, 1, 1), destSize: SIMD2(Float(width), Float(mark.rows * m.cellHeight))))
        }
    }

    /// The left padding beside the grid's rows in drawable pixels: stripes never draw over
    /// the cells or the top and bottom padding.
    private var gutterClip: MTLScissorRect? {
        guard let grid, pixelSize.width > 0 else { return nil }
        let y = max(0, Int(paddingPx.x))
        let width = min(Int(paddingPx.w), Int(pixelSize.width))
        let height = min(Int(grid.rows) * Int(grid.cellHeight), Int(pixelSize.height) - y)
        guard width > 0, height > 0 else { return nil }
        return MTLScissorRect(x: 0, y: y, width: width, height: height)
    }

    // MARK: Rendering

    /// Marks the terminal as changed. Safe to call from any thread; coalesces wakeups.
    public nonisolated func setNeedsRender() {
        guard !wakePending.exchange(true, ordering: .acquiringAndReleasing) else { return }
        Task { @MainActor in self.displayLink?.isPaused = false }
    }

    /// Forces a redraw of everything (resize, focus, scale changes).
    private func invalidate() {
        needsFullRender = true
        setNeedsRender()
    }

    /// Redraws with every row reused: only overlays changed.
    private func invalidateOverlay() {
        overlayDirty = true
        setNeedsRender()
    }

    fileprivate func tick(_ link: CADisplayLink) {
        wakePending.store(false, ordering: .releasing)
        let rendered = renderIfDirty()
        // Keep ticking while predictions wait for confirmation, so their timeouts fire, and while
        // a search is still working through the scrollback.
        if !rendered, !(predictor?.isActive ?? false), search?.status.isComplete ?? true { link.isPaused = true }
    }

    private func currentOverlay(cursor: RenderState.Cursor) -> FrameOverlay {
        var overlay = FrameOverlay()
        overlay.focused = isFocused
        overlay.cursorBlinkOn = cursorBlinkOn
        overlay.textBlinkOn = textBlinkOn
        overlay.hoveredLink = hoveredLink
        overlay.searchHighlights = searchHighlights()
        let cols = Int(grid?.cols ?? 1)

        if let predictor, terminal.viewportAtBottom {
            if outputPending.exchange(false, ordering: .acquiringAndReleasing) {
                predictor.reconcile(screen: terminal, outputArrived: true)
            } else if predictor.isActive {
                predictor.reconcile(screen: terminal, outputArrived: false)
            }
            for cell in predictor.overlay {
                overlay.cells.append(OverlayCell(x: cell.x, y: cell.y, text: cell.text, span: 1, underline: cell.underlined ? .single : .none))
            }
            if let p = predictor.predictedCursor { overlay.cursorOverride = GridPoint(x: p.x, y: p.y) }
        }

        if let preedit, !preedit.text.isEmpty, let position = cursor.position {
            var x = Int(position.x)
            let y = Int(position.y)
            for character in preedit.text {
                let span = Self.isWide(character) ? 2 : 1
                guard x + span <= cols else { break }
                overlay.cells.append(OverlayCell(x: x, y: y, text: String(character), span: span, underline: .single))
                x += span
            }
            overlay.cursorOverride = GridPoint(x: min(x, cols - 1), y: y)
            overlay.barCursor = true
        }
        return overlay
    }

    /// East Asian wide and emoji presentation characters take two cells (preedit only; the grid
    /// uses libghostty-vt's widths).
    static func isWide(_ character: Character) -> Bool {
        guard let v = character.unicodeScalars.first?.value else { return false }
        if character.unicodeScalars.count > 1, character.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) { return true }
        return (0x1100...0x115F).contains(v) || (0x2E80...0x303E).contains(v) || (0x3041...0x33FF).contains(v)
            || (0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v) || (0xA000...0xA4CF).contains(v)
            || (0xAC00...0xD7A3).contains(v) || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v)
            || (0xFF00...0xFF60).contains(v) || (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1F64F).contains(v)
            || (0x1F900...0x1F9FF).contains(v) || (0x20000...0x3FFFD).contains(v)
    }

    /// Snapshots the terminal and, if anything changed, rebuilds dirty rows and presents a frame.
    /// Returns false when the frame was clean (the display link uses this to go idle).
    /// - Parameter offscreen: draw into an offscreen texture instead of a layer drawable (headless
    ///   benchmarks; a layer that is not on screen hands out drawables at an arbitrary cadence).
    @discardableResult
    public func renderIfDirty(offscreen: Bool = false) -> Bool {
        guard let fonts, pixelSize.width > 0 else { return false }
        gpuReleased = false
        let start = CACurrentMediaTime()
        scheduleAnimationFrame(terminal.tickKittyAnimations(nowMs: Self.nowMs()))
        state.update(from: terminal)
        let cursor = state.cursor
        let overlay = currentOverlay(cursor: cursor)
        let overlayChanged = overlay != lastOverlay || overlayDirty
        let images = inlineImages?() ?? []
        let imagesChanged = imagesDirty || images != lastImages
        let marks = gutterMarks?() ?? []
        let marksChanged = marksDirty || marks != lastMarks
        let kittyChanged = refreshKittyImages(full: state.dirty == .full || needsFullRender)
        guard state.dirty != .clean || needsFullRender || overlayChanged || imagesChanged || marksChanged || kittyChanged
        else { return false }
        if cursor.blinking != cursorBlinks {
            cursorBlinks = cursor.blinking
            restartBlink()
        }
        let rows = builder.build(state, fonts: fonts, overlay: overlay, into: &frame)
        if builder.hasBlinkingText, blinkTask == nil { restartBlink() }
        cursorRect = cursorRect(cursor, metrics: fonts.metrics)
        state.markClean()
        needsFullRender = false
        overlayDirty = false
        lastOverlay = overlay
        lastImages = images
        imagesDirty = false
        kittyDraws = kittyImageDraws(metrics: fonts.metrics)
        let draws = rowTintDraws(marks, colors: state.colors, metrics: fonts.metrics) + kittyDraws.aboveText
            + (images.isEmpty && inlineImageFrames.isEmpty ? [] : imageDraws(images, metrics: fonts.metrics))
        lastMarks = marks
        marksDirty = false
        let stripes = marks.isEmpty && gutterMarkFrames.isEmpty ? [] : gutterDraws(marks, colors: state.colors, metrics: fonts.metrics)
        let built = CACurrentMediaTime()

        let stats = stats
        let drawable = offscreen ? nil : layer.nextDrawable()
        if let target = drawable?.texture ?? (offscreen ? offscreenTarget() : nil) {
            renderer.draw(
                frame, uniforms: uniforms(fonts.metrics), fonts: fonts, to: target, present: drawable,
                belowBackground: kittyDraws.belowBackground, belowText: kittyDraws.belowText, images: draws, imageClip: imageClip, gutter: stripes, gutterClip: gutterClip
            ) {
                stats.recordGPU(seconds: $0)
            }
        }
        let encoded = CACurrentMediaTime()
        stats.recordFrame(at: encoded, build: built - start, encode: encoded - built, rows: rows, instances: frame.text.count)
        onFrameRendered?()
        return true
    }

    // MARK: Blink

    /// Shows the cursor and restarts its blink cycle (on input and focus changes, as Ghostty
    /// does), running the timer only while something can blink.
    private func restartBlink() {
        blinkTask?.cancel()
        blinkTask = nil
        if !cursorBlinkOn || !textBlinkOn {
            cursorBlinkOn = true
            invalidateOverlay()
        }
        guard displayLink != nil, appearance.cursorBlinkInterval > 0 else { return }
        let interval = appearance.cursorBlinkInterval
        blinkTask = Task { [weak self] in
            while !Task.isCancelled {
                guard (try? await Task.sleep(for: .seconds(interval))) != nil, let self else { return }
                let cursorBlinks = self.isFocused && self.cursorBlinks
                let textBlinks = self.builderHasBlinkingText
                guard cursorBlinks || textBlinks || !self.cursorBlinkOn || !self.textBlinkOn else {
                    self.blinkTask = nil
                    return
                }
                self.cursorBlinkOn = cursorBlinks ? !self.cursorBlinkOn : true
                self.textBlinkOn = textBlinks ? !self.textBlinkOn : true
                self.invalidateOverlay()
            }
        }
    }

    /// Whether the last frame had SGR 5 text.
    private var builderHasBlinkingText: Bool { builder.hasBlinkingText }

    // MARK: Off screen

    /// Frees what a surface that is not on screen does not need: the layer and its drawables
    /// (the bulk: up to three frames of the pane's pixels, plus the one it shows), the
    /// per-frame GPU buffers, the offscreen target and the built frame. The terminal and the
    /// shared glyph atlases stay, so the next frame rebuilds everything at once.
    public func releaseGPUResources() {
        guard !gpuReleased, pixelSize.width > 0 else { return }
        gpuReleased = true
        let old = layer
        let fresh = CAMetalLayer()
        configure(fresh)
        fresh.contentsScale = old.contentsScale
        fresh.frame = old.frame
        #if os(macOS)
        fresh.autoresizingMask = old.autoresizingMask
        #endif
        fresh.drawableSize = pixelSize
        layer = fresh
        onLayerReplaced?(old, fresh)
        previousDrawableSize = .zero
        renderer.releaseBuffers()
        offscreenTexture = nil
        frame = FrameContents()
        builder = FrameBuilder()
        builder.style = Self.frameStyle(appearance)
        needsFullRender = true
    }

    // MARK: Snapshots

    /// Renders the last built frame into an offscreen texture and returns it as an image (Display
    /// P3, like the layer). Works without a window, for tests and headless captures.
    public func snapshot() -> CGImage? {
        guard let fonts, let texture = offscreenTarget() else { return nil }
        let done = DispatchSemaphore(value: 0)
        let draws = rowTintDraws(lastMarks, colors: state.colors, metrics: fonts.metrics) + kittyDraws.aboveText
            + (lastImages.isEmpty ? [] : imageDraws(lastImages, metrics: fonts.metrics))
        let stripes = lastMarks.isEmpty ? [] : gutterDraws(lastMarks, colors: state.colors, metrics: fonts.metrics)
        renderer.draw(
            frame, uniforms: uniforms(fonts.metrics), fonts: fonts, to: texture, present: nil,
            belowBackground: kittyDraws.belowBackground, belowText: kittyDraws.belowText, images: draws, imageClip: imageClip,
            gutter: stripes, gutterClip: gutterClip
        ) { _ in done.signal() }
        done.wait()

        let width = texture.width, height = texture.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: layer.colorspace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private func cursorRect(_ cursor: RenderState.Cursor, metrics m: CellMetrics) -> CGRect? {
        guard cursor.visible, let position = cursor.position else { return nil }
        let scale = layer.contentsScale
        let x = Int(position.x) - (cursor.onWideTail ? 1 : 0)
        // paddingPx is (top, right, bottom, left), as in Ghostty's uniforms.
        return CGRect(
            x: (CGFloat(paddingPx.w) + CGFloat(x * m.cellWidth)) / scale,
            y: (CGFloat(paddingPx.x) + CGFloat(Int(position.y) * m.cellHeight)) / scale,
            width: CGFloat(m.cellWidth) / scale,
            height: CGFloat(m.cellHeight) / scale)
    }

    private func offscreenTarget() -> MTLTexture? {
        let width = Int(pixelSize.width), height = Int(pixelSize.height)
        guard width > 0 else { return nil }
        if let texture = offscreenTexture, texture.width == width, texture.height == height { return texture }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalRenderer.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        offscreenTexture = renderer.device.makeTexture(descriptor: descriptor)
        return offscreenTexture
    }

    private func uniforms(_ m: CellMetrics) -> Uniforms {
        let screen = SIMD2(Float(pixelSize.width), Float(pixelSize.height))
        let cursor = frame.blockCursor
        return Uniforms(
            projectionMatrix: Uniforms.projection(screen: screen, padding: paddingPx),
            screenSize: screen,
            cellSize: SIMD2(Float(m.cellWidth), Float(m.cellHeight)),
            gridSize: SIMD2(UInt16(frame.cols), UInt16(frame.rows)),
            gridPadding: paddingPx,
            paddingExtend: 0,
            minContrast: 1,
            cursorPos: cursor?.pos ?? SIMD2(.max, .max),
            cursorColor: cursor?.textColor ?? .zero,
            bgColor: frame.background,
            cursorWide: cursor?.wide ?? false,
            useDisplayP3: false,
            useLinearBlending: false,
            useLinearCorrection: false)
    }
}

/// `CADisplayLink` needs an Objective-C target; this forwards to the surface without retaining it.
@MainActor
private final class DisplayLinkTarget: NSObject {
    weak var surface: TerminalSurface?

    init(surface: TerminalSurface) {
        self.surface = surface
    }

    @objc func tick(_ link: CADisplayLink) {
        surface?.tick(link)
    }
}
