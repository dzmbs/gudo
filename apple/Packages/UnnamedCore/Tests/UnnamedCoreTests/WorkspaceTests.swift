import Darwin
import Foundation
import Synchronization
import Testing
import UnnamedCore

/// Records multiplayer pushes; tests poll it.
final class MultiplayerRecorder: MultiplayerListener {
    private let events = Mutex<[MultiplayerEvent]>([])

    func onMultiplayerEvent(event: MultiplayerEvent) {
        events.withLock { $0.append(event) }
    }

    func wait<T>(_ what: String, _ match: ([MultiplayerEvent]) -> T?) async throws -> T {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if let found = match(events.withLock { $0 }) { return found }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestError("timed out waiting for \(what); events: \(events.withLock { $0 }.suffix(5))")
    }
}

/// A TCP echo server on 127.0.0.1 (blocking sockets on their own threads).
final class EchoServer: Sendable {
    let port: UInt16
    private let fd: Int32

    init() throws {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(sock, 16) == 0 else { throw TestError("echo server: bind/listen failed") }
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
        }
        port = UInt16(bigEndian: local.sin_port)
        fd = sock
        let listener = sock
        Thread.detachNewThread {
            while true {
                let conn = accept(listener, nil, nil)
                if conn < 0 { return }
                Thread.detachNewThread {
                    var buf = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let n = read(conn, &buf, buf.count)
                        if n <= 0 || write(conn, buf, n) != n { break }
                    }
                    close(conn)
                }
            }
        }
    }

    deinit { close(fd) }
}

/// Connects to `127.0.0.1:port`, sends `message` and reads as many bytes back.
func echoRoundTrip(port: UInt16, _ message: String) throws -> String {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { throw TestError("connect to \(port) failed") }
    let bytes = Array(message.utf8)
    guard write(fd, bytes, bytes.count) == bytes.count else { throw TestError("write failed") }
    var got = [UInt8]()
    var buf = [UInt8](repeating: 0, count: 4096)
    while got.count < bytes.count {
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { throw TestError("read failed after \(got.count) bytes") }
        got += buf[0..<n]
    }
    return String(decoding: got, as: UTF8.self)
}

private func config() -> ClientConfig {
    ClientConfig(secretKey: generateDeviceKey(), relay: .disabled, mirrorVt: true)
}

@Suite(.serialized) struct WorkspaceTests {
    @Test func forwardFilesAndInviteJoin() async throws {
        let daemon = try LocalDaemon(config: "[files]\nallow = [\"{state}\"]\n")
        let ticket = try await daemon.ticket()
        let events = Recorder()
        let owner = try DaemonClient.connect(ticket: ticket, config: config(), listener: events)
        let pane = try await attachFirstPane(owner, events)

        // Forward: a local port to an echo server "on the host" (this machine).
        let echo = try EchoServer()
        let local = try owner.forward(localPort: 0, target: .tcp(port: echo.port))
        #expect(local != 0)
        #expect(owner.forwards() == [ForwardInfo(localPort: local, target: .tcp(port: echo.port))])
        for round in 0..<3 {
            #expect(try echoRoundTrip(port: local, "ping \(round)") == "ping \(round)")
        }
        #expect(owner.stopForward(localPort: local))
        #expect(owner.forwards().isEmpty)

        // Files: list a directory the app does not own, typed errors outside the policy.
        let project = daemon.stateDir.appending(path: "project")
        try FileManager.default.createDirectory(at: project.appending(path: "src"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: project.appending(path: "README.md"))
        let listing = try await owner.fsList(path: project.path, showHidden: false)
        #expect(listing.entries.map(\.name) == ["src", "README.md"])
        #expect(listing.entries.map(\.kind) == [.dir, .file])
        let written = try await owner.fsWrite(
            target: WriteTarget(path: project.appending(path: "notes.txt").path, ifMatch: nil, createNew: true, mkdirs: false, mode: nil),
            data: Data("from swift".utf8)
        )
        #expect(written.size == 10)
        let chunk = try await owner.fsRead(path: written.path, offset: 5, len: 100)
        #expect(chunk.data == Data("swift".utf8))
        await #expect(throws: WorkspaceError.self) {
            try await owner.fsList(path: "/etc", showHidden: false)
        }

        // Invite a viewer, join with a second client: it is told who it is, and its keys
        // are refused.
        let invite = try await owner.createInvite(options: InviteOptions(
            roles: [.viewer], scope: .daemon, ttlSecs: 3600, maxUses: 1,
            delegate: false, label: "carol", inviter: "alice"
        ))
        #expect(invite.link.hasPrefix("unnamed://join/"))
        #expect(invite.qrPayload == invite.link.uppercased())
        #expect(try inspectInvite(invite: invite.qrPayload).roles == [.viewer])

        let guestEvents = Recorder()
        let guestMp = MultiplayerRecorder()
        let guest = try DaemonClient.join(invite: invite.link, config: config(), listener: guestEvents)
        guest.setMultiplayerListener(listener: guestMp)
        let me = try await guestMp.wait("joined") { all in
            all.lazy.compactMap { if case let .joined(info) = $0 { info } else { nil } }.first
        }
        #expect(me.roles == [.viewer])
        #expect(me.grantId == invite.grantId)
        let guestPane = try await attachFirstPane(guest, guestEvents)
        #expect(guestPane == pane)
        try await guestEvents.wait("snapshot") { all in
            all.first { if case .paneSnapshot = $0 { true } else { false } }
        }
        guest.sendInput(paneId: pane, data: Data("echo viewer\r".utf8))
        try await guestMp.wait("input refused") { all in
            all.first {
                if case let .inputRejected(paneId, reason) = $0 { paneId == pane && reason == .role } else { false }
            }
        }
        let participants = try await owner.participants()
        #expect(participants.count == 2)
    }
}
