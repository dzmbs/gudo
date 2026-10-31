import Foundation
import HostKit
import Observation
import PaneLayout
import TerminalCore
import TerminalRenderer
import os

/// One live terminal: the VT state, its renderer surface and host view, and the backend that feeds
/// it. The view is created once and moved between parents as the split tree changes, so a split,
/// zoom or tab switch never re-creates the surface or loses scrollback.
@Observable
final class Pane {
    let id: PaneId
    @ObservationIgnored let view: TerminalView
    /// SwiftUI host containers showing this pane (see `TerminalHost`).
    @ObservationIgnored let hosts = NSHashTable<TerminalHost.Container>.weakObjects()

    /// OSC 0/2 title ("" until the program sets one).
    private(set) var title = ""
    /// OSC 7 working directory, as a path ("" until the shell reports one).
    private(set) var workingDirectory = ""
    /// The pane's foreground program as the backend reports it (the daemon's `tcgetpgrp`); nil
    /// when the backend cannot tell (local backends), in which case the title stands in.
    private(set) var foregroundProgram: String?
    /// Live, or showing stale content while its host reconnects (dimmed, never blank: R12).
    private(set) var connection = PaneConnection.live
    /// Showing the screen this device saved last, until the host sends its own (instant start).
    private(set) var showsSavedScreen = false
    /// Input typed over the saved screen: held, then sent or dropped (`DaemonPaneBackend`).
    private(set) var heldInput: DaemonPaneBackend.HeldInputState?
    /// Held input was dropped: the host's screen was not the one it was typed at.
    @ObservationIgnored var onHeldInputDropped: (() -> Void)?
    /// Called on the main actor after `title` or `foregroundProgram` change.
    @ObservationIgnored var onContextChange: (() -> Void)?
    /// BEL from the program (after the view's own haptic or sound).
    @ObservationIgnored var onBell: (() -> Void)?
    /// The cell size in points after a layout (split sizes snap to it).
    @ObservationIgnored var onCellSize: ((CGSize) -> Void)?
    /// Whether this pane is its tab's focused pane on screen (set by `Workspace`).
    @ObservationIgnored var isFocusedPane: () -> Bool = { false }

    @ObservationIgnored let backend: any PaneBackend
    /// Grid changes, for the cols × rows overlay.
    @ObservationIgnored var onGridChange: ((TerminalSurface.Grid) -> Void)?
    /// Resizes sent to the backend (UI tests: one per layout change).
    private(set) var resizesSent = 0
    /// Scrolls and input so far, whoever made them: following tells its own from the user's.
    @ObservationIgnored private(set) var moves = 0

