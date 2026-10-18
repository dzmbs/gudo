import Foundation
import Observation
import PaneLayout
import TerminalCore
import TerminalRenderer

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
    /// Called on the main actor after `title` or `foregroundProgram` change.
    @ObservationIgnored var onContextChange: (() -> Void)?
    /// The cell size in points after a layout (split sizes snap to it).
    @ObservationIgnored var onCellSize: ((CGSize) -> Void)?

    @ObservationIgnored let backend: any PaneBackend
    @ObservationIgnored private var appliedGrid: TerminalSurface.Grid?
    @ObservationIgnored private var resizeTask: Task<Void, Never>?

    /// PTY resizes (SIGWINCH) are debounced so a divider drag does not make TUIs redraw on every
    /// frame (04-mobile-ux C3).
    private static let resizeDebounce = Duration.milliseconds(80)

    init(id: PaneId, backend: any PaneBackend, appearance: TerminalAppearance = .init(), onExit: @escaping @Sendable () -> Void) throws {
        self.id = id
        self.backend = backend
        let terminal = Terminal(cols: 80, rows: 24, configuration: appearance.terminalConfiguration) { backend.write($0) }
        let surface = try TerminalSurface(terminal: terminal, appearance: appearance)
        view = TerminalView(surface: surface)
        view.onInput = { bytes in bytes.withUnsafeBytes { backend.write($0) } }
        surface.onGridChange = { [weak self] grid in self?.gridChanged(grid) }

        var events = Terminal.Events()
        events.titleChanged = { [weak self] in Task { @MainActor in self?.refreshTitle() } }
        events.pwdChanged = { [weak self] in Task { @MainActor in self?.refreshWorkingDirectory() } }
        events.bell = { [weak self] in Task { @MainActor in self?.view.ringBell() } }
        terminal.setEvents(events)

        if let feed = backend as? any PredictionFeed {
            // Keystrokes carry the predictor's input sequence number, which the backend acks.
            surface.enablePrediction()
            view.onInput = { [weak surface] bytes in
                let seq = surface?.predictor?.lastInputSeq ?? 0
                bytes.withUnsafeBytes { feed.writeInput($0, inputSeq: seq) }
            }
            feed.startPredictionFeed { [weak surface] update in
                Task { @MainActor in surface?.applyPrediction(update) }
            }
        }
        backend.start(
            onOutput: { bytes in
                terminal.write(bytes)
                surface.outputArrived()
            },
            onExit: onExit)
        if let program = backend as? any ForegroundProgramReporting {
            program.onForegroundProgramChange { [weak self] name in
                Task { @MainActor in
                    self?.foregroundProgram = name
                    self?.onContextChange?()
                }
            }
        }
    }

    func terminate() {
        resizeTask?.cancel()
        backend.terminate()
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
        if let size = view.surface.cellSize { onCellSize?(size) }
        resizeTask?.cancel()
        // The first layout applies at once, so the shell starts at the real size.
        guard appliedGrid != nil else { return applyGrid(grid) }
        resizeTask = Task { [weak self] in
            guard (try? await Task.sleep(for: Self.resizeDebounce)) != nil else { return }
            self?.applyGrid(grid)
        }
    }

    private func applyGrid(_ grid: TerminalSurface.Grid) {
        appliedGrid = grid
        backend.resize(cols: grid.cols, rows: grid.rows, cellWidth: grid.cellWidth, cellHeight: grid.cellHeight)
    }
}
