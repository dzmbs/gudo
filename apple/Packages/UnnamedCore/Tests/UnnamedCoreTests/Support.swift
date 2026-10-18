import Foundation
import Synchronization
import Testing
import UnnamedCore

/// The repository root (this file is apple/Packages/UnnamedCore/Tests/UnnamedCoreTests/…).
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

struct TestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Records every event; tests poll it.
final class Recorder: ClientEventListener {
    private let events = Mutex<[ClientEvent]>([])

    func onEvent(event: ClientEvent) {
        events.withLock { $0.append(event) }
    }

    var all: [ClientEvent] { events.withLock { $0 } }

    /// Everything a pane printed so far (`PaneBytes` only), lossily decoded.
    func output(of pane: UInt64) -> String {
        var data = Data()
        for case let .paneBytes(paneId, _, bytes) in all where paneId == pane {
            data.append(bytes)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Polls until `match` finds something in the events so far.
    @discardableResult
    func wait<T>(
        _ what: String,
        timeout: Duration = .seconds(20),
        _ match: ([ClientEvent]) -> T?
    ) async throws -> T {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let found = match(all) { return found }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestError("timed out waiting for \(what); events: \(all.suffix(10))")
    }
}

/// Ignores events (to time the FFI crossing alone).
final class Discard: ClientEventListener {
    func onEvent(event: ClientEvent) {}
}

/// Touches each event the way a renderer feeding its VT would (switch, read the payload).
final class Touch: ClientEventListener {
    private let total = Atomic<Int>(0)

    func onEvent(event: ClientEvent) {
        if case let .paneBytes(_, _, data) = event {
            total.add(data.count, ordering: .relaxed)
        }
    }

    var bytes: Int { total.load(ordering: .relaxed) }
}

/// Runs a program and returns its standard output.
func runProgram(_ executable: URL, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw TestError("\(executable.lastPathComponent) \(arguments) exited \(process.terminationStatus)")
    }
    return String(decoding: data, as: UTF8.self)
}

/// A local `unnamed-hostd` with relays off, in a temporary state directory, as
/// crates/client-core's tests run the daemon. Build it first: `cargo build -p hostd`
/// (or point `UN_HOSTD_BIN` at a build).
final class LocalDaemon {
    let binary: URL
    let stateDir: URL
    let process = Process()

    init() throws {
        let env = ProcessInfo.processInfo.environment
        binary = env["UN_HOSTD_BIN"].map(URL.init(fileURLWithPath:))
            ?? repoRoot.appending(path: "target/debug/unnamed-hostd")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw TestError("no daemon at \(binary.path): run `cargo build -p hostd` first")
        }
        stateDir = FileManager.default.temporaryDirectory
            .appending(path: "un-swift-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        process.executableURL = binary
        process.arguments = [
            "--state-dir", stateDir.path, "run",
            "--no-relay", "--bind", "127.0.0.1:0", "--shell", "/bin/sh",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// A pairing ticket, once the daemon has recorded its endpoint.
    func ticket() async throws -> String {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            // `pair` fails until the daemon has written its keys.
            let json = (try? runProgram(binary, ["--state-dir", stateDir.path, "pair", "--json"])) ?? "{}"
            if let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
               object["running"] as? Bool == true,
               let addrs = object["addrs"] as? [Any], !addrs.isEmpty,
               let ticket = object["ticket"] as? String
            {
                return ticket
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw TestError("the daemon did not come up")
    }

    deinit {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: stateDir)
    }
}

/// Attaches and returns the focused pane of the first tab, subscribed.
func attachFirstPane(_ client: DaemonClient, _ events: Recorder) async throws -> UInt64 {
    try await events.wait("connected") { all in
        all.first { if case .connected = $0 { true } else { false } }
    }
    client.attach(sessionId: nil)
    let layout = try await events.wait("layout") { all in
        all.lazy.compactMap { if case let .layout(layout) = $0 { layout } else { nil } }.first
    }
    let pane = try #require(layout.tabs.first).focused
    client.subscribe(paneId: pane)
    client.setView(focused: pane, visible: [pane])
    client.resize(paneId: pane, size: PaneSize(cols: 80, rows: 24))
    return pane
}
