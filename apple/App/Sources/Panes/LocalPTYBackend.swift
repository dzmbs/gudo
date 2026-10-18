#if os(macOS)
import Darwin
import Foundation
import LocalPTY

/// The user's login shell on a local PTY.
nonisolated final class LocalPTYBackend: PaneBackend {
    private let pty: PTY

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

    /// The terminal's foreground process group leader and its cwd, straight from the kernel.
    func foreground() -> PaneForeground? {
        let group = tcgetpgrp(pty.fd)
        let pid = group > 0 ? group : pty.pid
        var name = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let directory: String? = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size
            ? withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            : nil
        return PaneForeground(program: String(cString: name), directory: directory)
    }
}
#endif
