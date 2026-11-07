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
            // An equal assignment would still throw away every cached row.
            guard appearance != oldValue else { return }
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
    private(set) var kittyTextures: [UInt32: KittyTexture] = [:]
    private var kittyGenerations: (placements: UInt64, storage: UInt64)?
    private var kittyDraws = KittyDraws()
    /// The kitty images the last frame drew and their visible part in view points, in drawing
    /// order (topmost last): what a drag lifts and VoiceOver finds.
    public private(set) var kittyImageFrames: [(placement: ImagePlacement, rect: CGRect)] = []
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
        // A held frame (`Motion`) larger than the view is cropped, not drawn past its edges.
        layer.masksToBounds = true
        #if os(iOS)
        // Top-left as seen: a UIKit layer's y axis points down, gravity's up.
        layer.contentsGravity = .bottomLeft
        #endif
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

    private static func frameStyle(_ appearance: TerminalAppearance) -> FrameStyle {
        FrameStyle(
            selectionBackground: appearance.selectionBackground, selectionForeground: appearance.selectionForeground,
            faintAlpha: UInt8(clamping: Int((appearance.faintOpacity * 255).rounded())),
            search: SearchColors(
                background: appearance.searchBackground, foreground: appearance.searchForeground,
                selectedBackground: appearance.searchSelectedBackground, selectedForeground: appearance.searchSelectedForeground))
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
    /// local grid stays anchored top-left, without reflow. A stream-sized grid that differs
    /// from the requested size scales down to fit and is centered on the terminal background.
    /// A view in a layout motion
    /// (`prepareResize`, `holdFrames`) does not even redraw: it shows its last frame.
    public func layout(size: CGSize, scale requestedScale: CGFloat) {
        lastLayout = (size, requestedScale)
        let scale = Self.drawableScale(for: size, scale: requestedScale)
        if fonts == nil || layer.contentsScale != scale {
            layer.contentsScale = scale
            fonts = FontGrid.shared(pixelSize: appearance.fontSize * scale, family: appearance.fontFamily)
            builder = FrameBuilder()
            builder.style = Self.frameStyle(appearance)
            // New cells: the frame on screen no longer stands for anything.
            motion = nil
            motionTask?.cancel()
            motionTask = nil
        }
        guard fonts != nil else { return }
        let newPixelSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        if motion == nil, ContinuousClock.now < Self.frameHoldUntil, grid != nil, pixelSize.width > 0, newPixelSize != pixelSize {
            motionPixelSize = pixelSize
            motion = Motion(target: nil, deadline: Self.frameHoldUntil)
            scheduleMotionEnd()
        }
        if var motion {
            // In motion: the last frame stays, anchored top-left, until the view arrives.
            if newPixelSize != motionPixelSize { lastSizeChange = .now }
            motionPixelSize = newPixelSize
            if motion.arrived == nil, let target = motion.target, Self.isClose(newPixelSize, target, scale: scale) {
                motion.arrived = .now
                self.motion = motion
            }
            return
        }
        if newPixelSize != pixelSize { lastSizeChange = .now }
        pixelSize = newPixelSize
        layer.drawableSize = pixelSize

        guard let target = gridFitting(pixelSize) else { return }

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

    /// Metal's texture limit: `CAMetalLayer` hands out no drawable past it, so the pane would
    /// stay blank.
    static let maxDrawableSide: CGFloat = 16384

    /// The display scale, lowered in quarter steps for a view so large (a window spanning
    /// displays) that its drawable would pass `maxDrawableSide`: it draws softer, not blank.
    static func drawableScale(for size: CGSize, scale: CGFloat) -> CGFloat {
        let side = max(size.width, size.height)
        guard side * scale > maxDrawableSide else { return scale }
        return max(0.25, ((maxDrawableSide / side) * 4).rounded(.down) / 4)
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
            self.invalidate()
        }
    }

    private func commitGrid(_ newGrid: Grid, in pixels: CGSize? = nil) {
        pendingGrid = nil
        pendingIsHeld = false
        gridCommitTask?.cancel()
        gridCommitTask = nil
        // The first grid is a starting point, not a step of a resize: the next may follow at once.
        if grid != nil { lastGridCommit = .now }
        let changed = newGrid != grid
        grid = newGrid
        updateInset(for: newGrid, in: pixels ?? pixelSize)
        guard changed else { return }
        if !sizeFollowsStream {
            terminal.resize(cols: newGrid.cols, rows: newGrid.rows, cellWidth: newGrid.cellWidth, cellHeight: newGrid.cellHeight)
        }
        predictor?.reset()
        onGridChange?(newGrid)
    }

    /// The whole cells that fit a drawable of `pixels`, the remainder becoming padding.
    private func gridFitting(_ pixels: CGSize) -> Grid? {
        guard let metrics = fonts?.metrics else { return nil }
        let pad = Int((appearance.padding * layer.contentsScale).rounded())
        let cols = max(1, (Int(pixels.width) - 2 * pad) / metrics.cellWidth)
        let rows = max(1, (Int(pixels.height) - 2 * pad) / metrics.cellHeight)
        return Grid(cols: UInt16(cols), rows: UInt16(rows), cellWidth: UInt32(metrics.cellWidth), cellHeight: UInt32(metrics.cellHeight))
    }

    /// `window-padding-balance`: split the space left over after whole cells evenly, so the grid
    /// sits centered instead of hugging the top-left edge.
    private func updateInset(for grid: Grid, in pixels: CGSize? = nil) {
        let pixels = pixels ?? pixelSize
        let pad = Int((appearance.padding * layer.contentsScale).rounded())
        guard appearance.paddingBalance else { return gridInset = SIMD2(pad, pad) }
        let extraX = Int(pixels.width) - 2 * pad - Int(grid.cols) * Int(grid.cellWidth)
        let extraY = Int(pixels.height) - 2 * pad - Int(grid.rows) * Int(grid.cellHeight)
        gridInset = SIMD2(pad + max(0, extraX) / 2, pad + max(0, extraY) / 2)
    }

    // MARK: Layout motion

    /// A view carried to a new size by an animated layout change (a split, a close, a zoom, a
    /// drop, the sidebar). Drawn at every size on the way, it would reallocate its drawable
    /// and redraw every frame, and the program's redraw for its new size would land after it
    /// stopped. Instead it shows its last frame, anchored top-left (cropped as it shrinks, on
    /// its background as it grows), its grid changes once for where it is going while nothing
    /// new is shown, and the next frame it draws is the program's at the new size.
    private struct Motion {
        /// Where the view is going, in pixels (nil: wherever it settles).
        var target: CGSize?
        /// When it should be there.
        var deadline: ContinuousClock.Instant
        /// When it got there.
        var arrived: ContinuousClock.Instant?
        /// The grid already changed for the target: nothing is drawn until the end.
        var regridded = false
        /// Output seen while waiting for the program's redraw, and since when it has been quiet.
        var outputSeen: UInt64 = 0
        var quietSince = ContinuousClock.now
    }

    private var motion: Motion?
    private var motionTask: Task<Void, Never>?
    /// The view's size in pixels while in motion (the drawable keeps the last frame's).
    private var motionPixelSize = CGSize.zero
    private nonisolated let outputSerial = Atomic<UInt64>(0)
    static var frameHoldUntil = ContinuousClock.now

    /// Close enough to count as there: a spring's last moves are under a pixel each.
    static let arrivalTolerance: CGFloat = 1.5
    /// How long the program's output must pause after a resize to count as redrawn, and how
    /// long a view that arrived waits for that at most.
    static let redrawQuiet = Duration.milliseconds(30)
    static let redrawWait = Duration.milliseconds(150)

    /// Holds the frames of views resized during `duration`, for an animation whose end size only
    /// the layout knows (the sidebar): each shows its last frame until it settles, then changes
    /// its grid once and draws again when the program has redrawn.
    public static func holdFrames(for duration: Duration) {
        frameHoldUntil = max(frameHoldUntil, .now + duration)
    }

    /// An animated layout change takes this view to `size` (points) within `duration`. The grid
    /// changes now, once, so the program gets one SIGWINCH and redraws while the view shows its
    /// last frame; it draws again once it is there and that redraw has come in. A view already
    /// at `size` only waits for the redraw.
    public func prepareResize(to size: CGSize, within duration: Duration) {
        guard let lastLayout, fonts != nil, grid != nil else { return }
        let scale = Self.drawableScale(for: size, scale: lastLayout.scale)
        guard scale == layer.contentsScale else { return }
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let here = CGSize(width: (lastLayout.size.width * scale).rounded(), height: (lastLayout.size.height * scale).rounded())
        guard let newGrid = gridFitting(target) else { return }
        let regrid = newGrid != grid
        let arrived = Self.isClose(here, target, scale: scale)
        if motion == nil, !regrid, arrived, here == pixelSize { return }
        var next = motion ?? Motion(target: target, deadline: .now + duration)
        if motion == nil { motionPixelSize = pixelSize }
        next.target = target
        next.deadline = .now + duration
        next.arrived = arrived ? .now : nil
        next.regridded = next.regridded || regrid
        next.outputSeen = outputSerial.load(ordering: .acquiring)
        next.quietSince = .now
        motion = next
        if regrid { commitGrid(newGrid, in: target) }
        scheduleMotionEnd()
    }

    /// Shows the last frame while the view is moved about with no known end (a dragged pane's
    /// preview of a drop), until `prepareResize` says where it lands. The grid keeps its size.
    public func holdFrame() {
        guard motion == nil, grid != nil else { return }
        motionPixelSize = pixelSize
        motion = Motion(target: nil, deadline: .now + .seconds(30))
        scheduleMotionEnd()
    }

    /// The frame on screen stands in for a view in motion: nothing new is drawn.
    private var showsHeldFrame: Bool {
        guard let motion else { return false }
        return motion.regridded || motionPixelSize != pixelSize
    }

    private static func isClose(_ lhs: CGSize, _ rhs: CGSize, scale: CGFloat) -> Bool {
        let tolerance = arrivalTolerance * scale
        return abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
    }

    private func scheduleMotionEnd() {
        guard motionTask == nil else { return }
        motionTask = Task { [weak self] in
            while let self, self.motion != nil, !Task.isCancelled {
                if self.stepMotion() { return }
                try? await Task.sleep(for: .milliseconds(8))
            }
            if !Task.isCancelled { self?.motionTask = nil }
        }
    }

    /// Moves the motion along; true once it is over.
    private func stepMotion() -> Bool {
        guard var motion, let lastLayout else { return finishMotion() }
        let now = ContinuousClock.now
        guard motion.target != nil else {
            // Settled where the layout put it: from here on, a resize to that size.
            guard now >= motion.deadline, now >= lastSizeChange + Self.settleInterval else { return false }
            motionTask = nil
            prepareResize(to: lastLayout.size, within: .zero)
            if self.motion?.target == nil { finishMotion() }
            return true
        }
        let output = outputSerial.load(ordering: .acquiring)
        if output != motion.outputSeen {
            motion.outputSeen = output
            motion.quietSince = now
        }
        if motion.arrived == nil, now >= motion.deadline { motion.arrived = now }
        self.motion = motion
        guard let arrived = motion.arrived else { return false }
        // A remote pane's terminal takes its new size when its stream says so.
        let caughtUp = !sizeFollowsStream || grid.map { terminal.size.cols == Int($0.cols) && terminal.size.rows == Int($0.rows) } ?? true
        let redrawn = !motion.regridded || (caughtUp && now >= motion.quietSince + Self.redrawQuiet)
        guard redrawn || now >= arrived + Self.redrawWait else { return false }
        return finishMotion()
    }

    /// Back to drawing, at the size the view has now.
    @discardableResult
    private func finishMotion() -> Bool {
        motion = nil
        motionTask = nil
        if let lastLayout {
            needsFullRender = true
            layout(size: lastLayout.size, scale: lastLayout.scale)
        }
        return true
    }

    /// The view shows a held frame in place of new ones (tests).
    public var isHoldingFrame: Bool { showsHeldFrame }

    private var drawingGrid: Grid? {
        guard let grid, sizeFollowsStream else { return grid }
        let size = terminal.size
        return Grid(cols: UInt16(clamping: size.cols), rows: UInt16(clamping: size.rows),
                    cellWidth: grid.cellWidth, cellHeight: grid.cellHeight)
    }

    private var gridFit: GridFit {
        guard sizeFollowsStream, let grid, let drawingGrid,
              grid.cols != drawingGrid.cols || grid.rows != drawingGrid.rows else {
            return GridFit(scale: 1, origin: CGPoint(x: gridInset.x, y: gridInset.y))
        }
        return GridFit.fit(
            CGSize(width: Int(drawingGrid.cols) * Int(drawingGrid.cellWidth),
                   height: Int(drawingGrid.rows) * Int(drawingGrid.cellHeight)),
            in: pixelSize, padding: appearance.padding * layer.contentsScale)
    }

    private var drawingScale: CGFloat { layer.contentsScale / gridFit.scale }

    private var paddingPx: SIMD4<Float> {
        guard let grid = drawingGrid else { return .zero }
        let fit = gridFit
        let x = fit.origin.x / fit.scale, y = fit.origin.y / fit.scale
        return SIMD4(Float(y), Float(max(0, pixelSize.width / fit.scale - x - CGFloat(grid.cols) * CGFloat(grid.cellWidth))),
                     Float(max(0, pixelSize.height / fit.scale - y - CGFloat(grid.rows) * CGFloat(grid.cellHeight))), Float(x))
    }

    /// The grid the view's size calls for while the applied one waits (nil: none waits).
    public var pendingGridSize: Grid? { pendingGrid }

    private var previousDrawableSize = CGSize.zero

    /// One cell in points (nil before the first layout).
    public var cellSize: CGSize? {
        guard let grid else { return nil }
        let scale = drawingScale
        return CGSize(width: CGFloat(grid.cellWidth) / scale, height: CGFloat(grid.cellHeight) / scale)
    }

    /// Fixed (top/left) padding in points.
    public var paddingPoints: CGFloat { CGFloat(paddingPx.x) / drawingScale }
    /// The grid's origin in points (differs from `paddingPoints` with padding balance).
    private var gridOrigin: CGPoint {
        CGPoint(x: CGFloat(paddingPx.w) / drawingScale, y: CGFloat(paddingPx.x) / drawingScale)
    }

    /// The viewport cell under a point in view coordinates, clamped into the grid.
    public func cell(at point: CGPoint) -> GridPoint {
        guard let grid = drawingGrid, let size = cellSize else { return GridPoint(x: 0, y: 0) }
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
        (Double(point.x * drawingScale), Double(point.y * drawingScale))
    }

    public var mouseGeometry: MouseGeometry {
        let grid = drawingGrid ?? Grid(cols: 1, rows: 1, cellWidth: 1, cellHeight: 1)
        return MouseGeometry(
            screenWidth: UInt32(clamping: Int(pixelSize.width / gridFit.scale)),
            screenHeight: UInt32(clamping: Int(pixelSize.height / gridFit.scale)),
            cellWidth: grid.cellWidth, cellHeight: grid.cellHeight,
            paddingTop: UInt32(paddingPx.x), paddingRight: UInt32(paddingPx.y),
            paddingBottom: UInt32(paddingPx.z), paddingLeft: UInt32(paddingPx.w))
    }

    public var selectionGeometry: SelectionGesture.Geometry {
        let grid = drawingGrid ?? Grid(cols: 1, rows: 1, cellWidth: 1, cellHeight: 1)
        return SelectionGesture.Geometry(
            columns: UInt32(grid.cols), cellWidth: grid.cellWidth, paddingLeft: UInt32(paddingPx.w),
            screenHeight: UInt32(clamping: Int(pixelSize.height / gridFit.scale)))
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
        outputSerial.add(1, ordering: .releasing)
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
        guard let search, let grid = drawingGrid else { return [] }
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

    private func imageDraws(_ placements: [InlineImagePlacement], metrics: CellMetrics) -> [ImageDraw] {
        var draws: [ImageDraw] = []
        var frames: [(placement: InlineImagePlacement, rect: CGRect)] = []
        let gridRows = Int(drawingGrid?.rows ?? 0)
        let scale = drawingScale
        for placement in placements {
            guard let texture = imageTextures[placement.key], placement.cols > 0, placement.rows > 0, placement.row + placement.rows > 0, placement.row < gridRows else { continue }
            let size = SIMD2(Float(placement.cols * metrics.cellWidth), Float(placement.rows * metrics.cellHeight))
            draws.append(ImageDraw(texture: texture, vertex: ImageVertex(
                gridPos: SIMD2(Float(placement.col), Float(placement.row)), cellOffset: .zero,
                sourceRect: SIMD4(0, 0, Float(texture.width), Float(texture.height)), destSize: size)))
            frames.append((placement, CGRect(
                x: (CGFloat(paddingPx.w) + CGFloat(placement.col * metrics.cellWidth)) / scale,
                y: (CGFloat(paddingPx.x) + CGFloat(placement.row * metrics.cellHeight)) / scale,
                width: CGFloat(size.x) / scale, height: CGFloat(size.y) / scale)))
        }
        inlineImageFrames = frames
        return draws
    }

    /// The grid area in drawable pixels: images never draw into the padding.
    private var imageClip: MTLScissorRect? {
        guard let grid = drawingGrid, pixelSize.width > 0 else { return nil }
        let scale = gridFit.scale
        let x = max(0, Int(CGFloat(paddingPx.w) * scale)), y = max(0, Int(CGFloat(paddingPx.x) * scale))
        let width = min(Int((CGFloat(grid.cols) * CGFloat(grid.cellWidth) * scale).rounded(.up)), Int(pixelSize.width) - x)
        let height = min(Int((CGFloat(grid.rows) * CGFloat(grid.cellHeight) * scale).rounded(.up)), Int(pixelSize.height) - y)
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
        for placement in placements {
            shown.insert(placement.imageID)
            guard kittyTextures[placement.imageID]?.generation != placement.generation else { continue }
            // Pixels still on the way (after a restore) or replaced since the update: the
            // image appears, at its final size, once a later frame finds them.
            guard let pixels = terminal.kittyImage(id: placement.imageID), pixels.generation == placement.generation,
                  let texture = KittyTexture(pixels, renderer: renderer)
            else { continue }
            kittyTextures[placement.imageID] = texture
        }
        kittyTextures = kittyTextures.filter { shown.contains($0.key) }
        return changed || full
    }

    /// The placements as quads in their layers, lowest z first, scaled from the terminal's cell
    /// pixels to the renderer's (a remote pane lays images out in the host's cells).
    private func kittyImageDraws(metrics: CellMetrics) -> KittyDraws {
        var draws = KittyDraws()
        kittyImageFrames = []
        guard !kittyPlacements.isEmpty, let grid = drawingGrid else { return draws }
        let vtCell = terminal.cellPixelSize
        guard vtCell.width > 0, vtCell.height > 0 else { return draws }
        let sx = Float(metrics.cellWidth) / Float(vtCell.width), sy = Float(metrics.cellHeight) / Float(vtCell.height)
        let sorted = kittyPlacements.sorted { ($0.layer, $0.z) < ($1.layer, $1.z) }
        let scale = drawingScale
        let gridRect = CGRect(
            x: CGFloat(paddingPx.w), y: CGFloat(paddingPx.x),
            width: CGFloat(Int(grid.cols) * metrics.cellWidth), height: CGFloat(Int(grid.rows) * metrics.cellHeight))
        for placement in sorted {
            guard let image = kittyTextures[placement.imageID], image.generation == placement.generation else { continue }
            let top = Float(placement.row) * Float(metrics.cellHeight) + Float(placement.offsetY) * sy
            let height = Float(placement.height) * sy
            guard top + height > 0, top < Float(Int(grid.rows) * metrics.cellHeight) else { continue }
            let left = Float(placement.col) * Float(metrics.cellWidth) + Float(placement.offsetX) * sx
            let drawn = CGRect(
                x: gridRect.minX + CGFloat(left), y: gridRect.minY + CGFloat(top),
                width: CGFloat(Float(placement.width) * sx), height: CGFloat(height)).intersection(gridRect)
            if !drawn.isNull, !drawn.isEmpty {
                kittyImageFrames.append((placement, CGRect(
                    x: drawn.minX / scale, y: drawn.minY / scale, width: drawn.width / scale, height: drawn.height / scale)))
            }
            let imageScale = image.scale
            let draw = ImageDraw(texture: image.texture, vertex: ImageVertex(
                gridPos: SIMD2(Float(placement.col), Float(placement.row)),
                cellOffset: SIMD2(Float(placement.offsetX) * sx, Float(placement.offsetY) * sy),
                sourceRect: SIMD4(Float(placement.sourceX) * imageScale, Float(placement.sourceY) * imageScale, Float(placement.sourceWidth) * imageScale, Float(placement.sourceHeight) * imageScale),
                destSize: SIMD2(Float(placement.width) * sx, height)))
            switch placement.layer {
            case .belowBackground: draws.belowBackground.append(draw)
            case .belowText: draws.belowText.append(draw)
            case .aboveText: draws.aboveText.append(draw)
            }
        }
        return draws
    }

    /// The topmost kitty image the last frame drew under `point` (view points).
    public func kittyImage(at point: CGPoint) -> (placement: ImagePlacement, rect: CGRect)? {
        kittyImageFrames.last { $0.rect.contains(point) }
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

    private func gutterDraws(_ marks: [GutterMark], colors: RenderState.Colors, metrics: CellMetrics) -> [ImageDraw] {
        var draws: [ImageDraw] = []
        var frames: [(mark: GutterMark, rect: CGRect)] = []
        let gridRows = Int(drawingGrid?.rows ?? 0)
        let scale = layer.contentsScale
        let left = Int(paddingPx.w)
        let width = Self.gutterWidth(paddingLeft: left, scale: scale)
        // Right-aligned towards the text with 2 pt of air when the padding allows, else at
        // the pane's edge.
        let x = max(0, left - width - Int((2 * scale).rounded()))
        let inset = Self.gutterInset(cellHeight: metrics.cellHeight, scale: scale)
        for mark in marks {
            let top = max(mark.row, 0), bottom = min(mark.row + mark.rows, gridRows)
            guard mark.rows > 0, bottom > top else { continue }
            frames.append((mark, CGRect(
                x: 0, y: (CGFloat(paddingPx.x) + CGFloat(top * metrics.cellHeight)) / drawingScale,
                width: pixelSize.width / scale, height: CGFloat((bottom - top) * metrics.cellHeight) / drawingScale)))
            guard let texture = gutterTextures.texture(mark.color(colors), opacity: mark.opacity, device: renderer.device) else { continue }
            // The whole stripe (its ends may be off screen; the clip trims them).
            let height = mark.rows * metrics.cellHeight - 2 * inset
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
    private func rowTintDraws(_ marks: [GutterMark], colors: RenderState.Colors, metrics: CellMetrics) -> [ImageDraw] {
        guard let grid = drawingGrid, marks.contains(where: { $0.rowTint > 0 }) else { return [] }
        let width = Int(grid.cols) * metrics.cellWidth
        return marks.compactMap { mark in
            guard mark.rowTint > 0, mark.rows > 0,
                  let texture = gutterTextures.texture(mark.color(colors), opacity: mark.rowTint, device: renderer.device)
            else { return nil }
            return ImageDraw(texture: texture, vertex: ImageVertex(
                gridPos: SIMD2(0, Float(mark.row)), cellOffset: SIMD2(0, 0),
                sourceRect: SIMD4(0, 0, 1, 1), destSize: SIMD2(Float(width), Float(mark.rows * metrics.cellHeight))))
        }
    }

    /// The left padding beside the grid's rows in drawable pixels: stripes never draw over
    /// the cells or the top and bottom padding.
    private var gutterClip: MTLScissorRect? {
        guard let grid = drawingGrid, pixelSize.width > 0 else { return nil }
        let scale = gridFit.scale
        let y = max(0, Int(CGFloat(paddingPx.x) * scale))
        let width = min(Int(CGFloat(paddingPx.w) * scale), Int(pixelSize.width))
        let height = min(Int((CGFloat(grid.rows) * CGFloat(grid.cellHeight) * scale).rounded(.up)), Int(pixelSize.height) - y)
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

    /// Main-thread time shared by every surface's display-link frames.
    static var renderBudget = RenderBudget()

    fileprivate func tick(_ link: CADisplayLink) {
        // Over budget: stay dirty and try again on a later tick.
        guard Self.renderBudget.mayRender(focused: isFocused, now: CACurrentMediaTime()) else { return }
        wakePending.store(false, ordering: .releasing)
        if terminal.releaseExpiredHeldOutput() { outputArrived() }
        let start = CACurrentMediaTime()
        let rendered = renderIfDirty()
        Self.renderBudget.spend(CACurrentMediaTime() - start)
        // Keep ticking while predictions wait for confirmation, so their timeouts fire, while a
        // search is still working through the scrollback, and while a synchronized update is
        // held, so it is shown when it times out.
        if !rendered, !(predictor?.isActive ?? false), search?.status.isComplete ?? true, !terminal.isHoldingOutput {
            link.isPaused = true
        }
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
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        if character.unicodeScalars.count > 1, character.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) { return true }
        return (0x1100...0x115F).contains(scalar) || (0x2E80...0x303E).contains(scalar) || (0x3041...0x33FF).contains(scalar)
            || (0x3400...0x4DBF).contains(scalar) || (0x4E00...0x9FFF).contains(scalar) || (0xA000...0xA4CF).contains(scalar)
            || (0xAC00...0xD7A3).contains(scalar) || (0xF900...0xFAFF).contains(scalar) || (0xFE30...0xFE4F).contains(scalar)
            || (0xFF00...0xFF60).contains(scalar) || (0xFFE0...0xFFE6).contains(scalar) || (0x1F300...0x1F64F).contains(scalar)
            || (0x1F900...0x1F9FF).contains(scalar) || (0x20000...0x3FFFD).contains(scalar)
    }

    /// Main-thread time per display frame that all surfaces together may spend rasterizing new
    /// glyphs; the rest appear over the next frames instead of stalling the UI (a screen of new
    /// emoji or CJK at a large size takes seconds to rasterize).
    static let rasterBudget: CFTimeInterval = 0.006
    private static var rasterWindowEnd: CFTimeInterval = 0
    private static var rasterWindowDeadline: CFTimeInterval = 0

    /// The rasterization deadline of the current display frame, shared by every surface that
    /// renders in it.
    private static func rasterDeadline() -> CFTimeInterval {
        let now = CACurrentMediaTime()
        if now >= rasterWindowEnd {
            rasterWindowDeadline = now + rasterBudget
            rasterWindowEnd = now + 1.0 / 60
        }
        return rasterWindowDeadline
    }

    /// Snapshots the terminal and, if anything changed, rebuilds dirty rows and presents a frame.
    /// Returns false when the frame was clean (the display link uses this to go idle).
    /// - Parameter offscreen: draw into an offscreen texture instead of a layer drawable (headless
    ///   benchmarks; a layer that is not on screen hands out drawables at an arbitrary cadence).
    @discardableResult
    public func renderIfDirty(offscreen: Bool = false) -> Bool {
        guard let fonts, pixelSize.width > 0, !showsHeldFrame else { return false }
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
            || builder.isIncomplete
        else { return false }
        if cursor.blinking != cursorBlinks {
            cursorBlinks = cursor.blinking
            restartBlink()
        }
        // Headless renders (snapshots, benchmarks) draw every glyph at once.
        fonts.rasterDeadline = offscreen ? .infinity : Self.rasterDeadline()
        let rows = builder.build(state, fonts: fonts, overlay: overlay, into: &frame)
        fonts.rasterDeadline = .infinity
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
    /// The last frame left glyphs for later frames.
    var builderIsIncomplete: Bool { builder.isIncomplete }

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
        // Up to the terminal's whole image storage again on the GPU; reloaded with the next frame.
        kittyTextures.removeAll()
        kittyGenerations = nil
        kittyDraws = KittyDraws()
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

    private func cursorRect(_ cursor: RenderState.Cursor, metrics: CellMetrics) -> CGRect? {
        guard cursor.visible, let position = cursor.position else { return nil }
        let scale = drawingScale
        let x = Int(position.x) - (cursor.onWideTail ? 1 : 0)
        // paddingPx is (top, right, bottom, left), as in Ghostty's uniforms.
        return CGRect(
            x: (CGFloat(paddingPx.w) + CGFloat(x * metrics.cellWidth)) / scale,
            y: (CGFloat(paddingPx.x) + CGFloat(Int(position.y) * metrics.cellHeight)) / scale,
            width: CGFloat(metrics.cellWidth) / scale,
            height: CGFloat(metrics.cellHeight) / scale)
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

    private func uniforms(_ metrics: CellMetrics) -> Uniforms {
        let scale = Float(gridFit.scale)
        let screen = SIMD2(Float(pixelSize.width), Float(pixelSize.height)) / scale
        let cursor = frame.blockCursor
        return Uniforms(
            projectionMatrix: Uniforms.projection(screen: screen, padding: paddingPx),
            screenSize: screen,
            cellSize: SIMD2(Float(metrics.cellWidth), Float(metrics.cellHeight)),
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
            useLinearCorrection: false, viewScale: scale)
    }
}

/// A token bucket of main-thread time for rendering, shared by all surfaces. Frames run on the
/// main thread, and a flood in a large grid or in many visible panes would otherwise take all of
/// it (a full 6K grid at a tiny font costs tens of ms per frame), leaving none for input and UI.
/// Rendering may use `share` of the time on average, in bursts up to `burst`; past that, panes
/// skip display-link frames (they drop frame rate, never content). The focused pane may run
/// further into debt, so it keeps priority over the others.
struct RenderBudget {
    var share = 0.5
    var burst: CFTimeInterval = 0.05
    private var tokens: CFTimeInterval = 0.05
    private var updated: CFTimeInterval?

    mutating func mayRender(focused: Bool, now: CFTimeInterval) -> Bool {
        if let updated { tokens = min(burst, tokens + max(0, now - updated) * share) }
        updated = now
        return tokens > (focused ? -burst : 0)
    }

    mutating func spend(_ seconds: CFTimeInterval) {
        tokens -= seconds
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