    nonisolated static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "pane")
    /// `showsSavedScreen` for the stream's thread.
    nonisolated private let savedScreenShown = OSAllocatedUnfairLock(initialState: false)
    /// Bumped by every output and snapshot: whether the screen may have changed since the
    /// workspace was last saved (`WorkspaceCacheWriter`).
    nonisolated let outputGeneration = OSAllocatedUnfairLock(initialState: 0)
    /// The grid's cell size in pixels, for resizes that follow the stream (off the main actor).
    nonisolated let cellPixels = OSAllocatedUnfairLock<(width: UInt32, height: UInt32)>(initialState: (0, 0))

    /// - Parameter saved: the pane's saved screen (instant start), drawn until the host's
    ///   arrives; input typed over it waits for that.
    init(
        id: PaneId, backend: any PaneBackend, appearance: TerminalAppearance = .init(), saved: CachedPane? = nil,
        onExit: @escaping @Sendable () -> Void
    ) throws {
        self.id = id
        self.backend = backend
        let terminal = Terminal(cols: 80, rows: 24, configuration: appearance.terminalConfiguration) { backend.write($0) }
        let surface = try TerminalSurface(terminal: terminal, appearance: appearance)
        view = TerminalView(surface: surface)
        view.onInput = { [weak self] bytes in
            self?.moves += 1
            bytes.withUnsafeBytes { backend.write($0) }
        }
        view.unpastedDragTypes = [TabDrag.typeIdentifier]
        surface.sizeFollowsStream = backend.sizeFollowsStream
        terminal.answersQueries = !backend.hostAnswersQueries
        surface.onGridChange = { [weak self] grid in self?.gridChanged(grid) }
        // Hold ⌃⌥Space to dictate into this pane (VoiceDictation).
        view.keyInterceptor = { [weak self] event in self.map { VoiceDictation.shared.handleKey(event, pane: $0) } ?? false }

        // A program can set its title or ring the bell hundreds of thousands of times a second:
        // each kind reaches the main actor at most once per turn, and the bell at most every
        // `bellInterval`.
        let title = MainActorCoalescer { [weak self] in self?.refreshTitle() }
        let pwd = MainActorCoalescer { [weak self] in self?.refreshWorkingDirectory() }
        let bell = MainActorCoalescer { [weak self] in self?.bellRang() }
        var events = Terminal.Events()
        events.titleChanged = { title.signal() }
        events.pwdChanged = { pwd.signal() }
        events.bell = { bell.signal() }
        terminal.setEvents(events)

        if let feed = backend as? any PredictionFeed {
            // Keystrokes carry the predictor's input sequence number, which the backend acks.
            surface.enablePrediction()
            view.onInput = { [weak self, weak surface] bytes in
                self?.moves += 1
                let seq = surface?.predictor?.lastInputSeq ?? 0
                bytes.withUnsafeBytes { feed.writeInput($0, inputSeq: seq) }
            }
            feed.startPredictionFeed { [weak surface] update in
                Task { @MainActor in surface?.applyPrediction(update) }
            }
        }
        let daemon = backend as? DaemonPaneBackend
        if let saved, let screen = saved.screen, let daemon, !daemon.isLive {
            showSaved(screen, saved: saved, on: terminal, holdingInputOf: daemon)
        }
        let cellPixels = cellPixels
        let generation = outputGeneration
        let savedShown = savedScreenShown
        // The host's own screen replaced the saved one (checked without a lock hop per output).
        let leaveSaved: @Sendable () -> Void = { [weak self] in
            guard savedShown.withLock({ $0 }), daemon?.isLive == true else { return }
            savedShown.withLock { $0 = false }
            Task { @MainActor in self?.showsSavedScreen = false }
        }
        let handle: @Sendable (PaneEvent) -> Void = { [weak self] event in
            switch event {
            case .output, .snapshot: generation.withLock { $0 += 1 }
            default: break
            }
            switch event {
            case .output(let data):
                data.withUnsafeBytes { terminal.write($0) }
                surface.outputArrived()
                leaveSaved()
            case .snapshot(let ready):
                // Resume after a gap or first attach: the daemon's state replaces ours. A bad
                // snapshot keeps what is on screen (stale beats blank) and is logged.
                do {
                    try terminal.restore(snapshot: ready)
                    let size = terminal.size
                    Pane.log.debug("snapshot restored \(size.cols)x\(size.rows)")
                } catch {
                    Pane.log.error("snapshot restore failed: \(String(describing: error), privacy: .public)")
                }
                surface.outputArrived()
                leaveSaved()
            case .history(let records, _):
                _ = try? terminal.appendHistory(records)
                surface.outputArrived()
            case .resized(let cols, let rows, let cellWidth, let cellHeight):
                // The remote PTY changed size at this point of the stream: follow it here, in
                // order with the output around it, so the bytes after it lay out as they did
                // there; in the host's cells, so images move the cursor as they did there too.
                let local = cellPixels.withLock { $0 }
                Pane.log.debug("remote resize \(cols)x\(rows)")
                terminal.resize(
                    cols: cols, rows: rows,
                    cellWidth: cellWidth > 0 ? cellWidth : local.width, cellHeight: cellHeight > 0 ? cellHeight : local.height)
                surface.outputArrived()
            case .connection(let state):
                Task { @MainActor in self?.connection = state }
            case .exited:
                onExit()
            }
        }
        if let shared = backend as? any SharedPaneTap {
            // Another window may show this pane already: start from its terminal, and let
            // windows opened later start from this one.
            shared.start(events: handle) { [weak terminal] in terminal?.seedEvents() ?? [] }
        } else {
            backend.start(events: handle)
        }
        // Scrolling to the top of what the pane holds asks the host for older scrollback.
        surface.onScroll = { [weak self, weak surface] rows in
            self?.moves += 1
            guard rows < 0, let terminal = surface?.terminal, terminal.scrollbar.offset == 0 else { return }
            _ = backend.requestHistory()
        }
        if let program = backend as? any ForegroundProgramReporting {
            program.onForegroundProgramChange { [weak self] name in
                Task { @MainActor in
                    self?.foregroundProgram = name
                    self?.onContextChange?()
                }
            }
        }
    }

    /// Draws the saved screen (and a little scrollback, scrolled where it was) and holds input
    /// until the host's screen replaces it.
    private func showSaved(_ screen: Data, saved: CachedPane, on terminal: Terminal, holdingInputOf daemon: DaemonPaneBackend) {
        do {
            try terminal.restore(snapshot: screen)
        } catch {
            Pane.log.error("saved screen unreadable: \(String(describing: error), privacy: .public)")
            return
        }
        _ = try? terminal.appendHistory(saved.history)
        if saved.scrolledBack > 0 { terminal.scrollViewport(by: -saved.scrolledBack) }
        showsSavedScreen = true
        savedScreenShown.withLock { $0 = true }
        daemon.holdInputUntilLive(screen: { [weak terminal] in terminal?.visibleText() ?? "" }) { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.heldInput = state == .sent ? nil : state
                if state == .dropped {
                    self.onHeldInputDropped?()
                    try? await Task.sleep(for: .seconds(3))
                    if self.heldInput == .dropped { self.heldInput = nil }
                }
            }
        }
    }

    func foreground() -> PaneForeground? {
        backend.foreground()
    }

    func terminate() {
        backend.terminate()
    }

    /// The window closed; the pane stays in its host's layout (other windows, later windows).
    func detach() {
        if let shared = backend as? any SharedPaneTap { shared.detach() } else { backend.terminate() }
    }

    /// This window's view of the pane drives its size (it took focus): the PTY follows it.
    func claimSize() {
        (backend as? any SharedPaneTap)?.claimSize()
    }

    @ObservationIgnored private var lastBell: ContinuousClock.Instant?
    static let bellInterval = Duration.milliseconds(100)

    private func bellRang() {
        let now = ContinuousClock.now
        if let lastBell, now - lastBell < Self.bellInterval { return }
        lastBell = now
        view.ringBell()
        onBell?()
    }

    private func refreshTitle() {
        let title = view.surface.terminal.title
        guard title != self.title else { return }
        self.title = title
        onContextChange?()
    }

    private func refreshWorkingDirectory() {
        let pwd = view.surface.terminal.pwd
        workingDirectory = ProjectNaming.directory(fromOSC7: pwd) ?? ""
    }

    private func gridChanged(_ grid: TerminalSurface.Grid) {
        cellPixels.withLock { $0 = (grid.cellWidth, grid.cellHeight) }
        onGridChange?(grid)
        if let size = view.surface.cellSize { onCellSize?(size) }
        // With the grid, as Ghostty does: the surface already coalesced layout into grid
        // changes, and a program redrawing after SIGWINCH must find the grid it was told of.
        resizesSent += 1
        backend.resize(cols: grid.cols, rows: grid.rows, cellWidth: grid.cellWidth, cellHeight: grid.cellHeight)
    }
}
