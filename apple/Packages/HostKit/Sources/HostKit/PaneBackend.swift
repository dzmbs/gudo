import Foundation
import PaneLayout

/// Where a pane's bytes come from and go to. The UI only talks to this protocol: a local PTY
/// (macOS), a daemon pane (`DaemonPaneBackend`), a plain-SSH pane (`SshPaneBackend`) or the
/// iOS echo stand-in all look the same to a `Pane`.
///
/// Byte-stream backends implement `start(onOutput:onExit:)`; remote backends implement
/// `start(events:)`, which also carries snapshots, history, in-band resizes, connection state
/// and echo-prediction facts. Each has a default in terms of the other, so a `Pane` always
/// calls `start(events:)`.
nonisolated public protocol PaneBackend: Sendable {
    /// Starts delivering output. `onOutput` may run on any thread, once per chunk; `onExit` runs
    /// once when the pane's process ends.
    func start(
        onOutput: @escaping @Sendable (UnsafeRawBufferPointer) -> Void,
        onExit: @escaping @Sendable () -> Void)
    /// Starts delivering `PaneEvent`s, in order, on any thread (never concurrently).
    func start(events: @escaping @Sendable (PaneEvent) -> Void)
    /// Input for the pane's process: encoded keys and terminal query replies. Callable from any thread.
    func write(_ bytes: UnsafeRawBufferPointer)
    /// Pasted text. Remote backends let the host apply bracketed-paste rules for the program's
    /// modes (docs/DAEMON.md "Input encoding"); the default sends the bytes as typed.
    func paste(_ text: String)
    func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32)
    /// Asks for scrollback older than what the pane holds (the user scrolled to the top). Answers
    /// arrive as `.history`. Returns false when there is nothing (more) to fetch.
    func requestHistory() -> Bool
    /// Ends the pane's process (local backends) or stops following it (remote ones: closing a
    /// remote pane is a layout op); called when the pane leaves the layout.
    func terminate()
}

nonisolated extension PaneBackend {
    public func start(
        onOutput: @escaping @Sendable (UnsafeRawBufferPointer) -> Void,
        onExit: @escaping @Sendable () -> Void
    ) {
        start { event in
            switch event {
            case .output(let data): data.withUnsafeBytes(onOutput)
            case .exited: onExit()
            default: break
            }
        }
    }

    public func start(events: @escaping @Sendable (PaneEvent) -> Void) {
        start(onOutput: { events(.output(Data($0))) }, onExit: { events(.exited) })
    }

    public func paste(_ text: String) {
        Array(text.utf8).withUnsafeBytes { write($0) }
    }

    public func requestHistory() -> Bool { false }
}

/// Everything a backend tells its pane, in stream order.
nonisolated public enum PaneEvent: Sendable, Equatable {
    /// Raw output for the VT.
    case output(Data)
    /// Replace the VT with this Ghostty snapshot's READY section (resume after a gap, first
    /// attach); scrollback older than it comes later as `.history`.
    case snapshot(Data)
    /// Older scrollback records for the last snapshot; `done` when there is no more.
    case history(Data, done: Bool)
    /// The remote PTY changed size at this point of the stream.
    case resized(cols: UInt16, rows: UInt16)
    /// Whether the pane is live, or showing stale content while its connection recovers
    /// (dimmed, never blank: 04-mobile-ux C3, R12).
    case connection(PaneConnection)
    case echo(EchoState)
    /// Input was written to the remote PTY; `rtt` is the time from sending it.
    case inputAck(atSeq: UInt64, rtt: Duration?)
    /// The pane's process ended (local backends; remote panes leave the layout instead).
    case exited
}

/// A pane's connection as its view shows it.
nonisolated public enum PaneConnection: Sendable, Equatable {
    case live
    /// Content is from before the connection dropped; input may be refused. `reason` is for
    /// the overlay.
    case stale(reason: String)
}

/// Termios and shell facts the host reports for a pane, tagged with the output offset they
/// hold from. A prediction engine (TerminalKit's echo prediction) predicts only when
/// `predict` is true: cooked mode with echo, or raw mode at a shell prompt; never at password
/// prompts or in full-screen programs.
nonisolated public struct EchoState: Sendable, Equatable {
    public var echo: Bool
    public var canonical: Bool
    public var alternateScreen: Bool
    public var atPrompt: Bool
    public var predict: Bool
    public var atSeq: UInt64

    public init(echo: Bool, canonical: Bool, alternateScreen: Bool, atPrompt: Bool, predict: Bool, atSeq: UInt64) {
        self.echo = echo
        self.canonical = canonical
        self.alternateScreen = alternateScreen
        self.atPrompt = atPrompt
        self.predict = predict
        self.atSeq = atSeq
    }
}

/// What an echo-prediction engine needs from the data layer. A `Pane` forwards `.echo`,
/// `.inputAck` and RTT updates here; the TerminalKit prediction engine adopts it (or an
/// adapter does) when it lands.
nonisolated public protocol EchoPredictionSink: AnyObject, Sendable {
    func echoStateChanged(_ state: EchoState)
    /// The host has written input up to here; predictions older than `atSeq` are confirmed or
    /// wrong.
    func inputAcknowledged(atSeq: UInt64)
    /// Smoothed keystroke round trip to the host (nil while unknown).
    func roundTripChanged(_ rtt: Duration?)
}
