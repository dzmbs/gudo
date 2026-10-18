import Foundation
import PaneLayout
import TerminalCore
import TerminalRenderer

/// One live terminal: the VT state, its renderer surface and host view, and the backend that feeds
/// it. The view is created once and moved between parents as the split tree changes, so a split,
/// zoom or tab switch never re-creates the surface or loses scrollback.
final class Pane {
    let id: PaneId
    let view: TerminalView
    /// SwiftUI host containers showing this pane (see `TerminalHost`).
    let hosts = NSHashTable<TerminalHost.Container>.weakObjects()
    private let backend: any PaneBackend
    private var appliedGrid: TerminalSurface.Grid?
    private var resizeTask: Task<Void, Never>?
    /// Every grid change, undebounced, for the cols × rows overlay.
    var onGridChange: ((TerminalSurface.Grid) -> Void)?

    /// PTY resizes (SIGWINCH) are debounced so a divider drag does not make TUIs redraw on every
    /// frame (04-mobile-ux C3).
    private static let resizeDebounce = Duration.milliseconds(80)

    init(id: PaneId, backend: any PaneBackend, onExit: @escaping @Sendable () -> Void) throws {
        self.id = id
        self.backend = backend
        let terminal = Terminal(cols: 80, rows: 24) { backend.write($0) }
        let surface = try TerminalSurface(terminal: terminal)
        view = TerminalView(surface: surface)
        view.onInput = { bytes in bytes.withUnsafeBytes { backend.write($0) } }
        surface.onGridChange = { [weak self] grid in self?.gridChanged(grid) }
        backend.start(
            onOutput: { bytes in
                terminal.write(bytes)
                surface.setNeedsRender()
            },
            onExit: onExit)
    }

    func foreground() -> PaneForeground? {
        backend.foreground()
    }

    func terminate() {
        resizeTask?.cancel()
        backend.terminate()
    }

    private func gridChanged(_ grid: TerminalSurface.Grid) {
        onGridChange?(grid)
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
