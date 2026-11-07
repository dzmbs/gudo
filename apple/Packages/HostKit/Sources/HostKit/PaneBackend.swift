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
    /// Generated terminal reports, which do not claim a shared terminal's size.
    func writeGenerated(_ bytes: UnsafeRawBufferPointer)
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
    /// A VT on the host answers the program's queries (the daemon's): the pane's own terminal
    /// must not answer them again. False where the pane's terminal is the only one (SSH, local).
    var hostAnswersQueries: Bool { get }
    /// The kitty image storage per screen of the host's VT, which the pane's terminal must
    /// share (`Terminal.kittyImageStorageLimit`); nil where the pane's terminal is the only one.
    /// Read before each snapshot is restored.
    var kittyImageStorageLimit: UInt64? { get }
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

    public func writeGenerated(_ bytes: UnsafeRawBufferPointer) { write(bytes) }

    public func paste(_ text: String) {
        Array(text.utf8).withUnsafeBytes { write($0) }
    }

    public func requestHistory() -> Bool { false }

    public var sizeFollowsStream: Bool { false }

    public var hostAnswersQueries: Bool { false }

    public var kittyImageStorageLimit: UInt64? { nil }

    public func foreground() -> PaneForeground? { nil }
}

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

    /// The directory at a prompt, the command while one runs.
    public var title: String {
        if isShell { return shortDirectory ?? program }
        return program
    }
}

/// Remote screen events follow stream order; local sizing notifications carry no VT state.
nonisolated public enum PaneEvent: Sendable, Equatable {
    /// Raw output for the VT.
    case output(Data)
    /// Replace the VT with this Ghostty snapshot's READY section (resume after a gap, first
    /// attach); scrollback older than it comes later as `.history`.
    case snapshot(Data)
    /// Older scrollback records for the last snapshot; `done` when there is no more.
    case history(Data, done: Bool)
    /// The remote PTY changed size at this point of the stream, with the cell size in pixels
    /// its host lays kitty images out in (0 when unknown).
    case resized(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32)
    /// Whether the pane is live, or showing stale content while its connection recovers
    /// (dimmed, never blank).
    case connection(PaneConnection)
    /// The pane's process ended (local backends; remote panes leave the layout instead).
    case exited
    /// A different local window drives sizing, even if the shared grid did not change.
    case sizingChanged
}

/// A pane's connection as its view shows it.
nonisolated public enum PaneConnection: Sendable, Equatable {
    case live
    /// Content is from before the connection dropped; input may be refused. `reason` is for
    /// the overlay.
    case stale(reason: String)
}

/// A backend that can feed the client's echo predictor: the daemon
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

/// A backend one pane shares between windows (docs/APP-ARCHITECTURE.md "Windows"): each window's
/// `Pane` has its own terminal and its own instance of this (a tap), all on one stream.
nonisolated public protocol SharedPaneTap: PaneBackend {
    /// Starts like `start(events:)`. A tap that starts while others of the pane run begins from
    /// one of their terminals (their `seed`), then follows the stream with them; `seed` is how
    /// to copy this tap's terminal for taps that start later (`Terminal.seedEvents()`).
    func start(events: @escaping @Sendable (PaneEvent) -> Void, seed: (@Sendable () -> [PaneEvent])?)
    /// This tap's window drives the pane's size now (it took focus); typing claims it too.
    func claimSize()
    func useSize()
    /// The window closed but the pane stays in the layout: stop following it without ending
    /// its process (the default ends it, like `terminate`).
    func detach()
}

nonisolated extension SharedPaneTap {
    public func detach() { terminate() }
    public func useSize() { claimSize() }
}

nonisolated extension Terminal {
    /// This terminal as the events that rebuild it elsewhere: its snapshot (screens, modes,
    /// cursor) and then its whole scrollback. Seeds a window's terminal from another's.
    public func seedEvents() -> [PaneEvent] {
        guard let snapshot = encodeSnapshot(), let (ready, history) = Terminal.splitSnapshot(snapshot) else { return [] }
        return [.snapshot(ready), .history(history, done: true)]
    }
}
