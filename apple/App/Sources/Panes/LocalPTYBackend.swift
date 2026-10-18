#if os(macOS)
import Foundation
import LocalPTY

/// The user's login shell on a local PTY.
nonisolated final class LocalPTYBackend: PaneBackend {
    /// Internal (not private) so debug tooling can find the shell's pid.
    let pty: PTY

    init() throws {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = Brand.name
        let shell = environment["SHELL"] ?? "/bin/zsh"
        pty = try PTY(
            argv: [shell, "-l"], environment: environment, workingDirectory: NSHomeDirectory(), cols: 80, rows: 24)
    }

    func start(
        onOutput: @escaping @Sendable (UnsafeRawBufferPointer) -> Void,
        onExit: @escaping @Sendable () -> Void
    ) {
        pty.start(onOutput: onOutput, onExit: onExit)
    }

    func write(_ bytes: UnsafeRawBufferPointer) {
        pty.write(bytes)
    }

    func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {
        pty.resize(
            cols: cols, rows: rows,
            pixelWidth: UInt16(clamping: UInt32(cols) * cellWidth),
            pixelHeight: UInt16(clamping: UInt32(rows) * cellHeight))
    }

    func terminate() {
        pty.terminate()
    }
}
#endif
