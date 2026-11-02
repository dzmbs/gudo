import CPTYSpawn
import Darwin
import Foundation

/// A local pseudo-terminal running one child process. macOS only: on iOS the PTY lives in the
/// host daemon and bytes arrive over the network.
public final class PTY: Sendable {
    public let fd: Int32
    public let pid: pid_t
    private let reader: DispatchSourceRead
    private let reaper: DispatchSourceProcess

    /// Spawns `argv` as a session leader whose controlling terminal is the PTY's slave side (so ^C
    /// and ^Z become signals), in `workingDirectory` if given. Output is not read until `start(onOutput:onExit:)`.
    public init(
        argv: [String], environment: [String: String], workingDirectory: String? = nil, cols: UInt16, rows: UInt16
    ) throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let slaveName = ptsname(master) else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)

        let cArgv = argv.map { strdup($0) } + [nil]
        let cEnv = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let cwd = workingDirectory.map { strdup($0) } ?? nil
        defer { (cArgv + cEnv + [cwd]).forEach { free($0) } }
        let pid = un_pty_spawn(slaveName, argv[0], cArgv, cEnv, cwd)
        guard pid > 0 else {
            let error = errno
            close(master)
            throw POSIXError(.init(rawValue: error) ?? .EIO)
        }
        // The child closed its copy; keep the master out of any later children.
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        self.fd = master
        self.pid = pid

        reader = DispatchSource.makeReadSource(fileDescriptor: master, queue: DispatchQueue(label: "pty.read", qos: .userInteractive))
        // Reap the child when it exits so it does not linger as a zombie.
        reaper = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        reaper.setEventHandler { [reaper] in
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            reaper.cancel()
        }
        reaper.resume()
    }

    /// Hangs up the child (SIGHUP), as closing a terminal window does. Output ends with EOF.
    public func terminate() {
        kill(pid, SIGHUP)
    }

    /// Starts reading. `onOutput` runs on a background queue for every chunk; `onExit` once at EOF.
    public func start(
        onOutput: @escaping @Sendable (UnsafeRawBufferPointer) -> Void,
        onExit: @escaping @Sendable () -> Void
    ) {
        let master = fd
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 1024, alignment: 1)
        reader.setEventHandler { [reader] in
            let count = read(master, buffer.baseAddress, buffer.count)
            if count > 0 {
                onOutput(UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                reader.cancel()
            }
        }
        reader.setCancelHandler {
            buffer.deallocate()
            close(master)
            onExit()
        }
        reader.resume()
    }

    public func write(_ bytes: UnsafeRawBufferPointer) {
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return
            }
            offset += count
        }
    }

    public func resize(cols: UInt16, rows: UInt16, pixelWidth: UInt16, pixelHeight: UInt16) {
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: pixelWidth, ws_ypixel: pixelHeight)
        _ = ioctl(fd, TIOCSWINSZ, &size)
    }
}
