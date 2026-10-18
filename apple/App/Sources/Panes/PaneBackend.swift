import Foundation
import PaneLayout
import TerminalCore

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

/// reads ECHO/ICANON from the PTY master, knows the OSC 133 prompt state and the alt screen, acks
/// inputs and measures RTT. Optional: panes of backends without it never predict.
nonisolated protocol PredictionFeed: PaneBackend {
    /// Starts delivering `.hint`, `.acknowledged` and `.rtt` updates (any thread). An ack for `seq`
    /// must come after the output produced by that input has been delivered through `onOutput`.
    func startPredictionFeed(_ onUpdate: @escaping @Sendable (PredictionUpdate) -> Void)
    /// A user keystroke tagged with the predictor's input sequence number (acked later as
    /// `.acknowledged(upTo:)`). Other writes (query replies, pastes) go through `write(_:)`.
    func writeInput(_ bytes: UnsafeRawBufferPointer, inputSeq: UInt64)
}

/// A backend that knows the pane's foreground program (the daemon's `tcgetpgrp` on the PTY master),
/// which picks the key bar profile. Without it the terminal title stands in.
nonisolated protocol ForegroundProgramReporting: PaneBackend {
    /// `onChange` receives the program name (e.g. "vim", "claude"), or nil when unknown; any thread.
    func onForegroundProgramChange(_ onChange: @escaping @Sendable (String?) -> Void)
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
