import Foundation
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
    /// The grid's cell size in pixels, for resizes that follow the stream (off the main actor).
    nonisolated let cellPixels = OSAllocatedUnfairLock<(width: UInt32, height: UInt32)>(initialState: (0, 0))

    init(id: PaneId, backend: any PaneBackend, appearance: TerminalAppearance = .init(), onExit: @escaping @Sendable () -> Void) throws {
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
        surface.onGridChange = { [weak self] grid in self?.gridChanged(grid) }
        // Hold ⌃⌥Space to dictate into this pane (VoiceDictation).
        view.keyInterceptor = { [weak self] event in self.map { VoiceDictation.shared.handleKey(event, pane: $0) } ?? false }

        var events = Terminal.Events()
        events.titleChanged = { [weak self] in Task { @MainActor in self?.refreshTitle() } }
        events.pwdChanged = { [weak self] in Task { @MainActor in self?.refreshWorkingDirectory() } }
        events.bell = { [weak self] in
            Task { @MainActor in
                self?.view.ringBell()
                self?.onBell?()
            }
        }
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
        let cellPixels = cellPixels
        let handle: @Sendable (PaneEvent) -> Void = { [weak self] event in
            switch event {
            case .output(let data):
                data.withUnsafeBytes { terminal.write($0) }
                surface.outputArrived()
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
            case .history(let records, _):
                _ = try? terminal.appendHistory(records)
                surface.outputArrived()
            case .resized(let cols, let rows):
                // The remote PTY changed size at this point of the stream: follow it here, in
                // order with the output around it, so the bytes after it lay out as they did there.
                let cell = cellPixels.withLock { $0 }
                Pane.log.debug("remote resize \(cols)x\(rows)")
                terminal.resize(cols: cols, rows: rows, cellWidth: cell.width, cellHeight: cell.height)
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

    private func refreshTitle() {
        let title = view.surface.terminal.title
        guard title != self.title else { return }
        self.title = title
        onContextChange?()
    }

    private func refreshWorkingDirectory() {
        let pwd = view.surface.terminal.pwd
        workingDirectory = URL(string: pwd).flatMap { $0.isFileURL ? $0.path : nil } ?? pwd
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
