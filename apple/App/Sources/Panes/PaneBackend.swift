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
    /// The foreground program and its working directory, for titles until the terminal reports
    /// OSC 0/2 titles and OSC 7 directories. Polled about once a second; keep it cheap.
    func foreground() -> PaneForeground?
}

extension PaneBackend {
    func foreground() -> PaneForeground? { nil }
}

/// What runs in a pane right now.
nonisolated struct PaneForeground: Equatable, Sendable {
    /// Executable name, e.g. `zsh`, `nvim`, `claude`.
    var program: String
    /// Absolute working directory.
    var directory: String?

    static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "nu", "elvish", "xonsh", "-zsh", "-bash", "login"]

    var isShell: Bool { Self.shells.contains(program) }

    /// The directory with the home directory as `~`.
    var shortDirectory: String? {
        guard let directory else { return nil }
        let home = NSHomeDirectory()
        if directory == home { return "~" }
        if directory.hasPrefix(home + "/") { return "~" + directory.dropFirst(home.count) }
        return directory
    }

    /// Ghostty's default title with shell integration: the directory at a prompt, the command
    /// while one runs.
    var title: String {
        if isShell { return shortDirectory ?? program }
        return program
    }
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
