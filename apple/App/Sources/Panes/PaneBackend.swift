import Foundation
import PaneLayout

/// Where a pane's bytes come from and go to. The UI only talks to this protocol, so the daemon
/// connection replaces today's local backends without UI changes.
nonisolated protocol PaneBackend: Sendable {
    /// Starts delivering output. `onOutput` may run on any thread, once per chunk; `onExit` runs
    /// once when the pane's process ends.
    func start(
        onOutput: @escaping @Sendable (UnsafeRawBufferPointer) -> Void,
        onExit: @escaping @Sendable () -> Void)
    /// Input for the pane's process: encoded keys and terminal query replies. Callable from any thread.
    func write(_ bytes: UnsafeRawBufferPointer)
    func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32)
    /// Ends the pane's process; called when the pane is closed.
    func terminate()
}

/// The backend for new panes on this platform: a login shell on a local PTY on macOS, a local echo
/// on iOS until the daemon connection lands.
@MainActor
func makeLocalBackend(for pane: PaneId) throws -> any PaneBackend {
    #if os(macOS)
    try LocalPTYBackend()
    #else
    EchoBackend(pane: pane)
    #endif
}
