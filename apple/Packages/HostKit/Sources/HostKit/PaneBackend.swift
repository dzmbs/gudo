import Foundation
import PaneLayout
import TerminalCore

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
    /// The foreground program and its working directory, for titles until the terminal reports
    /// OSC 0/2 titles and OSC 7 directories. Polled about once a second; keep it cheap.
    func foreground() -> PaneForeground?
    /// The terminal takes its size from the stream (`.resized` events, where the remote PTY
    /// changed size), never from the view's layout: output in flight was produced at the old
    /// size, and a shell's redraw at the wrong size wipes its prompt line. Local PTYs: false.
    var sizeFollowsStream: Bool { get }
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

    public var sizeFollowsStream: Bool { false }

    public func foreground() -> PaneForeground? { nil }
}

/// What runs in a pane right now.
nonisolated public struct PaneForeground: Equatable, Sendable {
    /// Executable name, e.g. `zsh`, `nvim`, `claude`.
    public var program: String
    /// Absolute working directory.
    public var directory: String?

    public init(program: String, directory: String?) {
        self.program = program
        self.directory = directory
    }

    public static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "nu", "elvish", "xonsh", "-zsh", "-bash", "login"]

    public var isShell: Bool { Self.shells.contains(program) }

    /// The directory with the home directory as `~`.
    public var shortDirectory: String? {
        guard let directory else { return nil }
        let home = NSHomeDirectory()
        if directory == home { return "~" }
        if directory.hasPrefix(home + "/") { return "~" + directory.dropFirst(home.count) }
        return directory
    }

    /// Ghostty's default title with shell integration: the directory at a prompt, the command
    /// while one runs.
    public var title: String {
        if isShell { return shortDirectory ?? program }
        return program
    }
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

/// reads ECHO/ICANON from the PTY master, knows the OSC 133 prompt state and the alt screen, acks
/// inputs and measures RTT. Optional: panes of backends without it never predict.
nonisolated public protocol PredictionFeed: PaneBackend {
    /// Starts delivering `.hint`, `.acknowledged` and `.rtt` updates (any thread). An ack for `seq`
    /// must come after the output produced by that input has been delivered.
    func startPredictionFeed(_ onUpdate: @escaping @Sendable (PredictionUpdate) -> Void)
    /// A user keystroke tagged with the predictor's input sequence number (acked later as
    /// `.acknowledged(upTo:)`). Other writes (query replies, pastes) go through `write(_:)`.
    func writeInput(_ bytes: UnsafeRawBufferPointer, inputSeq: UInt64)
}

/// A backend that knows the pane's foreground program (the daemon's foreground process group on
/// the PTY master), which picks the key bar profile. Without it the terminal title stands in.
nonisolated public protocol ForegroundProgramReporting: PaneBackend {
    /// `onChange` receives the program name (e.g. "vim", "claude"), or nil when unknown; any thread.
    func onForegroundProgramChange(_ onChange: @escaping @Sendable (String?) -> Void)
}
