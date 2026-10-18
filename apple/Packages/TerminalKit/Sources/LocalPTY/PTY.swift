import Darwin
import Foundation

/// A local pseudo-terminal running one child process. macOS only: on iOS the PTY lives in the
/// host daemon and bytes arrive over the network.
public final class PTY: Sendable {
    public let fd: Int32
    public let pid: pid_t
    private let reader: DispatchSourceRead

    /// Spawns `argv` as a session leader whose controlling terminal is the PTY's slave side.
    /// Output is not read until `start(onOutput:onExit:)`.
    public init(argv: [String], environment: [String: String], cols: UInt16, rows: UInt16) throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let slaveName = ptsname(master) else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)

        var attributes = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // setsid() runs before the file actions, so opening the slave makes it the controlling tty.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, slaveName, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)

        let cArgv = argv.map { strdup($0) } + [nil]
        let cEnv = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (cArgv + cEnv).forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, argv[0], &actions, &attributes, cArgv, cEnv)
        guard status == 0 else {
            close(master)
            throw POSIXError(.init(rawValue: status) ?? .EIO)
        }
        self.fd = master
        self.pid = pid

        reader = DispatchSource.makeReadSource(fileDescriptor: master, queue: DispatchQueue(label: "pty.read", qos: .userInteractive))
    }

    /// Starts reading. `onOutput` runs on a background queue for every chunk; `onExit` once at EOF.
    public func start(
        onOutput: @escaping @Sendable (UnsafeRawBufferPointer) -> Void,
        onExit: @escaping @Sendable () -> Void
    ) {
        let master = fd
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 1024, alignment: 1)
        reader.setEventHandler { [reader] in
            let n = read(master, buffer.baseAddress, buffer.count)
            if n > 0 {
                onOutput(UnsafeRawBufferPointer(rebasing: buffer[0..<n]))
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
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
            let n = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return
            }
            offset += n
        }
    }

    public func resize(cols: UInt16, rows: UInt16, pixelWidth: UInt16, pixelHeight: UInt16) {
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: pixelWidth, ws_ypixel: pixelHeight)
        _ = ioctl(fd, TIOCSWINSZ, &size)
    }
}
